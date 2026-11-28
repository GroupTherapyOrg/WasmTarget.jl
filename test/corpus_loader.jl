# The corpus's added forms, loaded by Julia's own answers (dev/climb/HILL.md, the corpus). The snapshot,
# test/smoke_corpus.jl as it stood at the oracle's bootstrap, is included into Main as before; every form a later landing
# adds is in a unit, test/corpus/<slug>.jl, one file and one module per landing, loaded here in landing order:
#
#   load_units(paths; register, labels)   each unit's forms, one at a time: macros from a closed table, lowered by Julia
#                                         (Meta.lower), the lowered code run by the loader itself one statement at a
#                                         time (the stepper), each statement run only once its real operands are
#                                         checked against closed lists; then the form's new methods read back
#   judge!(world, modules)                the judge's world and names, recorded before the snapshot loads
#
# What a unit's form may run at load: the callees of THE callee table (CALLEES: pure builtins, readers on what _reader!
# admits, writers on the unit's own module or types, a definition's machinery at the judge's world, a constant's
# arithmetic), each checked with its real callee and arguments as the stepper reaches it, the branch taken by the value
# it has, any other statement refused by name (a `try`'s Core.EnterNode among them). Every read a load makes passes _reader! and every write _writer!, _bind! or _one!,
# so a unit's load is a function of its text, Julia's build and the snapshot: the same program in every process that
# loads it, and its digest (the writes, in a form the same in every process) says which (spec v13 R1). Everything else a
# definition holds is a body, which runs when a case calls it. A unit's registration (`_g`/`_xf`) is read, never
# evaluated: its labels literal, its functions a lambda or a function the unit defines, its arguments values of Base's the
# stepper computes (as any form: Julia lowers, the stepper runs).
# The worlds: a label of a unit is inferred, compiled and answered at the world just after its unit loaded, the
# judge's code at the world before the snapshot (test/smoke.jl), so a later unit's methods reach no earlier label and
# no judge (dev/climb/HILL.md, the corpus's four premises).
#
#   julia --startup-file=no test/corpus_loader.jl --labels <file>...
#       the driver's reader of the labels a corpus file registers (`registered`): `label\t<group>/<case>` each
#   julia --startup-file=no test/corpus_loader.jl --check <root>
#       G5's run (dev/climb/measure.py corpus_problems): <root>/test/smoke_corpus.jl and the units under <root>/test/corpus,
#       in the order <root>/units.log gives, loaded with no WasmTarget and no runner; prints `label\t<group>/<case>` for
#       each label a unit registers and `refused\t<unit>\t<line>\t<why>\t<form>` for the first form refused
module CorpusLoader

import SHA

# THE judge's modules (spec v16 X8, v17 Y6), named once: no unit adds a method to a function of one (_owner_refusal:
# "the judge's or the compiler's"; test/smoke_judge.jl hands those a process holds to judge!), and the ratchet's L204
# checks the list is exactly the modules the judge's Julia files define (dev/climb/core.py JUDGE_WRITE, JUDGE_READ) and
# WasmTarget, the compiler. test/runner.jl's WTRunner is the judge's since spec v18 P2 (no process that loads a corpus
# loads it, spec v16 X1: named here for the one list's sake, absent wherever a corpus is)
const JUDGE_MODULES = (:WTOracle, :WTOracleRead, :WTVerdict, :WTChild, :WTRunner, :CorpusLoader, :WasmTarget)

"""A unit's form the loader refuses, located: its file, its line, why, and the form's text."""
struct Refusal <: Exception
    unit::String
    line::Int
    why::String
    text::String
end
Base.showerror(io::IO, e::Refusal) = print(io, "the corpus loader refuses ", e.unit, ":", e.line, ": ", e.why, ": ", e.text)

# ---- the closed tables
# The macros a unit's form may hold, anywhere in it: Base's macros the corpus uses, none of which runs its arguments
# as it expands (`@static` does, and `@generated` defines a generator), named by the macro function itself, resolved
# once here (a name a unit could rebind is no part of the test). Not here: `@big_str` (its value, a BigInt or BigFloat,
# is one the digest cannot state, and its expansion reads MPFR's process-global precision: spec v14 V3), `@eval` (its expansion is a call of
# Core.eval) and `@enum` (Base's expansion calls Base's functions on the type it makes as it loads): a unit holding
# `@enum` is refused by name, and a new enum case is Dale's to add to the snapshot.
const MACRO_NAMES = ((Base, Symbol("@assert")), (Base, Symbol("@goto")), (Base, Symbol("@label")), (Base, Symbol("@raw_str")),
    (Base, Symbol("@something")), (Base, Symbol("@inline")), (Base, Symbol("@noinline")), (Base.GC, Symbol("@preserve")),
    (Base, Symbol("@fastmath")), (Base, Symbol("@nospecialize")), (Base, Symbol("@specialize")),
    (Base, Symbol("@NamedTuple")), (Core, Symbol("@int128_str")), (Core, Symbol("@uint128_str")),
    (Base, Symbol("@atomic")), (Base, Symbol("@__MODULE__")), (Base, Symbol("@inbounds")), (Base, Symbol("@boundscheck")),
    (Base, Symbol("@view")), (Base, Symbol("@views")), (Base, Symbol("@isdefined")), (Base, Symbol("@simd")))
const MACROS = Base.IdSet{Any}(getglobal(m, s) for (m, s) in MACRO_NAMES)
const ENUM = getglobal(Base, Symbol("@enum"))

# ---- THE callee table (spec v14 V3): every function a unit's top-level code may call at load, matched by the callee's
# own identity (never by `isa Core.Builtin` and then a list), each entry a kind and its one-line reason; a callee the
# table does not hold is the refusal arm, by name, with the rewrite a climber can make. The stepper checks each call's
# real callee and real arguments (_call!). The kinds:
#   :pure       a builtin that builds or compares a value, its result a function of its operands alone (values the
#               stepper holds only once _reader! admitted them, or this load made them): admitted with any argument
#   :reader     reads a binding or an object's contents: admitted only on a target _reader! admits
#   :writer     declares or sets a binding, or makes or fills a type: admitted only with the unit's own module, or a type
#               the unit made in this load, as its real target (_writer!)
#   :machinery  a generic function a definition's lowering calls, run at the judge's world, where no unit's method
#               exists; `methods_refused`: no unit's method on it at all (checked before and after every form, L1), else
#               V1's rule alone (a unit's method on it takes the unit's own values, so the lowering's call never meets it)
#   :const      a constant's arithmetic: a function of Base's on values of Base's (_const_args), at the judge's world, an
#               exception it throws a located refusal (spec v13 R2: one evaluator, the stepper)
#   :refused    a callee refused by its own name, with why
# Not in the table, so refused: every other builtin (setfield! and its kin, the memory reads and writes, memoryref*
# among them; one that calls another function: _apply_iterate, invoke, invoke_in_world, _call_in_world, finalizer,
# Core.eval; one that reads a method table, a world, a task, a pointer, the clock, the environment or an object's
# address) and every other generic function; ccall is no call, its :foreigncall a statement the stepper refuses.
struct Callee
    kind::Symbol
    reason::String
    args::Any                 # nothing, or a predicate on the real arguments (the entry admits only those)
    methods_refused::Bool     # :machinery: no unit's method on it at all
end
const CALLEES = Base.IdDict{Any,Callee}()
const CALLEE_ORDER = Any[]
# the table's entries in their order, as climber.md lists them (table_markdown): kind, reason, each callee's name (one
# Julia defines on some versions alone named with them, so the text is the same on every version)
const CALLEE_DOC = Tuple{Symbol,String,Vector{String}}[]
function _entry!(kind, reason, fs...; args = nothing, methods_refused = false, names = nothing)
    foreach(f -> (CALLEES[f] = Callee(kind, reason, args, methods_refused); push!(CALLEE_ORDER, f)), fs)
    push!(CALLEE_DOC, (kind, reason, names === nothing ? String[string(nameof(f)) for f in fs] : names))
end
# an entry of callees Julia defines on some versions alone (`Core.declare_const` from 1.13): each one defined is held
_versioned(m::Module, ns, since::String) = (Any[getglobal(m, n) for n in ns if isdefined(m, n)],
                                           String[since == "" ? string(n) : "$(n) (Julia $since)" for n in ns])
_entry!(:pure, "a tuple of its operands", Core.tuple)
_entry!(:pure, "a SimpleVector of its operands", Core.svec)
_entry!(:pure, "the type its operands name (a type's identity is the same in every process)", Core.apply_type)
_entry!(:pure, "its operand's type", Core.typeof)
_entry!(:pure, "whether its operand's type is a subtype of a type", Core.isa)
_entry!(:pure, "the identity of two values the stepper holds", Core.:(===))
_entry!(:pure, "whether two type definitions agree: two types' structure, fixed once each is made", Core._equiv_typedef)
_entry!(:pure, "one of its operands, chosen by a Bool", Core.ifelse)
_entry!(:pure, "a type's field type, fixed when the type is made", Core.fieldtype)
_entry!(:pure, "subtyping of two types", Core.:(<:))
_entry!(:pure, "an Expr of its operands", Core._expr)
_entry!(:pure, "an intrinsic lowering emits for a branch's condition or integer arithmetic: a function of its bits operands (no memory, no pointer, no call)",
        Core.Intrinsics.not_int, Core.Intrinsics.and_int, Core.Intrinsics.or_int, Core.Intrinsics.xor_int,
        Core.Intrinsics.eq_int, Core.Intrinsics.ne_int, Core.Intrinsics.slt_int, Core.Intrinsics.sle_int,
        Core.Intrinsics.ult_int, Core.Intrinsics.ule_int, Core.Intrinsics.add_int, Core.Intrinsics.sub_int,
        Core.Intrinsics.mul_int)
_entry!(:reader, "reads a binding (getglobal, isdefinedglobal, get_binding_type) or an object's contents (getfield, nfields, sizeof)",
        Core.getglobal, Core.isdefinedglobal, Core.get_binding_type, Core.getfield, Core.nfields, Core.sizeof)
_entry!(:reader, "a dotted callee's binding (`Base.show`): a module's binding read, no dispatch",
        Base.getproperty; args = a -> length(a) == 2 && a[1] isa Module && a[2] isa Symbol)
# (Julia 1.13 lowers `const` and `global` to Core.declare_const and Core.declare_global; 1.12 to statements of their own,
# _declare!)
let (fs, ns) = _versioned(Core, (:setglobal!, :_structtype, :_abstracttype, :_primitivetype, :_setsuper!, :_typebody!,
                                 :_defaultctors), ""),
    (vs, vn) = _versioned(Core, (:declare_const, :declare_global), "1.13")
    _entry!(:writer, "declares or sets a binding of the unit's own module, or makes or fills a type the unit made", fs..., vs...;
            names = vcat(ns, vn))
end
_entry!(:machinery, "makes a `where`'s and a parametric type's variable", Core.TypeVar; methods_refused = true)
_entry!(:machinery, "a method's callee type", Core.Typeof; methods_refused = true)
_entry!(:machinery, "a keyword method's callee type", Core.kwftype; methods_refused = true)
_entry!(:machinery, "the UnionAll of a TypeVar and a body: `<:` sugar and `where` (`f(x::Vector{<:Integer})`, `Vector{T} where T<:Real`)",
        Core.UnionAll; args = a -> length(a) == 2 && a[1] isa TypeVar)
_entry!(:machinery, "a keyword slurp's type (`f(x; kw...)`): `pairs(NamedTuple)`, Base's Iterators.Pairs over a NamedTuple",
        Base.pairs; args = a -> length(a) == 1 && a[1] === NamedTuple)
_entry!(:const, "a sum of Base's values", Base.:+)
_entry!(:const, "a difference or a negation", Base.:-)
_entry!(:const, "a product", Base.:*)
_entry!(:const, "a quotient", Base.:/)
_entry!(:const, "a power", Base.:^)
_entry!(:const, "a truncated quotient", Base.div)
_entry!(:const, "a remainder (`%`)", Base.rem)
_entry!(:const, "Julia's lowering of `x^n` for a literal `n`: `x^n` by `Val(n)`", Base.literal_pow)
_entry!(:const, "`T[x, ...]`'s lowering: a new Vector{T} of its arguments, T a type of Base's", Base.getindex)
_entry!(:const, "`[x, ...]`'s lowering: a new Vector of its arguments", Base.vect)
_entry!(:const, "the largest value of a type of Base's", Base.typemax)
_entry!(:const, "the smallest value of a type of Base's", Base.typemin)
_entry!(:const, "a conversion to a number type of Base's", Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32,
        UInt64, UInt128, Float16, Float32, Float64, Bool, Char)
_entry!(:const, "the singleton `Val{n}()` literal_pow takes (a `Val{n}` type called with no argument)", Val;
        args = a -> isempty(a), names = ["Val{n}"])
let (fs, ns) = _versioned(Base, (:_eval_import,), "1.13")
    _entry!(:refused, "a `using` or an `import` (Julia 1.13's lowering of both): a unit sees Base, Core and, by name, the snapshot's bindings alone",
            fs...; names = ns)
end
# The statements a form may run at load, a bound with a band (D17): intent, a definition's lowering runs tens of
# statements (a struct about forty); band, past STEP_BUDGET the form is refused as a loop at load, never a hang
const STEP_BUDGET = 100_000
# what a climber writes instead of a call the table does not hold
const CALLEE_REWRITE = "a value computed by a call the table does not hold is computed in a function a case calls " *
    "(`const P0 = _Point(0, 0)` → `_p0() = _Point(0, 0)`; `const R = 1:3` → `_r() = 1:3`), and top-level code that " *
    "does work (`println(1)`) belongs in a case's body"
# a callee's entry: by its identity; a `Val{n}` type by its family's (Val), the one family entry
function _callee(f)::Union{Nothing,Callee}
    local e = get(CALLEES, f, nothing)
    e === nothing && f isa DataType && f.name === Val.body.name && isconcretetype(f) && return CALLEES[Val]
    return e
end
_machinery(f) = (e = get(CALLEES, f, nothing); e !== nothing && e.kind === :machinery && e.methods_refused)
const MACHINERY_REFUSED = Any[f for f in CALLEE_ORDER if _machinery(f)]
"""    table_markdown() -> String

The callee table as dev/climb/climber.md lists it (one source: climber.md's block is checked against this text by the
loader's negatives): each kind's callees and reason, then what is refused and what to write instead."""
function table_markdown()::String
    local io = IOBuffer()
    local title = Dict(:pure => "builds or compares a value", :reader => "reads (on a target the read rule admits)",
                       :writer => "writes (the unit's own module or type alone)", :machinery => "a definition's machinery, at the judge's world",
                       :const => "a constant's arithmetic, on values of Base's, at the judge's world", :refused => "refused by name")
    for k in (:pure, :reader, :writer, :machinery, :const, :refused)
        local es = [e for e in CALLEE_DOC if e[1] === k]
        isempty(es) && continue
        println(io, "- ", title[k], ":")
        for (_, r, ns) in es
            println(io, "  - ", join(("`$(n)`" for n in ns), ", "), ": ", r)
        end
    end
    println(io, "- anything else is refused by name: ", CALLEE_REWRITE)
    return String(take!(io))
end
# a :const call's arguments: values of Base's, and its form's own (`literal_pow(^, x, Val{n}())`, `T[...]`'s type
# first, `typemax(T)`)
function _const_args(f, args::Vector{Any})::Bool
    f === Base.literal_pow && return length(args) == 3 && args[1] === Base.:^ && _plain(args[2]) && args[3] isa Val
    (f === Base.getindex || f === Base.typemax || f === Base.typemin) &&
        (isempty(args) || !(args[1] isa Type) || !_plain(args[1])) && return false
    return all(_plain, args)
end

# ---- the judge, recorded before the snapshot loads
mutable struct Judge
    world::UInt
    names::Set{Symbol}            # what Main names at the judge's world: smoke.jl's, the runner's, WasmTarget's
    modules::Vector{Module}       # the judge's own modules: no unit method on a function of theirs
    functions::Base.IdSet{Any}    # the functions Main binds at the judge's world
    snapshot::Union{Nothing,Set{Symbol}}   # the names the snapshot binds in Main (_snapshot_names), once it loaded
end
const JUDGE = Ref{Union{Nothing,Judge}}(nothing)
"""
    judge!(world, modules)

The judge's world (test/smoke.jl's W_JUDGE, taken after the runner, the loader and WasmTarget load and before the
snapshot) and what Main names then: no unit sees a name of the judge's unqualified (it is never imported into a
unit), and no unit adds a method to a function of `modules` or to one Main binds now.
"""
function judge!(world::UInt, modules)
    local ns = Set{Symbol}(names(Main; all = true, imported = true))
    for m in _usings(Main)   # the names Main reaches through a `using` (WasmTarget's exports): the judge's too
        m === Base || m === Core || union!(ns, names(m))
    end
    local fs = Base.IdSet{Any}()
    for s in ns
        isdefinedglobal(Main, s) && (v = getglobal(Main, s); v isa Function && push!(fs, v))
    end
    JUDGE[] = Judge(world, ns, collect(Module, modules), fs, nothing)
    return nothing
end
_usings(m::Module) = ccall(:jl_module_usings, Any, (Any,), m)::Vector{Any}

# ---- the order: a unit's place is its landing's, the first-parent order of the commits that added each unit file,
# derived here from git's own log and from nothing else (D5): the climb's driver runs git with UNIT_LOG_ARGV and hands
# the judge that log, its first line the argv it ran (checked against this one); a developer's or CI's run of
# test/smoke.jl runs the same git itself. A unit file the log does not name (a unit not yet committed, or one a
# measurement lays over its base) comes after every landed unit, by name.
const UNIT_LOG_ARGV = ["log", "--first-parent", "--reverse", "--diff-merges=first-parent", "--no-renames", "--diff-filter=A",
                       "--name-only", "--format=%x00%H"]   # then <rev>, `--`, test/corpus/
"""
    unit_order(log, present) -> Vector{String}

The unit files `present` (paths under test/corpus/, as git names them) in landing order: by the last first-parent
commit of `log` (git's output for UNIT_LOG_ARGV) that added each, then those it names not, by name.
"""
function unit_order(log::AbstractString, present::AbstractVector{<:AbstractString})
    local order = String[]
    for chunk in split(log, '\0'; keepempty = false)
        local lines = filter(!isempty, strip.(split(chunk, '\n')))
        isempty(lines) && continue
        occursin(r"^[0-9a-f]{40}$", lines[1]) || error("the units' log holds a commit line that is no sha: $(first(lines[1], 80))")
        for p in sort!(String.(lines[2:end]))
            startswith(p, "test/corpus/") && endswith(p, ".jl") || continue
            filter!(!=(p), order)
            push!(order, p)
        end
    end
    local have = Set(String.(present))
    local out = [p for p in order if p in have]
    append!(out, sort!([p for p in have if !(p in order)]))
    return out
end
_unit_files(root::AbstractString) = (d = joinpath(root, "test", "corpus"); isdir(d) ?
    sort!(["test/corpus/" * f for f in readdir(d) if endswith(f, ".jl")]) : String[])
"""
    unit_paths(root; handed) -> Vector{String}

The unit files of the checkout at `root`, in landing order, as absolute paths: from the log the climb's driver handed
(`handed`, WT_SMOKE_UNITS's file: its first line the argv it ran, which must be UNIT_LOG_ARGV), or from this
checkout's own git, whose history must not be shallow (a shallow clone's log names no landing).
"""
function unit_paths(root::AbstractString; handed::Union{Nothing,AbstractString} = nothing,
                    labels::Union{Nothing,AbstractSet{<:AbstractString}} = nothing)
    local present = _unit_files(root)
    # the units of the labels a run is named (all of them when it is named none): a unit sees no other unit, and its
    # methods on functions it does not own are deleted once its world is taken (_retire_foreign!), so a label's load,
    # answer and compile world are the same whichever other units a process loads (spec v14 V1): a gate need not load
    # every unit
    labels === nothing || filter!(p -> any(in(labels), registered_labels(joinpath(root, p))), present)
    local log = if handed !== nothing
        local text = read(handed, String)
        local first_line, rest = occursin('\n', text) ? split(text, '\n'; limit = 2) : (text, "")
        first_line == join(UNIT_LOG_ARGV, ' ') ||
            error("the units' log handed to the judge ran `git $(first_line)`, not test/corpus_loader.jl's `git $(join(UNIT_LOG_ARGV, ' '))`")
        rest
    else
        isempty(present) && return String[]
        strip(read(`git -C $root rev-parse --is-shallow-repository`, String)) == "false" ||
            error("test/corpus holds units and this checkout's history is shallow: their landing order is not in it")
        read(`git -C $root $(UNIT_LOG_ARGV) HEAD -- test/corpus/`, String)
    end
    return [joinpath(root, p) for p in unit_order(log, present)]
end
"""
    registered(text; filename) -> Vector{Tuple{Symbol,String,String}}

The one reader of a corpus file's groups and labels (the snapshot's or a unit's): each top-level registration's kind
(:_g or :_xf), group and case, read from Julia's parse of `text` by the reader a unit's load uses
(_registration_cases), never by a pattern over its lines. The climb's driver (`--labels`), the ratchet's readers of
groups and cases (L153, L226, L227) and unit_paths all read it. A registration that reader refuses names nothing (a
unit holding one is refused when it loads)."""
function registered(text::AbstractString; filename::AbstractString = "none", unread = nothing)
    local out = Tuple{Symbol,String,String}[]
    for a in Meta.parseall(text; filename).args
        local r = _registration_cases(a)
        if !(r isa Tuple)   # (`unread`: each registration whose group or a case is no literal, named)
            unread === nothing || r == "no registration" || push!(unread, first(replace(string(a), r"\s+" => " "), 120))
            continue
        end
        for t in r[2]
            if t isa Expr && t.head === :tuple && length(t.args) >= 2 && t.args[1] isa String && _label_refusal(t.args[1]) === nothing
                push!(out, (a.args[1]::Symbol, r[1], t.args[1]))
            else
                unread === nothing || push!(unread, r[1] * ": " * first(replace(string(t), r"\s+" => " "), 120))
            end
        end
    end
    return out
end
registered_labels(path::AbstractString) = String["$g/$c" for (_, g, c) in registered(read(path, String); filename = path)]
# the corpus files of the checkout at `root`: the snapshot and its units, as paths under root
corpus_files(root::AbstractString) = vcat(["test/smoke_corpus.jl"], _unit_files(root))
"""
    corpus_groups(root) -> Set{String}

The groups the corpus of the checkout at `root` registers, an xfail group as `xfail <group>` (test/smoke_times.tsv's
keys), by `registered`: the snapshot's and every unit's."""
function corpus_groups(root::AbstractString)
    local out = Set{String}()
    for p in corpus_files(root), (k, g, _) in registered(read(joinpath(root, p), String); filename = p)
        push!(out, k === :_xf ? "xfail " * g : g)
    end
    return out
end

# ---- reading what the corpus binds: the loader's own code runs at the judge's world (load_units), where no unit's
# method exists, so a unit's method on a Base function the loader calls never runs in it; a binding the snapshot or a
# unit made since is read at the latest world, by builtins alone (isdefinedglobal, getglobal, and jl_is_const by ccall)
_def(m::Module, s::Symbol) = Base.invokelatest(isdefinedglobal, m, s)::Bool
_get(m::Module, s::Symbol) = Base.invokelatest(getglobal, m, s)
_is_const(m::Module, s::Symbol) = ccall(:jl_is_const, Cint, (Any, Any), m, s) != 0
_isconst(m::Module, s::Symbol) = Base.invokelatest(_is_const, m, s)::Bool

# ---- the units
mutable struct Unit
    path::String
    name::Symbol                  # its module's name, U_<slug>, bound in Main by the loader
    mod::Module
    world::UInt                   # the world just after its last form loaded
    names::Set{Symbol}            # the names it binds
    labels::Vector{String}        # the labels it registers, group/case
    nmethods::Int                 # the methods its forms added, as the loader attributed them
    w0::UInt                      # the world before its first form
    made::Base.IdSet{Any}         # the types its forms made in this load (_structtype, _abstracttype, _primitivetype)
    state::Dict{Symbol,Symbol}    # each name it binds: :declared, :global, :const or :function (_bind!)
    objs::Base.IdSet{Any}         # every mutable object a statement of its load returned (by _reader!, one it made)
    imports::Set{Symbol}          # the snapshot's names imported into its module (_imports!)
    writes::Vector{NTuple{3,String}}   # its load's writes, in order: (writer, subject, the sha-256 of the write's
                                       # canonical form, in hex): the digest's entries (_feed!)
    texts::Vector{String}         # each write's canonical form, its first 300 characters (a mismatch names it)
    sha::SHA.SHA256_CTX           # the digest of every write so far
    digest::String                # once loaded: the sha-256 of every write's canonical form, in order, in hex
    foreign::Vector{Method}       # its methods on functions it does not own (_reflect!): deleted once its world is taken
    line::Int                     # the form being loaded: its line, and the form (a refusal at a write is located there)
    form::Any
end
const LOADED = Unit[]

_text(x) = (s = replace(string(x), r"#=[^=]*=#\s*" => "", r"\s+" => " "); length(s) > 160 ? first(s, 160) * "…" : s)
refuse(u::Unit, line::Int, why::AbstractString, form) = throw(Refusal(u.path, line, String(why), _text(form)))

"""
    load_units(paths; register, labels) -> Vector{Unit}

Each unit of `paths` (test/corpus/<slug>.jl, in landing order) loaded in a module of its own, `Main.U_<slug>`, its
forms one at a time; `register(kind, group, cases)` is the judge's `_g` (kind :_g) or `_xf` (:_xf), called for each
registration the loader reads, with a `Vector{Any}` of `Core.tuple`s; `labels` the labels registered already (the
snapshot's), a label registered twice refused; `read_file(path)` the reader of a unit's text (the judging entry's,
which records each file it reads). A form the loader refuses throws a `Refusal`, located.
"""
# load_units is called once a process (spec v16 X3): every deletion a load makes (_retire_foreign!) then precedes every
# compile and answer the process makes, the premise the compile world rests on; a second call is refused, located.
# (_load_units, its body, is what the loader's own negatives call unit by unit, each unit's refusal its own verdict)
const _UNITS_LOADED = Ref(false)
function load_units(paths::AbstractVector{<:AbstractString}; register, labels::Set{String}, read_file = _read_text)
    _UNITS_LOADED[] && error("the corpus loader: load_units was called a second time in this process; it loads a process's " *
                             "units once, so every deletion precedes every compile and answer (spec v16 X3)")
    _UNITS_LOADED[] = true
    return _load_units(paths; register, labels, read_file)
end
function _load_units(paths::AbstractVector{<:AbstractString}; register, labels::Set{String}, read_file = _read_text)
    JUDGE[] === nothing && error("the corpus loader: judge!(world, modules) was not called before the units")
    local out = Unit[]
    for p in paths
        push!(out, Base.invoke_in_world((JUDGE[]::Judge).world, load_unit, String(p); register, labels, read_file))
    end
    _cross_check(out)
    return out
end

_read_text(path) = read(path, String)
function load_unit(path::String; register, labels::Set{String}, read_file = _read_text)
    local slug = replace(basename(path), r"\.jl$" => "")
    local name = Symbol("U_", slug)
    local w0 = Base.get_world_counter()
    local u = Unit(path, name, Module(name), w0, Set{Symbol}(), String[], 0, w0, Base.IdSet{Any}(),
                   Dict{Symbol,Symbol}(), Base.IdSet{Any}(), Set{Symbol}(), NTuple{3,String}[], String[], SHA.SHA256_CTX(), "", Method[], 0, path)
    _snapshot_names()
    occursin(r"^[a-z0-9][a-z0-9_]*$", slug) && endswith(path, ".jl") ||
        refuse(u, 0, "a unit's file is test/corpus/<slug>.jl, its slug ASCII lowercase letters, digits and `_`", path)
    _def(Main, name) && refuse(u, 0, "Main binds $name already, the name of this unit's module", path)
    local text = read_file(path)::String   # (the judging entry's recording reader, test/smoke_judge.jl's _judge_read)
    local top = Meta.parseall(text; filename = path)
    local forms = Tuple{Int,Any}[]
    local line = 0
    for a in top.args
        if a isa LineNumberNode
            line = a.line
        elseif a isa Expr && a.head in (:error, :incomplete)
            refuse(u, line, "Julia's parser does not read it", a)
        else
            push!(forms, (line, a))
        end
    end
    Core.eval(Main, Expr(:const, Expr(:(=), name, u.mod)))
    _imports!(u, forms)
    for (ln, form) in forms
        load_form!(u, ln, form; register, labels)
    end
    u.world = Base.get_world_counter()
    u.digest = bytes2hex(SHA.digest!(u.sha))
    _retire_foreign!(u)
    push!(LOADED, u)
    return u
end

# One program per label (spec v14 V1): a label's program is the snapshot plus its own unit, in every process that
# loads it, whichever other units that process loads (a gate loads the units of its labels, the score every unit).
# What a unit's load changes outside its own module, by writer (every write passes _writer!, _bind!, _one! or
# _method!): setglobal!, declare_const and declare_global bind the unit's own module's names alone (_writer!, _declare!);
# _structtype, _abstracttype and _primitivetype make a type in the unit's own module, and _setsuper!, _typebody! and
# _defaultctors fill only a type the unit made (_writer!), each a new type no other unit's text can name (it reads no
# unit's module: _binding_read); `:new` allocates an instance of the unit's own type; a registration hands the judge
# its cases; and `:method` adds a method to a function: one of the unit's own (its own module's, unreachable from
# another unit's code), or one it does not own (the snapshot's, Base's, Core.kwcall's for a keyword method), which
# another unit's call could dispatch to: the one effect a later unit's compile sees. Each such method is recorded at
# _reflect! and deleted here, after the unit's world is taken and before the next unit loads (Base.delete_method;
# precedent(Julia ecosystem: Revise.jl deletes the methods a file no longer defines, so the method table equals the
# file's text)): it then lives in the unit's own world range alone, where its labels are compiled and answered, and
# every later unit's world is the one it has alone. What that claim rests on is the state Julia keeps of a method,
# read by v14/v1/visit.jl and the negatives' retire test: the methods a later world sees (restored by the deletion),
# the method table's entries (the deleted ones kept with their world range closed, seen by no later world) and the
# type name's max_args (never lowered by Julia: a unit's method may not raise it, _max_args_refusal).
# Julia differs from Revise in the reason only: the method is kept for
# the unit's own world, not removed for good. The loader's own write outside the unit, `Main.U_<slug>` (its module's
# binding), is read by no unit's load (_binding_read refuses it) and only by a body that computes the name (RISKS (d)).
function _retire_foreign!(u::Unit)
    foreach(Base.delete_method, u.foreign)
    return nothing
end

# ---- what a unit sees: Base and Core (its module's own), and, for each name its forms mention that the snapshot binds,
# that binding, imported by name; never a name of the judge's and never another unit's (a helper two units need is
# written in each)
function _snapshot_binds(s::Symbol)::Bool
    s in _snapshot_names() || return false
    # a name Base or Core gives every module is the unit's own already, unless the snapshot binds it apart
    _def(Base, s) && _get(Base, s) === _get(Main, s) && return false
    _def(Core, s) && _get(Core, s) === _get(Main, s) && return false
    return true
end
# The snapshot's names, the fixed set every process binds alike: what Main names once the snapshot loaded (taken before
# the first unit, so no unit's module is among them) less what it named at the judge's world (the judge's names, which
# differ by process: WasmTarget's, the runner's) and less a unit module's name. The snapshot is one file, included the
# same way in every process, and WasmTarget, the one module only the compiling process adds, exports no name
# (`names(WasmTarget) == [:WasmTarget]`), so no snapshot name is a judge's name in one process and not in another; and
# a unit's imports of them are writes the digest holds (_imports!), so a difference would ring there
function _snapshot_names()::Set{Symbol}
    local j = JUDGE[]::Judge
    j.snapshot === nothing || return j.snapshot
    isempty(LOADED) || error("the corpus loader: the snapshot's names are taken before the first unit loads")
    # (read at the latest world: the loader runs at the judge's, where Main names none of the snapshot's bindings yet)
    local now = Base.invokelatest(names, Main; all = true, imported = true)::Vector{Symbol}
    j.snapshot = Set{Symbol}(s for s in now if !(s in j.names) && !_unit_name(s))
    return j.snapshot
end
# (a quoted name, a field's or a dotted path's, is no lookup in the unit)
_symbols!(out, x) = (x isa Symbol ? push!(out, x) : x isa Expr ? foreach(a -> _symbols!(out, a), x.args) : nothing; out)
function _imports!(u::Unit, forms)
    local seen = Set{Symbol}()
    foreach(f -> _symbols!(seen, f[2]), forms)
    local from_main = [s for s in sort!(collect(seen)) if _snapshot_binds(s)]
    for s in from_main   # each import a write the digest holds: its name, whether const, and its value in the digest's
        push!(u.imports, s)   # form (a mutable value by its type alone: its contents are no part of what a unit loads)
        _feed!(u, "import", s, _isconst(Main, s) ? :const : :global, _get(Main, s); mode = :import)
    end
    isempty(from_main) || Core.eval(u.mod, Expr(:using, Expr(:(:), Expr(:., :Main), (Expr(:., s) for s in from_main)...)))
    return nothing
end

# ---- one form
function load_form!(u::Unit, line::Int, form; register, labels::Set{String})
    u.line, u.form = line, form
    form isa Expr || refuse(u, line, "a bare value at the top of a unit runs nothing a case needs", form)
    _check_macros(u, line, form, true)
    if form.head === :call && form.args[1] in (:_g, :_xf)
        return _registration!(u, line, form; register, labels)
    end
    # every form, a constant's among them, is lowered by Julia and stepped as written: one evaluator of Julia's
    # semantics, the stepper (spec v13 R2), its calls a constant's lowering makes the table's :const entries
    _run_lowered!(u, line, form, Meta.lower(u.mod, form))
    return nothing
end

# The heads Julia's lowering gives a top-level form that is no thunk (jl_toplevel_eval_flex's), matched by name (spec v13
# R3): `global` (1.12 lowers a bare `global x` to it; 1.13 to a thunk of Core.declare_global) is the same declaration
# 1.13 steps, so it loads on both: Julia lowers it again in statement position, a thunk whose `global` statement the one
# declaration reader takes (_declare!, `:weak`: it binds a fresh name of the unit's or repeats its own); `module`,
# `using`, `import`, `export` and `public` are each refused by its own name; any other head is refused as unknown
const NONTHUNK_REFUSED = Dict(
    :module => "a `module`: a unit is one module, the loader's, Main.U_<slug>",
    :using => "a `using`: a unit sees Base, Core and, by name, the snapshot's bindings alone",
    :import => "an `import`: a unit sees Base, Core and, by name, the snapshot's bindings alone",
    :export => "an `export`: a unit's names are read by its registration, never exported",
    :public => "a `public`: a unit's names are read by its registration, never declared public")
# a form's lowering run by the stepper: a thunk stepped (_run_form!), a `toplevel` of several forms each lowered and
# run in turn, a bare `global` stepped as a declaration; Julia's lowering error and every other head refused by name
function _run_lowered!(u::Unit, line::Int, form, lowered)
    if lowered isa Expr && lowered.head === :toplevel
        for a in lowered.args
            a isa LineNumberNode && continue
            _run_lowered!(u, line, form, a isa Expr && a.head === :thunk ? a : Meta.lower(u.mod, a))
        end
        return nothing
    end
    lowered isa Expr || refuse(u, line, "a value, not a definition", form)
    lowered.head in (:error, :incomplete) && refuse(u, line, "Julia's lowering refuses it: $(lowered.args[1])", form)
    if lowered.head === :global
        local th = Meta.lower(u.mod, Expr(:block, lowered, nothing))
        th isa Expr && th.head === :thunk || refuse(u, line, "a top-level `global` Julia's lowering gives no thunk for in statement position", form)
        return _run_form!(u, line, form, th.args[1]::Core.CodeInfo)
    end
    haskey(NONTHUNK_REFUSED, lowered.head) && refuse(u, line, NONTHUNK_REFUSED[lowered.head], form)
    lowered.head === :thunk || refuse(u, line, "a top-level `$(lowered.head)`, a form Julia's lowering gives no thunk for that the loader does not know", form)
    return _run_form!(u, line, form, lowered.args[1]::Core.CodeInfo)
end

# one lowered thunk stepped (_step!), the definition's machinery checked before and after, and every method it added
# read back (_reflect!); returns the thunk's value (a registration's lambda)
function _run_form!(u::Unit, line::Int, form, ci::Core.CodeInfo)
    local why = _machinery_refusal(u)
    why === nothing || refuse(u, line, why, form)
    local s = Step(u, line, form, Any[], 0)
    local w0 = Base.get_world_counter()
    local v = _step!(s, ci)
    _reflect!(u, line, form, s.callees, w0, Base.get_world_counter())
    why = _machinery_refusal(u)
    why === nothing || refuse(u, line, why, form)
    return v
end


# a macro call's macro, resolved in the unit's module: a name, or a dotted path from a module the unit sees
# (a dotted path only through a module of Base's or Core's, which every process holds alike, as _reader! reads modules)
function _macro(u::Unit, m)
    m isa Symbol && return _def(u.mod, m) ? _get(u.mod, m) : nothing
    m isa GlobalRef && return (m.mod === u.mod || _base_or_core(m.mod)) && _def(m.mod, m.name) ? _get(m.mod, m.name) : nothing
    if m isa Expr && m.head === :. && length(m.args) == 2 && m.args[2] isa QuoteNode
        local p = _macro(u, m.args[1])
        p isa Module && _base_or_core(p) || return nothing
        local s = m.args[2].value
        return _def(p, s) ? _get(p, s) : nothing
    end
    return nothing
end
# every macro of a form one of MACROS; `@enum` refused by name
function _check_macros(u::Unit, line::Int, x, top::Bool)
    x isa Expr || return nothing
    if x.head === :macrocall
        local m = _macro(u, x.args[1])
        m === ENUM && refuse(u, line, "an `@enum`: a unit defines no enum (Base's expansion calls Base's functions on the type it makes, at load); a new enum case is Dale's to add to the snapshot", x)
        m in MACROS || refuse(u, line, "a macro off the loader's table ($(x.args[1])): a macro runs its own code as the form expands", x)
    end
    for a in x.args
        _check_macros(u, line, a, false)
    end
    return nothing
end

# ---- the stepper: a form's lowered code run by the loader itself, one statement at a time. Julia lowers the form
# (Meta.lower); the loader then holds its SSA values and locals, takes each branch by the value it actually has, and
# runs each statement only once its real operands are checked: a call's real callee and real arguments (_call!), a
# definition's real target (_bind!, _method!), each on a closed list; every other statement kind refused by name. So
# what runs at load is exactly what was checked, and nothing is predicted (dev/climb/HILL.md, the corpus).
mutable struct Step
    u::Unit
    line::Int
    form::Any
    callees::Vector{Any}   # the callee types its methods were defined on, read back after the form (_reflect!)
    steps::Int             # the statements it ran, bounded by STEP_BUDGET
end
_refuse(s::Step, why::AbstractString) = refuse(s.u, s.line, why, s.form)

# an operand's value: a statement's, a local's, a global's (read at the latest world, by builtins), a quoted one, or a
# literal of Base's (a number, a string, a char, nothing, a tuple or vector of them, a type of Base's, a line), or a
# module (lowering names a definition's module by the module itself)
_literal(x) = !(x isa Symbol) && (_plain(x) || x isa LineNumberNode || x isa Module)
function _val(s::Step, x, ssa::Vector{Any}, have::BitVector, slots::Dict{Int,Any})
    if x isa Core.SSAValue
        have[x.id] || _refuse(s, "it reads %$(x.id) before the statement that computes it ran")
        return ssa[x.id]
    elseif x isa Core.SlotNumber
        haskey(slots, x.id) || _refuse(s, "it reads a local before it is assigned")
        return slots[x.id]
    elseif x isa GlobalRef
        return _binding!(s, x.mod, x.name, :value)
    elseif x isa QuoteNode
        return x.value
    elseif _literal(x)
        x isa Module && !_module_seen(s.u, x) && _refuse(s, "an operand that is the module $(x), which a unit does not see")
        return x
    end
    _refuse(s, "an operand of kind $(typeof(x)): the loader's operands are a statement's value, a local, a global, a quoted value and a literal of Base's")
end

# a body's reference to a unit's module (a global of one, or a name the loader gives units, U_<slug>, read or quoted:
# `Main.U_x.f`), refused before its method exists, whether or not that unit is loaded in this process: an early refusal
# by a scan of the body's operands, no guarantee (a body can compute such a name and tell its process when a case calls
# it: RISKS (d), G4's to judge, dev/climb/HILL.md)
_unit_name(x) = x isa Symbol && occursin(r"^U_[a-z0-9][a-z0-9_]*$", String(x))
function _unit_reference(u::Unit, ci::Core.CodeInfo)
    for st in ci.code, x in (st isa Expr ? st.args : Any[st])
        x isa GlobalRef && any(y -> y.mod === x.mod && y.mod !== u.mod, LOADED) && return "$(x.mod).$(x.name)"
        x isa GlobalRef && _unit_name(x.name) && x.name !== u.name && return "$(x.mod).$(x.name)"
        x isa QuoteNode && _unit_name(x.value) && x.value !== u.name && return ":$(x.value)"
    end
    return nothing
end

"""
    _step!(s, ci) -> the thunk's value

`ci`'s statements run in order by the loader: `goto` and `goto … if not` taken by the condition's value (a Bool, else
refused), `return` ending the thunk, an assignment to a local held here, every other statement by _stmt; past
STEP_BUDGET statements a form is refused (a loop at load), never a hang.
"""
function _step!(s::Step, ci::Core.CodeInfo)
    local code = ci.code
    local n = length(code)
    local ssa, have, slots = Vector{Any}(undef, n), falses(n), Dict{Int,Any}()
    local pc = 1
    while true
        1 <= pc <= n || _refuse(s, "its lowered code runs past its last statement")
        (s.steps += 1) > STEP_BUDGET && _refuse(s, "it runs more than $STEP_BUDGET lowered statements at load (a loop)")
        local st = code[pc]
        if st isa Core.GotoNode
            pc = st.label
            continue
        elseif st isa Core.GotoIfNot
            local c = _val(s, st.cond, ssa, have, slots)
            c isa Bool || _refuse(s, "a branch on a $(typeof(c)), not a Bool")
            pc = c ? pc + 1 : st.dest
            continue
        elseif st isa Core.ReturnNode
            isdefined(st, :val) || _refuse(s, "its lowered code reaches an `unreachable`")
            return _val(s, st.val, ssa, have, slots)
        end
        local v = if st isa Expr && st.head === :(=)
            local l = st.args[1]
            l isa Core.SlotNumber || _refuse(s, "an assignment to $(l), which is no local (a global is set by setglobal!, checked)")
            slots[l.id] = _made!(s.u, _stmt(s, ci, st.args[2], ssa, have, slots))
        else
            _stmt(s, ci, st, ssa, have, slots)
        end
        ssa[pc] = v
        have[pc] = true
        _made!(s.u, v)
        pc += 1
    end
end

# One statement, of the kinds a definition's lowering writes, closed over Julia's IR: a call (_call!), `:method`
# (_method!), a binding's declaration (`:const`, `:global`, `:globaldecl`: _declare!), `:new` of a type the unit made in
# this load (a closure's instance: an allocation, no constructor runs), `:isdefined` (a read), a thunk inside (a
# lambda's closure type, stepped as its own code), `:latestworld` (every binding is read at the latest world already),
# a value read, `NewvarNode`, a line, `nothing` and a literal. Every other kind is refused by name: Core.EnterNode (a
# `try`, whose catch edge would run code the loader never took), PhiNode, PiNode, UpsilonNode, PhiCNode, and the
# heads :leave, :pop_exception, :the_exception, :foreigncall, :cfunction, :new_opaque_closure, :copyast, :meta,
# :module, :using, :import, :toplevel or any head Julia adds.
function _stmt(s::Step, ci::Core.CodeInfo, st, ssa::Vector{Any}, have::BitVector, slots::Dict{Int,Any})
    local val(x) = _val(s, x, ssa, have, slots)
    if st isa Expr
        local h = st.head
        if h === :call
            return _call!(s, val(st.args[1]), Any[val(a) for a in st.args[2:end]])
        elseif h === :method
            return _method!(s, ci, st, val)
        elseif h === :const || h === :global || h === :globaldecl
            return _declare!(s, ci, st, val)
        elseif h === :new
            local T = val(st.args[1])
            T in s.u.made || _refuse(s, "a `new` of $(T), which is no type the unit made in this load")
            return _one!(s, ci, Expr(:new, QuoteNode(T), Any[QuoteNode(val(a)) for a in st.args[2:end]]...), true)
        elseif h === :isdefined
            local a = st.args[1]
            a isa Core.SlotNumber && return haskey(slots, a.id)
            a isa GlobalRef && return _binding!(s, a.mod, a.name, :defined)
            _refuse(s, "an `isdefined` of $(a)")
        elseif h === :thunk
            return _step!(s, st.args[1]::Core.CodeInfo)
        elseif h === :latestworld
            return nothing
        end
        haskey(NONTHUNK_REFUSED, h) && _refuse(s, NONTHUNK_REFUSED[h])   # 1.12's `using`/`import` in a thunk: by name
        _refuse(s, "lowered code holds a `$(h)` statement, which no definition's lowering the loader steps writes")
    elseif st isa Union{Core.SSAValue,Core.SlotNumber,GlobalRef,QuoteNode}
        return val(st)
    elseif st isa Core.NewvarNode
        delete!(slots, st.slot.id)
        return nothing
    elseif st === nothing || st isa LineNumberNode
        return nothing
    elseif _literal(st)
        return st
    end
    _refuse(s, "lowered code holds a $(typeof(st)) statement, which no definition's lowering the loader steps writes")
end

# a statement Julia runs itself, its operands already the values checked: a thunk of that one statement in the unit's
# module, so what Julia evaluates is exactly the statement that was checked; `value` its result, else nothing
function _one!(s::Step, ci::Core.CodeInfo, ex::Expr, value::Bool = false)
    _feed!(s.u, "one", ex.head, ex)
    local c = copy(ci)
    c.code = Any[ex, Core.ReturnNode(value ? Core.SSAValue(1) : nothing)]
    c.ssavaluetypes = 2
    c.ssaflags = UInt32[0, 0]
    c.debuginfo = Core.DebugInfo(:none)
    return Core.eval(s.u.mod, Expr(:thunk, c))
end

"""
    _call!(s, f, args)

A call, run once its real callee `f` and real arguments `args` are checked against THE callee table (CALLEES, by `f`'s
identity): a :pure builtin with any arguments; a :reader on a target _reader! admits; a :writer when its target is
the unit's own (_writer!); a :machinery function at the judge's world, where no unit's method exists; a :const call on
values of Base's at the judge's world, an exception it throws a located refusal; an entry's `args` predicate, when it
has one, holding of the real arguments; anything else refused by name with the rewrite (CALLEE_REWRITE). A builtin
runs at the latest world, as Julia's top level runs it.
"""
function _call!(s::Step, f, args::Vector{Any})
    local e = _callee(f)
    local what() = "it calls $(f) at load$(isempty(args) ? "" : " with a " * join((typeof(a) for a in args), ", a "))"
    e === nothing && _refuse(s, "$(what()), which the loader's table does not hold: $(CALLEE_REWRITE)")
    e.args === nothing || e.args(args) || _refuse(s, "$(what()), which its table entry ($(e.reason)) does not take: $(CALLEE_REWRITE)")
    if e.kind === :pure
        return Base.invokelatest(f, args...)
    elseif e.kind === :reader
        f === Base.getproperty && return _binding!(s, args[1], args[2], :value)
        return _reader!(s, f, args)
    elseif e.kind === :writer
        _writer!(s, f, args)
        local r = Base.invokelatest(f, args...)
        (f === Core._structtype || f === Core._abstracttype || f === Core._primitivetype) && push!(s.u.made, r)
        return r
    elseif e.kind === :machinery
        return Base.invoke_in_world((JUDGE[]::Judge).world, f, args...)
    elseif e.kind === :const
        _const_args(f, args) || isempty(args) ||
            _refuse(s, "$(what()): a constant's arithmetic takes values of Base's alone (numbers, strings, chars, symbols, tuples and vectors of them, Base's types): $(CALLEE_REWRITE)")
        return try
            Base.invoke_in_world((JUDGE[]::Judge).world, f, args...)
        catch err
            _refuse(s, "$(what()), which throws a $(typeof(err)): $(CALLEE_REWRITE)")
        end
    end
    f === getglobal(Base, :_eval_import) && _refuse(s, NONTHUNK_REFUSED[!isempty(args) && args[1] === true ? :import : :using])
    _refuse(s, "$(what()): $(e.reason)")
end

# ---- what a load may read (spec v13 R1 a): every read a load makes passes here, as every write passes _writer!. A
# unit's load must be a function of its text, Julia's build and the snapshot, so that every process loading it (the
# answering one: no WasmTarget, its own unit alone, `JULIA_LOAD_PATH=@stdlib`; the compiling one: WasmTarget,
# `--project`, the units of every label it runs; G5's: neither) loads the same program: what a read may target is what
# every such process holds alike. Admitted, decided on the real operands at the real statement:
#   - a binding of the unit's own module this load made (its value whatever this load wrote there); a name of it this
#     load did not make resolves to Base's, Core's or (imported, _imports!) the snapshot's, read as next;
#   - a const binding of a module of Base's or Core's, or of Main's of the snapshot's names (_snapshot_names: Main is
#     read through as the snapshot's namespace alone), whose value is the same in every process (_same): a type, a
#     function, a bits value but a pointer, a String, a Symbol, an immutable built of those, or a module of Base's,
#     Core's, the unit's own or Main. Refused: Main's other names (`WasmTarget`, a unit's `U_<slug>`, the judge's),
#     another unit's or a package's module, a binding that is not const, and a const of a mutable value
#     (`Base.DEPOT_PATH` and `Base.LOAD_PATH` are const bindings of Vectors whose contents differ by process);
#   - a field or content (getfield, nfields, sizeof) only of a value this load made (u.objs) or of an immutable value
#     the same in every process, never of a type (a DataType is mutable: its TypeName's method table grows as methods
#     are added) or a module (getfield of a module is a binding read, as above); sizeof of a type, its layout, fixed
#     when the type is made, is admitted.
# So every value the stepper holds, and so every branch it takes and every operand a writer gets, is the same in every
# process: no liveness, no prediction, each check on the real operand at the real statement (spec v11 R1).
_base_or_core(m::Module) = (r = Base.moduleroot(m); r === Base || r === Core)
# a module a unit sees as an operand: its own, Base's, Core's (and their submodules), and Main as the snapshot's
# namespace, a read target alone (the stated deviation: `Main.helper(x::_T) = …` extends a snapshot function, which
# no unit can name otherwise, since `import` is refused and the snapshot's names are imported by `using`; Main as a
# value a writer takes is refused at the write, _canon!)
_module_seen(u::Unit, m::Module) = m === u.mod || m === Main || _base_or_core(m)
# a value the same in every process: a type (its identity), a String, a Symbol, a module of Base's or Core's or the unit's
# own (never Main: Main is a read target for a snapshot name alone, never a value a load holds, spec v14 V3), a bits value
# but a pointer (an address), an immutable all of whose fields are such, or (with the unit `u`) a mutable object its own
# load made; a mutable value of anyone else's is not (its contents are whatever its process did)
function _same(u, x, depth::Int = 0)::Bool
    depth > 16 && return false
    x isa Type && return true
    x isa Union{Symbol,String} && return true
    x isa Module && return u isa Unit && x === u.mod || _base_or_core(x)
    u isa Unit && x in u.objs && return true
    local T = typeof(x)
    (T <: Ptr || T <: Core.LLVMPtr) && return false
    ismutabletype(T) && return false
    isprimitivetype(T) && return true
    for i in 1:nfields(x)
        isdefined(x, i) && !_same(u, getfield(x, i), depth + 1) && return false
    end
    return true
end
# every mutable object a statement of the load returns is one the load made (by _reader!, it holds no other)
_made!(u::Unit, v) = (ismutable(v) && !(v isa Module) && !(v isa Type) && push!(u.objs, v); v)

"""
    _binding_read(u, m, n, kind) -> (why or nothing, the value)

The rule for a binding read of `m.n` at a unit's load: `kind` :value (getglobal, a GlobalRef, the getproperty arm,
getfield of a module), :defined (isdefinedglobal, `:isdefined`) or :type (get_binding_type). Returns why it is
refused, or nothing and what the read gives.
"""
function _binding_read(u::Unit, m::Module, n::Symbol, kind::Symbol)
    local read() = kind === :value ? _get(m, n) : kind === :defined ? _def(m, n) :
        Base.invokelatest(Core.get_binding_type, m, n)
    if m === u.mod
        if haskey(u.state, n)   # a name this load bound: whatever this load wrote there
            kind === :value && !_def(m, n) && return ("it reads $n, which the unit declared and gave no value", nothing)
            return (nothing, read())
        end
        # a name this load did not bind: its own module resolves it through Base's and Core's exports and the
        # snapshot's imports alone, each fixed, so whether it is defined, and its binding type, are the same in every
        # process; its value is read where it is bound, by the rule below
        kind === :value || return (nothing, read())
        _def(m, n) || return ("it reads $n, which is not defined", nothing)
        local o = n in u.imports ? Main : Base.binding_module(m, n)
        o === m && return ("it reads $n, a name of the unit's module its load did not bind", nothing)
        return _binding_read(u, o, n, kind)
    end
    local where = m === Main ? "Main" : string(m)
    if m === Main
        n in _snapshot_names() || return ("it reads Main.$n at load: of Main a unit's load reads only the snapshot's names, which every process binds alike, and $n is none (the judge's, a unit's module, or a name only some processes bind)", nothing)
    elseif any(x -> x.mod === m, LOADED)
        return ("it reads $where.$n at load, another unit's module: a unit sees no other unit", nothing)
    elseif !_base_or_core(m)
        return ("it reads $where.$n at load, a binding of $where, a module a unit does not see (a package's, the judge's or another unit's)", nothing)
    end
    _def(m, n) || return ("it reads $where.$n at load, which is not defined" * (kind === :defined ? " (whether it is may differ by process)" : ""), nothing)
    _isconst(m, n) || return ("it reads $where.$n at load, a binding that is not const: its value is whatever its process last set", nothing)
    kind === :value || return (nothing, read())
    local v = _get(m, n)
    # Main itself: read as an operand alone, the read target of a snapshot name (`Main.helper`, the stated deviation);
    # as a value a writer takes it is refused at the write (_canon!), and its contents by the content readers (_same)
    v === Main && return (nothing, v)
    _same(u, v) || return ("it reads $where.$n at load, a $(typeof(v)) whose " *
                           (v isa Module ? "module a unit does not see" : "contents may differ by process (a const binding of a mutable value, or a pointer)"), nothing)
    return (nothing, v)
end
function _binding!(s::Step, m::Module, n::Symbol, kind::Symbol)
    local r = _binding_read(s.u, m, n, kind)
    return r[1] === nothing ? r[2] : _refuse(s, r[1])
end

"""
    _reader!(s, f, args) -> what the read gives

A :reader of the callee table with its real operands: a binding read (getglobal, isdefinedglobal, get_binding_type, getfield of a
module) by _binding_read's rule; a content read (getfield, nfields, sizeof) of a value this load made or of an immutable
value the same in every process, never of a type or a module (sizeof of a type, its layout, admitted). Anything else
refused, named.
"""
function _reader!(s::Step, f, args::Vector{Any})
    if f === Core.getglobal || f === Core.isdefinedglobal || f === Core.get_binding_type || f === Core.getfield && !isempty(args) && args[1] isa Module
        length(args) >= 2 && args[1] isa Module && args[2] isa Symbol || _refuse(s, "it calls $(f) on no module and name")
        return _binding!(s, args[1], args[2], f === Core.isdefinedglobal ? :defined : f === Core.get_binding_type ? :type : :value)
    end
    isempty(args) && _refuse(s, "it calls $(f) with no operand")
    local x = args[1]
    if x isa Type
        f === Core.sizeof || _refuse(s, "it reads a field of the type $(x) at load ($(f)): a type's fields (its name, its method table) change as methods are added")
    elseif !_same(s.u, x)
        _refuse(s, "it reads the contents of a $(typeof(x)) at load ($(f)) that this load did not make: its contents may differ by process")
    end
    return Base.invokelatest(f, args...)
end

# ---- the digest of a load (spec v13 R1 b): the program a unit's load made, said in a form the same in every process.
# Every change a load makes passes a writer (_writer!, _bind!, _one!; and _imports! and a registration, the two changes
# no statement makes): there, and only there, _feed! adds the write, in order: the writer's name and its operands in
# the canonical form _canon! writes. The answering process writes the digest in the label's block; the compiling process
# compares its own with it before it compiles the label (digest_mismatch), and a difference is the label errored: "the
# program loaded here is not the program answered". The construction refuses (_reader!); the digest only rings (D10).
"""
    _canon!(c, x)

`x` in a form the same in every process that loads the same program, or a refusal at the write (CanonRefusal, located
by _feed!) where no such form states it whole: a module by its full name (the unit's own as `@`); a type by its
module's full name, its name and its parameters, read by field access (test/oracle.jl's type_path, made total: a Union,
a UnionAll, a Vararg by their parts); a TypeVar by its position, never its name (`V<k>(lb,ub)` where the write first
meets it, `v<k>` after: lowering names a `<:` TypeVar from a process-global counter, `#s2` in one process and `#s7` in
another, round12-architect p1); a String or Symbol by its bytes; a bits value by its type and bytes; lowered code by its
statements, slots and flags (no line's file, no world, no debug info); an immutable by its fields; a mutable object by
its contents when this load made it. Refused: a pointer (an address), a mutable object the load did not make (a
BigInt's or a BigFloat's digits lie behind a pointer or in a buffer the load never held), Main as a value, and a
value nested past DEPTH: none of them is written lossy (D9). The one exception, stated: a snapshot binding a unit
imports (c.mode :import) is written by its type alone when it is a pointer or a mutable object, since a load never
reads its contents (_binding_read refuses them), so the import's form is its name, its constness and its type. No
object address, no absolute path, no world number: a gensym is the unit module's own counter's, the same in every
process that lowers the same forms in the same order (the two-process test says so).
"""
mutable struct Canon
    io::IOBuffer
    u::Any                       # the Unit
    tvs::Base.IdDict{TypeVar,Int}   # each TypeVar the write met, by its position
    mode::Symbol                 # :write, or :import (a snapshot binding's value, by its type where it is mutable)
end
struct CanonRefusal <: Exception
    why::String
end
const DEPTH = 48   # a bound with a band (D17): intent, a definition's operands nest a few levels; band, past 48 refused
function _canon!(c::Canon, x, depth::Int = 0)
    depth > DEPTH && throw(CanonRefusal("a value nested deeper than $DEPTH levels, which the digest does not write whole"))
    local io, u = c.io, c.u
    local k(y) = _canon!(c, y, depth + 1)
    if x isa Module
        x === Main && c.mode === :write && throw(CanonRefusal("Main as a value: Main is a read target for a snapshot name alone (`Main.helper`), never a value a unit's load writes"))
        print(io, 'M', x === u.mod ? "@" : join(fullname(x), '.'))
    elseif x isa DataType
        print(io, 'T', join(fullname(x.name.module), '.'), '.', x.name.name, '{'); foreach(p -> (k(p); print(io, ',')), x.parameters); print(io, '}')
    elseif x === Union{}
        print(io, "U()")
    elseif x isa Union
        print(io, "U("); k(x.a); print(io, ','); k(x.b); print(io, ')')
    elseif x isa UnionAll
        print(io, "A("); k(x.var); print(io, ','); k(x.body); print(io, ')')
    elseif x isa TypeVar
        local n = get(c.tvs, x, 0)
        if n > 0
            print(io, 'v', n)
        else
            c.tvs[x] = length(c.tvs) + 1
            print(io, 'V', c.tvs[x], '('); k(x.lb); print(io, ','); k(x.ub); print(io, ')')
        end
    elseif x isa Core.TypeofVararg
        print(io, "VA("); isdefined(x, :T) && k(x.T); print(io, ','); isdefined(x, :N) && k(x.N); print(io, ')')
    elseif x isa Symbol
        print(io, 'S', sizeof(String(x)), ':', String(x))
    elseif x isa String
        print(io, 's', sizeof(x), ':', x)
    elseif x isa Core.CodeInfo
        print(io, "CI(", Int(x.nargs), ',', x.isva, ',', x.inlining, ',', x.constprop, ',', x.propagate_inbounds, ',')
        # its slots' names and flags by their contents (Vectors the lowering made, part of the code; written by type alone
        # before spec v14 V3, a lossy form)
        print(io, "SN("); foreach(n -> (k(n); print(io, ',')), x.slotnames); print(io, ")SF(", bytes2hex(x.slotflags), ')')
        foreach(st -> (print(io, ';'); k(st)), x.code); print(io, ')')
    elseif x isa Expr
        print(io, "E(", x.head); foreach(a -> (print(io, ','); k(a)), x.args); print(io, ')')
    elseif x isa QuoteNode
        print(io, "Q("); k(x.value); print(io, ')')
    elseif x isa GlobalRef   # a name in code: its module named, never taken as a value (Main among them)
        print(io, "G(M", x.mod === u.mod ? "@" : join(fullname(x.mod), '.'), ','); k(x.name); print(io, ')')
    elseif x isa Core.SSAValue
        print(io, '%', x.id)
    elseif x isa Core.SlotNumber
        print(io, '_', x.id)
    elseif x isa Core.Argument
        print(io, 'a', x.n)
    elseif x isa Core.GotoNode
        print(io, "→", x.label)
    elseif x isa Core.GotoIfNot
        print(io, "?("); k(x.cond); print(io, ',', x.dest, ')')
    elseif x isa Core.ReturnNode
        print(io, "R("); isdefined(x, :val) ? k(x.val) : print(io, "unreachable"); print(io, ')')
    elseif x isa Core.NewvarNode
        print(io, 'N', x.slot.id)
    elseif x isa LineNumberNode
        print(io, 'L', x.line)
    elseif x isa Core.SimpleVector
        print(io, "SV("); foreach(a -> (k(a); print(io, ',')), x); print(io, ')')
    else
        local T = typeof(x)
        if T <: Ptr || T <: Core.LLVMPtr
            c.mode === :import || throw(CanonRefusal("a $(T), an address, which no process shares and the digest cannot state"))
            print(io, "P("); k(T); print(io, ')')
        elseif isprimitivetype(T)
            print(io, "B("); k(T); print(io, ',', bytes2hex(reinterpret(UInt8, [x])), ')')
        elseif x isa Array && x in u.objs
            print(io, "R("); k(T); print(io, ',', join(size(x), 'x')); foreach(i -> (print(io, ','); isassigned(x, i) ? k(x[i]) : print(io, '#')), eachindex(x)); print(io, ')')
        elseif !ismutabletype(T) || x in u.objs
            print(io, "O("); k(T); foreach(i -> (print(io, ','); isdefined(x, i) ? k(getfield(x, i)) : print(io, '#')), 1:nfields(x)); print(io, ')')
        elseif c.mode === :import
            print(io, "~("); k(T); print(io, ')')   # an imported snapshot binding's mutable value: its type, never its contents
        else
            throw(CanonRefusal("a $(T) the load did not make, whose contents the digest cannot state (a BigInt's or a BigFloat's digits lie behind a pointer)"))
        end
    end
    return nothing
end
"""
    _feed!(u, writer, subject, operands...; mode = :write)

One write of `u`'s load, in order: its canonical form (the writer's name, its subject and operands, _canon!'s) fed to
the load's digest, and its entry (writer, subject, the form's sha-256) kept, so a mismatch names the first write that
differs; a form _canon! cannot write whole is the load's refusal, located at the form being loaded (D9). Called by the
writers alone (_writer!, _bind!, _one!, _imports! with mode :import, a registration).
"""
function _feed!(u::Unit, writer::AbstractString, subject, operands...; mode::Symbol = :write)
    local c = Canon(IOBuffer(), u, Base.IdDict{TypeVar,Int}(), mode)
    local text, sub = try
        _canon!(c, subject)
        local sub = String(take!(c.io))
        print(c.io, writer, '\t', sub)
        foreach(o -> (print(c.io, '\t'); _canon!(c, o)), operands)
        (take!(c.io), sub)
    catch e
        e isa CanonRefusal || rethrow()
        refuse(u, u.line, "it writes ($(writer)) $(e.why); the loader refuses what its digest cannot state: compute it in a function a case calls", u.form)
    end
    SHA.update!(u.sha, text); SHA.update!(u.sha, UInt8['\n'])
    push!(u.writes, (String(writer), first(sub, 160), bytes2hex(SHA.sha256(text))))
    push!(u.texts, first(String(text), 300))   # (String takes the bytes: after the hash)
    return nothing
end
import Base64
"""
    digest_fields(u) -> Vector{String}

A unit's digest as the answering process writes it in each of its labels' blocks, after the label (test/smoke.jl's
judging process: `digest <label> <these fields>`): the load's sha-256, its count of writes, and each write's entry,
`<writer>,<subject in base64>,<its sha-256's first 16 hex digits>`, joined by `;`.
"""
digest_fields(u::Unit) = [u.digest, string(length(u.writes)),
    join((string(w, ',', Base64.base64encode(sub), ',', first(h, 16)) for (w, sub, h) in u.writes), ';')]
"""
    digest_mismatch(stored, u) -> nothing or why

The one compare of a label's stored digest (`stored`: its block's `digest` fields after the label, or nothing) with its
unit's load in this process (`u`, nothing for a snapshot label): nothing when they agree; else why, naming the unit and
the first write that differs.
"""
function digest_mismatch(stored, u)
    u === nothing && return stored === nothing ? nothing : "its stored answer carries a digest of a unit's load, and it is no unit's label here"
    local name = basename(u.path)
    stored === nothing && return "the program loaded here is not the program answered: its stored answer carries no digest of $(name)'s load, which every answer of a unit's label carries (a store written before digests: `climb.py oracle-replay`)"
    length(stored) == 3 || return "the program loaded here is not the program answered: its stored digest of $(name) does not read"
    stored[1] == u.digest && return nothing
    local theirs = split(stored[3], ';'; keepempty = false)
    for (i, w) in enumerate(u.writes)
        local t = i <= length(theirs) ? split(theirs[i], ',') : String[]
        local mine = string(w[1], ',', Base64.base64encode(w[2]), ',', first(w[3], 16))
        i <= length(theirs) && theirs[i] == mine && continue
        return "the program loaded here is not the program answered: $(name)'s write $i differs (" *
               (isempty(t) ? "the answered load made $(length(theirs)) write(s)" : "answered: $(t[1]) $(length(t) >= 2 ? String(Base64.base64decode(t[2])) : "?")") *
               "; loaded here: $(replace(u.texts[i], '\t' => ' ')))"
    end
    return "the program loaded here is not the program answered: $(name)'s load made $(length(u.writes)) write(s), the answered one $(length(theirs))"
end

# a writer's real target: a binding of the unit's own module (each name fresh, _bind!), or a type the unit made in
# this load (a type is filled once: _typebody! of a fresh type alone)
function _writer!(s::Step, f, args::Vector{Any})
    local u = s.u
    _feed!(u, String(nameof(f)), length(args) >= 2 && args[2] isa Symbol ? args[2] : :none, args...)
    local mine(T) = T in u.made || _refuse(s, "it calls $(f) on $(T), which is no type the unit made in this load")
    if f === Core.setglobal! || isdefined(Core, :declare_const) && f === getglobal(Core, :declare_const) ||
       isdefined(Core, :declare_global) && f === getglobal(Core, :declare_global)
        length(args) >= 2 && args[1] isa Module && args[2] isa Symbol || _refuse(s, "it calls $(f) on no module and name")
        args[1] === u.mod || _refuse(s, "it binds $(args[1]).$(args[2]), a name of another module (a unit binds its own names alone)")
        _bind!(s, args[2]::Symbol, f === Core.setglobal! ? :set : f === getglobal(Core, :declare_const) ? :const :
                                   length(args) >= 3 && args[3] === false ? :weak : :declare)
    elseif f === Core._structtype || f === Core._abstracttype || f === Core._primitivetype
        length(args) >= 2 && args[1] === u.mod || _refuse(s, "it defines a type in $(isempty(args) ? "no module" : args[1]), not in the unit's own module")
    elseif f === Core._setsuper! || isdefined(Core, :_defaultctors) && f === getglobal(Core, :_defaultctors)
        isempty(args) && _refuse(s, "it calls $(f) with no type")
        mine(args[1])
        f === Core._setsuper! || push!(s.callees, Type{X} where X<:args[1])
    elseif f === Core._typebody!
        length(args) in (2, 3) || _refuse(s, "it calls $(f) with $(length(args)) arguments")
        args[1] === false || _refuse(s, "it redefines the type $(args[2]) (a unit defines each type once)")
        mine(args[2])
    else
        _refuse(s, "it calls $(f), a writer the loader has no target rule for")
    end
    return nothing
end

# A name a statement binds in the unit (every spelling: 1.12's :const, :global and :globaldecl heads and :method of a
# name, 1.13's Core.declare_const and Core.declare_global, and setglobal!): `kind` :weak (`global x`, which declares a
# name and changes none the unit binds already: a struct's lowering repeats it after the `const`), :declare (a strong
# or typed global, no value), :const, :set (a value of a global the unit declared) or :function (a generic function,
# gaining methods). Admitted when the name is fresh (_fresh_refusal) or the unit's own in a state that kind continues:
# a declared global given a value or declared again, a function gaining a method; anything else, a name bound twice,
# refused
function _bind!(s::Step, name::Symbol, kind::Symbol)
    local u = s.u
    _feed!(u, "bind", name, kind)
    local now = get(u.state, name, nothing)
    if now === nothing
        startswith(String(name), '#') ? (_def(u.mod, name) && _refuse(s, "it binds $name twice")) :
            (why = _fresh_refusal(u, name); why === nothing || _refuse(s, why))
    elseif kind === :weak || kind === :function && now === :const && _get(u.mod, name) in u.made
        return nothing   # (a method of a type the unit made: its constructor, `_T(x::Float64) = …`)
    elseif !(now === :declared && kind in (:declare, :const, :set, :function) || now === :global && kind in (:declare, :set) ||
             now === :function && kind === :function)
        _refuse(s, "it binds $name, which the unit binds already ($(now)): every name a unit binds is bound once")
    end
    u.state[name] = kind in (:weak, :declare) ? (now === :global ? :global : :declared) : kind === :set ? :global : kind
    startswith(String(name), '#') || push!(u.names, name)
    return nothing
end
# a binding statement's target, a GlobalRef or a name of the thunk's module, as (module, name)
function _target(s::Step, r)
    r isa GlobalRef && return (r.mod, r.name)
    r isa Symbol && return (s.u.mod, r)
    _refuse(s, "it binds $(r), which is no name")
end

# 1.12's binding heads: each target the unit's own, bound by _bind!; then the statement run by Julia, its value quoted
function _declare!(s::Step, ci::Core.CodeInfo, st::Expr, val)
    local h = st.head
    for r in (h === :global ? st.args : st.args[1:1])
        local m, n = _target(s, r)
        m === s.u.mod || _refuse(s, "it binds $(m).$(n), a name of another module (a unit binds its own names alone)")
        _bind!(s, n, h === :const ? :const : h === :global ? :weak : :declare)
    end
    h === :global && return _one!(s, ci, Expr(:global, st.args...))
    return _one!(s, ci, Expr(h, st.args[1], (QuoteNode(val(a)) for a in st.args[2:end])...))
end

"""
    _method!(s, ci, st, val)

`:method` of a name (a generic function declared, or a function of the unit's own gaining methods: _bind!), or of a
callee, a real signature and a body: the method's callee owned by the unit or admitted (_owner_refusal), its signature
replacing no method and reachable only with the unit's own types (_sig_refusal), both read from the real signature
before the method exists; its function value no method table (an overlay); its body lowered code, which runs when a
case calls it. Then Julia runs the statement, its operands quoted.
"""
function _method!(s::Step, ci::Core.CodeInfo, st::Expr, val)
    local u = s.u
    if length(st.args) == 1
        local m, n = _target(s, st.args[1])
        m === u.mod || _refuse(s, "it adds a method to $(m).$(n), a name of another module")
        _bind!(s, n, :function)
        return _one!(s, ci, Expr(:method, st.args[1]))
    end
    length(st.args) == 3 || _refuse(s, "a `:method` of $(length(st.args)) arguments")
    local fv = st.args[1] isa Union{Bool,Nothing} ? st.args[1] : val(st.args[1])
    fv isa Core.MethodTable && _refuse(s, "a method into a method table of its own (an overlay)")
    local sig = val(st.args[2])
    sig isa Core.SimpleVector && length(sig) >= 2 && sig[1] isa Core.SimpleVector && length(sig[1]) >= 1 &&
        sig[2] isa Core.SimpleVector || _refuse(s, "a method whose signature is no svec of types")
    local body = st.args[3]
    body isa Core.CodeInfo || _refuse(s, "a method whose body is no lowered code")
    local r = _unit_reference(u, body)
    r === nothing || _refuse(s, "a method whose body reads $(r), another unit's: a unit sees no other unit")
    local T = try
        local T = Core.apply_type(Tuple, sig[1]...)
        for tv in reverse(collect(sig[2]))
            T = UnionAll(tv::TypeVar, T)
        end
        T
    catch
        _refuse(s, "a method whose signature the loader cannot form")
    end
    local owner = _callee_owner(u, sig[1][1], length(sig[1]) >= 3 ? sig[1][3] : nothing)
    owner === nothing && _refuse(s, "a method on $(sig[1][1]), a callee the loader cannot name")
    local why = _owner_refusal(u, owner...)
    why === nothing || _refuse(s, why)
    why = _sig_refusal(u, T, Base.get_world_counter(), "")
    why === nothing || _refuse(s, why)
    _within(owner[1], u.mod) || (why = _max_args_refusal(T); why === nothing || _refuse(s, why))
    local C = sig[1][1]
    for tv in reverse(collect(sig[2]))
        C = UnionAll(tv::TypeVar, C)
    end
    push!(s.callees, C)
    return _one!(s, ci, Expr(:method, QuoteNode(fv), QuoteNode(sig), body))
end

# a name a unit binds is fresh: nothing Base, Core or the snapshot binds and no unit module's name, so every lookup
# the corpus and the judge make reaches what it reached before the unit (round 9b)
function _fresh_refusal(u::Unit, s::Symbol)
    _unit_name(s) && return "it binds $s, a name of the form the loader gives a unit's module (U_<slug>)"
    _def(u.mod, s) && return "it binds $s, which $(s in u.names ? "the unit binds already" : "Base, Core or an imported name binds"): every name a unit binds is fresh"
    _snapshot_binds(s) && return "it binds $s, a name the snapshot binds: every name a unit binds is fresh"
    return nothing
end

# the module that owns a method's callee, from its real callee type: a function's own module, a type's (a constructor,
# Type{X}), a callable type's; a keyword method's (Core.kwcall) its function's, the signature's third type
function _callee_owner(u::Unit, c, sig3)
    c === typeof(Core.kwcall) && return sig3 === nothing ? nothing : _callee_owner(u, sig3, nothing)
    c isa UnionAll && return _callee_owner(u, Base.unwrap_unionall(c), sig3)
    c isa DataType || return nothing
    if c.name === Type.body.name   # a constructor: Type{X}
        local x = c.parameters[1]
        x isa TypeVar && (x = x.ub)
        x isa UnionAll && (x = Base.unwrap_unionall(x))
        x isa DataType || return nothing
        return (x.name.module, x)
    end
    return (c.name.module, c <: Function && Base.issingletontype(c) ? c.instance : c)
end

# a method's owner: no unit method on the definition's machinery (Core.Typeof, Core.TypeVar, Core.kwftype), on any
# function of Core or of Julia's compiler, or on a function of the judge's (its modules', or one Main bound before the
# snapshot): the judge's and the compiler's own code would reach it
function _owner_refusal(u::Unit, mod::Module, callee)
    local j = JUDGE[]::Judge
    (callee === TypeVar || _machinery(callee)) && return "it adds a method to $(callee), which every definition's lowering calls (L1)"
    local root = Base.moduleroot(mod)
    callee isa Function && (mod === Core || root === Core) && return "it adds a method to $(callee), a function of Core"
    (mod === Core.Compiler || _within(mod, Core.Compiler) || isdefined(Base, :Compiler) && _within(mod, _get(Base, :Compiler))) &&
        return "it adds a method to $(callee), a definition of Julia's compiler"
    any(m -> _within(mod, m), j.modules) && return "it adds a method to $(callee), the judge's or the compiler's ($(mod))"
    any(x -> x.mod !== u.mod && _within(mod, x.mod), LOADED) && return "it adds a method to $(callee), another unit's ($(mod)): a unit sees no other unit"
    callee isa Function && callee in j.functions && return "it adds a method to $(callee), a function of the judge's"
    return nothing
end
function _within(m::Module, outer::Module)
    while true
        m === outer && return true
        local p = parentmodule(m)
        p === m && return false
        m = p
    end
end

# ---- reading back what a form made
# the definition's machinery carries no unit's method (checked before and after every form)
function _machinery_refusal(u::Unit)
    local units = Base.IdSet{Module}(x.mod for x in LOADED); push!(units, u.mod)
    for f in MACHINERY_REFUSED
        for m in methods(f)
            m.module in units && return "a unit's method on $(f), which every definition's lowering calls (L1): $(m)"
        end
    end
    return nothing
end

# every method a form added: those of a callee type its stepped `:method`s and default constructors named, with a
# primary world in the form's
function _new_methods(callees, w0::UInt, w1::UInt)
    local out = Method[]
    for C in callees
        local t = Base.rewrap_unionall(Tuple{Base.unwrap_unionall(C),Vararg{Any}}, C)
        local ms = Base._methods_by_ftype(t, -1, Base.get_world_counter())
        ms isa AbstractVector || continue
        for x in ms
            local m = x.method
            w0 < m.primary_world <= w1 && !(m in out) && push!(out, m)
        end
    end
    return out
end

function _reflect!(u::Unit, line::Int, form, callees, w0::UInt, w1::UInt)
    for m in _new_methods(callees, w0, w1)
        u.nmethods += 1
        local why = _method_refusal(u, m, w0)
        why === nothing || refuse(u, line, why, form)
        _owns(u, m) || push!(u.foreign, m)   # deleted once the unit's world is taken (_retire_foreign!)
    end
    return nothing
end
# The width a method raises its function's type name to, as Julia computes it on inserting the method (src/gf.c:1989
# update_max_args: the signature's parameter count, an unbounded Vararg not counted; Core.kwcall's and a `Type{…}`
# callee's never raised), and that width now. Julia reads it in jl_compilation_sig (which varargs calls specialize)
# and never lowers it, and Base.delete_method leaves it raised, so a unit's method on a function it does not own may
# not raise it (spec v14 W1): the one piece of state a deletion would not restore (v14/v1/visit.jl), refused at the
# source, before the method exists. precedent(julia: src/gf.c:1989 update_max_args)
function _max_args_refusal(@nospecialize(sig))
    local t = Base.unwrap_unionall(sig)
    t isa DataType && !isempty(t.parameters) || return nothing
    local d = t.parameters[1]
    d isa Core.TypeofVararg && (d = isdefined(d, :T) ? d.T : Any)
    d isa TypeVar && (d = d.ub)
    d = Base.unwrap_unionall(d)
    d isa DataType || return nothing
    (d === typeof(Core.kwcall) || d.name === Type.body.name) && return nothing
    local na = length(t.parameters)
    !isempty(t.parameters) && t.parameters[end] isa Core.TypeofVararg && !isdefined(t.parameters[end], :N) && (na -= 1)
    local now = Int(d.name.max_args)
    na > now || return nothing
    return "it adds a method of $(na - 1) argument(s) to $(d.name.singletonname), a function it does not own whose widest method " *
           "takes $(now - 1): Julia keeps the width a method raises (max_args) after the method is deleted, so another " *
           "unit's compile would see it; define the wider method on a function of your own (`_my_f(...)`)"
end
# whether the unit owns a method's function: its callee's module is the unit's own (a keyword method's, Core.kwcall's,
# is its function's: _callee_owner)
function _owns(u::Unit, m::Method)::Bool
    local p = Base.unwrap_unionall(m.sig).parameters
    local c = _callee_owner(u, p[1], length(p) >= 3 ? p[3] : nothing)
    return c !== nothing && _within(c[1], u.mod)
end

function _sig_refusal(u::Unit, sig, w::UInt, what::AbstractString)
    local old = Base._methods_by_ftype(sig, -1, w)
    if old isa AbstractVector
        for x in old
            x.method.sig == sig && return "it replaces $(x.method.sig) of $(x.method.module), a method visible before it"
        end
    end
    unreachable_without(u, sig) || return "it adds a method of $(sig) that a call passing none of the unit's own values " *
        "can reach (piracy): a unit's method on a function it does not own takes, at some argument, only the unit's own " *
        "values: " * join((f.text for f in OWN_ONLY_FORMS), "; ") * "; never a Union with a foreign type " *
        "(`Union{_T,Int}`), a Vararg alone (`Vararg{_T}`, which may be empty), a Type of a variable (`Type{<:_T}`, which " *
        "`Type{Union{}}` meets), a supertype bound (`S where S>:_T`) or Any (spec v14 V1: no unit's method is dispatched " *
        "to by another unit's or the snapshot's values)"
    return nothing
end

# a method a unit adds: no generator (a generator runs as the case is inferred), no effect override (inference would
# run its body by what it claims), none replacing a method visible before it, its owner admitted (_owner_refusal), and
# reachable only by a call that passes one of the unit's own types (the early refusal of piracy, section 2)
function _method_refusal(u::Unit, m::Method, w0::UInt)
    isdefined(m, :generator) && m.generator !== nothing && return "it defines a generated function ($(m.sig)): its generator runs as the case is inferred"
    m.purity != 0 && return "it defines $(m.sig) with an effect override (@assume_effects, @pure): inference would run it by what it claims"
    local why = _sig_refusal(u, m.sig, w0, "after")
    why === nothing || return why
    local p = Base.unwrap_unionall(m.sig).parameters
    local c = _callee_owner(u, p[1], length(p) >= 3 ? p[3] : nothing)
    c === nothing && return "a method on a callee the loader cannot name: $(m.sig)"
    local why = _owner_refusal(u, c...)
    why === nothing || return why
    return nothing
end

"""
    OWN_ONLY_FORMS

THE forms of an argument's type every value of which is the unit's own (spec v16 X6), each its decision (`holds(mod, t,
param)`, recursive through _own_only) beside its text: _own_only decides by them and _sig_refusal's text is theirs, one
place. A form holds by structure: no foreign value has such a type, since a foreign value is made by code that cannot
name the unit's types (it sees no unit's module: _binding_read), and a type mentioning one of them invariantly, as a
parameter, a Tuple's element or a variable's bound, is that unit's to make. `param` is true where `t` is a type
parameter: there a variable is never the unit's (it may be Union{}, which Vector{Union{}} a foreign caller can make).
"""
const OWN_ONLY_FORMS = (
    (text = "a type the unit made (`x::_T`), or the Type of one (`x::Type{_T}`)",
     holds = (mod, t, param) -> t isa DataType && (t.name === Type.body.name ?
         (x = t.parameters[1]; !(x isa TypeVar) && (x = Base.unwrap_unionall(x); x isa DataType && x.name.module === mod)) :
         t.name.module === mod)),
    (text = "an invariant parameterisation with such a parameter (`x::Vector{_T}`, `x::Ref{_T}`, `x::Pair{_T,Int}`)",
     holds = (mod, t, param) -> t isa DataType && t.name !== Type.body.name && !(t <: Tuple) && t.name.module !== mod &&
         any(p -> _own_only(mod, p, true), t.parameters)),
    (text = "a Tuple with such an element (`x::Tuple{_T,Int}`)",
     holds = (mod, t, param) -> t isa DataType && t <: Tuple && any(p -> !(p isa Core.TypeofVararg) && _own_only(mod, p), t.parameters)),
    (text = "a where-bound of one (`x::S where S<:Vector{_T}`)",
     holds = (mod, t, param) -> !param && t isa TypeVar && _own_only(mod, t.ub)),
    (text = "a Union of such (`x::Union{_T,_U}`)",
     holds = (mod, t, param) -> t isa Union && _own_only(mod, t.a, param) && _own_only(mod, t.b, param)),
)
# a type every value of which is the unit's own: one of OWN_ONLY_FORMS (a UnionAll by its body)
_own_only(mod::Module, t, param::Bool = false)::Bool =
    t isa UnionAll ? _own_only(mod, Base.unwrap_unionall(t), param) : any(f -> f.holds(mod, t, param), OWN_ONLY_FORMS)

"""
    unreachable_without(u, sig) -> Bool

True when no call whose arguments are free of the unit's own types can reach a method of signature `sig`: at some
position (the callee's among them; never a Vararg's, which may be empty) the signature takes only the unit's own values
(_own_only: one of OWN_ONLY_FORMS), or it is a subtype of a signature with the unit's types at one position and meets
no `Type{Union{}}` there (dev/climb loader design, section 2). Sound: `<:` is exact, and typeintersect never empties a
non-empty intersection. For a method on a function the unit does not own the callee's position is not the unit's, so an
argument must be: no other unit's or the snapshot's values reach it, and a unit loaded beside it answers natively as it
does alone (spec v14 V1, with _retire_foreign!).
"""
function unreachable_without(u::Unit, sig)
    local owned = Any[]
    _owned!(owned, u.mod, sig, Base.IdSet{Any}())
    isempty(owned) && return false
    local O = Union{owned...}
    local ps = Base.unwrap_unionall(sig).parameters
    local n = length(ps)
    for i in 1:n   # by structure: a position every value of which is the unit's own (OWN_ONLY_FORMS)
        ps[i] isa Core.TypeofVararg || !_own_only(u.mod, ps[i]) || return true
    end
    for i in 0:n-1
        local P = Tuple{ntuple(_ -> Any, i)..., O, Vararg{Any}}
        local Z = Tuple{ntuple(_ -> Any, i)..., Type{Union{}}, Vararg{Any}}
        sig <: P && typeintersect(sig, Z) === Union{} && return true
    end
    return false
end
# the unit's own types a signature mentions, each as every instance of its type name and every Type of one
function _owned!(out, mod::Module, t, seen)
    t in seen && return out
    push!(seen, t)
    if t isa UnionAll
        _owned!(out, mod, t.var.ub, seen); _owned!(out, mod, t.body, seen)
    elseif t isa Union
        _owned!(out, mod, t.a, seen); _owned!(out, mod, t.b, seen)
    elseif t isa TypeVar
        _owned!(out, mod, t.ub, seen)
    elseif t isa Core.TypeofVararg
        isdefined(t, :T) && _owned!(out, mod, t.T, seen)
    elseif t isa DataType
        if t.name.module === mod
            local w = t.name.wrapper
            push!(out, w, Type{<:w})
        end
        foreach(p -> _owned!(out, mod, p, seen), t.parameters)
    end
    return out
end

# every method whose primary world falls in a unit's load was attributed to one of its forms, so no definition the
# loader did not read back stands: Julia's own method table, read once a load (Base.visit; the units' world ranges are
# disjoint, each method counted in the range its primary world falls in), not once a unit
function _cross_check(units::Vector{Unit})
    isempty(units) && return nothing
    local n = zeros(Int, length(units))
    local lo, hi = first(units).w0, last(units).world
    Base.visit(Core.methodtable) do m
        local w = m.primary_world
        lo < w <= hi || return
        local k = findfirst(x -> x.w0 < w <= x.world, units)
        k === nothing || (n[k] += 1)
    end
    for (k, u) in enumerate(units)
        n[k] == u.nmethods || refuse(u, 0, "its forms added $(n[k]) method(s), and the loader read back $(u.nmethods)", u.path)
    end
    return nothing
end

# ---- Base's values: what a constant's arithmetic (CONST_CALLS) takes and a case's argument is: a number, a string, a
# char, a symbol, nothing or missing of Base's types, a tuple or vector of them, a type of Base's
# (a mutable Number, BigInt or BigFloat, is none: its digits lie behind a pointer the digest cannot state, and its
# arithmetic reads MPFR's process-global precision and rounding, spec v14 V3)
_plain_type(T) = T isa DataType && Base.moduleroot(T.name.module) in (Core, Base) && !(T <: Number && ismutabletype(T))
function _plain(x)
    x isa Union{Number,String,Char,Symbol,Nothing,Missing} && return _plain_type(typeof(x))
    x isa Tuple && return all(_plain, x)
    x isa Array && return _plain_type(typeof(x)) && _plain_type(eltype(x)) || eltype(x) === Any && all(_plain, x)
    x isa Type && return _plain_type(x)
    return false
end
# ---- a registration: read, never evaluated. `_g("<group>", Any[("<case>", f, args...), ...])` (or `_xf`, or a `[...]`
# of cases): the group and each case a string literal, f a lambda (lowered, checked and evaluated as a definition) or a
# function the unit defines, each argument an expression Julia lowers and the stepper runs to a value of Base's
# (_argument); the judge's registrar called with a Vector{Any} of Core.tuples
# the characters a label may hold (spec v17 Y4, red 8c): every record downstream is tab- and line-framed (the labels
# file, the answer and compile records, the cases), so a label outside them is refused at its registration, located,
# never far from its cause
const LABEL_CHARS = r"^[A-Za-z0-9_./-]+$"
_label_refusal(name) = occursin(LABEL_CHARS, name) ? nothing :
    "the name $(repr(name)) holds a character outside [A-Za-z0-9_./-], which every tab- and line-framed record of a label needs"
# a registration's group and its case expressions, or why it is none: the one reader registered_labels and the load share
function _registration_cases(form)
    form isa Expr && form.head === :call && form.args[1] in (:_g, :_xf) || return "no registration"
    length(form.args) == 3 || return "a registration of $(length(form.args) - 1) arguments, not 2"
    local group = form.args[2]
    group isa String || return "a registration whose group is no string literal"
    (w = _label_refusal(group)) === nothing || return "a registration whose group is refused: $w"
    local cs = form.args[3]
    cs isa Expr && cs.head === :vect && return (group, cs.args)
    cs isa Expr && cs.head === :ref && cs.args[1] === :Any && return (group, cs.args[2:end])
    return "a registration whose cases are no `Any[…]` or `[…]` of tuples"
end
function _registration!(u::Unit, line::Int, form; register, labels::Set{String})
    local r = _registration_cases(form)
    r isa Tuple || refuse(u, line, r, form)
    local group, elems = r
    local cases = Any[]
    for t in elems
        t isa Expr && t.head === :tuple && length(t.args) >= 2 && t.args[1] isa String ||
            refuse(u, line, "a case that is no `(\"<label>\", f, args...)` with a string literal label", t)
        local label = "$group/$(t.args[1])"
        (w = _label_refusal(t.args[1])) === nothing || refuse(u, line, "the case $(repr(t.args[1])) of $group is refused: $w", t)
        label in labels && refuse(u, line, "the label $label is registered already: smoke keeps the last, masking the first", t)
        local fx = t.args[2]
        local f = if fx isa Expr && fx.head === :->
            _check_macros(u, line, fx, false)
            local lowered = Meta.lower(u.mod, fx)
            lowered isa Expr && lowered.head === :thunk || refuse(u, line, "the case $label's function lowers to no thunk", t)
            local f = _run_form!(u, line, t, lowered.args[1]::Core.CodeInfo)
            f isa Function || refuse(u, line, "a lambda whose definition gives a $(typeof(f))", t)
            f
        elseif fx isa Symbol && fx in u.names && _get(u.mod, fx) isa Function
            _get(u.mod, fx)
        else
            refuse(u, line, "the case $label's function is no lambda and no function the unit defines", t)
        end
        local args = Any[_argument(u, line, t, label, a) for a in t.args[3:end]]
        push!(labels, label); push!(u.labels, label)
        _feed!(u, "register", label, f, args...)
        push!(cases, Core.tuple(String(t.args[1]), f, args...))
    end
    register(form.args[1]::Symbol, group, cases)
    return nothing
end
# a case's argument: its expression lowered by Julia in the unit's module and run by the stepper, as any form is (its
# calls a constant's arithmetic, CONST_CALLS; a name read by _reader!), its value one of Base's
function _argument(u::Unit, line::Int, t, label::String, a)
    local lowered = Meta.lower(u.mod, a)
    local v = if lowered isa Expr && lowered.head === :thunk
        _run_form!(u, line, t, lowered.args[1]::Core.CodeInfo)
    elseif lowered isa Symbol
        _binding!(Step(u, line, t, Any[], 0), u.mod, lowered, :value)
    elseif lowered isa Expr || lowered isa GlobalRef
        refuse(u, line, "the case $label's argument lowers to $(lowered isa Expr ? lowered.head : "a global"), no value", a)
    else
        lowered isa QuoteNode ? lowered.value : lowered
    end
    _plain(v) || refuse(u, line, "the case $label's argument is a $(typeof(v)), none of Base's numbers, strings, symbols, tuples or vectors of them", a)
    return v
end
_check_register(kind, group, cases) = nothing   # G5's: the labels are the loader's own record (Unit.labels)
# ---- G5's run: no WasmTarget, no runner; the snapshot at <root>/test/smoke_corpus.jl included into Main with a
# registrar that records labels, then the units under <root>/test/corpus in the order <root>/units.log gives (a unit
# file the log does not name, the move's, last)
function check_main(args)
    if length(args) >= 2 && args[1] == "--labels"   # the driver's labels of corpus files, by `registered`
        local unread = String[]
        for p in args[2:end], (_, g, c) in registered(read(p, String); filename = p, unread)
            println("label\t", g, "/", c)
        end
        foreach(x -> println("unread\t", x), unread)
        return 0
    end
    length(args) == 2 && args[1] == "--check" || (println(stderr, "usage: corpus_loader.jl --check <root> | --labels <file>..."); return 2)
    local root = args[2]
    local seen = Set{String}()
    Core.eval(Main, :(_g(name, cases) = (foreach(c -> push!($seen, string(name, "/", c[1])), cases); nothing)))
    Core.eval(Main, :(_xf(name, cases) = (foreach(c -> push!($seen, string(name, "/", c[1])), cases); nothing)))
    judge!(Base.get_world_counter(), Module[CorpusLoader])
    Base.include(Main, joinpath(root, "test", "smoke_corpus.jl"))
    for p in unit_paths(root; handed = joinpath(root, "units.log"))
        try
            local u = Base.invoke_in_world((JUDGE[]::Judge).world, load_unit, p; register = _check_register, labels = seen)
            foreach(l -> println("label\t", l), u.labels)
        catch e
            e isa Refusal || rethrow()
            println("refused\t", relpath(e.unit, root), "\t", e.line, "\t", replace(e.why, r"\s+" => " "), "\t", replace(e.text, r"\s+" => " "))
            return 0
        end
    end
    return 0
end

end # module CorpusLoader

abspath(PROGRAM_FILE) == (@__FILE__) && exit(CorpusLoader.check_main(ARGS))
