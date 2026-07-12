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
    # SSA that has Nothing type or is an exact alias of the `nothing` binding.
    # Inference may retain a surrounding Union at a phi edge, so the statement
    # itself is authoritative evidence that this particular edge is null.
    if val isa Core.SSAValue
        ssa_type = get(ctx.ssa_types, val.id, Any)
        ssa_type === Nothing && return true
        if 1 <= val.id <= length(ctx.code_info.code)
            stmt = ctx.code_info.code[val.id]
            (stmt isa GlobalRef && stmt.name === :nothing) && return true
            if stmt isa Core.PiNode
                stmt.typ === Nothing && return true
                return is_nothing_value(stmt.val, ctx)
            end
        end
    end
    return false
end

# M3 (dart2wasm parity): the tagged-union wrapper family is DELETED — needs_tagged_union
# (≡ false since U2), emit_wrap_union_value, emit_unwrap_union_value. A Union value is JUST an
# AnyRef discriminated by classId: numerics ride THE classId box (emit_classid_box!/unbox!,
# translator.dart:854-870), object refs pass through with their own field-0 classId. All
# boundary coercion goes through convert_type! (the ONE funnel). This file keeps only the
# nullable-union helpers + is_nothing_value.
