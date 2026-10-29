# The differential runner, the third oracle (AGENTS.md: native-vs-wasm execution; dev/AUDIT.md A46E1):
# every module a test gets from WasmTarget, which the builder already accepted (D10), runs in node, the
# major .github/workflows/ci.yml names, its entry called with the case's arguments, and its answer is
# compared with native Julia's, === at the answer's type. One node process runs every case of a batch.
# Marshalled: Int32, UInt32, Int64, UInt64, UInt8, Float32, Float64 and Bool, arguments and answer, ReturnsRef(), a
# read answer's own module returning a non-null reference, an answer of a
# singleton type (nothing), whose call must return and whose type is its value, and Throws(T), a native call that
# throws, whose module must raise a wasm exception, neither trap nor return; any other type, a module that imports anything, an entry not found, a trap or a throw is a located failure of its
# case, never a skip. An unsigned integer crosses as the signed one of its bits, a float as its bit
# pattern, so NaN payloads and -0.0 keep their bits.
# A case carries both modules of its program: compile's own (dartdev's default phases, ending with
# dart's opt phase, wasm-opt) and compile's `optimize = false` (codegen's module). Both run in the same
# node process, each answer against native's and the two against each other, a difference its own
# failure (an optimizer miscompile, or a module relying on something undefined).
# Each module's call has a budget (D17): intent, a call answers in milliseconds; band, past RUN_BUDGET
# seconds it fails, naming its seconds; node itself is killed past RUN_BUDGET per module plus
# NODE_START seconds, every module without an answer failing as a hang, named.
#
#   isdefined(Main, :WTRunner) || include("runner.jl")
#   WTRunner.answer_cases(label, WasmTarget.compile, f, args, native) -> Vector{WTRunner.RunCase}
#   WTRunner.run_cases(cases) -> Vector{WTRunner.RunResult}
module WTRunner

import Base64

const ROOT = dirname(@__DIR__)
const RUN_BUDGET = 5.0
const NODE_START = 30.0

"""One module's case: its bytes, its wasm-opt'd bytes (empty for none), the arguments of its entry,
native Julia's answer for them."""
struct RunCase
    label::String
    bytes::Vector{UInt8}
    optimized::Vector{UInt8}
    args::Tuple
    native::Any
    entry::String   # "" for the module's one exported function
    unread::String  # why the runner cannot read this fact yet ("" when it can): its reader is rejected, unported
end
RunCase(label, bytes, optimized, args, native, entry) = RunCase(label, bytes, optimized, args, native, entry, "")
RunCase(label, bytes, args, native; optimized::Vector{UInt8} = UInt8[], entry::String = "") =
    RunCase(label, bytes, optimized, args, native, entry, "")

"""
    compiled_case(label, compile, f, args, native; optimized = true) -> RunCase

The case of a program `compile` compiles: `compile(f, T; optimize = false)`, codegen's module, as the
case's own, and `compile(f, T)`, which dartdev's default phases end with opt (wasm-opt), as the
optimized one; one module when the two are the same bytes, or when `optimized` is false (a run that
leaves wasm-opt, an external tool, to another run).
"""
function compiled_case(label::String, compile, f, args::Tuple, native; optimized::Bool = true)::RunCase
    local argtypes = Tuple(map(typeof, args))
    local plain = compile(f, argtypes; optimize = false)
    local opt = optimized ? compile(f, argtypes) : plain
    return RunCase(label, plain, args, native; optimized = plain == opt ? UInt8[] : opt)
end

# A tuple answer leaves the module as a reference to a wasm struct, which JS cannot read (and wasm-opt,
# closed-world, strips the fields nothing in the module reads). Its facts are read in wasm by a reader:
# a program calling the case's function and returning the fact a run-time index picks, one reader per
# leaf type, its index chain over the leaves' paths spelt out by Julia's own @generated. The facts are
# then compared one by one in Julia, so a wrong one names itself. The precedent is dart's own test:
# its main reads the facts it asserts inside the program (Expect), dart2wasm's JS host reading none.
# A vector inside the answer is read the same way: its length a leaf, each element a leaf (or a nest); so is a
# String: its ncodeunits a leaf, each codeunit (a UInt8) a leaf, Base's own reading of a String's bytes.
# A path's steps: an Int, a tuple's field; (:ix, i), a vector's element; :len, a vector's length; (:cu, i), a
# String's codeunit; :ncu, its ncodeunits.
_step(x, i::Int) = getfield(x, i)
_step(x, s::Tuple{Symbol,Int}) = s[1] === :cu ? codeunit(x, s[2]) : x[s[2]]
_step(x, s::Symbol) = s === :ncu ? Int64(ncodeunits(x)) : Int64(length(x))
_step_ex(e, i::Int) = :(getfield($e, $i))
_step_ex(e, s::Tuple{Symbol,Int}) = s[1] === :cu ? :(codeunit($e, $(s[2]))) : :(getindex($e, $(s[2])))
_step_ex(e, s::Symbol) = s === :ncu ? :(Int64(ncodeunits($e))) : :(Int64(length($e)))
_string_step(s) = s === :ncu || (s isa Tuple && s[1] === :cu)
_on_string(p::Tuple) = any(_string_step, p)
_string_of(p::Tuple) = p[1:findfirst(_string_step, p)-1]   # the path of the String a leaf reads
struct Leaves{F,P} <: Function end
@generated function _pick(x, ::Val{P}, k::Int64) where {P}
    local at(p) = foldl(_step_ex, p; init = :x)
    local ex = at(P[end])
    for i in length(P)-1:-1:1
        ex = :(k == $i ? $(at(P[i])) : $ex)
    end
    return ex
end
# fixed arities: compile has no varargs method yet (src/julia/nir.jl rejects one, unported)
(::Leaves{F,P})(k::Int64) where {F,P} = _pick(F(), Val(P), k)
(::Leaves{F,P})(a, k::Int64) where {F,P} = _pick(F(a), Val(P), k)
(::Leaves{F,P})(a, b, k::Int64) where {F,P} = _pick(F(a, b), Val(P), k)
(::Leaves{F,P})(a, b, c, k::Int64) where {F,P} = _pick(F(a, b, c), Val(P), k)

# each leaf's path in a nest of tuples, vectors and Strings, in order
_leaves(x, p::Tuple = ())::Vector{Tuple} =
    x isa Tuple ? reduce(vcat, (_leaves(y, (p..., i)) for (i, y) in enumerate(x)); init = Tuple[]) :
    x isa Vector ? reduce(vcat, (_leaves(y, (p..., (:ix, i))) for (i, y) in enumerate(x)); init = Tuple[(p..., :len)]) :
    x isa String ? Tuple[(p..., :ncu); [(p..., (:cu, i)) for i in 1:ncodeunits(x)]] :
    Tuple[p]

"""
    answer_cases(label, compile, f, args, native; optimized = true) -> Vector{RunCase}

The cases that read `f(args...)`'s answer from wasm: `f`'s own modules when the answer is one value;
for a tuple or a vector, one reader per leaf type, each leaf a case of its reader labelled by its path. A leaf no
reader can read (a type the runner does not marshal, or a case of more than 3 arguments) is a case
with no module, which run_cases fails, naming why.
"""
function answer_cases(label::String, compile, f, args::Tuple, native; optimized::Bool = true,
                      own::Vector{UInt8} = UInt8[])::Vector{RunCase}
    (native isa Tuple && !isempty(native)) || native isa Vector || native isa String ||
        return [compiled_case(label, compile, f, args, native; optimized)]
    local paths = _leaves(native)
    local leaf(p) = foldl(_step, p; init = native)
    # the case's own modules run too: a non-null reference, returned without a trap; `own` is the compile the
    # caller already holds (compile's default, wasm-opt'd), so only codegen's module is compiled here
    local argtypes = Tuple(map(typeof, args))
    local plain = compile(f, argtypes; optimize = false)
    local opt = !optimized ? UInt8[] : isempty(own) ? compile(f, argtypes) : own
    local out = RunCase[RunCase("$label(own module)", plain, args, ReturnsRef(); optimized = plain == opt ? UInt8[] : opt)]
    # one reader per leaf type, a String's leaves apart from the rest. A reader WasmTarget rejects as Unported or
    # Unquarantined (a String's codeunit before its lowering, a boxed leaf before convertType's boxing) leaves its
    # facts unread, each a case naming the rejection: the runner's gap, which only a :unread record admits; a
    # String is then one such case, not its codeunits. Any other rejection is WT's and propagates.
    local rejected(e) = nameof(typeof(e)) === :RejectionError && nameof(typeof(e.rejection)) in (:Unported, :Unquarantined)
    for (T, on_string) in unique(map(p -> (typeof(leaf(p)), _on_string(p)), paths))
        local ps = Tuple(filter(p -> typeof(leaf(p)) === T && _on_string(p) == on_string, paths))
        local readable = length(args) <= 3 && _wire_answer(leaf(first(ps))) !== nothing
        local reader, why = nothing, ""
        if readable
            try
                reader = compiled_case(label, compile, Leaves{f,ps}(), (args..., Int64(1)), nothing; optimized)
            catch e
                rejected(e) || rethrow()
                why = first(sprint(showerror, e), 300)
            end
        end
        if !isempty(why)
            for p in unique(on_string ? map(_string_of, ps) : collect(ps))
                any(c -> c.label == "$label$p", out) ||
                    push!(out, RunCase("$label$p", UInt8[], UInt8[], (args..., Int64(1)), leaf(p), "", "its reader is rejected: $why"))
            end
            continue
        end
        for (k, p) in enumerate(ps)
            push!(out, RunCase("$label$p", readable ? reader.bytes : UInt8[], readable ? reader.optimized : UInt8[],
                               (args..., Int64(k)), leaf(p), ""))
        end
    end
    return out
end

"""
    Throws(T)

The answer of a case whose native call throws an exception of type `T`: its module must raise a wasm exception
(WasmTarget's exception tag, a `WebAssembly.Exception` in JS), never trap (a `WebAssembly.RuntimeError`:
unreachable, an integer divided by zero) and never return. The exception's type is not read yet: its class id
needs an exported reader the runtime has not ported.
"""
struct Throws
    type::Type
end

"""
    ReturnsRef()

What a case's own module must answer when its answer is read by readers (a tuple, a vector, a String): a
reference, non-null, returned without a trap. Its facts are the readers'; this is the module itself run.
"""
struct ReturnsRef end

"""A case's verdict: `ok` when the module answered native's value; `why` says what differs, located."""
struct RunResult
    label::String
    ok::Bool
    why::String
end

# the node of CI's major: Homebrew's node@<major>, else the node on PATH when it is that major
function node_binary()::Union{String,Nothing}
    local ci = read(joinpath(ROOT, ".github", "workflows", "ci.yml"), String)
    local m = match(r"node-version: *'?([0-9]+)", ci)
    m === nothing && return nothing
    local major = m[1]
    for pre in ("/opt/homebrew/opt/node@$major/bin", "/usr/local/opt/node@$major/bin")
        isfile(joinpath(pre, "node")) && return joinpath(pre, "node")
    end
    local v = try readchomp(`node --version`) catch; "" end
    return startswith(v, "v$major.") ? "node" : nothing
end

# a scalar's wire form: its wasm type and its value as text (an integer in decimal, a float's bits in hex)
function _wire(x)::Union{Tuple{String,String},Nothing}
    x isa Bool && return ("i32", x ? "1" : "0")
    x isa Int32 && return ("i32", string(x))
    x isa UInt32 && return ("i32", string(reinterpret(Int32, x)))
    x isa UInt8 && return ("i32", string(x))
    x isa Int64 && return ("i64", string(x))
    x isa UInt64 && return ("i64", string(reinterpret(Int64, x)))
    x isa Float32 && return ("f32", string(reinterpret(UInt32, x); base = 16))
    x isa Float64 && return ("f64", string(reinterpret(UInt64, x); base = 16))
    return nothing
end

# an answer's wire form: a scalar's, or "void" for a value of a singleton type (nothing, a fieldless struct),
# which carries no bits: its call must return no value (undefined or null in JS), and its type is its value; a
# module returning a value there, a Union{Nothing,T} answer's T, differs from native (A56E1)
_wire_answer(x)::Union{Tuple{String,String},Nothing} =
    x isa Throws ? ("throws", "-") : x isa ReturnsRef ? ("ref", "-") : Base.issingletontype(typeof(x)) ? ("void", "-") : _wire(x)

# the answer read back at native's type
function _unwire(::Type{T}, s::AbstractString) where {T}
    T === ReturnsRef && return s == "ref" ? ReturnsRef() : "the module returns $(s == "null" ? "a null reference" : s)"
    Base.issingletontype(T) && return s == "-" ? T.instance : String(s)   # a value where none is due: compared, it differs
    T === Bool && return s == "1" ? true : s == "0" ? false : nothing
    T === Int32 && return parse(Int32, s)
    T === UInt32 && return reinterpret(UInt32, parse(Int32, s))
    T === UInt8 && return (v = parse(Int32, s); 0 <= v <= 255 ? UInt8(v) : "the i32 $v, no UInt8")   # never truncated to fit
    T === Int64 && return parse(Int64, s)
    T === UInt64 && return reinterpret(UInt64, parse(Int64, s))
    T === Float32 && return reinterpret(Float32, parse(UInt32, s; base = 16))
    T === Float64 && return reinterpret(Float64, parse(UInt64, s; base = 16))
    return nothing
end

# the script node runs: one line per module in, one line per module out, `ok <answer> <ms>` or
# `err <why>`, each written as it is known, so a hang shows where it stopped; a module is compiled
# and instantiated once however many lines call it
const _JS = raw"""
const fs = require('fs');
const lines = fs.readFileSync(process.argv[2], 'utf8').split('\n').filter(l => l.length > 0);
const toWasm = (t, v) => {
  if (t === 'i32') return Number(BigInt.asIntN(32, BigInt(v)));
  if (t === 'i64') return BigInt.asIntN(64, BigInt(v));
  const dv = new DataView(new ArrayBuffer(8));
  if (t === 'f32') { dv.setUint32(0, parseInt(v, 16)); return dv.getFloat32(0); }
  dv.setBigUint64(0, BigInt('0x' + v)); return dv.getFloat64(0);
};
const fromWasm = (t, x) => {
  if (t === 'void') return (x === undefined || x === null) ? '-' : 'a_value:' + typeof x;
  if (t === 'throws') return 'returned';
  if (t === 'ref') return (x === undefined || x === null) ? 'null' : typeof x === 'object' ? 'ref' : 'a_value:' + typeof x;
  if (t === 'i32') return String(x | 0);
  if (t === 'i64') return BigInt.asIntN(64, x).toString();
  const dv = new DataView(new ArrayBuffer(8));
  if (t === 'f32') { dv.setFloat32(0, x); return dv.getUint32(0).toString(16); }
  dv.setFloat64(0, x); return dv.getBigUint64(0).toString(16);
};
const instances = new Map();
(async () => {
  for (const line of lines) {
    const [wasmB64, entry, rtype, ...args] = line.split(' ');
    try {
      let mi = instances.get(wasmB64);
      if (mi === undefined) {
        const mod = await WebAssembly.compile(Buffer.from(wasmB64, 'base64'));
        const imps = WebAssembly.Module.imports(mod);
        mi = imps.length > 0 ? { imports: imps.map(i => i.module + '.' + i.name) } :
          { mod, inst: await WebAssembly.instantiate(mod, {}) };
        instances.set(wasmB64, mi);
      }
      if (mi.imports) { process.stdout.write('err the module imports ' + mi.imports.join(', ') + ', which the runner provides none of yet\n'); continue; }
      const fns = WebAssembly.Module.exports(mi.mod).filter(e => e.kind === 'function').map(e => e.name);
      const name = entry === '-' ? (fns.length === 1 ? fns[0] : null) : entry;
      if (name === null || typeof mi.inst.exports[name] !== 'function') { process.stdout.write('err no entry: the module exports the functions [' + fns.join(', ') + ']\n'); continue; }
      const vals = args.map(a => { const [t, v] = a.split(':'); return toWasm(t, v); });
      const t0 = performance.now();
      const r = mi.inst.exports[name](...vals);
      const ms = performance.now() - t0;
      process.stdout.write('ok ' + fromWasm(rtype, r) + ' ' + ms.toFixed(1) + '\n');
    } catch (e) {
      const why = String(e && e.message || e).replace(/\s+/g, ' ');
      // a wasm exception (the module's throw) apart from a trap (unreachable, an integer divided by zero)
      process.stdout.write((e instanceof WebAssembly.Exception ? 'exc ' : e instanceof WebAssembly.RuntimeError ? 'err trap: ' : 'err ') + why + '\n');
    }
  }
})();
"""

"""
    run_cases(cases) -> Vector{RunResult}

Run every case, and each one's wasm-opt'd module, in one node process; compare each answer with
native Julia's, `===`, and the two modules' answers with each other.
"""
function run_cases(cases::AbstractVector{RunCase}; run_budget::Float64 = RUN_BUDGET, node_start::Float64 = NODE_START)::Vector{RunResult}
    isempty(cases) && return RunResult[]
    local results = Vector{Union{RunResult,Nothing}}(nothing, length(cases))
    local lines = String[]
    local sent = Tuple{Int,Bool}[]   # each line's case and whether it is the wasm-opt'd module
    for (i, c) in enumerate(cases)
        if !isempty(c.unread)
            results[i] = RunResult(c.label, false, "the runner does not read it yet, $(c.unread)")
            continue
        end
        local args = map(_wire, c.args)
        local rt = _wire_answer(c.native)
        if any(isnothing, args) || rt === nothing
            local bad = Any[typeof(a) for (a, w) in zip(c.args, args) if w === nothing]
            rt === nothing && push!(bad, typeof(c.native))
            results[i] = RunResult(c.label, false, "the runner marshals no $(join(unique(bad), ", ")) yet (its marshalling is not ported)")
            continue
        end
        if isempty(c.bytes)
            results[i] = RunResult(c.label, false, "the runner reads a tuple's leaves for a case of at most 3 arguments, this one has $(length(c.args) - 1)")
            continue
        end
        for (opt, bytes) in ((false, c.bytes), (true, c.optimized))
            opt && isempty(bytes) && continue
            push!(lines, join([Base64.base64encode(bytes), isempty(c.entry) ? "-" : c.entry, rt[1], ("$(t):$(v)" for (t, v) in args)...], ' '))
            push!(sent, (i, opt))
        end
    end
    if !isempty(sent)
        local node = node_binary()
        if node === nothing
            for (i, _) in sent
                results[i] = RunResult(cases[i].label, false, "no node of the major .github/workflows/ci.yml names")
            end
        else
            local dir = mktempdir()
            local js = joinpath(dir, "run.js")
            local inp = joinpath(dir, "cases.txt")
            write(js, _JS)
            write(inp, join(lines, '\n') * "\n")
            local out = IOBuffer()
            local err = IOBuffer()
            local proc = run(pipeline(`$node $js $inp`; stdout = out, stderr = err); wait = false)
            local limit = run_budget * length(lines) + node_start
            local killed = Ref(false)
            local watchdog = Timer(_ -> (process_running(proc) && (killed[] = true; kill(proc))), limit)
            wait(proc)
            close(watchdog)
            local answers = split(String(take!(out)), '\n'; keepempty = false)
            local stderr_text = strip(String(take!(err)))
            # each module's verdict: its answer read back, or why it has none
            local verdicts = Dict{Tuple{Int,Bool},Tuple{Bool,Any,String}}()
            for (k, (i, opt)) in enumerate(sent)
                local c = cases[i]
                local a = k <= length(answers) ? answers[k] :
                    killed[] ? "err no answer within $(limit) s, node killed: a hang or a blow-up" : "err node gave no answer: $stderr_text"
                if startswith(a, "err ")
                    verdicts[(i, opt)] = (false, nothing, String(a[5:end]) * (c.native isa Throws ? ", where native Julia throws $(c.native.type)" : ""))
                elseif startswith(a, "exc ")
                    # a wasm exception: native's answer when native throws, else the module's fault
                    verdicts[(i, opt)] = c.native isa Throws ? (true, c.native, "") :
                        (false, nothing, "throws a wasm exception ($(a[5:end])), where native Julia answers $(repr(c.native))")
                elseif c.native isa Throws
                    verdicts[(i, opt)] = (false, nothing, "returns, where native Julia throws $(c.native.type)")
                else
                    local ans, ms = split(a[4:end], ' ')
                    local secs = parse(Float64, ms) / 1000
                    verdicts[(i, opt)] = secs > run_budget ? (false, nothing, "ran $(round(secs; digits = 1)) s, past its $(run_budget) s budget") :
                        (true, _unwire(typeof(c.native), ans), "")
                end
            end
            for i in unique(first.(sent))
                local c = cases[i]
                local why = String[]
                local answered = Any[]
                for opt in (false, true)
                    haskey(verdicts, (i, opt)) || continue
                    local which = opt ? "the wasm-opt'd module" : "the module"
                    local ok, got, w = verdicts[(i, opt)]
                    if !ok
                        push!(why, "$which: $w")
                    else
                        push!(answered, got)
                        got === c.native || push!(why, "$which answers $(repr(got)), native Julia $(repr(c.native))")
                    end
                end
                length(answered) == 2 && !(answered[1] === answered[2]) &&
                    push!(why, "the module and the wasm-opt'd module differ: $(repr(answered[1])) against $(repr(answered[2]))")
                results[i] = RunResult(c.label, isempty(why), join(why, "; "))
            end
            rm(dir; recursive = true, force = true)
        end
    end
    return RunResult[r for r in results]
end

end
