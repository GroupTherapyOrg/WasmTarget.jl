# ============================================================================
# Tagged Union Type Registration
# Multi-variant unions (not just Union{Nothing, T}) are stored as tagged unions:
# WasmGC struct { tag: i32, value: anyref }
# ============================================================================

"""
Check if a Union type is a "simple" nullable type (Union{Nothing, T}).
Returns the inner type T if so, nothing otherwise.
"""
function get_nullable_inner_type(T::Union)::Union{Type, Nothing}
    types = Base.uniontypes(T)
    non_nothing = filter(t -> t !== Nothing, types)
    if length(non_nothing) == 1 && Nothing in types
        return non_nothing[1]
    end
    return nothing
end

"""
Check if a type is a reference type (struct or Union containing struct).
Used to determine if ref.eq should be used for comparison.
"""
function is_ref_type_or_union(T::Type)::Bool
    # Any maps to externref (reference type)
    if T === Any
        return true
    end
    # Direct struct types (excluding primitive types)
    if T isa DataType && isstructtype(T) && !isprimitivetype(T)
        return true
    end
    # Union types - check if any component is a ref type
    if T isa Union
        types = Base.uniontypes(T)
        for t in types
            if t !== Nothing && is_ref_type_or_union(t)
                return true
            end
        end
    end
    # Arrays/Vectors are refs
    if T <: AbstractArray
        return true
    end
    # String/Symbol map to ArrayRef
    if T === String || T === Symbol || T <: AbstractString
        return true
    end
    # Abstract types map to ExternRef (e.g., Compiler.CallInfo, AbstractInterpreter)
    if isabstracttype(T)
        return true
    end
    # UnionAll types map to AnyRef or ExternRef (e.g., Type, parametric types)
    if T isa UnionAll
        return true
    end
    # PURE-4151: Type{T} singleton types (e.g., Type{Int64}, Type{Any})
    # Now represented as unique Wasm global struct refs (not i32.const 0)
    if T isa DataType && T <: Type
        return true
    end
    return false
end

"""
Check if a value represents `nothing` (literal or GlobalRef to nothing).
"""
function is_nothing_value(val, ctx)::Bool
    # Literal nothing
    if val === nothing
        return true
    end
    # GlobalRef to nothing (e.g., WasmTarget.nothing or Core.nothing)
    if val isa GlobalRef && val.name === :nothing
        return true
    end
    # SSA that has Nothing type
    if val isa Core.SSAValue
        ssa_type = get(ctx.ssa_types, val.id, Any)
        return ssa_type === Nothing
    end
    return false
end

"""
Check if a Union type needs tagged union representation.
Returns true for multi-variant unions that aren't simple nullable types.
"""
function needs_tagged_union(T::Union)::Bool
    types = Base.uniontypes(T)
    non_nothing = filter(t -> t !== Nothing, types)
    # Need tagged union if we have 2+ non-Nothing types
    return length(non_nothing) >= 2
end

"""
Register a multi-variant Union type as a WasmGC tagged union struct.

Tagged unions are structs with two fields:
- Field 0: tag (i32) - identifies which variant is stored
- Field 1: value (anyref) - the actual value, boxed to anyref

Tag values are assigned in order based on the union type list.
Tag 0 is reserved for Nothing if present in the union.
"""
function register_union_type!(mod::WasmModule, registry::TypeRegistry, T::Union)::UnionInfo
    # Already registered?
    haskey(registry.unions, T) && return registry.unions[T]

    # Get variant types
    types = Base.uniontypes(T)

    # Build tag map - assign tag values to each type
    # Nothing gets tag 0 if present, other types get sequential tags
    tag_map = Dict{Type, Int32}()
    variant_types = Type[]
    next_tag = Int32(0)

    # Assign tag 0 to Nothing if present
    if Nothing in types
        tag_map[Nothing] = next_tag
        push!(variant_types, Nothing)
        next_tag += Int32(1)
    end

    # Assign tags to other types in order
    for t in types
        if t !== Nothing
            tag_map[t] = next_tag
            push!(variant_types, t)
            next_tag += Int32(1)
        end
    end

    # Create WasmGC struct with two fields: tag (i32) and value (anyref)
    # Using AnyRef allows us to store any WasmGC reference type
    wasm_fields = [
        FieldType(I32, true),    # tag - mutable so we can set it
        FieldType(AnyRef, true)  # value - anyref can hold any reference
    ]

    # Add struct type to module
    type_idx = add_struct_type!(mod, wasm_fields)

    # Record mapping
    info = UnionInfo(T, type_idx, variant_types, tag_map)
    registry.unions[T] = info

    return info
end

"""
Get or create a tagged union type for a Union.
Returns the UnionInfo with type index and tag mappings.
"""
function get_union_type!(mod::WasmModule, registry::TypeRegistry, T::Union)::UnionInfo
    if haskey(registry.unions, T)
        return registry.unions[T]
    else
        return register_union_type!(mod, registry, T)
    end
end

"""
Get the tag value for a specific type within a union.
"""
function get_union_tag(info::UnionInfo, T::Type)::Int32
    return get(info.tag_map, T, Int32(-1))
end

"""
Emit bytecode to wrap a value on the stack in a tagged union struct.
Stack: [value] -> [tagged_union_struct]

The value is first converted to anyref (via extern.convert_any if needed),
then wrapped with its type tag.
"""
function emit_wrap_union_value(ctx, value_type::Type, union_type::Union)::Vector{UInt8}
    bytes = UInt8[]

    # Get or register the union type
    union_info = get_union_type!(ctx.mod, ctx.type_registry, union_type)
    tag = get_union_tag(union_info, value_type)

    if tag < 0
        # Not a direct variant — try subtype-based matching (handles concrete subtypes)
        for (variant_type, vtag) in union_info.tag_map
            if value_type <: variant_type
                tag = vtag
                break
            end
        end
    end

    if tag < 0
        # Check if value is already a compatible tagged union struct on the stack.
        # This happens when val_type == union_type (value already wrapped elsewhere).
        if value_type isa Union && value_type <: union_type
            return bytes  # Value is already a properly tagged union struct; no re-wrap needed
        end
        # Truly incompatible type (dead code path from imprecise type inference).
        # Convert to anyref and use tag 0 so compilation succeeds.
        # This branch should never execute for valid inputs (it's type-inference dead code).
        tag = Int32(0)
    end

    # For Nothing, we need to create a null anyref
    if value_type === Nothing
        # Drop any value on stack (Nothing has no value)
        # Push tag (0 for Nothing)
        push!(bytes, Opcode.I32_CONST)
        append!(bytes, encode_leb128_signed(Int64(tag)))
        # Push null anyref for the value
        push!(bytes, Opcode.REF_NULL)
        push!(bytes, UInt8(AnyRef))  # anyref
    else
        # Value is on stack - need to save it, push tag, then restore value
        # Allocate a scratch local for the value
        scratch_local = length(ctx.locals) + ctx.n_params
        value_wasm_type = julia_to_wasm_type_concrete(value_type, ctx)
        push!(ctx.locals, value_wasm_type)

        # Store value to scratch local
        push!(bytes, Opcode.LOCAL_SET)
        append!(bytes, encode_leb128_unsigned(scratch_local))

        # Push tag
        push!(bytes, Opcode.I32_CONST)
        append!(bytes, encode_leb128_signed(Int64(tag)))

        # Reload value and convert to anyref
        push!(bytes, Opcode.LOCAL_GET)
        append!(bytes, encode_leb128_unsigned(scratch_local))

        # Convert to anyref if needed
        if value_wasm_type === I32
            # PURE-6024: Box i32 into i31ref (subtype of anyref) using ref.i31
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.REF_I31)
        elseif value_wasm_type === I64
            # PURE-6024: Truncate i64 to i32, then box via ref.i31
            push!(bytes, Opcode.I32_WRAP_I64)
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.REF_I31)
        elseif value_wasm_type === F32 || value_wasm_type === F64
            # PURE-6024: Float in anyref field — drop value, emit ref.null any
            push!(bytes, Opcode.DROP)
            push!(bytes, Opcode.REF_NULL)
            push!(bytes, UInt8(AnyRef))
        elseif value_wasm_type === ExternRef
            # ExternRef must be converted to anyref via any_convert_extern
            push!(bytes, Opcode.GC_PREFIX)
            push!(bytes, Opcode.ANY_CONVERT_EXTERN)
        elseif value_wasm_type isa ConcreteRef || value_wasm_type isa RefType
            # Struct/array refs are subtypes of anyref — no conversion needed
        end
    end

    # Create the tagged union struct
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_NEW)
    append!(bytes, encode_leb128_unsigned(union_info.wasm_type_idx))

    return bytes
end

"""
Emit bytecode to extract a value from a tagged union struct.
Stack: [tagged_union_struct] -> [value]

Extracts the value field and casts it to the expected type.
Note: Caller should verify type via isa() first for safety.
"""
function emit_unwrap_union_value(ctx, union_type::Union, target_type::Type)::Vector{UInt8}
    bytes = UInt8[]

    # Handle Nothing specially - just check if null
    if target_type === Nothing
        # For Nothing, we just need to verify it's null (via isa check done elsewhere)
        # Return nothing meaningful - the caller knows it's Nothing
        push!(bytes, Opcode.DROP)  # Drop the union struct
        return bytes
    end

    # Get the union info
    union_info = get_union_type!(ctx.mod, ctx.type_registry, union_type)

    # Get the value field (field 1)
    push!(bytes, Opcode.GC_PREFIX)
    push!(bytes, Opcode.STRUCT_GET)
    append!(bytes, encode_leb128_unsigned(union_info.wasm_type_idx))
    append!(bytes, encode_leb128_unsigned(1))  # field 1 is value

    # Cast anyref to the target type
    target_wasm_type = julia_to_wasm_type_concrete(target_type, ctx)
    if target_wasm_type isa ConcreteRef
        # Cast anyref to concrete type using ref.cast / ref.cast_null
        # The immediate is a heaptype (just the type index), not a reftype
        push!(bytes, Opcode.GC_PREFIX)
        if target_wasm_type.nullable
            push!(bytes, Opcode.REF_CAST_NULL)
        else
            push!(bytes, Opcode.REF_CAST)
        end
        append!(bytes, encode_leb128_signed(Int64(target_wasm_type.type_idx)))
    elseif target_wasm_type === ArrayRef || target_wasm_type === StructRef
        # PURE-6024: Cast anyref to abstract arrayref/structref.
        # Needed for abstract types (e.g., AbstractString → ArrayRef).
        push!(bytes, Opcode.GC_PREFIX, Opcode.REF_CAST_NULL)
        push!(bytes, UInt8(target_wasm_type))
    elseif target_wasm_type === I32
        # PURE-6025: Unbox i31ref → i32. Value was boxed via ref.i31 in emit_wrap_union_value.
        # anyref → (ref null i31) → i32
        push!(bytes, Opcode.GC_PREFIX, Opcode.REF_CAST_NULL)
        push!(bytes, UInt8(I31Ref))  # heaptype: i31
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.I31_GET_S)
    elseif target_wasm_type === I64
        # PURE-6025: Unbox i31ref → i32 → i64. Value was boxed via i32.wrap_i64 + ref.i31.
        # anyref → (ref null i31) → i32 → i64
        push!(bytes, Opcode.GC_PREFIX, Opcode.REF_CAST_NULL)
        push!(bytes, UInt8(I31Ref))  # heaptype: i31
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.I31_GET_S)
        push!(bytes, Opcode.I64_EXTEND_I32_S)
    elseif target_wasm_type === ExternRef
        # PURE-6025: Convert anyref → externref via extern.convert_any.
        push!(bytes, Opcode.GC_PREFIX)
        push!(bytes, Opcode.EXTERN_CONVERT_ANY)
    end

    return bytes
end

