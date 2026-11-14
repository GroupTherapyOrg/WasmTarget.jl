# The oracle's capture: native Julia's answer to a case, computed once and written as data (dev/climb/HILL.md, the
# oracle). Every fact a stored answer holds is computed here and nowhere else. This file is one of the answering
# program's files (dev/climb/core.py JUDGE_WRITE: test/smoke_judge.jl, the judging entry; this file; test/corpus_loader.jl),
# whose blobs at origin are the store's `judge` key: a change to any stales every stored answer (a deliberate replay,
# `climb.py oracle-replay`). It is the WRITE half alone: what reads the records back (read_answers, _restore,
# resolve_type_path, the Named and Opaque stand-ins) is test/oracle_read.jl's, which no stored byte depends on (spec
# v14 V2), and test/runner.jl, the keeper's, is never loaded where an answer is written or a verdict decided (spec v16
# X1: test/verdict.jl).
#
#   answer_of(label, f, args) -> Answer        the one code that calls a case's function natively
#   answer_lines(case, a)                      an Answer as records (texts in base64); test/oracle_read.jl reads them back
#   type_path(T)                               a type named by its structure (test/oracle_read.jl finds it again)
#
# A module of its own, WTOracle, loaded into Main by the judging entry (test/smoke_judge.jl) and, in the processes that
# compile and judge, by test/smoke.jl and test/verdict.jl. Nothing here dispatches on a value the corpus may
# define a method for, except the case's own call (native_answer) and the leaf reads Base defines (_step on a tuple, a
# Vector or a String): a type is named by field access (T.name.module, T.name.name, T.parameters), never by show.
module WTOracle

import Base64

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
    native_answer(f, args, world = Base.get_world_counter())

Native Julia's answer to `f(args...)` called at `world` (the case's own: test/smoke.jl), or `Throws(typeof(e))` when the
call throws. The call alone runs at that world; the caller's code, which reads the answer, runs at its own.
"""
native_answer(f, args::Tuple, world::UInt = Base.get_world_counter()) = try
    Base.invoke_in_world(world, f, args...)
catch e
    Throws(typeof(e))
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
# the positions of a case's String arguments: a structural test (isa), no method of the corpus's
_string_positions(args::Tuple) = Tuple(i for (i, a) in enumerate(args) if a isa String)
_bound_label(label::String, P::Tuple) = isempty(P) ? label :
    "$label(String argument$(length(P) == 1 ? "" : "s") $(join(P, ", ")) bound)"
# the case as the runner compiles it: (label, f, args) unchanged when no argument is a String, else Bound's
function _bound(label::String, f, args::Tuple)
    local P = _string_positions(args)
    isempty(P) && return (label, f, args)
    local B = Bound{f,P,Tuple(Symbol(args[i]) for i in P)}
    return (_bound_label(label, P), B(), Tuple(a for a in args if !(a isa String)))
end

# A tuple answer leaves the module as a reference to a wasm struct, which JS cannot read: its facts are read in wasm
# by a reader (test/runner.jl's Leaves), one per leaf type, each leaf named by its path in the answer. A vector's
# length is a leaf, each element a leaf (or a nest); a String's ncodeunits is a leaf, each codeunit (a UInt8) a leaf.
# A path's steps: an Int, a tuple's field; (:ix, i), a vector's element; :len, a vector's length; (:cu, i), a
# String's codeunit; :ncu, its ncodeunits.
_step(x, i::Int) = getfield(x, i)
_step(x, s::Tuple{Symbol,Int}) = s[1] === :cu ? codeunit(x, s[2]) : x[s[2]]
_step(x, s::Symbol) = s === :ncu ? Int64(ncodeunits(x)) : Int64(length(x))
_string_step(s) = s === :ncu || (s isa Tuple && s[1] === :cu)
_on_string(p::Tuple) = any(_string_step, p)
_string_of(p::Tuple) = p[1:findfirst(_string_step, p)-1]   # the path of the String a leaf reads
# each leaf's path in a nest of tuples, vectors and Strings, in order
_leaves(x, p::Tuple = ())::Vector{Tuple} =
    x isa Tuple ? reduce(vcat, (_leaves(y, (p..., i)) for (i, y) in enumerate(x)); init = Tuple[]) :
    x isa Vector ? reduce(vcat, (_leaves(y, (p..., (:ix, i))) for (i, y) in enumerate(x)); init = Tuple[(p..., :len)]) :
    x isa String ? Tuple[(p..., :ncu); [(p..., (:cu, i)) for i in 1:ncodeunits(x)]] :
    Tuple[p]
# an answer read by readers, not by its own module's return: a tuple (not empty), a vector or a String
_aggregate(x) = (x isa Tuple && !isempty(x)) || x isa Vector || x isa String

# ---- a type named by its structure (the oracle, 6e): read by field access alone, never by show (a corpus
# `Base.show(::IO, ::Type{_T})` chooses that text), and found again by lookups alone (getglobal and Core.apply_type, no
# parse, no eval), the result checked to be the type the path names. Tokens, space-separated, in prefix order:
#   T <module fullname, each part base64, joined by .> <name, base64> <n>   a DataType and its n parameters
#   S <base64>                                                               a Symbol parameter
#   B <hex bytes> <its type, a T node>                                       a parameter of a primitive type (3, true)
#   P <n>                                                                    a tuple parameter and its n elements
#   U                                                                        a parameter the path cannot name
_b64(s) = Base64.base64encode(s)
# a value of a primitive type as its bytes (no padding: a primitive type is its bits), `-` for none, and back
_hex(x) = (b = reinterpret(UInt8, [x]); isempty(b) ? "-" : bytes2hex(b))
function _type_path!(out::Vector{String}, x)
    if x isa DataType
        local ps = x.parameters
        push!(out, "T", join(map(n -> _b64(String(n)), fullname(x.name.module)), '.'), _b64(String(x.name.name)), string(length(ps)))
        for p in ps
            _type_path!(out, p)
        end
    elseif x isa Symbol
        push!(out, "S", _b64(String(x)))
    elseif isprimitivetype(typeof(x))
        push!(out, "B", _hex(x)); _type_path!(out, typeof(x))
    elseif x isa Tuple
        push!(out, "P", string(length(x)))
        foreach(y -> _type_path!(out, y), x)
    else
        push!(out, "U")
    end
    return out
end
"""    type_path(T) -> String

`T` named by its structure: its module's fullname, its name and its parameters, read by field access."""
type_path(T) = join(_type_path!(String[], T), ' ')


# ---- a value as the store holds it, whatever the wire carries (test/runner.jl's _wire, a keeper's to extend): a value
# of a primitive type by its bytes and its type path, exactly; a singleton by its type path; a thrown exception by its
# type's path; any other value by its type path alone (opaque). Read back by test/oracle_read.jl (_restore).
function _capture(x)::String
    local T = x isa Throws ? x.type : typeof(x)
    local k = x isa Throws ? "throws" : Base.issingletontype(T) ? "void" : isprimitivetype(T) ? "bits" : "opaque"
    return join((k, _b64(type_path(T)), k == "bits" ? _hex(x) : "-"), ',')
end

"""    oracle_key() -> String

What a stored answer depends on besides the corpus and the answering program's files, as this process sees it: Julia
(its version and commit) and the host (its architecture, its CPU, whether it fuses multiply-add, its word size),
tab-separated. The driver adds the answering program's files' blobs, the snapshot's blob and the native processes'
environment (dev/climb/measure.py oracle_key)."""
oracle_key() = string("julia=", VERSION, "+", Base.GIT_VERSION_INFO.commit, "\t", "host=", Sys.ARCH, ",", Sys.CPU_NAME, ",fma=",
                      Core.Intrinsics.have_fma(Float64), ",word=", Sys.WORD_SIZE)

# ---- the answer
"""One leaf group of an aggregate answer: the leaves of one type, a String's apart from the rest, in answer order."""
struct LeafGroup
    tpath::String          # the leaves' type, type_path's
    on_string::Bool
    paths::Vector{Tuple}
    leaves::Vector{Any}    # native's values (the stand-ins once read back)
end

"""
    Answer

Native Julia's answer to a case, everything a later binding needs and nothing of a compile: the label its runs carry
(`label`, String arguments bound), the bound positions `P` and their Strings `S`, the wire arguments `args`, the
`native` value, the structural type paths of the argument types (`key`) and of a reader's (`rkey`, those and Int64),
and for an aggregate answer its leaf groups in the order the readers are compiled.
"""
struct Answer
    label::String
    P::Tuple
    S::Tuple
    args::Tuple
    native::Any
    key::String
    rkey::String
    aggregate::Bool
    groups::Vector{LeafGroup}
end
_key(argtypes) = join(map(type_path, argtypes), " ; ")

"""
    answer_of(label, f, args; world) -> Answer

The one code that calls a case's function natively (native_answer, once, at `world`, the case's own: the world just
after its unit loaded), and reads its answer's leaves where it is called (test/smoke.jl calls it at the judge's world,
before the corpus): by structure alone (a tuple's fields, a vector's elements and length, a String's code units, each
by `isa` and Base's own methods on Base's types, a type by its fields), so no method the corpus defines (a `show`, a
`hash`, an `iterate` of its own type) runs as the answer is read.
"""
function answer_of(label::String, f, args::Tuple; world::UInt = Base.get_world_counter())::Answer
    local label′, f′, args′ = _bound(label, f, args)
    local P = _string_positions(args)
    local S = Tuple(Symbol(args[i]) for i in P)
    local native = native_answer(f′, args′, world)
    local argtypes = Tuple(map(typeof, args′))
    local key, rkey = _key(argtypes), _key((argtypes..., Int64))
    _aggregate(native) || return Answer(label′, P, S, args′, native, key, rkey, false, LeafGroup[])
    local paths = _leaves(native)
    local leaf(p) = foldl(_step, p; init = native)
    local groups = LeafGroup[]
    for (T, on_string) in unique(map(p -> (typeof(leaf(p)), _on_string(p)), paths))
        local ps = filter(p -> typeof(leaf(p)) === T && _on_string(p) == on_string, paths)
        push!(groups, LeafGroup(type_path(T), on_string, ps, Any[leaf(p) for p in ps]))
    end
    return Answer(label′, P, S, args′, native, key, rkey, true, groups)
end

# a path as one field: its steps joined by ',' (i<k> a field, x<k> an element, c<k> a codeunit, len, ncu), `-` for none
_path_code(p::Tuple) = isempty(p) ? "-" : join((s isa Int ? "i$s" : s isa Symbol ? String(s) : (s[1] === :ix ? "x" : "c") * string(s[2]) for s in p), ',')
_opt(xs) = isempty(xs) ? "-" : join(xs, ';')

"""
    answer_lines(case, a) -> Vector{String}

An Answer as records, each naming the case: `answer <case> <label> <P> <S> <args> <native> <key> <rkey> <ngroups>` (ngroups
`-` for a scalar answer), then each group `group <case> <type path> <on_string> <nleaves>` and its leaves `leaf <case>
<path> <value>`. Texts in base64, values as _capture writes them; test/oracle_read.jl's read_answers reads them back.
"""
function answer_lines(case::String, a::Answer)::Vector{String}
    local out = [join(["answer", case, _b64(a.label), _opt(string.(a.P)), _opt(_b64.(String.(a.S))), _opt(_capture.(a.args)),
                       _capture(a.native), _b64(a.key), _b64(a.rkey), a.aggregate ? string(length(a.groups)) : "-"], '\t')]
    for g in a.groups
        push!(out, join(["group", case, _b64(g.tpath), g.on_string ? "1" : "0", string(length(g.paths))], '\t'))
        for (p, v) in zip(g.paths, g.leaves)
            push!(out, join(["leaf", case, _path_code(p), _capture(v)], '\t'))
        end
    end
    return out
end

end # module WTOracle
