# parity(sdk/lib/_internal/wasm/common/type.dart): dart's runtime types at the pin, the subtype checks
# the code generator calls where a type test needs the runtime, ported as Julia methods of the module
# Runtime (src/julia/parity.jl RUNTIME_FILES). As dart's file, the code avoids type tests (`isa`,
# typeassert) of its own, which would call back into these checks.

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
