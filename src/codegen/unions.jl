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

    # PURE-9024: Prepend typeId:i32 as field 0 (universal object layout)
    # Create WasmGC struct with fields: typeId (i32), tag (i32), value (anyref)
    wasm_fields = [
        FieldType(I32, false),   # PURE-9024: typeId (immutable)
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
Reverse-map a wasm struct type index to the registered tagged-union Julia type whose
wrapper struct it is, or `nothing`. (The phi machinery only knows the ConcreteRef type
index; emit_wrap_union_value needs the Julia Union to look up the variant tag.)
"""
function tagged_union_type_for_idx(ctx, idx)::Union{Type,Nothing}
    for (T, info) in ctx.type_registry.unions
        info.wasm_type_idx == idx && return T
    end
    return nothing
end

"""
Resolve a phi/flow edge `val` (SSAValue, literal, QuoteNode) to its concrete Julia variant
type for tagged-union wrapping, or `nothing` when it can't be pinned to a concrete DataType.
"""
function phi_edge_variant_julia(ctx, val)::Union{Type,Nothing}
    if val isa Core.SSAValue
        t = get(ctx.ssa_types, val.id, nothing)
        return t === nothing ? nothing : Core.Compiler.widenconst(t)
    elseif val isa Core.Argument
        # `_2`→arg_types[1], … (Julia IR `_1` is the function, not in arg_types).
        idx = val.n - 1
        return (idx >= 1 && idx <= length(ctx.arg_types)) ? Core.Compiler.widenconst(ctx.arg_types[idx]) : nothing
    elseif val isa QuoteNode
        return phi_edge_variant_julia(ctx, val.value)
    elseif val isa Core.SlotNumber || val isa GlobalRef
        return nothing
    else
        return val isa Type ? nothing : Core.Compiler.widenconst(typeof(val))
    end
end

# Nullability-insensitive wasm-type match (a String literal's edge rep is non-nullable while
# julia_to_wasm_type_concrete may report nullable — same struct index, same box shape).
_wt_box_type_match(a, b)::Bool =
    a === b || (a isa ConcreteRef && b isa ConcreteRef && a.type_idx == b.type_idx)

"""
F31: decide whether a phi/flow edge value should be CONSTRUCTED into a tagged-union struct
(via `emit_wrap_union_value`) rather than dummied to `ref.null`. Returns `(union_T,
variant_T)` when (a) the phi-local is a registered tagged-union struct, (b) the edge value
resolves to a concrete variant that is a member of the union (`vt <: uT`), and (c) the
variant's wasm box-shape matches `val_wasm` (the type actually on the stack). Else `nothing`
(caller keeps its prior behavior). Surfaced by heterogeneous Union value extraction
(e.g. `a = x>0 ? 42 : "neg"; Int(a)`), which previously stored ref.null → trapped on read.
"""
function phi_tagged_union_wrap(ctx, phi_local_wasm_type, val, val_wasm)::Union{Tuple{Type,Type},Nothing}
    phi_local_wasm_type isa ConcreteRef || return nothing
    uT = tagged_union_type_for_idx(ctx, phi_local_wasm_type.type_idx)
    (uT === nothing || !(uT isa Union)) && return nothing
    vt = phi_edge_variant_julia(ctx, val)
    (vt === nothing || !(vt isa DataType) || !isconcretetype(vt)) && return nothing
    vt <: uT || return nothing
    _wt_box_type_match(julia_to_wasm_type_concrete(vt, ctx), val_wasm) || return nothing
    return (uT, vt)
end

"""
Emit bytecode to wrap a value on the stack in a tagged union struct.
Stack: [value] -> [tagged_union_struct]

The value is first converted to anyref (via extern.convert_any if needed),
then wrapped with its type tag.
"""
# MIGRATED to InstrBuilder (typed, dart2wasm-style). Consumes the value the caller left
# on the stack (seed_input!); emits a tagged-union struct. Byte-identical to before.
function emit_wrap_union_value(ctx, value_type::Type, union_type::Union)::Vector{UInt8}
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
            return UInt8[]  # Value is already a properly tagged union struct; no re-wrap needed
        end
        # Truly incompatible type (dead code path from imprecise type inference).
        # Convert to anyref and use tag 0 so compilation succeeds.
        tag = Int32(0)
    end

    b = InstrBuilder(; func_name="emit_wrap_union_value", strict=_wt_builder_strict())
    set_context!(b, "wrap $(value_type) → $(union_type)")
    # union struct layout: typeId(i32), tag(i32 mutable), value(anyref)
    union_fields = WasmValType[I32, I32, AnyRef]

    # For Nothing, we need to create a null anyref
    if value_type === Nothing
        i32_const!(b, 0)            # PURE-9024: typeId (0 placeholder)
        i32_const!(b, Int64(tag))   # tag (0 for Nothing)
        ref_null!(b, AnyRef)        # null anyref value
    else
        # Value is on stack — save it, push typeId + tag, then restore + box.
        scratch_local = length(ctx.locals) + ctx.n_params
        value_wasm_type = julia_to_wasm_type_concrete(value_type, ctx)
        push!(ctx.locals, value_wasm_type)
        seed_input!(b, WasmValType[value_wasm_type])  # caller left the value on the stack
        builder_set_local_type!(b, scratch_local, value_wasm_type)

        local_set!(b, scratch_local)
        i32_const!(b, 0)             # PURE-9024: typeId (0 placeholder)
        i32_const!(b, Int64(tag))    # tag
        local_get!(b, scratch_local) # reload value

        # Convert to anyref if needed
        if value_wasm_type === I32 || value_wasm_type === I64 || value_wasm_type === F32 || value_wasm_type === F64
            # F-i31/F31: i31ref holds only 31 bits → boxing i32/i64 via ref.i31 SILENTLY
            # TRUNCATES any value ≥ 2^30 (verified: typemax(Int64) → -1, 2^31 → 0). Box ALL
            # numerics full-width into the {typeId,value} numeric box (the same rep Loop B's
            # numeric-Union AnyRef path uses), preserving every bit. emit_unwrap_union_value
            # reads it back symmetrically. dart2wasm likewise boxes large ints (no bare i31).
            drop!(b)
            box_idx = get_numeric_box_type!(ctx.mod, ctx.type_registry, value_wasm_type)
            i32_const!(b, 0)                             # box typeId
            local_get!(b, scratch_local)
            struct_new!(b, box_idx, WasmValType[I32, value_wasm_type])
        elseif value_wasm_type === ExternRef
            any_convert_extern!(b)                       # externref → anyref
        elseif value_wasm_type isa ConcreteRef || value_wasm_type isa RefType
            # Struct/array refs are subtypes of anyref — no conversion needed
        end
    end

    # Create the tagged union struct
    struct_new!(b, union_info.wasm_type_idx, union_fields)
    return builder_code(b)
end

"""
Emit bytecode to extract a value from a tagged union struct.
Stack: [tagged_union_struct] -> [value]

Extracts the value field and casts it to the expected type.
Note: Caller should verify type via isa() first for safety.
"""
# MIGRATED to InstrBuilder (typed, dart2wasm-style). Consumes the tagged-union struct the
# caller left on the stack (seed_input!); emits the unboxed target value. Byte-identical.
function emit_unwrap_union_value(ctx, union_type::Union, target_type::Type)::Vector{UInt8}
    # Handle Nothing specially - just drop the union struct
    if target_type === Nothing
        b = InstrBuilder(; func_name="emit_unwrap_union_value", strict=_wt_builder_strict())
        seed_input!(b, WasmValType[AnyRef])  # the union struct on the stack
        drop!(b)
        return builder_code(b)
    end

    # Get the union info
    union_info = get_union_type!(ctx.mod, ctx.type_registry, union_type)

    b = InstrBuilder(; func_name="emit_unwrap_union_value", strict=_wt_builder_strict())
    set_context!(b, "unwrap $(union_type) → $(target_type)")
    seed_input!(b, WasmValType[ConcreteRef(UInt32(union_info.wasm_type_idx), true)])

    # Get the value field (PURE-9024: field 2 due to typeId at field 0)
    struct_get!(b, union_info.wasm_type_idx, 2, AnyRef)

    # Cast anyref to the target type
    target_wasm_type = julia_to_wasm_type_concrete(target_type, ctx)
    if target_wasm_type isa ConcreteRef
        # Cast anyref to concrete type using ref.cast / ref.cast_null
        ref_cast!(b, target_wasm_type.type_idx, target_wasm_type.nullable)
    elseif target_wasm_type === ArrayRef || target_wasm_type === StructRef
        # PURE-6024: cast anyref → abstract arrayref/structref (e.g. AbstractString → ArrayRef)
        ref_cast!(b, target_wasm_type, true)
    elseif target_wasm_type === I32 || target_wasm_type === I64 || target_wasm_type === F32 || target_wasm_type === F64
        # F-i31/F31: numerics are boxed FULL-WIDTH into the {typeId,value} numeric box by
        # emit_wrap_union_value (was lossy i31 for ints) — read field 1 back symmetrically.
        box_idx = get_numeric_box_type!(ctx.mod, ctx.type_registry, target_wasm_type)
        ref_cast!(b, box_idx, true)
        struct_get!(b, box_idx, 1, target_wasm_type)  # field 1 = value (0=typeId)
    end

    return builder_code(b)
end

