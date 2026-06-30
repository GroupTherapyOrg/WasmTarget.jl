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
    # B4/U2 — dart2wasm parity: there is NO tagged-union wrapper. A Union value is JUST a
    # boxed AnyRef discriminated by classId (the canonical classId box for numerics, the
    # struct ref directly for objects). The {typeId,tag,value} 3-field wrapper + per-union
    # tag scheme is RETIRED — every former wrapper site now routes through emit_wrap/
    # unwrap_union_value (box/unbox via the classId box) + the AnyRef isa path (classId read).
    return false
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
    # B4/U2 — dart2wasm parity (translator.dart:854-862 convertType): a Union value is JUST a
    # boxed ref discriminated by classId — NO wrapper struct, NO tag, NO double-box. Box the
    # variant value to an AnyRef: numerics → the canonical classId box (emit_classid_box!,
    # real classId for concrete variants); struct/array refs pass through (already anyref
    # subtypes, discriminated by their own field-0 classId); Nothing → ref.null.
    b = InstrBuilder(; func_name="emit_wrap_union_value", strict=_wt_builder_strict(), mod=ctx.mod)
    set_context!(b, "wrap $(value_type) → $(union_type)")
    if value_type === Nothing
        ref_null!(b, AnyRef)
        return builder_code(b)
    end
    # The value is already on the stack (caller left it).
    if value_type isa Union && value_type <: union_type
        return UInt8[]   # already a boxed union value (anyref) — no re-wrap
    end
    value_wasm_type = julia_to_wasm_type_concrete(value_type, ctx)
    seed_input!(b, WasmValType[value_wasm_type])
    if value_wasm_type === I32 || value_wasm_type === I64 || value_wasm_type === F32 || value_wasm_type === F64
        emit_classid_box!(b, ctx, value_wasm_type, isconcretetype(value_type) ? value_type : nothing)
    elseif value_wasm_type === ExternRef
        any_convert_extern!(b)                       # externref → anyref
    # else: struct/array ConcreteRef/RefType — already an anyref subtype, pass through as-is.
    end
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
    # B4/U2 — dart2wasm parity (translator.dart:863-870 convertType unbox): the union value
    # IS the boxed AnyRef (no wrapper). Numerics → unbox the classId box (ref.cast box;
    # struct.get value); struct/array refs → ref.cast to target; Nothing → drop.
    b = InstrBuilder(; func_name="emit_unwrap_union_value", strict=_wt_builder_strict(), mod=ctx.mod)
    set_context!(b, "unwrap $(union_type) → $(target_type)")
    if target_type === Nothing
        seed_input!(b, WasmValType[AnyRef]); drop!(b)
        return builder_code(b)
    end
    seed_input!(b, WasmValType[AnyRef])   # the boxed union value (was the wrapper struct)
    target_wasm_type = julia_to_wasm_type_concrete(target_type, ctx)
    if target_wasm_type === I32 || target_wasm_type === I64 || target_wasm_type === F32 || target_wasm_type === F64
        emit_classid_unbox!(b, ctx, target_wasm_type)
    elseif target_wasm_type isa ConcreteRef
        ref_cast!(b, target_wasm_type.type_idx, target_wasm_type.nullable)
    elseif target_wasm_type === ArrayRef || target_wasm_type === StructRef
        ref_cast!(b, target_wasm_type, true)
    end
    return builder_code(b)
end

