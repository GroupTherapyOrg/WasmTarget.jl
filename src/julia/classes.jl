# The closed world's classes (dev/MARCH.md 1.C): every type a value of the program can have, in the
# order the program first meets it, with every type on its supertype chain. dart numbers the classes
# of its component, each library's classes in order (class_info.dart:864, `for (final library in
# translator.component.libraries) for (final cls in library.classes)`); a Julia program is the
# closed world Julia inferred, read once as the NIR, so its classes are the types the NIR carries.
# Julia answers every edge (ledger D3): a class's parent is its `supertype`, never re-derived.

# Julia's kinds, the concrete types of a type as a value, read from Base.iskindtype over Core's
# bindings (src/julia/construction.jl, core_kinds), never a copy of its list (D3, D5)
@quarantine "a type is a value in Julia, its class one of Julia's kinds, which Base.iskindtype names" Core.DataType const _KINDS = core_kinds()::Tuple{Vararg{DataType}}

"""
    closed_world_classes(world, at) -> Vector{DataType}

The classes of the closed world `world`, its NIR, in the order its walk first meets them: each body in
order, its argument types (its MethodInstance's signature), then each statement's type, then the
type of each literal and constant binding its statements read (nir_value_type: the value's own
type, which no statement's type need hold: `"hello"` compared, a `const` Ref read), then its return
type. A type meets the walk by Julia's own inferred form: a `Union` by its members, a
`Vararg` by its element, a type as a value (`Type{X}`, or a `UnionAll` under `Type`) by its kind
(`typeof(X)`, or every kind when `X` is not known) and by the classes `X` denotes (`X` itself, or each
member of a Union, that is a DataType with no free type variable), whose ids a type value's layout
holds; any other `UnionAll` rejects, located. A class
met brings its supertype chain to `Any`, the root, and a concrete class that is not a kind brings
its field types, each met as a value's type. `Union{}`, the type of no value, brings nothing.

precedent(dart: a component's classes, the libraries' classes in order, class_info.dart:864).
Julia's differs: a program declares no class list, so the list is the types Julia inferred for its
values, each met once, and a parametric instance (`Vector{Int64}`) is a class of its own, as Julia's
`supertype` gives it.

formal(dev/formal/ValueClasses.tla): every class a value can have listed once, closed under supertype and fields, nothing extra
"""
@quarantine "a Julia program declares no class list; its classes are the types Julia inferred for its values" Base.unwrap_unionall function closed_world_classes(world::NirWorld, at::String)::Vector{DataType}
    local out = DataType[]
    local seen = Base.IdSet{DataType}()
    for b in world
        foreach(t -> _meet_value!(out, seen, t, at), Base.unwrap_unionall(b.ci.def.specTypes).parameters)
        foreach(t -> _meet_value!(out, seen, t, at), b.types)
        for st in b.stmts, v in nir_value_operands(st)
            v isa Union{NirConst,NirGlobal} && _meet_value!(out, seen, nir_value_type(b, v), at)
        end
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
        if x isa TypeVar
            foreach(k -> _meet_class!(out, seen, k, at), _KINDS)
        else
            _meet_class!(out, seen, typeof(x), at)
            # the classes the type value denotes, so its layout's classId has one (the kinds' fields,
            # below): a DataType with no free type variable, or each such member of a Union
            for d in (x isa Union ? Base.uniontypes(x) : Any[x])
                d isa DataType && !Base.has_free_typevars(d) && _meet_class!(out, seen, d, at)
            end
        end
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
    if Base.iskindtype(t)
        # a kind's instance takes dart's runtime type layout, its fields' classes met as Julia's are
        foreach(f -> _meet_value!(out, seen, f.type, at), _kind_instance_fields(t, at))
    elseif isconcretetype(t)
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
none; a kind (a type as a value) dart's runtime type layout (`_kind_instance_fields`); a
`Core.SimpleVector` its elements as one immutable wasm array (`_svec_instance_fields`); a `String`
its UTF-8 code units as one immutable i8 wasm array (`_string_instance_fields`). Any other class
whose data Julia holds outside its fields (`Symbol`) rejects, located, until its representation is
written.
"""
@quarantine "a class's fields are Julia's fieldnames, fieldtypes and isconst; a primitive type holds one value" Base.isconst function class_instance_fields(c::DataType, at::String)::Vector{ClassField}
    class_is_abstract(c) && return ClassField[]
    isprimitivetype(c) && return ClassField[ClassField(c, 0, "value", c, false)]
    Base.iskindtype(c) && return _kind_instance_fields(c, at)
    if fieldcount(c) == 0
        Base.issingletontype(c) && return ClassField[]
        c === Core.SimpleVector && return _svec_instance_fields(c, at)
        c === String && return _string_instance_fields(c, at)
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
class the type denotes, and dart's `typeArguments` (FieldIndex.interfaceTypeTypeArguments,
sdk/lib/_internal/wasm/common/type.dart:277 `final WasmArray<_Type> typeArguments;`) is Julia's own
field `parameters`, at Julia's own index and of Julia's declared type (`Core.SimpleVector`), read
from `Base.fieldindex` and `fieldtype`, so `T.parameters` reads it. `Union` and `UnionAll` have no dart
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
    c === DataType && return ClassField[nullable, ClassField(c, 0, "classId", Int32, false),
        ClassField(c, Base.fieldindex(c, :parameters), "parameters", fieldtype(c, :parameters), false)]
    c === Union && return ClassField[nullable, ClassField(c, 1, "a", Any, false), ClassField(c, 2, "b", Any, false)]
    c === UnionAll && return ClassField[nullable, ClassField(c, 1, "var", Any, false), ClassField(c, 2, "body", Any, false)]
    c === Core.TypeofBottom && return ClassField[nullable]
    reject!(Internal("src/julia/classes.jl _kind_instance_fields: $c, no kind of Julia's"), at)
end

"""
    _svec_instance_fields(c, at) -> Vector{ClassField}

The fields of a `Core.SimpleVector`, whose data Julia holds outside its fields: one field, `data`,
of type `ImmutableWasmArray{eltype(c)}` (src/julia/wasm_array.jl), the elements as one immutable
wasm array of references. The ruling, from its two sources:

- Julia's layout (julia.h:155, `jl_svec_t`): "A SimpleVector is an immutable pointer array", its
  `length` then its `jl_value_t *data[]`. So the elements are references to values of any class
  (`eltype(Core.SimpleVector)`, read here: `Any`), as many as its length, and immutable: Core binds
  `svec`, `_svec_len` and `_svec_ref` over it and nothing that writes an element. The wasm array
  carries its own length (`array.len`, what `Core._svec_len` reads), as `jl_svec_t.length` counts
  its data.
- dart's representation of a list of types (sdk/lib/_internal/wasm/common/type.dart:277,
  `final WasmArray<_Type> typeArguments;`): a wasm array of references to the element type's class,
  `arrayTypeForDartType` of it (translator.dart:1205); an immutable one is
  `ImmutableWasmArray<T>` (sdk/lib/_wasm/wasm_types.dart:814), translated with `mutable: false`
  (translator.dart:1094).

A SimpleVector is also a Julia object (it flows into `Any`, `typeof` answers its class), so the
array sits in a field of its class's struct, below the object header, where dart's typeArguments
sits in its `_InterfaceType`. The field is not one of Julia's (a SimpleVector has none), so it
takes index 0, like a primitive class's `value`.

precedent(dart: `_InterfaceType.typeArguments`, a WasmArray<_Type> field; rust: `Box<[T]>`, a
length-carrying slice behind a pointer). Julia's differs: its SimpleVector stores the elements
inline after the length, where wasm's array is an object of its own the struct references.
"""
@quarantine "a SimpleVector's data lies outside its fields: Julia's jl_svec_t, an immutable pointer array" Core.SimpleVector function _svec_instance_fields(c::DataType, at::String)::Vector{ClassField}
    c === Core.SimpleVector || reject!(Internal("src/julia/classes.jl _svec_instance_fields: $c, no SimpleVector"), at)
    return ClassField[ClassField(c, 0, "data", ImmutableWasmArray{eltype(c)}, false)]
end

"""
    _string_instance_fields(c, at) -> Vector{ClassField}

The fields of a `String`, whose data Julia holds outside its fields: one field, `_data`, of type
`WasmArray{WasmI8}` (src/julia/wasm_array.jl), the string's UTF-8 code units as one i8 wasm array,
the field immutable and the array's elements writable, as Julia's runtime fills a fresh String
(`jl_alloc_string`, then Base's `_string` copies the bytes in) and dart2wasm's earlier OneByteString's
`WasmArray<WasmI8>` was; a String is immutable once made, by Julia's convention. The ruling (Dale's choice B, 2026-10-29), from its sources:

- Julia's layout (julia.h, `jl_string_len` and `jl_string_data`): a String is its length in bytes
  followed by its UTF-8 code units, immutable; `ncodeunits`, `codeunit`, `sizeof` and iteration
  index those bytes, and `==` compares them. So the field holds exactly the code units, as many as
  `ncodeunits`, the wasm array's own length (`array.len`) counting them as `jl_string_len` does.
- dart's string class (sdk/lib/_internal/wasm/standalone/embedder_string.dart:32,
  `EmbedderStringImpl`): an object of its own class, the object header and then its data, built
  for a literal by translator.dart:2534 `pushStandaloneStringConstant`, which copies the literal's
  code units into the constants' passive data segment and makes a wasm array of them
  (`array.new_data`). At the pin dart's data is a host string reference; dart2wasm's earlier
  `OneByteString` held an i8 wasm array of its code units (the precedent; the pinned checkout is
  shallow, so no commit anchors it). The class shape and the literal path are dart's; the data is
  Julia's, the bytes, so no Julia string operation is a host call. A host string is made only at
  the interop boundary.

Why Julia differs from dart's shape at the pin (a host string reference, `WasmExternRef? _ref`, whose
length and code units are host calls): every String operation in Julia's Base indexes the bytes
(`codeunit`, `ncodeunits`, `sizeof`, `nextind`, iteration, `==` through `memcmp`), so a host string
would make each a host call transcoding between Julia's UTF-8 and the host's UTF-16, a change of
behavior (indices and lengths count UTF-8 bytes in Julia, UTF-16 units in the host) and of
performance alike.

The field is not one of Julia's (a String has none), so it takes index 0, like a primitive class's
`value`.

precedent(dart: EmbedderStringImpl, the header and its data in a field; dart2wasm's earlier
OneByteString, an i8 wasm array of code units; rust: `String`, a UTF-8 byte buffer). Julia's differs:
its String stores the bytes inline after the length, where wasm's array is an object the struct
references.
"""
@quarantine "a String's data lies outside its fields (Julia's jl_string_len, jl_string_data), its UTF-8 bytes in place of dart's host externref, since Base indexes the bytes" Core.String function _string_instance_fields(c::DataType, at::String)::Vector{ClassField}
    c === String || reject!(Internal("src/julia/classes.jl _string_instance_fields: $c, no String"), at)
    return ClassField[ClassField(c, 0, "_data", WasmArray{WasmI8}, false)]
end
