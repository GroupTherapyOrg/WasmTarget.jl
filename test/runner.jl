# The differential runner, the third oracle (AGENTS.md: native-vs-wasm execution; dev/AUDIT.md A46E1):
# every module a test gets from WasmTarget, which the builder already accepted (D10), runs in node, the
# major .github/workflows/ci.yml names, its entry called with the case's arguments, and its answer is
# compared with native Julia's, === at the answer's type. One node process runs every case of a batch.
# Marshalled: Int32, UInt32, Int64, UInt64, UInt8, Float32, Float64 and Bool, arguments and answer, ReturnsRef(), a
# read answer's own module returning a non-null reference, an answer of a
# singleton type (nothing), whose call must return and whose type is its value, and Throws(T), a native call that
# throws, whose module must raise a wasm exception, neither trap nor return; any other type, a module that imports anything but the standalone embedder's `dart` functions the runner gives (dart's own test runner's), an entry not found, a trap or a throw is a located failure of its
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
# WasmTarget answers have_fma(Float64) true and rounds muladd and fma once, as native Julia does on an FMA host, and the
# differential reads Julia's math kernels bit for bit against native (test/smoke_corpus.jl's bit_exact_math). On a host
# without FMA, native Julia takes the kernels' other branches (have_fma in expm1), and every such case would read as
# WasmTarget's wrong answer: refused here, located, once (A84S6)
Core.Intrinsics.have_fma(Float64) || error("test/runner.jl: native Julia on this host has no fused multiply-add " *
    "(Core.Intrinsics.have_fma(Float64) is false), so its math kernels take branches WasmTarget's modules do not: " *
    "the differential runs on an FMA host only (A84S6)")

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

# a program's modules: `compile(f, T; optimize = false)`, codegen's, and `compile(f, T)`, which dartdev's default
# phases end with opt (wasm-opt), or `own` when the caller holds that compile already; none when `optimized` is false
# (a run that leaves wasm-opt, an external tool, to another run)
function _modules(compile, f, args::Tuple; optimized::Bool = true, own::Vector{UInt8} = UInt8[])::Tuple{Vector{UInt8},Vector{UInt8}}
    local argtypes = Tuple(map(typeof, args))
    local plain = compile(f, argtypes; optimize = false)
    local opt = !optimized ? UInt8[] : isempty(own) ? compile(f, argtypes) : own
    return (plain, isempty(opt) || opt == plain ? UInt8[] : opt)
end

"""
    native_answer(f, args)

Native Julia's answer to `f(args...)`, or `Throws(typeof(e))` when the call throws. The runner computes it itself,
once, after the compiles it is compared against (A61S4): a compile reads the session's heap as it stands, so a
native call made before it would hand the compile a heap one step on.
"""
native_answer(f, args::Tuple) = try
    f(args...)
catch e
    Throws(typeof(e))
end

"""
    compiled_case(label, compile, f, args; optimized = true) -> RunCase

The case of a program `compile` compiles: codegen's module as the case's own, and the wasm-opt'd one beside it
(one module when the two are the same bytes, or when `optimized` is false), its native answer native_answer's,
computed after both compiles.
"""
function compiled_case(label::String, compile, f, args::Tuple; optimized::Bool = true)::RunCase
    local label′, f′, args′ = _bound(label, f, args)
    local plain, opt = _modules(compile, f′, args′; optimized)
    return RunCase(label′, plain, args′, native_answer(f′, args′); optimized = opt)
end

# A String argument crosses no wire: JS has no way to hand the module a Julia String. It becomes a constant of the
# program, as a dart test's strings are literals its main holds (dart2wasm's tests at the pin pass their programs
# no argument; precedent: tests/web/wasm, each a main()). Julia differs in that a case's arguments live in the corpus,
# not in the program's text, so the runner binds them: Bound{F,P,S} is the callable `(wire arguments...) ->
# F(...)` with the String S[j] at argument position P[j], each one a literal of the method _call_bound generates,
# lowered by WT's own constant lowering as a literal of the program is, and passed to F as its argument inside the
# program, so argument passing is still exercised. The native answer is Bound's own, the same constants, and the
# case's label names the positions bound, "(String argument 1 bound)", so a bound case reads apart from a wire one.
# F is the function itself, as Leaves's is: a function of no fields is its own type's one instance.
struct Bound{F,P,S} <: Function end
@generated function _call_bound(f, ::Val{P}, ::Val{S}, w::Tuple) where {P,S}
    local wire = Any[:(getfield(w, $k)) for k in 1:fieldcount(w)]
    local all = Any[]
    for i in 1:(length(P) + fieldcount(w))
        local j = findfirst(==(i), P)
        push!(all, j === nothing ? popfirst!(wire) : String(S[j]))
    end
    return :(f($(all...)))
end
# fixed arities, as Leaves's: a varargs method of an open count reads its tuple by a run-time index, not yet compiled
(::Bound{F,P,S})() where {F,P,S} = _call_bound(F, Val(P), Val(S), ())
(::Bound{F,P,S})(a) where {F,P,S} = _call_bound(F, Val(P), Val(S), (a,))
(::Bound{F,P,S})(a, b) where {F,P,S} = _call_bound(F, Val(P), Val(S), (a, b))
(::Bound{F,P,S})(a, b, c) where {F,P,S} = _call_bound(F, Val(P), Val(S), (a, b, c))
# the case as the runner compiles it: (label, f, args) unchanged when no argument is a String, else Bound's
function _bound(label::String, f, args::Tuple)
    local P = Tuple(i for (i, a) in enumerate(args) if a isa String)
    isempty(P) && return (label, f, args)
    local B = Bound{f,P,Tuple(Symbol(args[i]) for i in P)}
    return ("$label(String argument$(length(P) == 1 ? "" : "s") $(join(P, ", ")) bound)", B(), Tuple(a for a in args if !(a isa String)))
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
# a reader's pick is typeasserted to its leaves' type, native's, so its export returns that type even where the
# answer holds the leaf as Any (a record of Any fields): an anyref holding a box JS cannot read otherwise
struct Leaves{F,P,T} <: Function end
@generated function _pick(x, ::Val{P}, ::Type{T}, k::Int64) where {P,T}
    local at(p) = :($(foldl(_step_ex, p; init = :x))::$T)
    local ex = at(P[end])
    for i in length(P)-1:-1:1
        ex = :(k == $i ? $(at(P[i])) : $ex)
    end
    return ex
end
# fixed arities: a varargs method of an open count reads its tuple by a run-time index, not yet compiled
(::Leaves{F,P,T})(k::Int64) where {F,P,T} = _pick(F(), Val(P), T, k)
(::Leaves{F,P,T})(a, k::Int64) where {F,P,T} = _pick(F(a), Val(P), T, k)
(::Leaves{F,P,T})(a, b, k::Int64) where {F,P,T} = _pick(F(a, b), Val(P), T, k)
(::Leaves{F,P,T})(a, b, c, k::Int64) where {F,P,T} = _pick(F(a, b, c), Val(P), T, k)

# each leaf's path in a nest of tuples, vectors and Strings, in order
_leaves(x, p::Tuple = ())::Vector{Tuple} =
    x isa Tuple ? reduce(vcat, (_leaves(y, (p..., i)) for (i, y) in enumerate(x)); init = Tuple[]) :
    x isa Vector ? reduce(vcat, (_leaves(y, (p..., (:ix, i))) for (i, y) in enumerate(x)); init = Tuple[(p..., :len)]) :
    x isa String ? Tuple[(p..., :ncu); [(p..., (:cu, i)) for i in 1:ncodeunits(x)]] :
    Tuple[p]

"""
    answer_cases(label, compile, f, args; optimized = true, own = UInt8[]) -> (cases, native)

The cases that read `f(args...)`'s answer from wasm, and the native answer they are read against. `f`'s own modules
are compiled first, then native_answer runs once (A61S4), and its value is returned beside the cases so a caller
proving a recorded answer reads the same one. For one value the cases are `f`'s own modules; for a tuple, a vector
or a String, `f`'s own modules (a non-null reference, returned without a trap) and one reader per leaf type, each
leaf a case of its reader labelled by its path. A leaf no reader can read (a type the runner does not marshal, or a
case of more than 3 arguments) is a case with no module, which run_cases fails, naming why. A known limit: a reader's
shape comes from the native value (a vector's length, a String's code units), so a reader is compiled after the
native run; for a program that changes global state the reader starts a step on and the case fails, a false
failure, never a false pass.
"""
function answer_cases(label::String, compile, f, args::Tuple; optimized::Bool = true,
                      own::Vector{UInt8} = UInt8[])::Tuple{Vector{RunCase},Any}
    # a String argument bound as a constant of the program (Bound); the caller's own compile took it as an argument,
    # so it is not the bound program's
    local label′, f′, args′ = _bound(label, f, args)
    args′ === args || return answer_cases(label′, compile, f′, args′; optimized)
    # the case's own modules first, `own` the compile the caller already holds (compile's default, wasm-opt'd)
    local plain, opt = _modules(compile, f, args; optimized, own)
    local native = native_answer(f, args)
    (native isa Tuple && !isempty(native)) || native isa Vector || native isa String ||
        return (RunCase[RunCase(label, plain, args, native; optimized = opt)], native)
    local paths = _leaves(native)
    local leaf(p) = foldl(_step, p; init = native)
    # the own modules run too, a read answer's: a non-null reference, returned without a trap
    local out = RunCase[RunCase("$label(own module)", plain, args, ReturnsRef(); optimized = opt)]
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
                local rp, ro = _modules(compile, Leaves{f,ps,T}(), (args..., Int64(1)); optimized)
                reader = (bytes = rp, optimized = ro)
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
    return (out, native)
end

"""
    Throws(T)

The answer of a case whose native call throws an exception of type `T`: its module must raise a wasm exception
under its exception tag (a `WebAssembly.Exception` that `is` the one tag the module exports), never another tag,
never a trap (a `WebAssembly.RuntimeError`: unreachable, an integer divided by zero) and never a return (A61E1).
The exception's type is not read yet: its class id needs an exported reader the runtime has not ported.
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
# the lowest Node major whose V8 runs WT's modules: Node 22's (v22.23.3) traps "unreachable" entering any try_table
# with a reference result, with no WT code in it (test/src/runner.jl's "a try_table of a reference result" module,
# 12 lines, returns 7 on Node 26.11 and traps on Node 22; the corpus's wasm-opt'd modules of
# dart_switch/case_fallthrough, dart_switch/try_catch and dart_web_wasm/no_omit_error_details trapped so on
# f05b2fa8, 2026-11-01, wt3-cgstubs2). Node 24 is untried here, so the floor is the major that was run.
const NODE_MIN_MAJOR = 26
function node_binary()::Union{String,Nothing}
    local ci = read(joinpath(ROOT, ".github", "workflows", "ci.yml"), String)
    local m = match(r"node-version: *'?([0-9]+)", ci)
    m === nothing && return nothing
    local major = m[1]
    # no exception-handling module runs on an engine that traps it: a ci.yml naming an older Node is refused, located
    parse(Int, major) >= NODE_MIN_MAJOR || error(".github/workflows/ci.yml names Node $major, below test/runner.jl's " *
        "NODE_MIN_MAJOR $NODE_MIN_MAJOR: its V8 traps entering a try_table with a reference result " *
        "(test/src/runner.jl's \"a try_table of a reference result\" module)")
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
    # Julia's Char is a 32-bit primitive (base/boot.jl `primitive type Char <: AbstractChar 32`), its UTF-8 bytes
    # left-aligned: its wire form is those 32 bits, as WT lowers it to an i32 of them
    x isa Char && return ("i32", string(reinterpret(Int32, x)))
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
    T === Char && return reinterpret(Char, parse(Int32, s))   # the 32 bits back, never decoded or validated
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
// the standalone embedder's `dart` imports a module may take, dart's own test runner's
// (pkg/test_runner/lib/src/browser.dart:441 dartEmbedder, given as {dart: dartEmbedder} at :695): those
// the runtime's ports import, each as dart's runner writes it
const dartEmbedder = {
  // browser.dart:509-519
  stackTraceGetCurrent: () => new Error().stack,
  stackTraceToString: (trace) => {
    const stackString = trace.toString();
    const frames = stackString.split('\n');
    // Format of stack traces is:
    //   1. stackTraceGetCurrent (from this embedder object)
    //   2. module0.StackTrace.current <noInline>
    //   3. The callsite we care about.
    const drop = 1 + frames.findIndex((l) => l.indexOf('stackTraceGetCurrent') > 0);
    return frames.slice(drop).join('\n');
  },
};
const instances = new Map();
(async () => {
  for (const line of lines) {
    const [wasmB64, entry, rtype, ...args] = line.split(' ');
    let mi;
    try {
      mi = instances.get(wasmB64);
      if (mi === undefined) {
        const mod = await WebAssembly.compile(Buffer.from(wasmB64, 'base64'));
        const missing = WebAssembly.Module.imports(mod).filter(i => !(i.module === 'dart' && i.kind === 'function' && i.name in dartEmbedder));
        mi = missing.length > 0 ? { imports: missing.map(i => i.module + '.' + i.name) } :
          { mod, inst: await WebAssembly.instantiate(mod, {dart: dartEmbedder}) };
        instances.set(wasmB64, mi);
      }
      if (mi.imports) { process.stdout.write('err the module imports ' + mi.imports.join(', ') + ', which the runner does not provide\n'); continue; }
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
      // a wasm exception (the module's throw) apart from a trap (unreachable, an integer divided by zero); a wasm
      // exception counts only under the module's one exported tag, its exception tag (A61E1)
      if (e instanceof WebAssembly.Exception) {
        const tags = WebAssembly.Module.exports(mi.mod).filter(x => x.kind === 'tag');
        if (tags.length !== 1) process.stdout.write('err a wasm exception, and the module exports ' + tags.length + ' tags, not its one exception tag to match it against\n');
        else if (!e.is(mi.inst.exports[tags[0].name])) process.stdout.write('err a wasm exception under another tag than the module\'s exported ' + tags[0].name + '\n');
        else process.stdout.write('exc ' + why + '\n');
      } else process.stdout.write((e instanceof WebAssembly.RuntimeError ? 'err trap: ' : 'err ') + why + '\n');
    }
  }
})();
"""

"""
    run_cases(cases) -> Vector{RunResult}

Run every case, and each one's wasm-opt'd module, in one node process; compare each answer with
native Julia's, `===`, and the two modules' answers with each other.
"""
# a part of the modules one node reads, in characters of its input: well under node's 0x1fffffe8 a string
const RUN_PART_CHARS = 200_000_000

function run_cases(cases::AbstractVector{RunCase}; run_budget::Float64 = RUN_BUDGET, node_start::Float64 = NODE_START,
                   part_chars::Int = RUN_PART_CHARS)::Vector{RunResult}
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
            write(js, _JS)
            # the modules in parts, each read by a node of its own: node reads its input as one string, at most
            # 0x1fffffe8 characters, and the whole corpus's base64 modules passed that on 2026-11-09 (every case
            # read "node gave no answer: Cannot create a string longer than 0x1fffffe8")
            local parts = UnitRange{Int}[]
            local lo, size = 1, 0
            for (k, l) in enumerate(lines)
                if k > lo && size + sizeof(l) + 1 > part_chars
                    push!(parts, lo:k-1); lo, size = k, 0
                end
                size += sizeof(l) + 1
            end
            isempty(lines) || push!(parts, lo:length(lines))
            local answers = Vector{String}(undef, length(lines))
            for (p, part) in enumerate(parts)
                local inp = joinpath(dir, "cases-$p.txt")
                write(inp, join(lines[part], '\n') * "\n")
                local out = IOBuffer()
                local err = IOBuffer()
                local proc = run(pipeline(`$node $js $inp`; stdout = out, stderr = err); wait = false)
                local limit = run_budget * length(part) + node_start
                local killed = Ref(false)
                local watchdog = Timer(_ -> (process_running(proc) && (killed[] = true; kill(proc))), limit)
                wait(proc)
                close(watchdog)
                local got = split(String(take!(out)), '\n'; keepempty = false)
                local stderr_text = strip(String(take!(err)))
                for (j, k) in enumerate(part)
                    answers[k] = j <= length(got) ? String(got[j]) :
                        killed[] ? "err no answer within $(limit) s, node killed: a hang or a blow-up" : "err node gave no answer: $stderr_text"
                end
                rm(inp; force = true)
            end
            # each module's verdict: its answer read back, or why it has none
            local verdicts = Dict{Tuple{Int,Bool},Tuple{Bool,Any,String}}()
            for (k, (i, opt)) in enumerate(sent)
                local c = cases[i]
                local a = answers[k]
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
