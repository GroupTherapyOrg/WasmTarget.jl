# The closed world's classes (dev/MARCH.md 1.C): every type a value of the program can have, in the
# order the program first meets it, with every type on its supertype chain. dart numbers the classes
# of its component, each library's classes in order (class_info.dart:864, `for (final library in
# translator.component.libraries) for (final cls in library.classes)`); a Julia program is the
# closed world Julia inferred, read once as the NIR, so its classes are the types the NIR carries.
# Julia answers every edge (ledger D3): a class's parent is its `supertype`, never re-derived.

# Julia's kinds, the concrete types of a type as a value: Base.iskindtype's four
@quarantine "a type is a value in Julia, its class one of Julia's kinds" Core.DataType const _KINDS = (DataType, UnionAll, Union, Core.TypeofBottom)

"""
    closed_world_classes(world, at) -> Vector{DataType}

The classes of the closed world `world`, its NIR, in the order its walk first meets them: each body in
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
@quarantine "a Julia program declares no class list; its classes are the types Julia inferred for its values" Base.unwrap_unionall function closed_world_classes(world::NirWorld, at::String)::Vector{DataType}
    local out = DataType[]
    local seen = Base.IdSet{DataType}()
    for b in world
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
# `cls.superclass`, `cls.isAbstract`, `cls.implementedTypes`. Julia has single inheritance and no
# interfaces or mixins: a class's supertype chain is its superclasses, none is an anonymous mixin,
# and what dart's interfaces give, a subtype off the superclass tree, is Julia's covariant Tuple.

"""
    class_superclass(c) -> Union{DataType,Nothing}

dart's `cls.superclass`: Julia's `supertype`, `nothing` for `Any`, the root (Julia's own
`supertype(Any)` is `Any`).
"""
@quarantine "a class's parent is Julia's supertype; Any, the root, has none" Base.supertype class_superclass(c::DataType)::Union{DataType,Nothing} = c === Any ? nothing : supertype(c)

"""
    class_is_abstract(c) -> Bool

dart's `cls.isAbstract`, a class no value has exactly: Julia's `!isconcretetype` (an abstract type,
or a covariant Tuple such as `Tuple{Any}`).
"""
@quarantine "a class is abstract when no value has it exactly: Julia's isconcretetype" Base.isconcretetype class_is_abstract(c::DataType)::Bool = !isconcretetype(c)

"""
    class_implemented_types(c, classes) -> Vector{DataType}

dart's `cls.implementedTypes`, the classes `c` is a subtype of off its superclass chain, among
`classes` (the closed world's), Julia's `<:` answering each: for a concrete class, every class of
`classes` it is a subtype of that is not on its supertype chain (`Tuple{Int64}` implements
`Tuple{Any}`; `Core.TypeofBottom` implements the open `Type{T}` that `DataType`'s chain holds). A
class that is not concrete implements none: each concrete subtype of a class off the tree is that
class's implementor itself, so a class's ranges (getConcreteClassIdRange) hold every concrete class
Julia's `<:` says is its subtype.
"""
@quarantine "a class's subtypes off its supertype chain are Julia's <:, its covariant Tuples" Base.supertype function class_implemented_types(c::DataType, classes::Vector{DataType})::Vector{DataType}
    isconcretetype(c) || return DataType[]
    local chain = Base.IdSet{DataType}()
    local s = c
    while s !== Any
        s = supertype(s)
        push!(chain, s)
    end
    return DataType[t for t in classes if t !== c && !(t in chain) && c <: t]
end

"""
    ClassField

dart's Kernel `Field`, an instance field of a class: Julia's field `index` (from 1) of the concrete
class `cls`, its `name`, its declared `type` and whether it is `mutable` (a mutable struct's field
not declared `const`); for a primitive class, index 0, its one `value`, the class itself.
"""
@quarantine "Julia's fields are a struct's fieldnames and fieldtypes, its primitive types a value with no field" Core.Type struct ClassField
    cls::DataType
    index::Int
    name::String
    type::Type
    mutable::Bool
end

"""
    class_instance_fields(c, at) -> Vector{ClassField}

dart's `cls.fields.where((f) => f.isInstanceMember)`, a class's own instance fields, Julia's answers:
an abstract class has none (Julia's abstract types have no fields, so every field is a concrete
class's own); a primitive class (`Int64`, `Bool`, `Float64`, ...) has its one `value`, as dart's
boxed classes do (`_BoxedInt.value`); a struct has its `fieldnames` and `fieldtypes`; a singleton
none; a kind (a type as a value) dart's runtime type layout (`_kind_instance_fields`). A class whose
data Julia holds outside its fields (`String`, `Symbol`, `Core.SimpleVector`) rejects, located,
until its representation is written.
"""
@quarantine "a class's fields are Julia's fieldnames, fieldtypes and isconst; a primitive type holds one value" Base.isconst function class_instance_fields(c::DataType, at::String)::Vector{ClassField}
    class_is_abstract(c) && return ClassField[]
    isprimitivetype(c) && return ClassField[ClassField(c, 0, "value", c, false)]
    Base.iskindtype(c) && return _kind_instance_fields(c, at)
    if fieldcount(c) == 0
        Base.issingletontype(c) && return ClassField[]
        reject!(Unquarantined("src/julia/classes.jl class_instance_fields: $c, whose data Julia holds outside its fields"), at)
    end
    return ClassField[ClassField(c, i, string(fieldname(c, i)), fieldtype(c, i), ismutabletype(c) && !isconst(c, i)) for i in 1:fieldcount(c)]
end

"""
    _kind_instance_fields(c, at) -> Vector{ClassField}

The fields of a kind's instance, a type as a value: dart's runtime type objects (`_Type` and its
subclasses, sdk/lib/_internal/wasm/lib/type.dart), whose fields class_info.dart's FieldIndex names.
Each kind first holds dart's `_Type.isDeclaredNullable` (FieldIndex.typeIsDeclaredNullable), which is
Julia's `Nothing <: T`: `Nothing` is dart's Null and `Any` dart's `Object?`, both nullable. A
`DataType` is dart's `_InterfaceType`: `classId` (FieldIndex.interfaceTypeClassId) is the id of the
class the type denotes. dart's `typeArguments` has no field here, because a Julia class is an instance
with its parameters bound, so its id already fixes them. `Union` and `UnionAll` have no dart
counterpart and keep Julia's own fields (`a`, `b`; `var`, `body`), each a value of any class.
`Union{}`'s kind, `Core.TypeofBottom`, is dart's `_BottomType` and holds nothing more. The two fields
that are not Julia's take index 0, like a primitive class's `value`.

precedent(dart: the runtime type classes of sdk/lib/_internal/wasm/lib/type.dart, laid out by
class_info.dart like any class). Julia's differs: its kinds are runtime classes whose own fields
(`DataType.name`, `.parameters`, ...) are Julia's internals, so a type value takes dart's layout
where dart has one, and Julia's own fields where only Julia has the kind.
"""
@quarantine "a type is a value in Julia, its class a kind whose own fields are the runtime's internals" Core.TypeofBottom function _kind_instance_fields(c::DataType, at::String)::Vector{ClassField}
    local nullable = ClassField(c, 0, "isDeclaredNullable", Bool, false)
    c === DataType && return ClassField[nullable, ClassField(c, 0, "classId", Int32, false)]
    c === Union && return ClassField[nullable, ClassField(c, 1, "a", Any, false), ClassField(c, 2, "b", Any, false)]
    c === UnionAll && return ClassField[nullable, ClassField(c, 1, "var", Any, false), ClassField(c, 2, "body", Any, false)]
    c === Core.TypeofBottom && return ClassField[nullable]
    reject!(Internal("src/julia/classes.jl _kind_instance_fields: $c, no kind of Julia's"), at)
end
