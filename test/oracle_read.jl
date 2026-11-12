# The oracle's READ half, the decoder of the store's records (spec v14 V2): what test/oracle.jl writes, read back. A judge
# file (dev/climb/core.py JUDGE_READ): no move's rule admits it, the keeper's neither (G5), and it is outside the store's
# key, since no stored byte depends on it (an edit of it replays nothing). The verdict (test/verdict.jl) loads it by its
# owner, in a process that never loads test/runner.jl, the keeper's (spec v16 X1). It was test/runner.jl's under spec v13
# R7, where a keeper's move could change how a stored answer decodes (round12-architect 3), and before that
# test/oracle.jl's, inside the key.
#
# A type is found again from its path by lookups alone (resolve_type_path: getglobal and Core.apply_type, no parse, no
# eval, no show); a value is read back as the store holds it: the value itself where its type is found (Base's or
# Core's anywhere; the corpus's where the corpus is loaded), else a stand-in that reads, compares and prints as it did:
# a singleton's one instance (Named), a value no wire carries (Opaque), a thrown type (Named's type). The stand-ins
# print the type's own name, read from the path, never by show.
#
#   read_answers(lines; digests) -> Dict{String,Union{Answer,String}}
#   read_shapes(lines; digests) -> Dict{String,Union{Shape,String}}   what the compiling process is handed (spec v16 X1)
#   resolve_type_path(s; world) -> Type
module WTOracleRead

import Base64
using ..WTOracle: WTOracle, Answer, LeafGroup, Throws, _capture, type_path

_unb64(s) = String(Base64.base64decode(s))

function _unhex(T, hx::AbstractString)
    (T isa DataType && isprimitivetype(T)) || throw(TypePathError("holds bytes of $T, which is no primitive type"))
    local b = hx == "-" ? UInt8[] : hex2bytes(hx)
    length(b) == sizeof(T) || throw(TypePathError("holds $(length(b)) bytes of $T, whose size is $(sizeof(T))"))
    return reinterpret(T, b)[1]
end

struct TypePathError <: Exception
    text::String
end
Base.showerror(io::IO, e::TypePathError) = print(io, "the type path ", e.text)
# a root module by its name: Core, Base or Main, or a module loaded under that name whose parent is itself
function _root_module(n::Symbol)::Module
    n === :Core && return Core
    n === :Base && return Base
    n === :Main && return Main
    for m in Base.loaded_modules_array()
        nameof(m) === n && parentmodule(m) === m && return m
    end
    throw(TypePathError("names the module $n, which no loaded module is"))
end
# a binding read at `world`, by builtins alone: a corpus type is resolved where the case that names it lives (the world
# its unit loaded in, test/smoke.jl), never where the judge's code runs
_defined_at(world::UInt, m::Module, s::Symbol) = Base.invoke_in_world(world, isdefinedglobal, m, s)::Bool
_global_at(world::UInt, m::Module, s::Symbol) = Base.invoke_in_world(world, getglobal, m, s)
function _resolve!(toks::Vector{SubString{String}}, i::Ref{Int}, world::UInt)
    i[] > length(toks) && throw(TypePathError("ends in the middle of a type"))
    local k = toks[i[]]; i[] += 1
    if k == "S"
        return Symbol(_unb64(toks[(i[] += 1) - 1]))
    elseif k == "P"
        local n = parse(Int, toks[i[]]); i[] += 1
        return Tuple(_resolve!(toks, i, world) for _ in 1:n)
    elseif k == "B"
        local hx = toks[i[]]; i[] += 1
        return _unhex(_resolve!(toks, i, world), hx)
    elseif k == "T"
        local mods = Symbol.(_unb64.(split(toks[i[]], '.'))); local name = Symbol(_unb64(toks[i[]+1]))
        local n = parse(Int, toks[i[]+2]); i[] += 3
        local m = _root_module(mods[1])
        for s in mods[2:end]
            local sub = _defined_at(world, m, s) ? _global_at(world, m, s) : nothing
            sub isa Module || throw(TypePathError("names $s in $m, which is no module there"))
            m = sub
        end
        local params = Any[_resolve!(toks, i, world) for _ in 1:n]
        _defined_at(world, m, name) || throw(TypePathError("names $name in $m, which is not defined there"))
        local U = _global_at(world, m, name)
        (U isa DataType || U isa UnionAll) || throw(TypePathError("names $name in $m, which is no type there"))
        local T = n == 0 ? U : Core.apply_type(U, params...)
        # the type found is the one the path names: its own module and name (a binding of that name to another type,
        # a shadow, is refused) and its parameters
        (T isa DataType && fullname(T.name.module) == Tuple(mods) && T.name.name === name && length(T.parameters) == n &&
         all(j -> T.parameters[j] === params[j], 1:n)) ||
            throw(TypePathError("names $(join(mods, '.')).$name, and the lookup found another type"))
        return T
    else
        throw(TypePathError("holds $(repr(k)), a part no path names"))
    end
end
"""    resolve_type_path(s; world) -> Type

The type `s` (type_path's) names, found by lookups alone (getglobal, Core.apply_type) at `world` (the case's: where the
corpus type it names is bound): no parse, no eval, no show. A path that names no type, or names one a lookup does not
find as named, is a TypePathError."""
function resolve_type_path(s::AbstractString; world::UInt = Base.get_world_counter())
    local toks = split(s, ' ')
    local i = Ref(1)
    local T = _resolve!(toks, i, world)
    i[] == length(toks) + 1 || throw(TypePathError("holds more than one type"))
    T isa Type || throw(TypePathError("names a value, not a type"))
    return T
end

struct Named{S} end
mutable struct Opaque{S} end
Base.show(io::IO, ::Type{Named{S}}) where {S} = print(io, S)
Base.show(io::IO, ::Named{S}) where {S} = print(io, S)
Base.show(io::IO, ::Type{Opaque{S}}) where {S} = print(io, S)

# the name a type path's head names (its type's own name, for a stand-in), read from the tokens alone
_path_name(tp::AbstractString) = (t = split(tp, ' '); length(t) >= 3 && t[1] == "T" ? Symbol(_unb64(t[3])) : Symbol("?"))
function _restore(s::AbstractString)
    local f = split(s, ',')
    length(f) == 3 || error("a stored value of $(length(f)) fields")
    local k, tp, hx = f[1], _unb64(f[2]), f[3]
    local T = try
        resolve_type_path(tp)
    catch e
        e isa TypePathError || rethrow()
        nothing   # a type this process does not hold (the corpus's, where no corpus is loaded): a stand-in
    end
    local name = _path_name(tp)
    k == "throws" && return Throws(T === nothing ? Named{name} : T)
    k == "void" && return T isa DataType && Base.issingletontype(T) ? T.instance : Named{name}()
    k == "bits" && return T === nothing ? Opaque{name}() : _unhex(T, hx)
    k == "opaque" && return Opaque{name}()
    error("a stored value names no value kind $k")
end

function _path_read(s::AbstractString)::Tuple
    s == "-" && return ()
    return Tuple(begin
        t == "len" ? :len : t == "ncu" ? :ncu : t[1] == 'i' ? parse(Int, t[2:end]) :
        t[1] == 'x' ? (:ix, parse(Int, t[2:end])) : t[1] == 'c' ? (:cu, parse(Int, t[2:end])) : error("a stored path holds the step $t")
    end for t in split(s, ','))
end

"""
    read_answers(lines; digests) -> Dict{String,Union{Answer,String}}

The records answer_lines writes, read back: each case's Answer, its values the stand-ins _restore makes; a `noanswer
<case> <why>` record maps to its why. One wholeness rule, dev/climb/measure.py unit_blocks' (spec v14 V4: the two
readers give one verdict on every block of test/src/oracle_edge_blocks.tsv): a block is an `answer` record and then
exactly the `group` records its count names, each followed by exactly the `leaf` records its own count names, then at
most one `digest <case> <fields>` (a unit label's: its unit's load's digest, whose fields go to `digests`, {case =>
fields}, when it is given), or one `noanswer` record alone; any other record before the next `answer` or `noanswer` (a
count not met, a field that does not read, a record naming another case, a second digest, a record of the case after
its digest or its noanswer) breaks the block: the case maps to why, located. A case named by two blocks is refused for
both.
"""
function read_answers(lines; digests = nothing)
    local out = Dict{String,Union{Answer,String}}()
    local twice = Set{String}()
    # the open block: its case, its Answer (nothing for a noanswer), the groups still due, the open group and its leaves
    # due, whether its digest was read, and its digest's fields
    local cur, a, need, g, gdue, digested, dfields = nothing, nothing, 0, nothing, 0, false, nothing
    local whole() = a === nothing || (need == 0 && gdue == 0)
    local close!() = begin
        if cur !== nothing && out[cur] isa Answer && !whole()
            out[cur] = "its answer's records are not whole"
        elseif cur !== nothing && out[cur] isa Answer && digests !== nothing && dfields !== nothing
            digests[cur] = dfields
        end
        cur, a, need, g, gdue, digested, dfields = nothing, nothing, 0, nothing, 0, false, nothing
    end
    local broken!(why) = begin
        cur === nothing || (out[cur] = why)
        cur, a, dfields = nothing, nothing, nothing
    end
    for ln in lines
        isempty(ln) && continue
        local f = split(ln, '\t')
        local k = f[1]
        if k == "answer" || k == "noanswer"
            close!()
            local case = length(f) >= 2 ? String(f[2]) : ""
            haskey(out, case) && push!(twice, case)
            cur = case
            if k == "noanswer"
                out[case] = length(f) >= 3 ? "no native answer: " * _unb64(f[3]) : "no native answer"
                continue
            end
            out[case] = "its answer's records are not whole"
            try
                length(f) == 10 || error("an answer record of $(length(f)) fields")
                (f[10] == "-" || all(isdigit, f[10])) || error("an answer record whose group count is $(f[10])")
                local P = f[4] == "-" ? () : Tuple(parse.(Int, split(f[4], ';')))
                local S = f[5] == "-" ? () : Tuple(Symbol.(_unb64.(split(f[5], ';'))))
                local args = f[6] == "-" ? () : Tuple(_restore.(split(f[6], ';')))
                a = Answer(_unb64(f[3]), P, S, args, _restore(f[7]), _unb64(f[8]), _unb64(f[9]), f[10] != "-", LeafGroup[])
                need = f[10] == "-" ? 0 : parse(Int, f[10])
                out[case] = a
            catch e
                broken!("its answer record does not read: " * sprint(showerror, e))
            end
        elseif cur === nothing
            continue   # a record outside any block, after a block it broke: its case is refused already
        elseif length(f) < 2 || f[2] != cur || a === nothing || digested
            broken!(a === nothing && length(f) >= 2 && f[2] == cur ? "a record after its noanswer: $(first(ln, 120))" :
                    digested && length(f) >= 2 && f[2] == cur ? "a record after its digest: $(first(ln, 120))" :
                    "a record inside its answer's block is not its own: $(first(ln, 120))")
        elseif k == "group" && length(f) == 5 && need > 0 && gdue == 0 && all(isdigit, f[5])
            g = LeafGroup(_unb64(f[3]), f[4] == "1", Tuple[], Any[]); gdue = parse(Int, f[5])
            push!(a.groups, g); need -= 1
        elseif k == "leaf" && length(f) == 4 && g !== nothing && gdue > 0
            try
                local p, v = _path_read(f[3]), _restore(f[4])
                push!(g.paths, p); push!(g.leaves, v); gdue -= 1
            catch e
                broken!("its leaf record does not read: " * sprint(showerror, e))
            end
        elseif k == "digest" && length(f) == 5 && need == 0 && gdue == 0
            digested, dfields = true, String.(f[3:5])
        else
            broken!("its answer's records are not whole: $(first(ln, 120))")
        end
    end
    close!()
    for case in twice
        out[case] = "the answers name it more than once"
    end
    return out
end

# ---- an answer's SHAPE (spec v16 X1): what the compiling process, which runs the measured src, is handed of a stored
# answer, and nothing else: the bound label, the bound String positions and their Strings (the corpus's own text), the
# count of wire arguments, the argument types' paths (`key`, `rkey`), whether the answer is read by readers, and each
# leaf group's type path, whether it reads a String and its leaves' paths. Never a native value, a leaf's value or an
# argument's value: those stay in the store, which the verdict alone reads (test/verdict.jl). The driver writes it from
# the store (dev/climb/measure.py shape_records, a projection of whole blocks); an answer read here projects to the same
# (Shape(a)). Records, tab-separated, texts in base64:
#   shape <case> <label> <P> <S> <nargs> <key> <rkey> <ngroups or -> <native: throws,<type path> | void,<type path> | ->
#                                    (spec v17 Y2: a scalar answer that is a type, a thrown exception's or a singleton's,
#                                    names that type, which its judge-built reader reads; any other answer `-`)
#   sgroup <case> <type path> <kind> <on_string> <npaths> <path codes, ;-joined>   (kind: the leaves' capture kind,
#                                    void, bits or opaque, test/oracle.jl's _capture: a kind, never a value)
#   digest <case> <fields...>        (a unit label's, as in the store)
#   noanswer <case>                  (the store holds no answer; its why is the driver's to book)
"""One leaf group of an answer's shape: its leaves' type path and capture kind, whether they read a String, their paths."""
struct ShapeGroup
    tpath::String
    kind::Symbol
    on_string::Bool
    paths::Vector{Tuple}
end
"""An answer's shape (spec v16 X1): an Answer without one value in it."""
struct Shape
    label::String
    P::Tuple
    S::Tuple
    nargs::Int
    key::String
    rkey::String
    aggregate::Bool
    groups::Vector{ShapeGroup}
    native_kind::Symbol      # :throws, :void (a scalar answer that is a type: spec v17 Y2) or :none
    native_tpath::String     # that type's path ("" for :none, or for a type this process does not hold)
end
Shape(label, P, S, nargs, key, rkey, aggregate, groups) = Shape(label, P, S, nargs, key, rkey, aggregate, groups, :none, "")
# a read answer's shape: each group's kind is its first leaf's as the capture names it (test/oracle.jl's _capture, the one
# rule), read off the value as stored (a stand-in's: a corpus singleton's Named is void, a value of a type this process
# does not hold is opaque, where the store wrote bits: neither has a leaf kind, test/verdict.jl's leaf_kind)
_capture_kind(x) = Symbol(first(split(_capture(x), ',')))
Shape(a::Answer) = Shape(a.label, a.P, a.S, length(a.args), a.key, a.rkey, a.aggregate,
                         ShapeGroup[ShapeGroup(g.tpath, _capture_kind(first(g.leaves)), g.on_string, g.paths) for g in a.groups],
                         _native_shape(a)...)
# a scalar answer's type where the answer is a type (spec v17 Y2): a thrown exception's, or a singleton's (its kind as
# the capture names it, test/oracle.jl's _capture: the one rule); a stand-in's type has no path this process can give
_tpath_of(T) = T isa Type && !(T <: Named) && !(T <: Opaque) ? type_path(T) : ""
function _native_shape(a::Answer)
    a.aggregate && return (:none, "")
    local x = a.native
    x isa Throws && return (:throws, _tpath_of(x.type))
    _capture_kind(x) === :void && return (:void, _tpath_of(typeof(x)))
    return (:none, "")
end

"""
    read_shapes(lines; digests) -> Dict{String,Union{Shape,String}}

The shape records (above), read back: each case's Shape, or why it has none (`noanswer`, or a block that does not read:
a count not met, a record of another case or kind inside it, a field that does not parse). A case named twice is refused
for both. `digests`, when given, receives each case's digest fields ({case => fields}), as read_answers does.
"""
function read_shapes(lines; digests = nothing)
    local out = Dict{String,Union{Shape,String}}()
    local twice = Set{String}()
    local cur, s, need, dfields = nothing, nothing, 0, nothing
    local close!() = begin
        cur !== nothing && s !== nothing && need != 0 && (out[cur] = "its shape's records are not whole")
        cur !== nothing && out[cur] isa Shape && digests !== nothing && dfields !== nothing && (digests[cur] = dfields)
        cur, s, need, dfields = nothing, nothing, 0, nothing
    end
    local broken!(why) = begin
        cur === nothing || (out[cur] = why)
        cur, s, dfields = nothing, nothing, nothing
    end
    for ln in lines
        isempty(ln) && continue
        local f = split(ln, '\t')
        local k = f[1]
        if k == "shape" || k == "noanswer"
            close!()
            local case = length(f) >= 2 ? String(f[2]) : ""
            haskey(out, case) && push!(twice, case)
            cur = case
            if k == "noanswer"
                out[case] = "no native answer"
                continue
            end
            try
                length(f) == 10 || error("a shape record of $(length(f)) fields")
                (f[9] == "-" || all(isdigit, f[9])) && all(isdigit, f[6]) || error("a shape record whose counts are $(f[6]), $(f[9])")
                local P = f[4] == "-" ? () : Tuple(parse.(Int, split(f[4], ';')))
                local S = f[5] == "-" ? () : Tuple(Symbol.(_unb64.(split(f[5], ';'))))
                local nk = f[10] == "-" ? (:none, "") : (g = split(f[10], ','); length(g) == 2 && g[1] in ("throws", "void") ?
                    (Symbol(g[1]), _unb64(g[2])) : error("a shape record's native $(repr(f[10])) is no type's"))
                f[9] != "-" && nk[1] !== :none && error("an aggregate's shape names a native type")
                s = Shape(_unb64(f[3]), P, S, parse(Int, f[6]), _unb64(f[7]), _unb64(f[8]), f[9] != "-", ShapeGroup[], nk...)
                need = f[9] == "-" ? 0 : parse(Int, f[9])
                out[case] = s
            catch e
                out[case] = "its shape record does not read"
                broken!("its shape record does not read: " * sprint(showerror, e))
            end
        elseif cur === nothing
            continue
        elseif length(f) < 2 || f[2] != cur || s === nothing || dfields !== nothing
            broken!("its shape's records are not whole: $(first(ln, 120))")
        elseif k == "sgroup" && length(f) == 7 && need > 0 && all(isdigit, f[6]) && f[4] in ("void", "bits", "opaque")
            try
                local paths = Tuple[_path_read(p) for p in split(f[7], ';')]
                length(paths) == parse(Int, f[6]) || error("$(length(paths)) paths where its count is $(f[6])")
                push!(s.groups, ShapeGroup(_unb64(f[3]), Symbol(f[4]), f[5] == "1", paths)); need -= 1
            catch e
                broken!("its group record does not read: " * sprint(showerror, e))
            end
        elseif k == "digest" && length(f) == 5 && need == 0
            dfields = String.(f[3:5])
        else
            broken!("its shape's records are not whole: $(first(ln, 120))")
        end
    end
    close!()
    for case in twice
        out[case] = "the shapes name it more than once"
    end
    return out
end

end # module WTOracleRead
