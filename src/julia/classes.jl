# The closed world's classes (dev/MARCH.md 1.C): every type a value of the program can have, in the
# order the program first meets it, with every type on its supertype chain. dart numbers the classes
# of its component, each library's classes in order (class_info.dart:864, `for (final library in
# translator.component.libraries) for (final cls in library.classes)`); a Julia program is the
# closed world Julia inferred, read once as the NIR, so its classes are the types the NIR carries.
# Julia answers every edge (ledger D3): a class's parent is its `supertype`, never re-derived.

# Julia's kinds, the concrete types of a type as a value: Base.iskindtype's four
@quarantine "a type is a value in Julia, its class one of Julia's kinds" Core.DataType const _KINDS = (DataType, UnionAll, Union, Core.TypeofBottom)

"""
    closed_world_classes(bodies, at) -> Vector{DataType}

The classes of the closed world `bodies`, in the order its walk first meets them: each body in
order, its argument types (its MethodInstance's signature), then each statement's type, then its
return type. A type meets the walk by Julia's own inferred form: a `Union` by its members, a
`Vararg` by its element, a type as a value (`Type{X}`, or a `UnionAll` under `Type`) by its kind
(`typeof(X)`, or every kind when `X` is not known); any other `UnionAll` rejects, located. A class
met brings its supertype chain to `Any`, the root, and a concrete class that is not a kind brings
its field types, each met as a value's type. `Union{}`, the type of no value, brings nothing.

precedent(dart: a component's classes, the libraries' classes in order, class_info.dart:864).
Julia's differs: a program declares no class list, so the list is the types Julia inferred for its
values, each met once, and a parametric instance (`Vector{Int64}`) is a class of its own, as Julia's
`supertype` gives it.
"""
@quarantine "a Julia program declares no class list; its classes are the types Julia inferred for its values" Base.unwrap_unionall function closed_world_classes(bodies::Vector{NirBody}, at::String)::Vector{DataType}
    local out = DataType[]
    local seen = Base.IdSet{DataType}()
    for b in bodies
        foreach(t -> _meet_value!(out, seen, t, at), Base.unwrap_unionall(b.ci.def.specTypes).parameters)
        foreach(t -> _meet_value!(out, seen, t, at), b.types)
        _meet_value!(out, seen, b.ci.rettype, at)
    end
    return out
end

# a value's type met by the walk, by Julia's inferred form
@quarantine "a value's type is Julia's inferred form: a DataType, a Union of them, a Vararg's element, or a type as a value" Base.isType function _meet_value!(out::Vector{DataType}, seen::Base.IdSet{DataType}, @nospecialize(t), at::String)::Nothing
    t === Union{} && return nothing
    if t isa Union
        foreach(u -> _meet_value!(out, seen, u, at), Base.uniontypes(t))
    elseif t isa Core.TypeofVararg
        _meet_value!(out, seen, isdefined(t, :T) ? t.T : Any, at)
    elseif t isa UnionAll
        t <: Type || reject!(Unquarantined("src/julia/classes.jl: a value of the UnionAll type $t, whose class Julia's inference left open"), at)
        foreach(k -> _meet_class!(out, seen, k, at), _KINDS)
    elseif t isa DataType && Base.isType(t)
        local x = t.parameters[1]
        x isa TypeVar ? foreach(k -> _meet_class!(out, seen, k, at), _KINDS) : _meet_class!(out, seen, typeof(x), at)
    elseif t isa DataType
        _meet_class!(out, seen, t, at)
    else
        reject!(Internal("src/julia/classes.jl: a value's type $t, a $(typeof(t)), no form of Julia's inferred types"), at)
    end
    return nothing
end

# a class met by the walk: itself, its supertype chain, and a concrete non-kind class's field types
@quarantine "a class's parent is Julia's supertype and its fields Julia's fieldtypes" Base.fieldtypes function _meet_class!(out::Vector{DataType}, seen::Base.IdSet{DataType}, t::DataType, at::String)::Nothing
    t in seen && return nothing
    push!(seen, t)
    push!(out, t)
    _meet_class!(out, seen, supertype(t), at)   # Any's supertype is Any, already met
    if isconcretetype(t) && !Base.iskindtype(t)
        foreach(f -> _meet_value!(out, seen, f, at), fieldtypes(t))
    end
    return nothing
end

# A class's place in the hierarchy, Julia's answers (ledger D3) where dart reads a Kernel Class:
# `cls.superclass`, `cls.isAbstract`. Julia has single inheritance and no interfaces or mixins, so a
# class implements nothing (`cls.implementedTypes` is empty) and none is an anonymous mixin.

"""
    class_superclass(c) -> Union{DataType,Nothing}

dart's `cls.superclass`: Julia's `supertype`, `nothing` for `Any`, the root (Julia's own
`supertype(Any)` is `Any`).
"""
@quarantine "a class's parent is Julia's supertype; Any, the root, has none" Base.supertype class_superclass(c::DataType)::Union{DataType,Nothing} = c === Any ? nothing : supertype(c)

"""
    class_is_abstract(c, at) -> Bool

dart's `cls.isAbstract`, a class no value has exactly: Julia's `!isconcretetype`. A class neither
concrete nor abstract (`isabstracttype`) is a covariant Tuple (`Tuple{Any}`, `Tuple{Vararg{Int}}`):
its subtypes (`Tuple{Int}`) are not under it in the supertype tree, so no subtree range holds them,
and it rejects, located, until the classes implement it (dart's `implementedTypes`).
"""
@quarantine "a class is abstract when no value has it exactly: Julia's isconcretetype; a covariant Tuple is neither" Base.isconcretetype function class_is_abstract(c::DataType, at::String)::Bool
    isconcretetype(c) && return false
    isabstracttype(c) && return true
    reject!(Unquarantined("src/julia/classes.jl class_is_abstract: the covariant Tuple class $c, whose subtypes Julia's supertype tree does not hold"), at)
end
