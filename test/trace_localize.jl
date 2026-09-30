# Locate a wrong value at the first statement whose value differs between Julia and wasm.
#
# `first_divergence(f, args...)` compiles `f` traced (WasmTarget.compile_with_statement_trace:
# every function compiled from Julia IR reports its entry, and each statement of a traced type
# its value after the store) and runs it in Node. It runs the SAME IR natively: each traced
# function's typed CodeInfo, as WT compiled it, becomes an OpaqueClosure with the same probes,
# and every call to a traced callee is routed to the callee's closure — so the native run
# follows WT's IR all the way down, overlays included. The two runs report the same events in
# the same order until the first difference, which is where the wrong value first appears; it
# is named with its function, statement text, inline chain, iteration and both values. The
# native run's answer is also compared with `f` itself, which tells a codegen fault (WT's IR
# answers what Julia does, the wasm does not) from a difference in the IR (an overlay or the
# collector's choice: the runs agree, and WT's IR already answers differently from Julia).
module TraceLocalize

using WasmTarget
using ..WasmRunner
const CC = Core.Compiler

# an event: (0, function id, 0, "") on entry, (1, function id, statement, value bits) after a store
const Event = Tuple{Int,Int,Int,String}
const _NATIVE = Event[]
const _OCS = Dict{Int,Any}()   # trace id → the OpaqueClosure of that function's IR
const _NATIVE_PROBED = Dict{Int,Set{Int}}()   # trace id → the statements its closure probes

_bits(v::Int64)::String = string(v)
_bits(v::UInt64)::String = string(reinterpret(Int64, v))
_bits(v::Int32)::String = string(v)
_bits(v::Bool)::String = v ? "1" : "0"
_bits(v::Float64)::String = string(reinterpret(Int64, v))
_bits(v::Float32)::String = string(reinterpret(Int32, v))

@noinline _probe(id::Int, i::Int, v)::Nothing = (push!(_NATIVE, (1, id, i, _bits(v))); nothing)
@noinline _probe_enter(id::Int)::Nothing = (push!(_NATIVE, (0, id, 0, "")); nothing)
@noinline _run_traced(id::Int, args...) = _OCS[id](args...)

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

# does a function's IR read its own `#self#` (a closure's captures)? Its closure cannot stand in
# for it, so calls to it stay native
_reads_self(code::Core.CodeInfo)::Bool =
    any(st -> st isa Expr && any(a -> a isa Core.Argument && a.n == 1, st.args), code.code)

# the MethodInstance an :invoke names
_invoked(x) = x isa Core.CodeInstance ? x.def : x

# the OpaqueClosure of trace id `id`'s IR: an entry probe, a probe after each statement of a
# traced type, and each call to a traced (non-self-reading) callee routed to that callee's IR
function _traced_closure(trace, id::Int, ids::IdDict{Any,Int}, routable::Vector{Bool})
    local ir = CC.inflate_ir(trace.codes[id], trace.mis[id])
    local n = length(ir.stmts)
    for i in 1:n
        local st = ir.stmts[i][:stmt]
        if st isa Expr && st.head === :invoke
            local callee = get(ids, _invoked(st.args[1]), 0)
            if callee > 0 && routable[callee]
                ir.stmts[i][:stmt] = Expr(:call, _run_traced, callee, st.args[3:end]...)
                ir.stmts[i][:flag] = CC.IR_FLAG_NULL
            end
        end
    end
    for i in 1:n
        local T = CC.widenconst(ir.stmts[i][:type])
        haskey(WasmTarget.TRACED_STATEMENT_TYPES, T) || continue
        local st = ir.stmts[i][:stmt]
        # no statement may follow a block's terminator (an `enter` ends its block as a goto
        # does) or sit among its phis; an exception region's Upsilon and PhiC nodes carry
        # values across it and take nothing between them (a probe after either aborted
        # Julia's process)
        (st isa Core.PhiNode || st isa Core.PhiCNode || st isa Core.UpsilonNode ||
         st isa Core.GotoNode || st isa Core.GotoIfNot || st isa Core.ReturnNode ||
         st isa Core.EnterNode || st === nothing) && continue
        CC.insert_node!(ir, CC.SSAValue(i), CC.NewInstruction(Expr(:call, _probe, id, i, CC.SSAValue(i)), Nothing), true)
        push!(get!(Set{Int}, _NATIVE_PROBED, id), i)
    end
    CC.insert_node!(ir, CC.SSAValue(1), CC.NewInstruction(Expr(:call, _probe_enter, id), Nothing), false)
    ir = CC.compact!(ir)
    ir.argtypes[1] = Tuple{}   # an opaque closure's first argument is its (empty) environment
    return Core.OpaqueClosure(ir; do_compile=true)
end

# the native run of WT's IR: its events and its answer
function native_trace(trace, args::Tuple)
    local ids = IdDict{Any,Int}(mi => id for (id, mi) in enumerate(trace.mis))
    local routable = Bool[!_reads_self(c) for c in trace.codes]
    routable[trace.entry] || error("the entry reads its own #self# (a closure): it cannot be run as its IR")
    empty!(_OCS)
    empty!(_NATIVE_PROBED)
    for id in eachindex(trace.codes)
        routable[id] && (_OCS[id] = _traced_closure(trace, id, ids, routable))
    end
    empty!(_NATIVE)
    local r = try
        (:ok, Base.invokelatest(_OCS[trace.entry], args...))
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
  trace_enter: (f) => { trace.push([0, f, 0, ""]); },
  trace_i32: (f, i, v) => { trace.push([1, f, i, String(v)]); },
  trace_i64: (f, i, v) => { trace.push([1, f, i, v.toString()]); },
  trace_f32: (f, i, v) => { trace.push([1, f, i, f32bits(v)]); },
  trace_f64: (f, i, v) => { trace.push([1, f, i, f64bits(v)]); } } };
HOST_MERGE
const { instance } = await WebAssembly.instantiate(bytes, importObject, { builtins: ['js-string'] });
let outcome = 'returned';
try { instance.exports[FNAME](ARGS); } catch (e) { outcome = 'trapped: ' + String(e && e.message || e); }
return [{ trace, outcome }];
"""

# the wasm run's events, and how the call ended
function wasm_trace(bytes::Vector{UInt8}, fname::String, js_args::String)
    local src = replace(_TRACE_JS, "FNAME" => repr(fname), "ARGS" => js_args,
                        "HOST_MERGE" => WasmRunner.HOST_RUNTIME_MERGE_JS)
    local status, results = WasmRunner.run_driver_batch(bytes, src; ninputs=1)
    status === :error && error("the traced module did not run: $(results)")
    local r = results[1]
    haskey(r, "trap") && error("the traced module did not run: $(r["trap"])")
    return Event[(Int(t[1]), Int(t[2]), Int(t[3]), String(t[4])) for t in r["trace"]], String(r["outcome"])
end

_fname(trace, id)::String = replace(sprint(show, trace.mis[id]), "MethodInstance for " => "")

# an event, as the report names it
function _event_text(trace, e::Event)::String
    e[1] == 0 && return "entered $(_fname(trace, e[2]))"
    local code = trace.codes[e[2]]
    return "statement %$(e[3]) ($(first(sprint(show, code.code[e[3]]), 160))) of $(_fname(trace, e[2]))"
end

_frames(trace, e::Event)::Vector{String} =
    e[1] == 1 ? WasmTarget.stmt_frames(trace.codes[e[2]].debuginfo, e[3]) : String[]

"""
    first_divergence(f, args...; js_args) -> NamedTuple

Where a wrong value first appears: `(; found, func, stmt, text, frames, iteration, native,
wasm, ir_matches_julia, summary)`. `js_args` is the JS argument list for `args` (the runner's
format_js_arg of each); `summary` is the report printed on a wrong answer.
"""
function first_divergence(f, args...; js_args::String)
    local argtypes = Tuple(map(typeof, args))
    local bytes, trace = WasmTarget.compile_with_statement_trace(f, argtypes)
    local nevents, nres = native_trace(trace, args)
    local jres = try (:ok, f(args...)) catch e; (:throw, e) end
    local ir_matches_julia = isequal(nres, jres)
    local wevents, outcome = wasm_trace(bytes, string(nameof(f)), js_args)
    # only the statements both sides report (a statement codegen stores nowhere has no probe,
    # and one the native run cannot probe has none there), and only the functions whose IR the
    # native run follows
    local keep = (e::Event) -> haskey(_OCS, e[2]) &&
        (e[1] == 0 || (e[3] in trace.probed[e[2]] && e[3] in get(_NATIVE_PROBED, e[2], Set{Int}())))
    filter!(keep, nevents)
    filter!(keep, wevents)
    local seen = Dict{Tuple{Int,Int},Int}()
    for k in 1:min(length(nevents), length(wevents))
        local ne, we = nevents[k], wevents[k]
        ne[1] == 1 && (seen[(ne[2], ne[3])] = get(seen, (ne[2], ne[3]), 0) + 1)
        ne == we && continue
        local frames = _frames(trace, ne)
        local T = ne[1] == 1 ? trace.codes[ne[2]].ssavaluetypes[ne[3]] : Any
        local same_site = ne[1] == we[1] == 1 && ne[2] == we[2] && ne[3] == we[3]
        local what = same_site ?
            "$(_event_text(trace, ne)) differs on its execution #$(seen[(ne[2], ne[3])]): native $(_shown(T, ne[4])), wasm $(_shown(T, we[4]))" :
            "the runs part after $(k - 1) matching events: natively $(_event_text(trace, ne)), in wasm $(_event_text(trace, we))"
        return (; found=true, func=_fname(trace, ne[2]), stmt=ne[3],
                text=ne[1] == 1 ? sprint(show, trace.codes[ne[2]].code[ne[3]]) : "",
                frames, iteration=get(seen, (ne[2], ne[3]), 0), native=ne[4], wasm=we[4],
                ir_matches_julia,
                summary=what * (isempty(frames) ? "" : "\n  in " * join(frames, "\n   ← ")))
    end
    if length(nevents) != length(wevents)
        local k = min(length(nevents), length(wevents)) + 1
        local longer = length(nevents) > length(wevents) ? "native" : "wasm"
        local e = (length(nevents) > length(wevents) ? nevents : wevents)[k]
        local frames = _frames(trace, e)
        return (; found=true, func=_fname(trace, e[2]), stmt=e[3],
                text=e[1] == 1 ? sprint(show, trace.codes[e[2]].code[e[3]]) : "", frames,
                iteration=0, native=longer == "native" ? e[4] : "", wasm=longer == "wasm" ? e[4] : "",
                ir_matches_julia,
                summary="after $(k - 1) matching events only the $longer run went on, to $(_event_text(trace, e)) (the wasm run $outcome)" *
                        (isempty(frames) ? "" : "\n  in " * join(frames, "\n   ← ")))
    end
    return (; found=false, func="", stmt=0, text="", frames=String[], iteration=0, native="", wasm="",
            ir_matches_julia,
            summary=ir_matches_julia ?
                "every traced event agrees ($(length(nevents)) events): the difference is in an untraced value" :
                "every traced event agrees ($(length(nevents)) events), and WT's IR run natively already answers $(nres) where Julia answers $(jres): the difference is in the IR (an overlay or the collector's choice), not in codegen")
end

end # module
