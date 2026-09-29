# Locate a wrong value at the first statement whose value differs between Julia and wasm.
#
# `first_divergence(f, args...)` compiles `f` traced (WasmTarget.compile_with_statement_trace:
# each statement of a traced type reports its value after it is stored), runs it in Node, and
# runs the SAME typed IR natively — the CodeInfo WT compiled, as an OpaqueClosure with a probe
# after each such statement — then walks both traces in execution order. The first statement
# whose values differ is where the wrong value first appears; it is reported with its text,
# its inline chain innermost first, the iteration, and both values. The IR run natively is
# also compared with `f` itself, which tells a codegen fault (the IR's native answer is
# Julia's, the wasm's is not) from a difference in the IR (an overlay, the collector's
# choice): there the traces agree and the IR's native answer is already the wasm's.
module TraceLocalize

using WasmTarget
using ..WasmRunner
const CC = Core.Compiler

const _NATIVE = Tuple{Int,String}[]

_bits(v::Int64)::String = string(v)
_bits(v::UInt64)::String = string(reinterpret(Int64, v))
_bits(v::Int32)::String = string(v)
_bits(v::Bool)::String = v ? "1" : "0"
_bits(v::Float64)::String = string(reinterpret(Int64, v))
_bits(v::Float32)::String = string(reinterpret(Int32, v))

@noinline _probe(i::Int, v)::Nothing = (push!(_NATIVE, (i, _bits(v))); nothing)

# a traced value's bits shown as the statement's Julia value (a float's bits are its value)
function _shown(T, bits::String)::String
    isempty(bits) && return "(none)"
    local n = tryparse(Int64, bits)
    n === nothing && return bits
    T === Float64 && return repr(reinterpret(Float64, n))
    T === Float32 && return repr(reinterpret(Float32, Int32(n)))
    T === UInt64 && return repr(reinterpret(UInt64, n))
    T === Bool && return bits == "1" ? "true" : "false"
    return bits
end

# the CodeInfo run natively with a probe after each statement of a traced type
function native_trace(code::Core.CodeInfo, mi::Core.MethodInstance, args::Tuple)
    local ir = CC.inflate_ir(code, mi)
    for i in 1:length(ir.stmts)
        local T = CC.widenconst(ir.stmts[i][:type])
        haskey(WasmTarget.TRACED_STATEMENT_TYPES, T) || continue
        local st = ir.stmts[i][:stmt]
        (st isa Core.PhiNode || st isa Core.GotoNode || st isa Core.GotoIfNot ||
         st isa Core.ReturnNode || st === nothing) && continue
        CC.insert_node!(ir, CC.SSAValue(i), CC.NewInstruction(Expr(:call, _probe, i, CC.SSAValue(i)), Nothing), true)
    end
    ir = CC.compact!(ir)
    ir.argtypes[1] = Tuple{}   # an opaque closure's first argument is its (empty) environment
    local oc = Core.OpaqueClosure(ir; do_compile=true)
    empty!(_NATIVE)
    local r = try
        (:ok, oc(args...))
    catch e
        (:throw, e)
    end
    return copy(_NATIVE), r
end

const _TRACE_JS = raw"""
const trace = [];
const f64bits = (x) => { const d = new DataView(new ArrayBuffer(8)); d.setFloat64(0, x); return d.getBigInt64(0).toString(); };
const f32bits = (x) => { const d = new DataView(new ArrayBuffer(4)); d.setFloat32(0, x); return String(d.getInt32(0)); };
const importObject = { wasmtarget: {
  trace_i32: (i, v) => { trace.push([i, String(v)]); },
  trace_i64: (i, v) => { trace.push([i, v.toString()]); },
  trace_f32: (i, v) => { trace.push([i, f32bits(v)]); },
  trace_f64: (i, v) => { trace.push([i, f64bits(v)]); },
  stack_trace: () => new Error() } };
const { instance } = await WebAssembly.instantiate(bytes, importObject, { builtins: ['js-string'] });
let outcome = 'returned';
try { instance.exports[FNAME](ARGS); } catch (e) { outcome = 'trapped: ' + String(e && e.message || e); }
return [{ trace, outcome }];
"""

# the wasm run's trace: (statement, value bits) in execution order, and how the call ended
function wasm_trace(bytes::Vector{UInt8}, fname::String, js_args::String)
    local src = replace(_TRACE_JS, "FNAME" => repr(fname), "ARGS" => js_args)
    local status, results = WasmRunner.run_driver_batch(bytes, src; ninputs=1)
    status === :error && error("the traced module did not run: $(results)")
    local r = results[1]
    haskey(r, "trap") && error("the traced module did not run: $(r["trap"])")
    return Tuple{Int,String}[(Int(t[1]), String(t[2])) for t in r["trace"]], String(r["outcome"])
end

"""
    first_divergence(f, args...; js_args) -> NamedTuple

Where a wrong value first appears: `(; found, stmt, text, frames, iteration, native, wasm,
ir_matches_julia, summary)`. `js_args` is the JS argument list for `args` (the runner's
format_js_arg of each); `summary` is the report printed on a wrong answer.
"""
function first_divergence(f, args...; js_args::String)
    local argtypes = Tuple(map(typeof, args))
    local bytes, code, probed = WasmTarget.compile_with_statement_trace(f, argtypes)
    local mi = Base.method_instance(f, argtypes)
    local ntrace, nres = native_trace(code, mi, args)
    # only the statements both sides report: one codegen stores nowhere has no probe
    local both = Set(probed)
    filter!(t -> t[1] in both, ntrace)
    local jres = try (:ok, f(args...)) catch e; (:throw, e) end
    local ir_matches_julia = isequal(nres, jres)
    local wtrace, outcome = wasm_trace(bytes, string(nameof(f)), js_args)
    filter!(t -> t[1] in both, wtrace)
    local seen = Dict{Int,Int}()
    for k in 1:min(length(ntrace), length(wtrace))
        local (ni, nv), (wi, wv) = ntrace[k], wtrace[k]
        seen[ni] = get(seen, ni, 0) + 1
        (ni == wi && nv == wv) && continue
        local frames = WasmTarget.stmt_frames(code.debuginfo, ni)
        local text = first(sprint(show, code.code[ni]), 160)
        local T = code.ssavaluetypes[ni]
        local what = ni == wi ?
            "statement %$ni ($text) differs on its execution #$(seen[ni]): native $(_shown(T, nv)), wasm $(_shown(T, wv))" :
            "control flow differs after $(k - 1) matching values: native reached statement %$ni, wasm %$wi"
        # a call WT compiled separately: the wrong value was made inside it
        (ni == wi && code.code[ni] isa Expr && code.code[ni].head === :invoke) &&
            (what *= "\n  (a call WT compiled separately, its arguments' traced values equal so far: " *
                     "locate inside the callee with first_divergence on it)")
        return (; found=true, stmt=ni, text, frames, iteration=seen[ni], native=nv, wasm=wv,
                ir_matches_julia,
                summary=what * (isempty(frames) ? "" : "\n  in " * join(frames, "\n   ← ")))
    end
    if length(ntrace) != length(wtrace)
        local k = min(length(ntrace), length(wtrace)) + 1
        local longer = length(ntrace) > length(wtrace) ? "native" : "wasm"
        local (i, v) = (length(ntrace) > length(wtrace) ? ntrace : wtrace)[k]
        local frames = WasmTarget.stmt_frames(code.debuginfo, i)
        return (; found=true, stmt=i, text=sprint(show, code.code[i]), frames, iteration=0,
                native=longer == "native" ? v : "", wasm=longer == "wasm" ? v : "",
                ir_matches_julia,
                summary="after $(k - 1) matching values only the $longer run reached statement %$i (the wasm run $outcome)" *
                        (isempty(frames) ? "" : "\n  in " * join(frames, "\n   ← ")))
    end
    return (; found=false, stmt=0, text="", frames=String[], iteration=0, native="", wasm="",
            ir_matches_julia,
            summary=ir_matches_julia ?
                "every traced statement agrees ($(length(ntrace)) values): the difference is in an untraced value" :
                "every traced statement agrees ($(length(ntrace)) values), and WT's IR run natively already answers $(nres) where Julia answers $(jres): the difference is in the IR (an overlay or the collector's choice), not in codegen")
end

end # module
