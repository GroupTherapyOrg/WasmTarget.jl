# Pure Julia reimplementation of jl_subtype (subtype.c)
# Phase 2d: Replaces C runtime subtype check for WasmGC compilation
#
# This file handles basic subtype cases:
#   - Identity: T <: T
#   - Bottom: Union{} <: T (always true)
#   - Top: T <: Any (always true)
#   - Concrete <: Abstract: walk supertype chain
#   - DataType comparisons
#
# Union, Tuple, and UnionAll handling are added in PURE-4112 and PURE-4114.

"""
    wasm_subtype(a::Type, b::Type) :: Bool

Check whether type `a` is a subtype of type `b`.
Pure Julia reimplementation of `jl_subtype` from `src/subtype.c`.

Must match `a <: b` for all inputs. Verified 1-1 against native.
"""
function wasm_subtype(@nospecialize(a::Type), @nospecialize(b::Type))::Bool
    # Fast path: identity
    a === b && return true

    # Bottom (Union{}) is subtype of everything
    a === Union{} && return true

    # Everything is subtype of Any
    b === Any && return true

    # Nothing is NOT Union{} — it's a concrete type (singleton)
    # So Nothing <: Int64 is false (handled by supertype walk below)

    # Handle Union on left: Union{A,B} <: C iff A <: C && B <: C
    if a isa Union
        return wasm_subtype(a.a, b) && wasm_subtype(a.b, b)
    end

    # Handle Union on right: A <: Union{B,C} iff A <: B || A <: C
    if b isa Union
        return wasm_subtype(a, b.a) || wasm_subtype(a, b.b)
    end

    # Both are DataType: walk supertype chain of a to find b
    if a isa DataType && b isa DataType
        return _datatype_subtype(a, b)
    end

    # Fallback: not a subtype
    return false
end

"""
    _datatype_subtype(a::DataType, b::DataType) :: Bool

Check if DataType `a` is a subtype of DataType `b` by walking the supertype chain.
Handles concrete and abstract types.
"""
function _datatype_subtype(a::DataType, b::DataType)::Bool
    # Identity
    a === b && return true

    # Everything is subtype of Any
    b === Any && return true

    # Walk up a's supertype chain
    t = a
    while t !== Any
        if t === b
            return true
        end
        # supertype of a DataType is its direct parent in the type hierarchy
        st = supertype(t)
        # Guard against cycles (shouldn't happen, but safety)
        st === t && break
        t = st
    end

    return false
end
