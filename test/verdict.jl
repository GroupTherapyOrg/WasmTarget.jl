# ============================================================================
# THE verdict (spec v16 X1): a judge file (dev/climb/core.py JUDGE_READ, no move's rule admits it), the one place a
# module's answer is compared with native Julia's. The climb measures a candidate in four processes, and no file a move
# may edit is loaded in the one whose output is a verdict, nor is the answer handed to a process that runs code a move
# may edit (dev/climb/HILL.md, the oracle):
#   answer   test/smoke_judge.jl: native Julia's answer, one label a process, frozen in the store
#   compile  test/smoke.jl with WasmTarget (the measured src): handed each answer's SHAPE alone (test/oracle_read.jl's
#            Shape: never a value), it writes each case's modules and the calls that read them (`call` records: a module,
#            its entry, the case's wire arguments, which the corpus's own text holds)
#   run      test/runner.jl, the keeper's, and node: handed the modules and the calls alone, it writes each call's RAW
#            result in this file's wire grammar (below), one fresh instance a call; it never sees an answer
#   verdict  this file, run as `julia test/verdict.jl`: loads test/oracle.jl and test/oracle_read.jl by their owner and
#            never test/runner.jl, checks the runner's fixtures (where the driver drew them among the calls: place),
#            binds each stored answer to its case's modules (bind, the compile side's own binding), checks the
#            compile's calls are the answer's, decodes the raw wire by its own table and compares bits, writing each
#            case's outcome.
# The wire (the run's output, one line a call), a closed grammar whose leaf kinds are this file's (a NEW leaf kind is a
# judge edit, the lead's hand; a keeper ports the node script and the marshalling of a new wasm shape into these kinds):
#   ret <kind> <bits> <ms>    kind i32, i64, f32 or f64 with its bits as lowercase hex, 8 or 16 digits (a float's
#                             integer bits, never a decoded value); void (no result), null or ref (a reference result,
#                             null or not) with bits `-`; ms the call's milliseconds
#   exc <text>                a wasm exception under the module's one exported tag
#   err <text>                a trap (`err trap: …`), or anything else the run failed at (a module that does not
#                             compile, a call of other argument kinds), located
#   gap <text>                a shape the runner cannot call or read (no such entry, a reference argument, a result of
#                             several values, an import it does not give): the judge's gap, booked `runner-gap`
#                             (spec v18 P2), never wrong
# The calls' arguments cross the same way: `<kind>:<bits>`, a float as its integer bits, both directions bit-exact (the
# runner calls the export from a wasm wrapper, so no float crosses JS: spec v16 X1, red 5's signaling NaNs).
#
# Run:   WT_VERDICT_ANSWERS=<answers> WT_VERDICT_MODULES=<compile's records> WT_VERDICT_RAW=<the run's lines>
#        WT_VERDICT_PLAN=<the driver's plan of the run> WT_VERDICT_CASES=<out> julia test/verdict.jl          (JULIA_LOAD_PATH=@stdlib, no WasmTarget, no corpus)
# ============================================================================
isdefined(Main, :WTOracle) || Base.include(Main, joinpath(@__DIR__, "oracle.jl"))
isdefined(Main, :WTOracleRead) || Base.include(Main, joinpath(@__DIR__, "oracle_read.jl"))
module WTVerdict

import Base64
using ..WTOracle: WTOracle, Answer, Throws, Bound, _string_positions, _string_of, type_path
using ..WTOracleRead: WTOracleRead, Shape, ShapeGroup, read_answers, resolve_type_path

# a call's budget (D17): intent, a call answers in milliseconds; band, past RUN_BUDGET seconds it fails, naming its
# seconds (the runner's node watchdog kills a hang past RUN_BUDGET a call plus its own start)
const RUN_BUDGET = 5.0

# ---- the leaf kinds, closed: a Julia type's value crosses as the bits Julia stores, in the wasm type WT lowers it to
# (Bool, UInt8, Int32, UInt32 and Char, base/boot.jl's primitive types of 8 and 32 bits, an i32 zero-extended from their
# bytes; Int64 and UInt64 an i64; Float32 and Float64 their IEEE bits), and a singleton's value is its type (no bits: a
# call that returns no value, or a null reference)
const LEAF_TYPES = (Bool => :i32, UInt8 => :i32, Int32 => :i32, UInt32 => :i32, Char => :i32,
                    Int64 => :i64, UInt64 => :i64, Float32 => :f32, Float64 => :f64)
const NUMERIC = (:i32, :i64, :f32, :f64)
const _PATH_KINDS = Dict{String,Symbol}(type_path(T) => k for (T, k) in LEAF_TYPES)
"""    leaf_kind(T) -> Symbol or nothing

The wire's leaf kind of a value of type `T`: one of NUMERIC, :void for a singleton type, or nothing (no leaf kind: a
new one is the judge's edit)."""
function leaf_kind(@nospecialize(T))::Union{Symbol,Nothing}
    for (U, k) in LEAF_TYPES
        T === U && return k
    end
    return T isa DataType && Base.issingletontype(T) ? :void : nothing
end
# a leaf group's kind from its shape alone (its capture kind and its type path), so the compiling process (which holds
# a shape) and the verdict (which holds the answer: test/oracle_read.jl's Shape(a)) decide alike, resolving no type
_group_kind(kind::Symbol, tpath::String) = kind === :void ? :void : kind === :bits ? get(_PATH_KINDS, tpath, nothing) : nothing
"""A group of an answer's leaves is read by a reader when its leaves have a leaf kind and the case has at most 3 wire
arguments (Leaves's arities)."""
_readable(s::Shape, g::ShapeGroup) = s.nargs <= 3 && _group_kind(g.kind, g.tpath) !== nothing
_width(k::Symbol) = k === :i32 || k === :f32 ? 32 : 64
_hexbits(k::Symbol, v::UInt64) = string(v; base = 16, pad = _width(k) ÷ 4)
_unsigned(x) = sizeof(x) == 1 ? UInt64(reinterpret(UInt8, x)) : sizeof(x) == 4 ? UInt64(reinterpret(UInt32, x)) : reinterpret(UInt64, x)
"""    wire_bits(x) -> (kind, bits) or nothing

A value of a NUMERIC leaf kind as the wire carries it: its kind and its bytes zero-extended to the kind's width."""
wire_bits(x) = (k = leaf_kind(typeof(x)); k in NUMERIC ? (k, _unsigned(x)) : nothing)
"""A call's argument as the wire writes it, `<kind>:<bits>`, or nothing for a value of no NUMERIC kind."""
wire_arg(x) = (w = wire_bits(x); w === nothing ? nothing : "$(w[1]):$(_hexbits(w[1], w[2]))")

# ---- the raw wire, read
"""One call's raw result: `what` :ret, :exc or :err; a :ret's `kind` (NUMERIC, :void, :null or :ref) and `bits`; its
milliseconds; an :exc's or :err's text."""
struct Raw
    what::Symbol
    kind::Symbol
    bits::UInt64
    ms::Float64
    text::String
end
const _HEX = ('0':'9'..., 'a':'f'...)
"""    read_raw(line) -> Raw, or why the line reads as no raw result (a String)"""
function read_raw(line::AbstractString)::Union{Raw,String}
    local f = split(line, ' '; limit = 2)
    f[1] in ("exc", "err", "gap") && return Raw(Symbol(f[1]), :none, 0, 0.0, length(f) == 2 ? String(f[2]) : "")
    local g = split(line, ' ')
    local bad = "the runner wrote a line no raw result reads: $(first(line, 120))"
    (g[1] == "ret" && length(g) == 4) || return bad
    local ms = tryparse(Float64, g[4])
    (ms === nothing || !(ms >= 0)) && return bad
    local k = Symbol(g[2])
    if k in NUMERIC
        (length(g[3]) == _width(k) ÷ 4 && all(in(_HEX), g[3])) || return bad
        return Raw(:ret, k, parse(UInt64, g[3]; base = 16), ms, "")
    end
    (k in (:void, :null, :ref) && g[3] == "-") || return bad
    return Raw(:ret, k, 0, ms, "")
end
_raw_text(r::Raw) = r.what === :ret ? "ret $(r.kind) $(r.kind in NUMERIC ? _hexbits(r.kind, r.bits) : "-")" : "$(r.what) $(r.text)"

# ---- a case and its verdict
"""
    ReturnsRef()

What a case's own module must answer when its answer is read by readers (a tuple, a vector, a String): a reference,
non-null, returned without a trap. Its facts are the readers'; this is the module itself run.
"""
struct ReturnsRef end
"""
    ReturnsAny()

What a case's own module must answer when its answer is a singleton read by its reader (spec v17 Y2): any result,
returned without a trap or an exception; the value is the reader's to judge (`F(a...) isa T`), never the own module's
`void`, which every singleton type shares.
"""
struct ReturnsAny end
"""One fact a run reads: its modules (codegen's, and the wasm-opt'd one, empty for none), the wire arguments of its
entry, native Julia's answer (`nothing` in the compiling process, which is handed none), its entry ("" for the module's
one exported function) and why it is not read (`unread`, "" when it is: a reader WasmTarget rejects, a leaf of no leaf
kind, a reader of more arguments than Leaves's arities) and its outcome by cause (`gap`: :unported, a reader WasmTarget
rejects, the port's to do; :judge_gap, what the judge's wire cannot carry, the judge's; :none when it is read)."""
struct RunCase
    label::String
    bytes::Vector{UInt8}
    optimized::Vector{UInt8}
    args::Tuple
    native::Any
    entry::String
    unread::String
    gap::Symbol
end
RunCase(label, bytes, optimized, args, native, entry, unread) =
    RunCase(label, bytes, optimized, args, native, entry, unread, isempty(unread) ? :none : JUDGE_GAP)
RunCase(label, bytes, optimized, args, native, entry) = RunCase(label, bytes, optimized, args, native, entry, "")
RunCase(label, bytes, args, native; optimized::Vector{UInt8} = UInt8[], entry::String = "") =
    RunCase(label, bytes, optimized, args, native, entry, "")
# the outcome of what the judge's wire cannot carry (spec v17 Y2): no climber, no G1, counted apart in a score
const JUDGE_GAP = Symbol("judge-gap")
# the outcome of a shape the runner cannot call or read (spec v18 P2): the judge's too, the lead's hand
const RUNNER_GAP = Symbol("runner-gap")
"""
A fact's verdict by its cause (spec v17 Y2, v18 P2): `outcome` :passed; :wrong ONLY where a module's answer is not
native's (`_matches`, a trap or an exception where native answers) or the two modules disagree; `runner-gap`
(RUNNER_GAP) where the runner cannot call or read the shape (a `gap` line); :unported where WasmTarget rejects its reader; `judge-gap` (JUDGE_GAP) where
the judge's wire has no leaf kind for it; :errored for anything else (no line, past its budget); `why` located. `ok`
is derived: the outcome is :passed.
"""
struct RunResult
    label::String
    outcome::Symbol
    why::String
end
Base.getproperty(r::RunResult, s::Symbol) = s === :ok ? getfield(r, :outcome) === :passed : getfield(r, s)
Base.:(==)(a::RunResult, b::RunResult) = (a.label, a.outcome, a.why) == (b.label, b.outcome, b.why)

"""One call the run makes: its case (an index), whether it is the wasm-opt'd module, the module, its entry and its wire
arguments."""
struct Call
    case::Int
    opt::Bool
    bytes::Vector{UInt8}
    entry::String
    args::Vector{String}
end
"""
    plan(cases) -> (calls, decided)

Every call the run makes for `cases`, in order (a case's module, then its wasm-opt'd one), and each case decided without
a run, {case => why}: its reader rejected (unread), an argument of no leaf kind, or a reader that cannot be built (no
module), each with its outcome by cause, (outcome, why). A function of the cases' modules, entries and arguments alone, never of a native value: the compiling process,
which holds none, writes the same calls the verdict expects.
"""
function plan(cases::AbstractVector{RunCase})
    local calls, decided = Call[], Dict{Int,Tuple{Symbol,String}}()
    for (i, c) in enumerate(cases)
        if !isempty(c.unread)
            decided[i] = (c.gap, c.unread)
            continue
        end
        local args = map(wire_arg, c.args)
        if any(isnothing, args)
            local bad = unique(Any[typeof(a) for (a, w) in zip(c.args, args) if w === nothing])
            decided[i] = (JUDGE_GAP, "the judge's wire has no leaf kind for the argument type $(join(bad, ", ")) (a new leaf kind is the judge's edit)")
            continue
        end
        if isempty(c.bytes)
            decided[i] = (:errored, "it has no module to run")
            continue
        end
        for (opt, b) in ((false, c.bytes), (true, c.optimized))
            opt && isempty(b) && continue
            push!(calls, Call(i, opt, b, c.entry, collect(String, args)))
        end
    end
    return calls, decided
end

_fits(T, v::UInt64) = (8 * sizeof(T) >= 64 || v >> (8 * sizeof(T)) == 0) && (T !== Bool || v <= 1)
_from_bits(T, v::UInt64) = sizeof(T) == 1 ? reinterpret(T, UInt8(v)) : sizeof(T) == 4 ? reinterpret(T, UInt32(v)) : reinterpret(T, v)
# a raw result shown for a verdict's text: at native's type where its kind is native's and its bits fit the type
function _shown(r::Raw, native)::String
    r.kind === :void && return "no value"
    r.kind === :null && return "a null reference"
    r.kind === :ref && return "a reference"
    local T = typeof(native)
    leaf_kind(T) === r.kind && _fits(T, r.bits) && return repr(_from_bits(T, r.bits))
    return "the $(r.kind) 0x$(_hexbits(r.kind, r.bits))"
end
_native_text(native) = native isa ReturnsRef ? "a non-null reference (its answer is read by readers)" :
    native isa ReturnsAny ? "a value (its type is read by its reader)" : repr(native)
# the one comparison: a raw result against native's answer, by bits at native's leaf kind
function _matches(native, r::Raw)::Bool
    native isa ReturnsRef && return r.kind === :ref
    native isa ReturnsAny && return true
    local k = leaf_kind(typeof(native))
    # a singleton here is a reader's leaf, its export typeasserted to exactly that type (_pick, IsA's Bool aside), so
    # `void` is exact and a null is another value; a top-level singleton answer is its reader's (bind: ReturnsAny and
    # IsA), never its own module's `void`, which every singleton type shares (spec v17 Y2)
    k === :void && return r.kind === :void
    k in NUMERIC || return false
    local w = wire_bits(native)
    return r.kind === k && r.bits == w[2]
end

"""
    verdicts(cases, calls, decided, raws; run_budget) -> Vector{RunResult}

Each case's verdict from its calls' raw results (`raws[j]` the run's line for `calls[j]`, read_raw's), by cause (spec v17
Y2): passed when each of its modules answers native's value (bits at native's leaf kind; a wasm exception where native
throws; a non-null reference for a read answer's own module; any result for a singleton's, whose reader reads its type)
and the two modules answer alike; wrong where a module answers otherwise or the two disagree; the plan's decision for a
case it decided; judge-gap for a native of no leaf kind; errored for a line missing or a call past its budget.
"""
function verdicts(cases::AbstractVector{RunCase}, calls::AbstractVector{Call}, decided::AbstractDict, raws::AbstractVector;
                  run_budget::Float64 = RUN_BUDGET)::Vector{RunResult}
    local got = Dict{Tuple{Int,Bool},Any}()
    for (j, c) in enumerate(calls)
        got[(c.case, c.opt)] = j <= length(raws) ? raws[j] : "the runner wrote no line for it"
    end
    local out = RunResult[]
    for (i, c) in enumerate(cases)
        if haskey(decided, i)
            push!(out, RunResult(c.label, decided[i]...)); continue
        end
        local native = c.native
        if !(native isa Throws || native isa ReturnsRef || native isa ReturnsAny || leaf_kind(typeof(native)) !== nothing)
            push!(out, RunResult(c.label, JUDGE_GAP, "the judge's wire has no leaf kind for $(typeof(native)) (a new leaf kind is the judge's edit)"))
            continue
        end
        local wrong, errored, gaps, answered = String[], String[], String[], Raw[]
        for opt in (false, true)
            haskey(got, (i, opt)) || continue
            local which = opt ? "the wasm-opt'd module" : "the module"
            local r = got[(i, opt)]
            if r isa String
                push!(errored, "$which: $r")
            elseif r.what === :gap   # a shape the runner cannot call or read: the judge's gap (spec v18 P2)
                push!(gaps, "$which: $(r.text)")
            elseif r.what === :err   # a trap is the module's answer (wrong); any other failure of the run is no answer
                push!(startswith(r.text, "trap:") ? wrong : errored,
                      "$which: $(r.text)" * (native isa Throws ? ", where native Julia throws $(native.type)" : ""))
            elseif r.what === :exc
                native isa Throws ? push!(answered, r) :
                    push!(wrong, "$which: throws a wasm exception ($(r.text)), where native Julia answers $(_native_text(native))")
            elseif native isa Throws
                push!(wrong, "$which: returns, where native Julia throws $(native.type)")
            elseif r.ms / 1000 > run_budget
                push!(errored, "$which: ran $(round(r.ms / 1000; digits = 1)) s, past its $(run_budget) s budget")
            else
                push!(answered, r)
                _matches(native, r) || push!(wrong, "$which answers $(_shown(r, native)), native Julia $(_native_text(native))")
            end
        end
        length(answered) == 2 && !(native isa ReturnsAny) &&
            (answered[1].what, answered[1].kind, answered[1].bits) != (answered[2].what, answered[2].kind, answered[2].bits) &&
            push!(wrong, "the module and the wasm-opt'd module differ: $(_shown(answered[1], native)) against $(_shown(answered[2], native))")
        push!(out, !isempty(wrong) ? RunResult(c.label, :wrong, join([wrong; errored; gaps], "; ")) :
                   !isempty(errored) ? RunResult(c.label, :errored, join([errored; gaps], "; ")) :
                   !isempty(gaps) ? RunResult(c.label, RUNNER_GAP, join(gaps, "; ")) : RunResult(c.label, :passed, ""))
    end
    return out
end
"""    case_outcome(rs) -> (outcome, why)

A case's outcome from its facts' (spec v17 Y2, v18 P2): wrong over errored over unported over runner-gap over
judge-gap over passed; a case
with no fact is errored (a case with no run is no pass, R7-1)."""
function case_outcome(rs::AbstractVector{RunResult})::Tuple{Symbol,String}
    isempty(rs) && return (:errored, "its answer binds no run")
    for o in (:wrong, :errored, :unported, RUNNER_GAP, JUDGE_GAP)
        any(r -> r.outcome === o, rs) && return (o, join(("$(r.label) $(r.why)" for r in rs if r.outcome !== :passed), "; "))
    end
    return (:passed, "")
end

# ---- the binding: an answer's cases, each with its modules. A tuple answer leaves the module as a reference to a wasm
# struct, which no wire reads: its facts are read in wasm by a reader, a program calling the case's function and
# returning the fact a run-time index picks, one reader per leaf group, its index chain over the leaves' paths spelt out
# by Julia's own @generated (the paths and their steps are test/oracle.jl's _leaves and _step; _step_ex is _step as an
# expression). The precedent is dart's own test: its main reads the facts it asserts inside the program (Expect).
_step_ex(e, i::Int) = :(getfield($e, $i))
_step_ex(e, s::Tuple{Symbol,Int}) = s[1] === :cu ? :(codeunit($e, $(s[2]))) : :(getindex($e, $(s[2])))
_step_ex(e, s::Symbol) = s === :ncu ? :(Int64(ncodeunits($e))) : :(Int64(length($e)))
# a reader's pick is typeasserted to its leaves' type, native's, so its export returns that type even where the answer
# holds the leaf as Any (a record of Any fields)
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

# a scalar answer that is a type (spec v17 Y2) is read in wasm too, by a reader the judge builds, its leaf one i32:
# Catches, a throw's (`try F(a...); 0 catch e; e isa T ? 1 : 2 end`, its leaf must be 1: the exception's type is
# native's), and IsA, a singleton's (`F(a...) isa T`, its leaf must be true: the value is native's one instance; a
# `void` result alone is shared by every singleton type and a null by every reference). precedent(dart's own tests:
# Expect.throws<T> and `is T`, read inside the program). Fixed arities, as Leaves's
struct Catches{F,T} <: Function end
struct IsA{F,T} <: Function end
# the type a throw reader tests is the caught value's (spec v18 P1, red round 15 1): Julia's inference knows F's
# exception type, and where it is one singleton type the optimizer replaces the caught value with that constant and
# folds `e isa T`, so the module would answer 1 for any exception under its tag. The try body first may throw the
# judge's own marker, reached behind an inference barrier (never at run time) and BEFORE F (spec v19 P1: after an F
# that always throws it was dead code), so the caught value's type is a union
# and `e isa T` is a test the module runs on the value it caught; a reader WasmTarget rejects is `unported`, never a
# pass. A throw answer is read by its type alone: two exceptions of one type and different messages read alike
struct _JudgeMark <: Exception end
_caught(e, ::Type{T}) where {T} = e isa T ? Int32(1) : Int32(2)
_unfolded() = Base.inferencebarrier(nothing) === 0 && throw(_JudgeMark())
(::Catches{F,T})() where {F,T} = try _unfolded(); F(); Int32(0) catch e; _caught(e, T) end
(::Catches{F,T})(a) where {F,T} = try _unfolded(); F(a); Int32(0) catch e; _caught(e, T) end
(::Catches{F,T})(a, b) where {F,T} = try _unfolded(); F(a, b); Int32(0) catch e; _caught(e, T) end
(::Catches{F,T})(a, b, c) where {F,T} = try _unfolded(); F(a, b, c); Int32(0) catch e; _caught(e, T) end
(::IsA{F,T})() where {F,T} = F() isa T
(::IsA{F,T})(a) where {F,T} = F(a) isa T
(::IsA{F,T})(a, b) where {F,T} = F(a, b) isa T
(::IsA{F,T})(a, b, c) where {F,T} = F(a, b, c) isa T

"""An answer bound to another case or another compile than its own: the binding's refusal, located."""
struct BindMismatch <: Exception
    text::String
end
Base.showerror(io::IO, e::BindMismatch) = print(io, e.text)
"""A reader's rejection as the verdict reads it from the compiling process's records."""
struct ReaderRejected <: Exception
    text::String
end
Base.showerror(io::IO, e::ReaderRejected) = print(io, e.text)
# a reader WasmTarget rejects as Unported or Unquarantined (read by its type's names: the verdict loads no WasmTarget),
# or the verdict's record of one
_reader_rejected(e) = e isa ReaderRejected ||
    nameof(typeof(e)) === :RejectionError && nameof(typeof(e.rejection)) in (:Unported, :Unquarantined)

# a program's modules: `compile(f, T; optimize = false)`, codegen's, and `compile(f, T)`, which dartdev's default phases
# end with opt (wasm-opt), or `own` when the caller holds that compile already; none when `optimized` is false
function _modules(compile, f, args::Tuple; optimized::Bool = true, own::Vector{UInt8} = UInt8[])::Tuple{Vector{UInt8},Vector{UInt8}}
    local argtypes = Tuple(map(typeof, args))
    local plain = compile(f, argtypes; optimize = false)
    local opt = !optimized ? UInt8[] : isempty(own) ? compile(f, argtypes) : own
    return (plain, isempty(opt) || opt == plain ? UInt8[] : opt)
end

# the String at path `p` of an aggregate answer, rebuilt from its stored leaves: its ncodeunits and each codeunit
function _string_at(a::Answer, p::Tuple)::String
    local at = Dict{Tuple,Any}(q => v for g in a.groups for (q, v) in zip(g.paths, g.leaves))
    return String(UInt8[at[(p..., (:cu, i))] for i in 1:at[(p..., :ncu)]])
end

"""
    bind(s, args, compile; a, f, optimized, own, world) -> Vector{RunCase}

The cases that read an answer of shape `s` (test/oracle_read.jl's Shape) from wasm, in order: its own modules, then, for
an answer read by readers, the own modules again (a non-null reference) and one reader per leaf group whose leaves have
a leaf kind (_readable), each leaf a case of its reader labelled by its path; a leaf no reader can read is a case with no
module, and a reader WasmTarget rejects as Unported or Unquarantined leaves its facts unread (a String's once). The ONE
binding, three callers:
- the compiling process: `f` the case's function and `args` its registration's arguments (its Strings bound where the
  shape's are: Bound), each module compiled by `compile(prog, argtypes; optimize)` (WasmTarget.compile's form), `a`
  nothing (it holds no answer): the cases' natives are `nothing`, their calls (plan) its `call` records;
- the verdict: `f` nothing, `a` the stored answer (s = Shape(a)), `args` its wire arguments, and `compile(key; optimize)`
  pops the compiling process's record of that compile (a module, or a reader's rejection), in order;
- a process that compiles and answers itself (test/smoke.jl standalone, test/runner.jl's answer_cases): `f`, `a` and
  `compile` WasmTarget's, `own` the own modules it compiled before the answer.
Nothing here calls the case's function natively.
"""
function bind(s::Shape, args::Tuple, compile; a::Union{Answer,Nothing} = nothing, f = nothing, optimized::Bool = true,
              own = nothing, world::UInt = Base.get_world_counter())::Vector{RunCase}
    local f′, args′ = nothing, args
    if f !== nothing   # the program the shape is of: the registration's Strings bound where the shape's are
        local P = _string_positions(args)
        local S = Tuple(Symbol(args[i]) for i in P)
        (P == s.P && S == s.S) || throw(BindMismatch("the answer binds the String arguments $(s.P), the case's are at $P"))
        f′, args′ = isempty(P) ? (f, args) : (Bound{f,P,S}(), Tuple(x for x in args if !(x isa String)))
    end
    length(args′) == s.nargs || throw(BindMismatch("the answer has $(s.nargs) wire arguments, the case $(length(args′))"))
    local mods(prog, xs, key) = f === nothing ? _modules((_, _; optimize = true) -> compile(key; optimize), nothing, xs; optimized) :
        _modules(compile, prog, xs; optimized)
    local plain, opt = own !== nothing ? own : mods(f′, args′, s.key)
    local native = a === nothing ? nothing : a.native
    s.aggregate || s.native_kind !== :none || return RunCase[RunCase(s.label, plain, opt, args′, native, "", "")]
    if !s.aggregate   # a type where the answer is a type (spec v17 Y2): the own modules, then the type's reader
        local throws = s.native_kind === :throws
        local cs = RunCase[RunCase(s.label, plain, opt, args′, throws ? native : ReturnsAny(), "", "")]
        local what = throws ? "(its exception's type)" : "(its value's type)"
        local want = throws ? Int32(1) : true
        if s.nargs > 3
            push!(cs, RunCase("$(s.label)$what", UInt8[], UInt8[], args′, want, "",
                              "the judge reads a type for a case of at most 3 arguments, this one has $(s.nargs)", JUDGE_GAP))
            return cs
        end
        try
            local prog = f === nothing ? nothing :
                (throws ? Catches : IsA){f′,resolve_type_path(s.native_tpath; world)}()
            local rp, ro = mods(prog, args′, s.key)
            push!(cs, RunCase("$(s.label)$what", rp, ro, args′, want, "", "", :none))
        catch e
            _reader_rejected(e) || rethrow()
            push!(cs, RunCase("$(s.label)$what", UInt8[], UInt8[], args′, want, "",
                              "the runner does not read it yet, its reader is rejected: " * first(sprint(showerror, e), 300), :unported))
        end
        return cs
    end
    # the own modules run too, a read answer's: a non-null reference, returned without a trap
    local out = RunCase[RunCase("$(s.label)(own module)", plain, opt, args′, ReturnsRef(), "", "")]
    for (gi, g) in enumerate(s.groups)
        local leaves = a === nothing ? nothing : a.groups[gi].leaves
        local leaf(k) = leaves === nothing ? nothing : leaves[k]
        local readable = _readable(s, g)
        local reader, why = nothing, ""
        if !readable   # no reader: each leaf unread, the judge's reason named
            why = s.nargs > 3 ? "the judge reads a tuple's leaves for a case of at most 3 arguments, this one has $(s.nargs)" :
                "the judge's wire has no leaf kind for $(WTOracleRead._path_name(g.tpath)) (a new leaf kind is the judge's edit)"
        else
            try
                local prog = f === nothing ? nothing : Leaves{f′,Tuple(g.paths),resolve_type_path(g.tpath; world)}()
                local rp, ro = mods(prog, (args′..., Int64(1)), s.rkey)
                reader = (bytes = rp, optimized = ro)
            catch e
                _reader_rejected(e) || rethrow()
                why = "the runner does not read it yet, its reader is rejected: " * first(sprint(showerror, e), 300)
            end
        end
        if !isempty(why)   # each leaf unread, a String's once, by its cause: a reader rejected is the port's
            for p in unique(g.on_string ? map(_string_of, g.paths) : g.paths)
                any(c -> c.label == "$(s.label)$p", out) ||
                    push!(out, RunCase("$(s.label)$p", UInt8[], UInt8[], (args′..., Int64(1)),
                                       a === nothing ? nothing : g.on_string ? _string_at(a, p) : leaf(findfirst(==(p), g.paths)),
                                       "", why, readable ? :unported : JUDGE_GAP))
            end
            continue
        end
        for (k, p) in enumerate(g.paths)
            push!(out, RunCase("$(s.label)$p", reader.bytes, reader.optimized, (args′..., Int64(k)), leaf(k), ""))
        end
    end
    return out
end

# ---- the runner's fixtures (G5: test/fixtures/runner_calls.tsv, the driver's to interleave, and test/fixtures/runner_raw.tsv,
# each call's exact raw wire, `<name>\t<raw>`, ms left out): the runner's fidelity, checked before any case is judged.
# A lossy marshal (two wasm values to one wire value) or a runner that answers anything but the module's own result fails
# here, located by the fixture's name, and the run part fails as the runner's
const FIXTURES = joinpath(@__DIR__, "fixtures")
"""    fixtures() -> [(name, the raw line without its ms)]"""
fixtures(dir::AbstractString = FIXTURES) =
    [(String(f[1]), String(f[2])) for f in (split(l, '\t'; limit = 2) for l in eachline(joinpath(dir, "runner_raw.tsv"))
                                           if !isempty(l) && !startswith(l, '#'))]
# a raw line as a fixture compares it: its ms left out
_fixture_text(line::AbstractString) = (r = read_raw(line); r isa Raw ? _raw_text(r) : String(line))
# ---- the drawn fixtures (spec v17 Y1): the driver interleaves the fixture calls among a measurement's calls at
# positions it draws each run, every module under a label drawn as the cases' are, and adds calls whose wire follows from
# what it drew: the frozen identities of test/fixtures/runner.wat called with drawn arguments, and test/fixtures/
# runner_patch.wat's slots, each a constant the driver writes at the slot's byte offset of the frozen bytes
# (runner_patch.tsv). Its plan (WT_VERDICT_PLAN) names each run line's call in run order, one line a call:
#   case <n>                           the n-th `call` record of the compile's (the judged calls, in their order)
#   frozen <k>                         the k-th call of runner_calls.tsv (its wire runner_raw.tsv's k-th)
#   ident <entry> <kind>:<bits>        runner.wat's identity export <entry> called with a drawn argument
#   patched <export> <bits> [<arg>]    runner_patch.wat's slot <export> holding the drawn <bits> (p_add called with <arg>)
#   patched <export>                   runner_patch.wat's export of no slot (a trap, a throw), in the same drawn bytes
# and the wire each fixture must produce follows from it by this table alone: the driver writes no expected line
const IDENTITIES = ("i32" => :i32, "i64" => :i64, "f32" => :f32, "f64" => :f64)
const PATCH_SLOTS = ("p_i32" => :i32, "p_i64" => :i64, "p_f32" => :f32, "p_f64" => :f64, "p_add" => :i64)
const PATCH_FIXED = ("p_trap" => "err trap: unreachable", "p_throw" => "exc [object WebAssembly.Exception]")
_kind_of(table, name) = (i = findfirst(p -> p.first == name, table); i === nothing ? nothing : table[i].second)
function _drawn_bits(k::Symbol, hex::AbstractString)::UInt64
    (length(hex) == _width(k) ÷ 4 && all(in(_HEX), hex)) || throw(ArgumentError("the plan's $k bits $(repr(hex)) are not $(_width(k) ÷ 4) hex digits"))
    return parse(UInt64, hex; base = 16)
end
"""    fixture_wire(fields, want) -> (name, wire)

A plan line's fixture (its fields after the first, `frozen`, `ident` or `patched`) as a fixture compares it: its name and
the exact raw wire it must produce, `want` the frozen calls' (fixtures()). A line that does not read throws."""
function fixture_wire(f::AbstractVector, want)::Tuple{String,String}
    if f[1] == "frozen" && length(f) == 2
        local k = parse(Int, f[2])
        1 <= k <= length(want) || throw(ArgumentError("the plan names frozen fixture $k of $(length(want))"))
        return want[k]
    elseif f[1] == "ident" && length(f) == 3
        local k = _kind_of(IDENTITIES, f[2])
        local a = split(f[3], ':')
        (k !== nothing && length(a) == 2 && a[1] == f[2]) || throw(ArgumentError("the plan's identity $(join(f, ' ')) does not read"))
        return ("the $(f[2]) identity of the drawn $(f[3])", "ret $k $(_hexbits(k, _drawn_bits(k, a[2])))")
    elseif f[1] == "patched" && length(f) == 2
        local w = _kind_of(PATCH_FIXED, f[2])
        w === nothing && throw(ArgumentError("the plan names no export of runner_patch.wat: $(f[2])"))
        return ("the patched module's $(f[2])", w)
    elseif f[1] == "patched" && length(f) in (3, 4)
        local k = _kind_of(PATCH_SLOTS, f[2])
        k === nothing && throw(ArgumentError("the plan names no slot of runner_patch.wat: $(f[2])"))
        local bits = _drawn_bits(k, f[3])
        if f[2] == "p_add"   # its argument plus the slot's bits, mod 2^64
            local a = length(f) == 4 ? split(f[4], ':') : String[]
            (length(a) == 2 && a[1] == "i64") || throw(ArgumentError("the plan's p_add names no i64 argument"))
            return ("the patched p_add of the drawn $(f[3]) to $(f[4])", "ret i64 $(_hexbits(:i64, _drawn_bits(:i64, a[2]) + bits))")
        end
        length(f) == 3 || throw(ArgumentError("the plan's slot $(f[2]) takes no argument"))
        return ("the patched $(f[2]) holding the drawn $(f[3])", "ret $k $(_hexbits(k, bits))")
    end
    throw(ArgumentError("a plan line that names no call: $(join(f, ' '))"))
end
"""
    place(raws, plan; want) -> (fixture raws, fixture wants, case raws)

The run's lines split by the driver's plan (one line a run line, in run order): each fixture's line with the wire it must
produce, and each judged call's line at its ordinal among the compile's `call` records (`nothing` where the run wrote no
line). A plan that does not name each ordinal once, from 1, throws: the driver's own fault, never a verdict."""
function place(raws::AbstractVector, plan; want = fixtures())
    local fx, fw, cases = String[], Tuple{String,String}[], Dict{Int,Any}()
    for (i, ln) in enumerate(plan)
        local f = split(ln, '\t')
        local got = i <= length(raws) ? raws[i] : nothing
        if f[1] == "case" && length(f) == 2
            local n = parse(Int, f[2])
            haskey(cases, n) && throw(ArgumentError("the plan names call $n twice"))
            cases[n] = got
        else
            push!(fw, fixture_wire(f, want)); push!(fx, got === nothing ? "no line" : got)
        end
    end
    sort(collect(keys(cases))) == 1:length(cases) || throw(ArgumentError("the plan's calls are not 1 to $(length(cases))"))
    return fx, fw, Any[cases[n] for n in 1:length(cases)]
end

"""    fixture_failures(raws, want) -> [why]: each fixture whose line is not its exact raw wire, named"""
function fixture_failures(raws::AbstractVector, want)::Vector{String}
    local bad = String[]
    for (k, (name, w)) in enumerate(want)
        local got = k <= length(raws) ? _fixture_text(raws[k]) : "no line"
        got == w || push!(bad, "the runner's fixture $name wrote `$(first(got, 160))`, its wire is `$w`")
    end
    return bad
end

# ---- the verdict process
_b64text(s) = String(Base64.base64decode(s))
# a case's text as the cases file holds it
_case_line(label, outcome, secs, why) = (t = replace(why, r"\s+" => " ");
    string(label, '\t', outcome, '\t', round(secs; digits = 2), '\t', length(t) > 500 ? first(t, 500) * "…" : t))

"""
    judge(modules, answers, raws; want, run_plan, run_budget) -> (records, failures, summary)

The verdict of a measurement: `modules` the compiling process's records as the driver framed them (each case's block
whole: its `module`, `rejected` and `call` records, then one `compiled` or `row`), `answers` the stored answers' records,
`raws` the run's lines (the fixtures' first, `want`; with `run_plan`, the driver's plan of the run, each fixture where the
plan places it, place's). Every label the records frame is judged, in their order, and nothing
else: a row keeps the compiling process's outcome (unported, outside or errored alone); a compiled case's answer is bound
to exactly its modules (bind: each compile the answer asks for pops the case's next record), its calls must be exactly
the ones its answer's binding makes (plan), and each call's raw line (the run's, in call order after the fixtures) is
judged (verdicts). A case with no answer, a module missing or one more than its answer asks for, a key that differs, or
calls not its answer's is errored, located. Returns ([(label, outcome, secs, why)], [failure lines], counts), or throws
FixtureFailure when the runner fails a fixture.
"""
function judge(modules, answers, raws::AbstractVector; want = fixtures(), run_plan = nothing, run_budget::Float64 = RUN_BUDGET)
    local bad, raw = if run_plan === nothing   # the fixtures first, then the calls in order (test/smoke.jl standalone)
        fixture_failures(raws, want), Any[raws[length(want)+1:end]...]
    else   # the driver's plan: the fixtures where it drew them (spec v17 Y1)
        local fx, fw, cr = place(raws, run_plan; want)
        fixture_failures(fx, fw), cr
    end
    isempty(bad) || throw(FixtureFailure(join(bad, "; ")))
    local order, frame = String[], Dict{String,Any}()
    local queue = Dict{String,Vector{Tuple{String,String,String,Int}}}()   # (kind, key, payload, the label's module index)
    local calls = Dict{String,Vector{Tuple{Int,String,Vector{String},Int}}}()   # (module index, entry, args, raw line)
    local nmod, ncall, twice = Dict{String,Int}(), 0, Set{String}()
    for ln in modules
        local f = split(ln, '\t')
        length(f) >= 3 || continue
        local l = String(f[2])
        if f[1] in ("row", "compiled")
            haskey(frame, l) ? push!(twice, l) : push!(order, l)
            frame[l] = f[1] == "row" && length(f) >= 5 ?
                (:row, String(f[3]), something(tryparse(Float64, f[4]), 0.0), _b64text(f[5])) :
                (:compiled, something(tryparse(Float64, f[3]), 0.0))
        elseif f[1] == "module" && length(f) >= 4
            local j = get(nmod, l, 0); nmod[l] = j + 1
            push!(get!(queue, l, Tuple{String,String,String,Int}[]), ("module", String(f[3]), String(f[4]), j))
        elseif f[1] == "rejected" && length(f) >= 4
            push!(get!(queue, l, Tuple{String,String,String,Int}[]), ("rejected", String(f[3]), String(f[4]), -1))
        elseif f[1] == "call" && length(f) >= 4
            ncall += 1   # every call record is a line of the run's, in order, whatever its label's verdict
            push!(get!(calls, l, Tuple{Int,String,Vector{String},Int}[]),
                  (something(tryparse(Int, f[3]), -1), String(f[4]), String.(f[5:end]), ncall))
        end
    end
    local count = Dict(:passed => 0, :unported => 0, :outside => 0, :wrong => 0, :errored => 0, JUDGE_GAP => 0, RUNNER_GAP => 0)
    local failures, records = String[], Tuple{String,Symbol,Float64,String}[]
    local book(l, o, secs, why) = (count[o] += 1; o === :errored && push!(failures, "ERROR $l  $why"); o === :wrong &&
                                   push!(failures, "WRONG $l  $why"); push!(records, (l, o, secs, why)))
    local stored = read_answers(answers)
    for l in order
        local fr = frame[l]
        if l in twice
            book(l, :errored, 0.0, "the compiling process's records frame it more than once"); continue
        elseif fr[1] === :row
            Symbol(fr[2]) in (:unported, :outside, :errored) ? book(l, Symbol(fr[2]), fr[3], fr[4]) :
                book(l, :errored, fr[3], "the compiling process wrote the outcome $(repr(fr[2])), which only a judgement gives")
            continue
        end
        local a, secs, q = get(stored, l, nothing), fr[2], copy(get(queue, l, Tuple{String,String,String,Int}[]))
        if !(a isa Answer)
            book(l, :errored, secs, a === nothing ? "the driver's answers hold none for a case the compiling process compiled" : a)
            continue
        end
        local index = IdDict{Any,Int}()   # each popped module's index among its label's module records
        local pop(key; optimize::Bool = true) = begin
            local want_ = string(key, optimize ? "" : " unoptimized")
            isempty(q) && throw(BindMismatch("the compiling process compiled no module for $want_, which its answer asks for"))
            local kind, k, payload, j = popfirst!(q)
            k == want_ || throw(BindMismatch("the compiling process compiled $k where its answer asks for $want_"))
            kind == "module" || throw(ReaderRejected(_b64text(payload)))
            local b = Base64.base64decode(payload); index[b] = j
            b
        end
        local cs = try
            bind(Shape(a), a.args, pop; a)
        catch e
            e isa BindMismatch || rethrow()
            book(l, :errored, secs, sprint(showerror, e)); continue
        end
        if !isempty(q)
            book(l, :errored, secs, "the compiling process compiled $(length(q)) module(s) more than its answer asks for"); continue
        elseif isempty(cs)
            book(l, :errored, secs, "its answer binds no run"); continue
        end
        local ps, decided = plan(cs)
        local have = get(calls, l, Tuple{Int,String,Vector{String},Int}[])
        local expect = [(get(index, c.bytes, -2), isempty(c.entry) ? "-" : c.entry, c.args) for c in ps]
        if [(h[1], h[2], h[3]) for h in have] != expect
            local k = findfirst(i -> i > length(have) || i > length(expect) || (have[i][1], have[i][2], have[i][3]) != expect[i],
                                1:max(length(have), length(expect)))
            book(l, :errored, secs, "the compiling process's calls are not its answer's: it wrote $(length(have)), its answer makes " *
                 "$(length(expect)), the first to differ is call $k" *
                 (k <= length(have) && k <= length(expect) ? " ($(join(have[k][3], ' ')) to module $(have[k][1]), where its answer passes " *
                  "$(join(expect[k][3], ' ')) to module $(expect[k][1]))" : ""))
            continue
        end
        local rs = verdicts(cs, ps, decided, Any[h[4] <= length(raw) && raw[h[4]] !== nothing ? read_raw(raw[h[4]]) :
                                                 "the runner wrote no line for it" for h in have];
                            run_budget)
        book(l, case_outcome(rs)[1], secs, case_outcome(rs)[2])   # by cause (spec v17 Y2)
    end
    return records, failures, count
end
"""The runner failed a fixture: the run part fails as the runner's, each fixture named."""
struct FixtureFailure <: Exception
    text::String
end
Base.showerror(io::IO, e::FixtureFailure) = print(io, e.text)

# the verdict process's entry: its inputs by environment, its cases written, a summary printed; a fixture the runner fails
# writes no case and exits 3, the run part the runner's failure (dev/climb/measure.py smoke)
function main()
    local env(k) = (v = get(ENV, k, ""); isempty(v) ? error("test/verdict.jl: $k names no file (dev/climb/measure.py smoke)") : v)
    local t0 = time()
    local records, failures, count = try
        judge(eachline(env("WT_VERDICT_MODULES")), eachline(env("WT_VERDICT_ANSWERS")), readlines(env("WT_VERDICT_RAW"));
              run_plan = readlines(env("WT_VERDICT_PLAN")))
    catch e
        e isa FixtureFailure || rethrow()
        # one bounded line: the driver reads a log's head and tail alone (measure.log_excerpt), and every fixture of a
        # runner with no node fails at once (probed: 54 failures in one line of tens of KB, the prefix out of the tail)
        println("verdict: the runner fails its fixtures: ", length(e.text) > 800 ? first(e.text, 800) * "…" : e.text)
        exit(3)
    end
    open(env("WT_VERDICT_CASES"), "w") do io
        foreach(r -> println(io, _case_line(r...)), records)
    end
    println("\n" * "="^60)
    foreach(fl -> println("  ", fl), failures)
    println("="^60)
    println("verdict: $(count[:passed]) passed, $(count[:wrong]) wrong, $(count[:errored]) errored, " *
            "$(count[:unported] + count[:outside]) loud ($(count[:unported]) unported, $(count[:outside]) outside the subset), " *
            "$(count[JUDGE_GAP]) judge-gap, $(count[RUNNER_GAP]) runner-gap  " *
            "($(round(time() - t0; digits = 1))s)")
    exit(0)
end

end # module WTVerdict

abspath(PROGRAM_FILE) == (@__FILE__) && WTVerdict.main()
