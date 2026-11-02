# parity(sdk/lib/_internal/wasm/common/type.dart): dart's runtime types at the pin, the subtype checks
# the code generator calls where a type test needs the runtime, ported as Julia methods of the module
# Runtime (src/julia/parity.jl RUNTIME_FILES). As dart's file, the code holds no type test (`isa`,
# typeassert) of its own, which would call back into these checks and which verifyTypeChecks would
# check again: a type value's kind is read from its tag (src/julia/runtime/rtutils.jl jl_typetagis, as
# dart reads ClassID.getID) and narrowed by unsafeCast (internal_patch.jl).

"""
The index of the substitution table entry that substitutes nothing (dart's `external WasmI32 get
_noSubstitutionIndex`): the intrinsifier lowers the call to the constant
(Intrinsifier.generateStaticGetterIntrinsic). Natively no table exists, so the body raises.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:665 _noSubstitutionIndex" @noinline _no_substitution_index()::Int32 =
    _wasm_only(Int32)

"""
Each class id's offset of its row in the displacement table (dart's `external WasmArray<WasmI32> get
_typeRowDisplacementOffsets`), the table RuntimeTypeInformation built, read by the intrinsifier.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:670 _typeRowDisplacementOffsets" @noinline _type_row_displacement_offsets()::WasmArray{WasmI32} =
    _wasm_only(WasmArray{WasmI32})

"""
The rows of superclass ids, displaced into one table (dart's `external WasmArray<WasmI32> get
_typeRowDisplacementTable`): a superclass's offset plus a class id holds the superclass's id exactly
where the class is below it.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:687 _typeRowDisplacementTable" @noinline _type_row_displacement_table()::WasmArray{WasmI32} =
    _wasm_only(WasmArray{WasmI32})

"""
The substitution index of each entry of the displacement table (dart's `external WasmArray<WasmI16>
get _typeRowDisplacementSubstTable`), a packed i16 array.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:695 _typeRowDisplacementSubstTable" @noinline _type_row_displacement_subst_table()::WasmArray{WasmI16} =
    _wasm_only(WasmArray{WasmI16})

"""
Whether `o` is below the class `t_id`: its class id's relation to it through the displacement table.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:1005 _TypeUniverse.isObjectInterfaceSubtype0" function _TypeUniverse_is_object_interface_subtype0(@nospecialize(o::Any), t_id::Int32)::Bool
    local s_id = ClassID_get_id(o)
    return _TypeUniverse__check_subclass_relationship(s_id, t_id) != Int32(-1)
end

"""
The substitution index from the class `s_id` to the class `t_id`, -1 where `s_id` is not below it. A
class is below itself with no substitution, which the table, holding each class's proper
superclasses, does not encode. dart's assertion that `t_id` is no top class is off in a product build,
as Julia's own `@assert` would be compiled in, so it is not written.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:1185 _TypeUniverse._checkSubclassRelationship" function _TypeUniverse__check_subclass_relationship(s_id::Int32, t_id::Int32)::Int32
    # The [sSupers] array below doesn't encode the class itself.
    s_id == t_id && return _no_substitution_index()
    return _TypeUniverse__check_subclass_relationship_via_table(s_id, t_id)
end

"""
The table's answer: the entry at `t_id`'s row offset plus `s_id`, an unsigned compare against the
table's length (wasm's i32 arithmetic wrapping, as dart's WasmI32's), holds `t_id` exactly where
`s_id` is below it, its substitution index beside it.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:1196 _TypeUniverse._checkSubclassRelationshipViaTable" function _TypeUniverse__check_subclass_relationship_via_table(s_id::Int32, t_id::Int32)::Int32
    local offset = _type_row_displacement_offsets()
    local table = _type_row_displacement_table()
    local index = wasm_array_read(offset, Int(t_id)) + s_id
    (index % UInt32) >= (wasm_array_length(table) % UInt32) && return Int32(-1)
    local value = wasm_array_read(table, Int(index))
    if value == t_id
        # Match: The [sId] is a subtype of [tId].
        return wasm_array_read_unsigned(_type_row_displacement_subst_table(), Int(index)) % Int32
    end
    return Int32(-1)
end

"""
A type test that only needs the null case: null, Julia's `nothing`, answers the type's nullability,
any other value passes.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:1498 _isNullabilityCheck" function _is_nullability_check(@nospecialize(o::Any), is_declared_nullable::Bool)::Bool
    o === nothing && return is_declared_nullable
    return true
end

"""
A test of `o` against the class `t_id`, which has no type arguments (a Julia class binds its
parameters): null answers the type's nullability, any other value its class's relation to `t_id`.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:1518 _isInterfaceSubtype0" function _is_interface_subtype0(@nospecialize(o::Any), is_declared_nullable::Bool, t_id::Int32)::Bool
    o === nothing && return is_declared_nullable
    return _TypeUniverse_is_object_interface_subtype0(o, t_id)
end

"""
A check of `o` against the class `t_id`: only its null case where the operand's type assures the
rest, else the full test; on failure the as-check error. dart's minified build throws without
details; WasmTarget has no minified build of its runtime.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:1589 _asInterfaceSubtype0" function _as_interface_subtype0(@nospecialize(o::Any), only_nullability_check::Bool, is_declared_nullable::Bool, t_id::Int32)::Nothing
    local success = only_nullability_check ? _is_nullability_check(o, is_declared_nullable) :
        _is_interface_subtype0(o, is_declared_nullable, t_id)
    success && return nothing
    _throw_interface_type_as_check_error0(o, is_declared_nullable, t_id)
end

"""
Throws the as-check error of `o` against the class `t_id`. dart rebuilds the type from the class id
(`_InterfaceType(tId, isDeclaredNullable, [])`); a Julia type is one canonical object, so it is the
class id's type (julia.h:971 jl_to_typeof), whose nullability it holds itself: a nullable DataType is
`Nothing` or `Any`.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:1651 _throwInterfaceTypeAsCheckError0" @noinline _throw_interface_type_as_check_error0(@nospecialize(o::Any), is_declared_nullable::Bool, t_id::Int32)::Union{} =
    _TypeError__throw_as_check_error(o, jl_to_typeof(t_id))

"""
Whether the type `t` admits null (dart's `final bool isDeclaredNullable`), Julia's `Nothing <: t`. The
layout holds it as each kind's first field, written from Julia's `Nothing <: T` (constants.jl, the
kinds' fields). dart reads its field from any kind; a Julia kind's struct shares no prefix with
another's, so the answer is Julia's own, by kind, as jl_isa answers `nothing` (julia/src/subtype.c:2511):
a DataType is a supertype of Nothing only as Nothing or Any, a Union where either member is, Union{}
never.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:68 _Type.isDeclaredNullable" function _Type_is_declared_nullable(t::Type)::Bool
    jl_typetagis(t, DataType) && return (d = unsafe_cast(DataType, t); d === Nothing || d === Any)
    if jl_typetagis(t, Union)
        local u = unsafe_cast(Union, t)
        return _Type_is_declared_nullable(unsafe_cast(Type, u.a)) || _Type_is_declared_nullable(unsafe_cast(Type, u.b))
    end
    return false
end

"""
The id of the class the DataType `t` denotes (dart's `final WasmI32 classId`), its layout's field,
read by the intrinsifier.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:276 _InterfaceType.classId" @noinline _InterfaceType_class_id(t::DataType)::Int32 =
    _wasm_only(Int32)

"""
Whether the non-null `o` is of the type `t`, dart's `_checkInstance`, a virtual method of each runtime
type class, here a switch over Julia's kinds by the type value's own class:
- a DataType is dart's `_InterfaceType`: its class id's relation to `o`'s class, the class table
  (`_InterfaceType._checkInstance`, a Julia class binding its parameters, so no type arguments);
- a Union, Julia's `jl_uniontype_t` (julia.h), which dart has no kind of: `o` is of it exactly when it
  is of either member, subtype.c's rule for a concrete type on the left (julia/src/subtype.c:1419
  subtype, its `jl_is_uniontype(y)` arm), each member a type again;
- `Union{}`'s kind is dart's `_BottomType`: no value.
A UnionAll, a Type{X} or an open tuple type never reaches here from the program: a run-time type test
compiles only where the program's type values hold none (src/julia/runtime/rtutils.jl
check_run_time_type_values, at link time); a UnionAll of WasmTarget's own runtime raises, loud.

precedent(julia: julia/src/subtype.c:2511 jl_isa, the kinds told apart by the type value's tag).
Julia's differs from dart: its Union is a kind of its own, where dart's nullable type is a flag.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:97 _Type._checkInstance" function _Type__check_instance(t::Type, @nospecialize(o::Any))::Bool
    # Any, dart's _TopType (Object?), whose class row the class table does not hold (types.jl
    # _buildTypeRules skips the top): every value is of it
    t === Any && return _TopType__check_instance(o)
    if jl_typetagis(t, DataType)
        return _InterfaceType__check_instance(unsafe_cast(DataType, t), o)
    elseif jl_typetagis(t, Union)
        # Julia's Union, which dart has no kind of: either member (subtype.c's union rule)
        local u = unsafe_cast(Union, t)
        return _is_subtype(o, unsafe_cast(Type, u.a)) || _is_subtype(o, unsafe_cast(Type, u.b))
    elseif jl_typetagis(t, Core.TypeofBottom)
        return _BottomType__check_instance(o)
    end
    # a UnionAll, which no type value of the program is where a run-time test compiles (the code
    # generator's link-time check), here only one of WasmTarget's own runtime (a TypeError's `Type`):
    # loud, never an answer
    Error__throw_with_current_stack_trace(ErrorException("WasmTarget: a run-time type test against a UnionAll, which Julia's subtype decides by its environment"))
end

"""
Whether `o` is of Union{}, dart's `_BottomType._checkInstance` (`=> false`): no value is.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:111 _BottomType._checkInstance" _BottomType__check_instance(@nospecialize(o::Any))::Bool = false

"""
Whether `o` is of the class the DataType `t` denotes (dart's `_InterfaceType._checkInstance`): its class
id's relation to `t`'s through the class table, no type arguments (a Julia class binds its parameters).
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:291 _InterfaceType._checkInstance" _InterfaceType__check_instance(t::DataType, @nospecialize(o::Any))::Bool =
    _TypeUniverse_is_object_interface_subtype0(o, _InterfaceType_class_id(t))

"""
Whether `o` is of the top type, Julia's Any (dart's `_TopType._checkInstance`, `=> true`): every value
is.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:138 _TopType._checkInstance" _TopType__check_instance(@nospecialize(o::Any))::Bool = true

"""
Whether `o` is of the run-time type `t`: null answers the type's nullability, any other value the
type's `_checkInstance`.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:1484 _isSubtype" function _is_subtype(@nospecialize(o::Any), t::Type)::Bool
    o === nothing && return _Type_is_declared_nullable(t)
    return _Type__check_instance(t, o)
end

"""
A check of `o` against the run-time type `t`: only its null case where the operand's type assures the
rest, else the full test; on failure Julia's typeassert error (_TypeError._throwAsCheckError).
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:1561 _asSubtype" function _as_subtype(@nospecialize(o::Any), only_nullability_check::Bool, t::Type)::Nothing
    local success = only_nullability_check ? _is_nullability_check(o, _Type_is_declared_nullable(t)) : _is_subtype(o, t)
    success && return nothing
    _TypeError__throw_as_check_error(o, t)
end

"""
Whether the class of the DataType `s` is below the class of the DataType `t`, by the class table (dart's
`_TypeUniverse.isInterfaceSubtype`): the substitution index of `s`'s class id to `t`'s, -1 where it is
not below. A Julia class binds its parameters, so no type arguments are compared.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:974 _TypeUniverse.isInterfaceSubtype" function _TypeUniverse_is_interface_subtype(s::DataType, t::DataType)::Bool
    local substitution_index = _TypeUniverse__check_subclass_relationship(_InterfaceType_class_id(s), _InterfaceType_class_id(t))
    # Return early if [sId] isn't a direct/indirect subclass of [tId].
    substitution_index == Int32(-1) && return false
    # A Julia class's type arguments are bound in the class itself: none to compare
    return true
end

"""
Whether the type `s` is a subtype of the type `t` (dart's `_TypeUniverse.isSubtype`, its rules in its
order, over the kinds the runtime ports): reflexivity, nullability, left bottom, right top, right
bottom, then Julia's Union, which dart has no kind of (julia/src/subtype.c:1419 subtype: a Union on the
left where both members are, on the right where either is), then two classes' DataTypes by the class
table, the one relation the instance check reads. dart's record rule (type.dart:1440, a Julia tuple
type, subtype.c:1582) and Julia's Type{X} (subtype.c:1550) are not ported: a program holding such a type
beside a run-time subtype test rejects, located, at link time, as it does a UnionAll. dart's function,
FutureOr and type-parameter rules have no Julia kind.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:1351 _TypeUniverse.isSubtype" function _TypeUniverse_is_subtype(s::Type, t::Type)::Bool
    # Reflexivity:
    s === t && return true
    # Compare nullabilities:
    _Type_is_declared_nullable(s) && !_Type_is_declared_nullable(t) && return false
    # Left bottom:
    jl_typetagis(s, Core.TypeofBottom) && return true
    # Right top:
    t === Any && return true
    # Right bottom:
    jl_typetagis(t, Core.TypeofBottom) && return false
    # Julia's Union, left then right (subtype.c)
    if jl_typetagis(s, Union)
        local su = unsafe_cast(Union, s)
        return _TypeUniverse_is_subtype(unsafe_cast(Type, su.a), t) && _TypeUniverse_is_subtype(unsafe_cast(Type, su.b), t)
    end
    if jl_typetagis(t, Union)
        local tu = unsafe_cast(Union, t)
        return _TypeUniverse_is_subtype(s, unsafe_cast(Type, tu.a)) || _TypeUniverse_is_subtype(s, unsafe_cast(Type, tu.b))
    end
    # Null: dart's Null is the nullable bottom, below every nullable type (Left bottom, type.dart:1364);
    # Julia's Nothing, past the nullabilities, is below Nothing and Any only, both answered above, and no
    # other type is below Nothing (julia/src/subtype.c:1419 subtype)
    (s === Nothing || t === Nothing) && return false
    # two DataTypes by the class table: a class's DataType, never a Type{X} (subtype.c:1550) nor a tuple
    # type (subtype.c:1582 subtype_tuple, dart's record rule, type.dart:1440): a program holding either
    # beside a run-time subtype test rejects, located, at link time (src/julia/runtime/rtutils.jl
    # check_run_time_type_values), as it does a UnionAll
    jl_typetagis(s, DataType) && jl_typetagis(t, DataType) &&
        return _TypeUniverse_is_interface_subtype(unsafe_cast(DataType, s), unsafe_cast(DataType, t))
    # a UnionAll, which that link-time check rejects in the program; here only one of WasmTarget's own
    # runtime: loud, never an answer
    Error__throw_with_current_stack_trace(ErrorException("WasmTarget: a run-time subtype test of a UnionAll, which Julia's subtype decides by its environment"))
end

"""
Whether the type `s` is a subtype of the type `t` (dart's `_isTypeSubtype`, `_TypeUniverse.isSubtype`
with no type environments).
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:1555 _isTypeSubtype" _is_type_subtype(s::Type, t::Type)::Bool =
    _TypeUniverse_is_subtype(s, t)

"""
The error an optimized type check raises when the runtime's reference check disagrees (dart's
`class _TypeCheckVerificationError extends Error`): the value's type and the tested type, both results,
and the check's source location when the compiler knew it. dart's Error is Julia's Exception.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:1744 _TypeCheckVerificationError" struct _TypeCheckVerificationError <: Exception
    left::Type
    right::Type
    optimized::Bool
    reference::Bool
    location::Union{String,Nothing}
    # dart's unnamed constructor, each field from its parameter
    _TypeCheckVerificationError(left::Type, right::Type, optimized::Bool, reference::Bool, location::Union{String,Nothing}) =
        new(left, right, optimized, reference, location)
end

"""
The verification error's message (dart's `String toString()`, Julia's `show`): its location when it has
one, the two types and both results, line for line as dart writes it.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:1759 _TypeCheckVerificationError.toString" function Base.show(io::IO, e::_TypeCheckVerificationError)::Nothing
    local location_string = e.location !== nothing ? " at $(e.location)" : ""
    print(io, "Type check verification error$location_string\n",
        "Checking $(e.left) <: $(e.right)\n",
        "Optimized result $(e.optimized), reference result $(e.reference)\n")
    return nothing
end

"""
Whether the class id is a record class's (dart's `@pragma("wasm:intrinsic") external bool
_isRecordClassId(WasmI32 classId)`): the intrinsifier lowers it to the class-id range check over the
record classes, Julia's tuple records (src/julia/classes.jl TupleRecord, the classes an open tuple
type's range holds). Natively no class id exists, so the body raises.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:2060 _isRecordClassId" @noinline _is_record_class_id(class_id::Int32)::Bool =
    _wasm_only(Bool)

"""
The runtime type of a non-null value (dart's `_getActualRuntimeType`): the type of its class id, read
from the table of each class's type value (julia.h:971 jl_to_typeof). Julia's typeof answers the same:
a value's class is its type, its parameters bound. dart's Object class id has no Julia instance. A
closure is a class of its own, its type the table's. A record class is the record model's TupleRecord,
whose values' Julia type is the tuple of their fields' types: dart's
Record._getMasqueradedRecordRuntimeType, not ported, raises, loud.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:1941 _getActualRuntimeType" function _get_actual_runtime_type(@nospecialize(object::Any))::Type
    local class_id = ClassID_get_id(object)
    _is_record_class_id(class_id) &&
        Error__throw_with_current_stack_trace(ErrorException("WasmTarget: the runtime type of a tuple held as its record (dart's Record._getMasqueradedRecordRuntimeType) is not ported"))
    return jl_to_typeof(class_id)
end

"""
The runtime type of a value that may be null (dart's `_getActualRuntimeTypeNullable`): null's is
Julia's Nothing, dart's `_literal<Null>()`; any other value's is `_get_actual_runtime_type`'s.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:1955 _getActualRuntimeTypeNullable" _get_actual_runtime_type_nullable(@nospecialize(object::Any))::Type =
    object === nothing ? Nothing : _get_actual_runtime_type(object)

"""
Checks an optimized type test against the runtime's reference subtype check (dart's
`@pragma("wasm:entry-point") bool _verifyOptimizedTypeCheck(bool result, Object? o, _Type t, String?
location)`), the call emitIsTest makes after a test under `verifyTypeChecks`: the value's runtime type
tested against `t` by `_isTypeSubtype`; a disagreement throws `_TypeCheckVerificationError`; else the
optimized result is returned. dart's `String? location` is a String here, empty where the compiler
knew none: a root is the specialization Julia compiles for its signature (src/julia/subset.jl
_entry_specialization), and Julia compiles none for a `Union{Nothing,String}` parameter.
"""
@parity "sdk/lib/_internal/wasm/common/type.dart:1730 _verifyOptimizedTypeCheck" function _verify_optimized_type_check(result::Bool, @nospecialize(o::Any), t::Type, location::String)::Bool
    local s = _get_actual_runtime_type_nullable(o)
    local reference = _is_type_subtype(s, t)
    result != reference && Error__throw_with_current_stack_trace(_TypeCheckVerificationError(s, t, result, reference, isempty(location) ? nothing : location))
    return result
end
