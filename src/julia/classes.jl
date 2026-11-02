# The closed world's classes (dev/MARCH.md 1.C): every type a value of the program can have, in the
# order the program first meets it, with every type on its supertype chain. dart numbers the classes
# of its component, each library's classes in order (class_info.dart:864, `for (final library in
# translator.component.libraries) for (final cls in library.classes)`); a Julia program is the
# closed world Julia inferred, read once as the NIR, so its classes are the types the NIR carries.
# Julia answers every edge (ledger D3): a class's parent is its `supertype`, never re-derived.

# Julia's kinds, the concrete types of a type as a value, read from Base.iskindtype over Core's
# bindings (src/julia/construction.jl, core_kinds), never a copy of its list (D3, D5)
@quarantine "a type is a value in Julia, its class one of Julia's kinds, which Base.iskindtype names" Core.DataType const _KINDS = core_kinds()::Tuple{Vararg{DataType}}

# Whether a value's class tells whether it is of the type `T`: each kind wholly in `T` or wholly out of
# it. Julia's isa tests a type value against a type that splits its kind (Type{Int} holds Int and no
# other DataType) by the value itself, any other value by its class (julia/src/subtype.c:2511 jl_isa:
# `jl_is_type_type(t)`, then `jl_subtype(jl_typeof(x), t)`)
@quarantine "julia/src/subtype.c:2511 jl_isa tests a type value by itself where the type splits its kind, any other value by its class (jl_typeof)" Base.typeintersect told_by_class(@nospecialize(T::Type))::Bool =
    all(k -> k <: T || typeintersect(k, T) === Union{}, _KINDS)

"""
    type_value_unmade(translator, T) -> Union{Nothing,Some}

The parameter that keeps the type `T` from being a constant (`Some(p)`), or `nothing` where constants.jl
makes it: a parameter that is a value of a primitive type with no wasm representation (GenericMemory's
`Core.AddrSpace{Core}`), or a value of no class of the closed world (a `Vararg`'s Core.TypeofVararg),
each of which visitInstanceConstant rejects, found in `T`'s parameters and in theirs. The one reading of which classes' type values jl_to_typeof's table lacks.
"""
@quarantine "julia/src/julia.h:971 jl_to_typeof reads every tag's type from its table; a type value whose parameter is a primitive with no wasm representation, or a value of no class, has no constant (src/constants.jl visitInstanceConstant)" Base.isprimitivetype function type_value_unmade(translator, @nospecialize(T))::Union{Nothing,Some}
    local builtins = translator.builtin_types[]
    local walk(@nospecialize(x)) = begin
        if x isa Union
            local a = walk(x.a)
            return a === nothing ? walk(x.b) : a
        elseif x isa DataType
            for p in x.parameters
                local r = walk(p)
                r === nothing || return r
            end
            return nothing
        elseif x isa Type || x isa TypeVar || x isa Symbol
            return nothing
        end
        local c = typeof(x)
        isprimitivetype(c) && return !haskey(builtins, c) && !(c <: Base.BitInteger && sizeof(c) == 16) ? Some(x) : nothing
        # any other value is an instance constant of its class, which must be a class of the closed world
        # (a Vararg parameter's Core.TypeofVararg is none)
        return haskey(translator.class_info, c) ? nothing : Some(x)
    end
    return walk(T)
end

"""
    is_interface_class_type(translator, T, check_only_null_assignability) -> Bool

Whether dart's emitIsTest and emitAsCheck take their interface arm for the tested type `T`: dart's
`testedAgainstType is InterfaceType && classForType(testedAgainstType) == interfaceTypeClass`, a
Julia DataType that is a class of the closed world, its runtime test the class table's. The table
relates classes, so it answers a test only where a value's class tells it (`told_by_class`); a type
that splits a kind's instances (Type{X}) is tested by the value itself, so it takes the arm only where
the null case alone is tested, which reads no table.
"""
@quarantine "julia/src/subtype.c:2511 jl_isa tests a type value by itself where the type splits its kind, any other value by its class (jl_typeof), the relation the class table holds" Base.haskey function is_interface_class_type(translator, @nospecialize(T::Type), check_only_null_assignability::Bool)::Bool
    T isa DataType || return false
    haskey(translator.class_info, T) || return false
    return check_only_null_assignability || told_by_class(T)
end

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
@quarantine "a Julia program declares no class list; its classes are the types Julia inferred for its values over the closed world julia/Compiler/src/typeinfer.jl:1534 typeinf_ext_toplevel infers for a trimmed program" Base.unwrap_unionall function closed_world_classes(world::NirWorld, at::String)::Vector{DataType}
    local out = DataType[]
    local seen = Base.IdSet{DataType}()
    local objs = Set{NirConst}()
    for b in world
        foreach(t -> _meet_value!(out, seen, t, at), Base.unwrap_unionall(b.ci.def.specTypes).parameters)
        # a varargs method's body reads its trailing arguments as one tuple (NirVarargPacking)
        local va = nir_vararg_packing(b.ci.def)
        va === nothing || _meet_value!(out, seen, va.packed, at)
        foreach(t -> _meet_value!(out, seen, t, at), b.types)
        for st in b.stmts
            for v in nir_value_operands(st)
                # a literal, or a constant binding's value, is a constant constants.jl instantiates:
                # its object graph (_meet_constant!)
                v isa NirConst && _meet_constant!(out, seen, objs, v.c.val, at)
                v isa NirGlobal && (_meet_value!(out, seen, nir_value_type(b, v), at);
                                    _meet_constant!(out, seen, objs, nir_binding_value(v.ref, at).c.val, at))
            end
            # a tuple's class is its operands' (nir_tuple_type), which the statement's widened type
            # may hide; so is the tuple an invoke of a varargs specialization of an open count packs
            # (nir_vararg_call_tuple); one whose class only run time knows is the record of its arity
            if st isa NirCall && nir_callee(st) === Core.tuple
                local tt = nir_tuple_type(b, st)
                isconcretetype(tt) ? _meet_value!(out, seen, tt, at) : _meet_tuple_record!(out, seen, tt, at)
            end
            # throw_methoderror's arguments, the tuple jl_method_error makes of them (jl_f_tuple), passed
            # as the runtime's open Tuple: the record of their count
            st isa NirCall && nir_callee(st) === Core.throw_methoderror && _meet_value!(out, seen, tuple_record_class(length(st.args) - 2), at)
            if st isa NirInvoke
                local vt = nir_vararg_call_tuple(b, st)
                vt !== nothing && (isconcretetype(vt) ? _meet_value!(out, seen, vt, at) : _meet_tuple_record!(out, seen, vt, at))
            end
        end
        _meet_value!(out, seen, b.ci.rettype, at)
    end
    # every tuple can reach a slot whose static type is open, where it is the record of its arity
    # (tuple_record_class, convertType's box): each concrete tuple class's record
    for c in copy(out)
        c <: Tuple && isconcretetype(c) && _meet_value!(out, seen, tuple_record_class(fieldcount(c)), at)
    end
    return out
end

# the record class a tuple of static type `T` takes where its class only run time knows: its arity's,
# a fixed one; a tuple of no fixed length brings none (the code generator rejects it where it meets it)
@quarantine "pkg/dart2wasm/lib/record_class_generator.dart:84 generateRecordClasses: its recordClasses holds one class per record shape, which a tuple of open elements takes" Base.unwrap_unionall function _meet_tuple_record!(out::Vector{DataType}, seen::Base.IdSet{DataType}, @nospecialize(T), at::String)::Nothing
    local tt = Base.unwrap_unionall(T)
    tt isa DataType && tt <: Tuple && !any(p -> p isa Core.TypeofVararg, tt.parameters) || return nothing
    _meet_value!(out, seen, tuple_record_class(length(tt.parameters)), at)
    return nothing
end

"""
    TupleRecord{N}

The class of a Julia tuple of `N` elements held where its static type is open (`Any`, `Tuple`,
`Tuple{Any,Any}`, a Union of tuple types): dart2wasm's record class of a shape, one class per shape
with a top-typed field per element (record_class_generator.dart:84 generateRecordClasses: its recordClasses, :280
_generateFields, its fields `Object? \$1..\$N`), here per arity `N ≥ 1`, a Julia tuple having
positional elements only; the empty shape's class is `Tuple{}` itself (`tuple_record_class`). A tuple whose static type is concrete is its own class, its fields unboxed;
convertType boxes it into its arity's record where it flows into an open slot and unboxes it where
Julia narrows it back (a PiNode, a typeassert), as dart boxes a value type on upcast. Julia's egal and
isa of a tuple read its fields (builtins.c:100 compare_fields; a tuple type is covariant), as dart's
record is-check reads its fields (_checkRecordType, type.dart:585 _RecordType._checkInstance). No Julia
value has the type: a struct of one field of type `Union{}`, uninhabited, its fields the record's
(`class_instance_fields`).

precedent(dart: the record classes of record_class_generator.dart, one per RecordShape). Julia's
differs: its tuple's type is its elements' (jl_f_tuple), so a tuple of a concrete static type keeps its
own class and only an open one is a record; the typeof of an open tuple, a type made at run time,
stays a rejection (A68S3).
"""
@quarantine "pkg/dart2wasm/lib/record_class_generator.dart:280 _RecordClassGenerator._generateFields gives a record class a top-typed field per element, a tuple's record here" Core.Union struct TupleRecord{N}
    _never::Union{}
end

# the record class of a tuple of `n` elements (TupleRecord), the one name of it; the empty shape's is
# Tuple{} itself, the class of Julia's one empty tuple (julia/src/julia.h:1134 jl_emptytuple), which has
# no field to box, so the empty tuple is never boxed (and a class of no field of its own shares its
# superclass's struct, so its reference could not be told apart from that struct's other classes)
@quarantine "pkg/dart2wasm/lib/record_class_generator.dart:84 generateRecordClasses: its recordClasses maps each shape to its class, a tuple's arity to its record here" Core.Int tuple_record_class(n::Int)::DataType = n == 0 ? Tuple{} : TupleRecord{n}

# the arity of the record class `c` (TupleRecord, or Tuple{} for the empty shape), or nothing for any other class
@quarantine "pkg/dart2wasm/lib/record_class_generator.dart:84 generateRecordClasses: its recordClasses keys each class by its shape, a record's arity its parameter here" Core.DataType tuple_record_arity(@nospecialize(c))::Union{Int,Nothing} =
    c === Tuple{} ? 0 : c isa DataType && c <: TupleRecord && c.parameters[1] isa Int ? c.parameters[1] : nothing

# whether the class `c` holds values of the open tuple type `T` (a Tuple type no concrete class is):
# the record classes of the arities `T` admits, a tuple of a concrete type boxed into its arity's record
# where it flows into an open slot (TupleRecord), never a concrete tuple class itself; the one rule the
# class-id ranges (getConcreteClassIdRange) and the type rules (_buildTypeRules) read
@quarantine "pkg/dart2wasm/lib/record_class_generator.dart:84 generateRecordClasses: a value of a record type is an instance of the record class of its shape, a tuple's arity here" Base.typeintersect function open_tuple_holds(@nospecialize(T), @nospecialize(c))::Bool
    local n = tuple_record_arity(c)
    return n !== nothing && typeintersect(T, NTuple{n,Any}) !== Union{}
end

# A constant's object graph met by the walk (dev/formal/ValueClasses.tla's MeetObject): the value's
# class, then every value it holds that constants.jl instantiates in its place, a field's value, an
# svec's or a memory's element, a type value's own fields (its kind's layout, _kind_instance_fields), each
# object walked once, as the model's seenObj holds every object: a mutable one by its identity and an
# immutable one by Julia's ===, a literal's key (NirConst, its hash bounded), so a constant whose
# immutable fields share heap objects is walked in linear time, never once per path (a 40-level DAG
# has 2^40). A field declared abstract (Any) holds a value whose class only the value tells.
# precedent(dart: dart2wasm's record class collection walks each constant's children once, its cache
# a Set.identity of the constants met, record_class_generator.dart:773; kernel's
# VisitOnceConstantVisitor.visitConstant, visitor.dart:1546, the same rule). Julia's differs: a constant
# is no canonical node, so an immutable value is met by === (its NirConst key), a mutable one by identity.
@quarantine "a constant's object graph is walked once per object, as dart2wasm's record class collection visits each constant's children once (pkg/dart2wasm/lib/record_class_generator.dart:773 _RecordVisitor.defaultConstantReference); a Julia constant is keyed by === where dart's canonical node is keyed by identity" Base.Set function _meet_constant!(out::Vector{DataType}, seen::Base.IdSet{DataType}, objs::Set{NirConst}, @nospecialize(v), at::String)::Nothing
    if !isbits(v)
        local key = NirConst(Core.Const(v))
        key in objs && return nothing
        push!(objs, key)
    end
    local t = typeof(v)
    _meet_value!(out, seen, Core.Typeof(v), at)
    if t === Core.SimpleVector
        foreach(x -> _meet_constant!(out, seen, objs, x, at), v)
    elseif t <: Core.GenericMemory
        # a memory's length and its elements, the values its data array holds (_memory_instance_fields;
        # Julia's `ptr`, a host address, is not one), each element written
        _meet_value!(out, seen, Int, at)
        foreach(k -> isassigned(v, k) && _meet_constant!(out, seen, objs, v[k], at), eachindex(v))
    elseif t <: Core.GenericMemoryRef
        # a reference's index and its memory (_memoryref_instance_fields; Julia's address is not one)
        _meet_value!(out, seen, Int, at)
        _meet_constant!(out, seen, objs, v.mem, at)
    elseif Base.iskindtype(t)
        for f in _kind_instance_fields(t, at)
            f.index > 0 && isdefined(v, f.index) && _meet_constant!(out, seen, objs, getfield(v, f.index), at)
        end
    elseif !isprimitivetype(t)
        for i in 1:fieldcount(t)
            isdefined(v, i) && _meet_constant!(out, seen, objs, getfield(v, i), at)
        end
    end
    return nothing
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
@quarantine "pkg/dart2wasm/lib/class_info.dart:420 ClassInfoCollector._createStructForClass meets a class's supertypes before it; a Julia class's parent is its supertype and its fields' classes Julia's fieldtypes" Base.fieldtypes function _meet_class!(out::Vector{DataType}, seen::Base.IdSet{DataType}, t::DataType, at::String)::Nothing
    t in seen && return nothing
    push!(seen, t)
    push!(out, t)
    _meet_class!(out, seen, supertype(t), at)   # Any's supertype is Any, already met
    # a tuple's record holds top-typed fields, no class of its own (TupleRecord)
    tuple_record_arity(t) === nothing || return nothing
    if Base.iskindtype(t)
        # a kind's instance takes dart's runtime type layout, its fields' classes met as Julia's are
        foreach(f -> _meet_value!(out, seen, f.type, at), _kind_instance_fields(t, at))
    elseif t === Symbol || t === Module
        # a symbol holds its name, a String, and a module its name, a Symbol, outside Julia's fields
        # (_symbol_instance_fields, _module_instance_fields)
        foreach(f -> _meet_value!(out, seen, f.type, at), class_instance_fields(t, at))
    elseif t <: Core.GenericMemory
        # a memory holds its length and its elements, each a value of its element type when the
        # elements are boxed (_memory_instance_fields)
        _meet_value!(out, seen, Int, at)
        local e = _memory_element_storage(t.parameters[2], at)
        e isa Union && _meet_value!(out, seen, e, at)
    elseif t <: Core.GenericMemoryRef
        # a memory reference holds its offset and its memory (_memoryref_instance_fields)
        foreach(f -> _meet_value!(out, seen, f.type, at), class_instance_fields(t, at))
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
    egal_by_identity(T) -> Bool

Whether Julia's egal (`===`) compares two values of class `T` by identity: a mutable class's, but the
three mutable classes jl_egal compares by content, String (its bytes), SimpleVector (its elements)
and DataType (the type it is), Julia's src/builtins.c jl_egal__unboxed_. The one source of that
rule, read by the code generator's `==` fallback and the intrinsifier's `===`.
"""
@quarantine "Julia's egal compares a mutable object by identity, except the String, SimpleVector and DataType it compares by content (builtins.c)" Base.ismutabletype function egal_by_identity(T::Type)::Bool
    return T isa DataType && ismutabletype(T) && !(T === String || T === Core.SimpleVector || T === DataType)
end

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
none, and so does a mutable struct declared with no fields, each instance an object of its own; a kind (a type as a value) dart's runtime type layout (`_kind_instance_fields`); a
`Core.SimpleVector` its elements as one immutable wasm array (`_svec_instance_fields`); a `String`
its UTF-8 code units as one immutable i8 wasm array (`_string_instance_fields`); a `Symbol` its name,
one String (`_symbol_instance_fields`); a `Module` its name, one Symbol (`_module_instance_fields`). Any
other class whose data Julia holds outside its fields rejects, located, until its representation is
written. After a struct's own fields come their set flags (`class_is_set_field`), one per field an
allocation may leave undefined whose type admits `nothing`, dart's late lowering's `#isSet` fields.
"""
@quarantine "pkg/dart2wasm/lib/class_info.dart:539 ClassInfoCollector._generateFields reads a class's instance fields; a Julia class's are its fieldnames, fieldtypes and isconst, a primitive type holding one value" Base.isconst function class_instance_fields(c::DataType, at::String)::Vector{ClassField}
    class_is_abstract(c) && return ClassField[]
    # a tuple's record (TupleRecord): a top-typed field per element, dart's record fields $1..$N
    local arity = tuple_record_arity(c)
    arity === nothing || return Dart2Wasm._generate_fields(Dart2Wasm._RecordClassGenerator(Dict{Dart2Wasm.RecordShape,DataType}()), Dart2Wasm.RecordShape(arity, String[]))
    # a 128-bit integer (Int128, UInt128): its two 64-bit halves, LLVM's legalization of an i128 on a
    # 64-bit target (llvm/lib/CodeGen/SelectionDAG/LegalizeIntegerTypes.cpp, ExpandIntegerResult:
    # the low and the high i64), each a field of the class's struct, as the value is one wasm value
    isprimitivetype(c) && c <: Base.BitInteger && sizeof(c) == 16 &&
        return ClassField[ClassField(c, 0, "lo", UInt64, false), ClassField(c, 0, "hi", UInt64, false)]
    isprimitivetype(c) && return ClassField[ClassField(c, 0, "value", c, false)]
    Base.iskindtype(c) && return _kind_instance_fields(c, at)
    if fieldcount(c) == 0
        Base.issingletontype(c) && return ClassField[]
        c === Core.SimpleVector && return _svec_instance_fields(c, at)
        c === String && return _string_instance_fields(c, at)
        c === Symbol && return _symbol_instance_fields(c, at)
        c === Module && return _module_instance_fields(c, at)
        # a mutable struct declared with no fields holds nothing: Julia's layout has no field
        # (fieldcount 0, nothing outside it), its identity the object's own; Julia's own types above,
        # mutable by Julia's account too, hold theirs outside their fields
        ismutabletype(c) && return ClassField[]
        reject!(Unquarantined("src/julia/classes.jl class_instance_fields: $c, whose data Julia holds outside its fields"), at)
    end
    c <: Core.GenericMemory && return _memory_instance_fields(c, at)
    c <: Core.GenericMemoryRef && return _memoryref_instance_fields(c, at)
    local fields = ClassField[ClassField(c, i, string(fieldname(c, i)), fieldtype(c, i), ismutabletype(c) && !isconst(c, i)) for i in 1:fieldcount(c)]
    for i in 1:fieldcount(c)
        local flag = class_is_set_field(fields[i])
        flag === nothing || push!(fields, flag)
    end
    return fields
end

"""
    holds_reference(T) -> Bool

Whether a slot of type `T` holds a reference Julia's NULL can stand in, its #undef: one Julia stores
boxed (`jl_field_isptr`, a memory's `arrayelem_isboxed`), or inline holding a pointer
(`jl_type_hasptr`, a memory's `first_ptr >= 0`). An inline slot of bits (a primitive, an isbits
struct, an isbits union) is never #undef: it holds bits.
"""
@quarantine "julia/src/cgutils.cpp:2768 field_may_be_null tests a slot's reference as jl_field_isptr || jl_type_hasptr" Base.allocatedinline holds_reference(@nospecialize(T))::Bool =
    !Base.allocatedinline(T) || (T isa DataType && !Base.datatype_pointerfree(T))

"""
    field_may_be_null(c, i) -> Bool

Whether field `i` of the struct `c` may be undefined (#undef), Julia's codegen's answer: a field past
the ones every constructor assigns (the trailing `n_uninitialized` of its type's name,
`Core.Compiler.datatype_min_ninitialized`) holding a reference (`holds_reference`).
"""
@quarantine "julia/src/cgutils.cpp:2768 field_may_be_null: a field past n_uninitialized's start holding a reference" Core.Compiler.datatype_min_ninitialized field_may_be_null(c::DataType, i::Int)::Bool =
    1 <= i <= fieldcount(c) && i > Core.Compiler.datatype_min_ninitialized(c) && holds_reference(fieldtype(c, i))

"""
    class_is_set_field(field) -> Union{ClassField,Nothing}

The set flag of a struct's field, or nothing: a field that may be undefined (`field_may_be_null`)
whose type admits `nothing` (`_needs_is_set`) keeps dart's late lowering's flag, named after it with
`#isSet` (late_lowering.dart:12 lateIsSetSuffix), a Bool, mutable where the field is, at index 0, not
one of Julia's fields. An allocation stores it true for a field it is given and false for one it
leaves out, a write sets it (late_lowering.dart:382), a read raises UndefRefError on false where dart's
getter throws (:295), and `isdefined` reads it. Every other field that may be undefined keeps the
null for #undef (useNull). The one test the layout, an allocation, a read, a write and `isdefined` ask.
"""
@quarantine "pkg/front_end/lib/src/kernel/late_lowering.dart:12 lateIsSetSuffix names a potentially nullable late slot's set flag (useIsSetField)" Core.Bool function class_is_set_field(field::ClassField)::Union{ClassField,Nothing}
    field.index > 0 && field_may_be_null(field.cls, field.index) && _needs_is_set(field.type) || return nothing
    return ClassField(field.cls, 0, field.name * "#isSet", Bool, field.mutable)
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
`WasmArray<WasmI8>` was; a String is immutable once made by Julia's convention, not by the wasm
type, whose elements a fresh String's maker writes. The ruling (Dale's choice B, 2026-10-29), from its sources:

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
@quarantine "a String's data lies outside its fields (Julia's jl_string_len, jl_string_data), its UTF-8 bytes in place of dart's host externref, since Base indexes the bytes; immutable once made by Julia's convention, not by the wasm type" Core.String function _string_instance_fields(c::DataType, at::String)::Vector{ClassField}
    c === String || reject!(Internal("src/julia/classes.jl _string_instance_fields: $c, no String"), at)
    return ClassField[ClassField(c, 0, "_data", WasmArray{WasmI8}, false)]
end

"""
    _symbol_instance_fields(c, at) -> Vector{ClassField}

The fields of a `Symbol`, whose data Julia holds outside its fields: one field, `_name`, of type
`String`, the symbol's name, immutable. Julia's layout (julia.h `jl_sym_t`, `jl_symbol_name`): a
symbol is its interned name, which `String(::Symbol)` and printing read; dart's class
(sdk/lib/internal/symbol.dart:16 Symbol, its one field `final String _name` :18): the object header
and then the name, as constants.dart's visitSymbolConstant builds one. A String's representation is
the ruling's (`_string_instance_fields`), so a symbol's name is one. The field is not one of Julia's
(a Symbol has none), so it takes index 0, like a String's `_data`.

precedent(dart: dart:_internal's Symbol class, a name String held by an object; Julia's jl_sym_t, a
name held by the interned symbol). Julia's differs: its symbols are interned and compared by identity,
which an object per constant symbol keeps (each symbol constant one instance).
"""
@quarantine "a Symbol's data lies outside its fields (Julia's jl_sym_t, jl_symbol_name), its name one String as dart's Symbol._name" Core.Symbol function _symbol_instance_fields(c::DataType, at::String)::Vector{ClassField}
    c === Symbol || reject!(Internal("src/julia/classes.jl _symbol_instance_fields: $c, no Symbol"), at)
    return ClassField[ClassField(c, 0, "_name", String, false)]
end

"""
    _memory_element_storage(T, at) -> Type

The element type of the wasm array a `Memory{T}` holds its elements in, by Julia's layout of `T`
(`Base.allocatedinline`, `sizeof`): a primitive element is stored unboxed, dart:_wasm's storage
class of its size (src/julia/wasm_array.jl), a float as WasmF32 or WasmF64 and any other as WasmI8,
WasmI16, WasmI32 or WasmI64 (a 16-bit float, which dart:_wasm has no storage class for, rejected, located); every other element is stored boxed, `Union{T,Nothing}`, a nullable
reference to its class (the top type for `Any`), null an element no write has set (#undef).

Reshaped: `T` — an element type Julia stores inline as a union of bits types (`Union{Nothing,Int}`,
allocatedinline, its selector bytes after the data, genericmemory.c `jl_genericmemory_typetagdata`)
is stored boxed, its answers the same, as is an inline struct of bits, whose class a box holds.
"""
@quarantine "a Memory's element storage is Julia's layout of its element type, julia/src/genericmemory.c:55 _new_genericmemory_'s element size: inline bits by size, else a reference" Base.isprimitivetype function _memory_element_storage(@nospecialize(T), at::String)::Type
    if T isa DataType && isprimitivetype(T)
        local n = sizeof(T)
        T <: AbstractFloat && n == 4 && return WasmF32
        T <: AbstractFloat && n == 8 && return WasmF64
        !(T <: AbstractFloat) && n == 1 && return WasmI8
        !(T <: AbstractFloat) && n == 2 && return WasmI16
        !(T <: AbstractFloat) && n == 4 && return WasmI32
        !(T <: AbstractFloat) && n == 8 && return WasmI64
        reject!(Unquarantined("src/julia/classes.jl _memory_element_storage: the primitive element type $T, $n bytes, with no wasm storage class"), at)
    end
    return Union{T,Nothing}
end

"""
    _memory_instance_fields(c, at) -> Vector{ClassField}

The fields of a `Memory{T}` (`GenericMemory{:not_atomic,T,Core.CPU}`), whose elements Julia holds
outside its fields: `data`, the elements as one mutable wasm array (`WasmArray` of
`_memory_element_storage(T)`), at index 0, and Julia's own `length`, an `Int`, at its index 1, both
immutable. Julia's layout (julia.h `jl_genericmemory_t` at v1.12.7): `length`, then `ptr`, the
address of the elements stored inline after it. `ptr` is left out: a host address, read only through
`pointer` and `unsafe_load`, foreigncalls the strict subset rejects; the elements are the array.
Only `memorynew` writes `data` and `length`, `length` the array's length, and no setter exists for
either, so the two cannot diverge (D6). Julia leaves an undefined bits element's contents
unspecified, so the zero a new wasm array holds is one of Julia's own values, never a default past
a gap (D9). An atomic memory (`AtomicMemory`) or another address space rejects, located: threads lie
outside the strict subset.

Reshaped: `data#isSet` — dart's late lowering gives a potentially nullable slot one bool flag
(pkg/front_end/lib/src/kernel/late_lowering.dart:560 computeIsSetEncoding, useIsSetField); a memory's
elements are slots of one array, so where they may hold nothing (`_needs_is_set`) their flags are one
array beside it, an i8 each, zero (unset) as a new array holds, a write setting it.

precedent(dart: list.dart:15 WasmListBase, its `WasmArray<Object?> _data` beside `int _length`;
Julia's jl_genericmemory_t, its length beside its inline data). Julia's differs: a Memory is an
object of its own class (it flows into `Any`), so the array sits in a field of its struct, as a
SimpleVector's does (`_svec_instance_fields`).
"""
@quarantine "a Memory's elements lie outside its fields: Julia's jl_genericmemory_t, its length beside its inline data" Core.GenericMemory function _memory_instance_fields(c::DataType, at::String)::Vector{ClassField}
    c <: Core.GenericMemory || reject!(Internal("src/julia/classes.jl _memory_instance_fields: $c, no GenericMemory"), at)
    c.parameters[1] === :not_atomic && c.parameters[3] === Core.CPU ||
        reject!(Unquarantined("src/julia/classes.jl _memory_instance_fields: $c, an atomic memory or one of another address space"), at)
    local T = c.parameters[2]
    local data = ClassField(c, 0, "data", WasmArray{_memory_element_storage(T, at)}, false)
    local length = ClassField(c, Base.fieldindex(c, :length), "length", fieldtype(c, :length), false)
    # elements that may hold nothing, each its set flag (_needs_is_set), as one array beside the data
    _needs_is_set(T) || return ClassField[data, length]
    return ClassField[data, ClassField(c, 0, "data#isSet", WasmArray{WasmI8}, false), length]
end

"""
    _needs_is_set(T) -> Bool

Whether a slot of type `T` that no write has set (Julia's #undef) keeps a separate set flag. dart's
late lowering answers how a slot tells unset apart from its values: under the strategy dart2wasm's
target selects (late_lowering.dart:552 computeIsSetStrategy's useIsSetFieldOrNull, as
pkg/dart2wasm/lib/target.dart:565 declares `supportsLateLoweringSentinel => false`), a slot of a
potentially nullable type keeps a flag, `useIsSetField`, which the setter sets (late_lowering.dart:382)
and the getter tests before reading the slot, throwing when it is false (:295); a slot of any other type
uses null for unset (`useNull`). WasmTarget's `nothing` is dart's null, so a reference slot whose type
admits `nothing` (`Nothing <: T`, potentially nullable) takes the flag; one Julia stores inline
(`Base.allocatedinline`) holds bits, never #undef, and takes none.
"""
@quarantine "pkg/front_end/lib/src/kernel/late_lowering.dart:560 computeIsSetEncoding keeps a potentially nullable slot's set state in a separate flag (useIsSetField); WasmTarget's nothing is dart's null" Base.allocatedinline _needs_is_set(@nospecialize(T))::Bool =
    !Base.allocatedinline(T) && Nothing <: T

"""
    _memoryref_instance_fields(c, at) -> Vector{ClassField}

The fields of a `MemoryRef{T}` (`GenericMemoryRef{:not_atomic,T,Core.CPU}`), immutable: Julia's own
`ptr_or_offset` and `mem`, at Julia's indices 1 and 2, the offset an `Int`, the element's index in
`mem` from 0, and `mem` its `Memory{T}`.

Reshaped: `ptr_or_offset` — Julia's field is a `Ptr{Nothing}`, the element's address, or, for a
memory of union or zero-size elements, its index from 0 (genericmemory.c, `jl_memoryrefoffset`
answering `ptr_or_offset + 1`); a wasm array has no addresses, so the index form, Julia's own, is
the only one.
"""
@quarantine "a MemoryRef is Julia's element address or index beside its memory; a wasm array has no addresses, so the index" Core.GenericMemoryRef function _memoryref_instance_fields(c::DataType, at::String)::Vector{ClassField}
    c <: Core.GenericMemoryRef || reject!(Internal("src/julia/classes.jl _memoryref_instance_fields: $c, no GenericMemoryRef"), at)
    c.parameters[1] === :not_atomic && c.parameters[3] === Core.CPU ||
        reject!(Unquarantined("src/julia/classes.jl _memoryref_instance_fields: $c, an atomic memory reference or one of another address space"), at)
    return ClassField[ClassField(c, Base.fieldindex(c, :ptr_or_offset), "ptr_or_offset", Int, false),
                      ClassField(c, Base.fieldindex(c, :mem), "mem", fieldtype(c, :mem), false)]
end

"""
    _module_instance_fields(c, at) -> Vector{ClassField}

The fields of a `Module`, whose data Julia holds outside its fields (`fieldcount(Module) == 0`): one
field, `name`, of type `Symbol`, immutable, in Symbol's own form (`_symbol_instance_fields`). Julia's
layout (julia.h:806 `jl_module_t` at v1.12.7): `name` (:808), the module's name, which `nameof` reads,
then `parent` (:809) and the bindings (:810), which are left out. `parent` is a cycle an eager
constant cannot build (a root module is its own parent), and a program reads it only through
`parentmodule`, a foreigncall. The bindings are runtime state: `getglobal` of a module known only at
run time is a builtin over them, which the strict subset rejects. A module's identity is the one
instance each module constant is (constants are canonical by `===`). The field is not one of Julia's
(a Module has none), so it takes index 0, like a Symbol's `_name`.

precedent(julia: jl_module_t, its name its first field after the header; dart: none, a library is no
value). Julia's differs: a module is a value a program can hold (a GlobalRef's `mod`, TypeError's
context), so it is a class, its layout Julia's own leading field.
"""
@quarantine "a Module's data lies outside its fields (Julia's jl_module_t); dart has no library value, so the layout is Julia's own, its leading name" Core.Module function _module_instance_fields(c::DataType, at::String)::Vector{ClassField}
    c === Module || reject!(Internal("src/julia/classes.jl _module_instance_fields: $c, no Module"), at)
    return ClassField[ClassField(c, 0, "name", Symbol, false)]
end

# a field's name, its Julia name as text: a struct's field's, or a module binding's
@quarantine "a Julia field is named by its fieldname, a Symbol or a tuple's position, and a binding by its Symbol, as kernel names a member by its Name's text (pkg/kernel/lib/src/ast/names.dart:25 Name.text)" Core.GlobalRef field_name(field::Union{ClassField,GlobalRef})::String =
    field isa ClassField ? field.name : string(field.name)

"""
    FieldAccessSite(member, index)

A field access's call site: the enclosing member's MethodInstance and the statement's SSA index in its
body, Julia's own name for a statement. dart keys TFA's selector metadata by the member's TreeNode
(DispatchTable.procedureAttributeMetadata); a Julia field access calls no member, so its site is named
by position, which a rebuilt NIR keeps.
"""
@quarantine "dart keys TFA's selector metadata by TreeNode (dart2wasm/lib/dispatch_table.dart:399 DispatchTable.procedureAttributeMetadata); a Julia field access has no Member, so the enclosing MethodInstance and the statement's SSA index name its site" Core.MethodInstance struct FieldAccessSite
    member::Core.MethodInstance
    index::Int
end

# a field selector's calls: its field's name, whether it is the setter, its call count, the classes
# its receivers' types admit, and its call sites
@quarantine "a field selector's calls, Julia's field accesses on receivers its inference left abstract, as TFA counts a selector's calls in its TableSelectorInfo (pkg/vm/lib/metadata/table_selector.dart:10 TableSelectorInfo)" Core.DataType mutable struct FieldSelectorCalls
    const name::String
    const is_setter::Bool
    call_count::Int
    const classes::Vector{DataType}
    const sites::Vector{FieldAccessSite}
end

# the class ids of a type's concrete classes, ClassIdNumbering.getConcreteClassIdRange's ranges read out
# id by id, and their classes, each id's in the translator's class list (dart's translator.classes,
# indexed by class id): the one projection of the one reading, which every site taking a type's
# concrete classes calls
@quarantine "a type's concrete classes are the ids dart2wasm/lib/class_info.dart:831 ClassIdNumbering.getConcreteClassIdRange answers, each a class of the translator's list" Core.Type concrete_class_ids(t, T::Type)::Vector{Int} =
    Int[id for r in Dart2Wasm.get_concrete_class_id_range(t.class_id_numbering[], T) for id in r.start:r.end_]
@quarantine "a type's concrete classes are the ids dart2wasm/lib/class_info.dart:831 ClassIdNumbering.getConcreteClassIdRange answers, each a class of the translator's list" Core.DataType concrete_classes(t, T::Type)::Vector{DataType} =
    DataType[t.classes[][id + 1].cls for id in concrete_class_ids(t, T)]

# the field selector a field access names on receivers of the classes `admitted`: a name, its own; a
# position, the field each class holds there, as Julia's getfield reads it (fieldname(typeof(x), i)).
# The selectors are named by their fields (DispatchTable.build), so a position naming one field in every
# admitted class is that field's selector; a position past a class's fields is Julia's BoundsError, and
# one naming different fields in different classes no one named selector, each a located rejection
@quarantine "Julia's getfield reads a position or a name as one field index of the receiver's own type (julia/src/builtins.c:994 get_checked_fieldindex)" Base.fieldname function field_selector_name(@nospecialize(f), admitted::Vector{DataType})::String
    local at = "src/julia/classes.jl field_selector_name"
    f isa Symbol && return string(f)
    local names = String[]
    for c in admitted
        f <= fieldcount(c) || reject!(Unquarantined("$at: Julia's BoundsError for $c, which a field access at position $f may reach past its $(fieldcount(c)) fields, a target not yet written"), at)
        local n = string(fieldname(c, f))
        n in names || push!(names, n)
    end
    length(names) <= 1 || reject!(Unquarantined("$at: a field access at position $f names the fields $(join(names, ", ")) in the classes its receiver admits, a selector per position not yet written"), at)
    return isempty(names) ? string(f) : only(names)
end

"""
Julia's answer where dart reads TFA's selector metadata: the calls of each field selector. A
`Core.getfield(x, f)` or `Core.setfield!(x, f, v)` whose receiver's type Julia's inference left
abstract (no concrete type, or a Union) and whose field `f` is a constant (a name or a position) is a
dynamic call of the getter or setter selector `f` names (`field_selector_name`), dart's instance field access through the
dispatch table. Each selector, a `FieldSelectorCalls` of its name and kind, in the order the closed world first meets it,
maps to its call count and the classes its receivers' types admit, `admitted(receiver)`, the
receiver type's concrete classes as ClassIdNumbering.getConcreteClassIdRange reads them (the one reading,
src/class_info.jl), which DispatchTable.build passes. DispatchTable.build (src/dispatch_table.jl)
reads it where dart reads TFA's selector ids. A receiver of a concrete type is a direct access, no call of a selector.
"""
@quarantine "a field access on a receiver Julia's inference left abstract is dart's dynamic call through the dispatch table, which TFA registers when the call is not direct (pkg/vm/lib/transformations/type_flow/table_selector_assigner.dart:142 TableSelectorAssigner.registerGetterCall)" Core.getfield function field_selector_calls(world::NirWorld, admitted_classes::Function)::Vector{FieldSelectorCalls}
    local out = FieldSelectorCalls[]
    for b in world, (index, st) in enumerate(b.stmts)
        st isa NirCall || continue
        local f = nir_callee(st)
        (f === Core.getfield || f === Core.setfield!) || continue
        length(st.args) >= 3 || continue
        local receiver = nir_value_type(b, st.args[2])
        isconcretetype(receiver) && continue
        # a tuple of no one shape (a concrete tuple never reaches here) is dart's record of a static type
        # Record or above, which dart reads by DynamicGet (code_generator.dart:2317 visitDynamicGet), its
        # dynamic dispatcher switching over the record classes holding the field (their `$1` fields,
        # record_class_generator.dart:23), never a call through the dispatch table. Julia's differs: the
        # intrinsifier writes that class-id switch at the read (intrinsics.jl), not in a shared dispatcher
        receiver <: Tuple && continue
        local name_op = st.args[3]
        name_op isa NirConst && (name_op.c.val isa Symbol || name_op.c.val isa Int) || continue
        local admitted = admitted_classes(receiver)::Vector{DataType}
        local name = field_selector_name(name_op.c.val, admitted); local is_setter = f === Core.setfield!
        local k = findfirst(e -> e.name == name && e.is_setter == is_setter, out)
        k === nothing && (push!(out, FieldSelectorCalls(name, is_setter, 0, DataType[], FieldAccessSite[])); k = length(out))
        out[k].call_count += 1
        push!(out[k].sites, FieldAccessSite(b.ci.def, index))
        for c in admitted
            c in out[k].classes || push!(out[k].classes, c)
        end
    end
    return out
end
