# Pure Julia reimplementation of jl_subtype (subtype.c)
# Phase 2d: Replaces C runtime subtype check for WasmGC compilation
#
# This file handles:
#   - Identity: T <: T
#   - Bottom: Union{} <: T (always true)
#   - Top: T <: Any (always true)
#   - Union: Union{A,B} <: C iff A <: C && B <: C; A <: Union{B,C} iff A <: B || A <: C
#   - Tuple: covariant element-wise, with Vararg support (PURE-4112)
#   - Concrete <: Abstract: walk supertype chain
#   - DataType comparisons
#
# UnionAll handling is added in PURE-4114.

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

    # Tuple subtype: covariant element-wise with Vararg support
    if a isa DataType && b isa DataType
        if a.name === Tuple.name && b.name === Tuple.name
            return _tuple_subtype(a, b)
        end
        # Non-Tuple DataType: walk supertype chain of a to find b
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

"""
    _tuple_subtype(a::DataType, b::DataType) :: Bool

Check Tuple{A1,A2,...} <: Tuple{B1,B2,...} with covariant parameters.
Both `a` and `b` must have `name === Tuple.name`.

Rules:
- Covariant: Tuple{A,B} <: Tuple{C,D} iff A <: C && B <: D
- Length must match exactly, UNLESS `b` has a trailing Vararg
- Vararg{T}: matches 0 or more elements, each must be <: T
- Vararg{T,N}: matches exactly N elements, each must be <: T
- Tuple === Tuple{Vararg{Any}}: the bare Tuple type
"""
function _tuple_subtype(a::DataType, b::DataType)::Bool
    # Identity fast path
    a === b && return true

    ap = a.parameters
    bp = b.parameters
    na = length(ap)
    nb = length(bp)

    # Check if b has a trailing Vararg
    b_has_vararg = nb > 0 && bp[nb] isa Core.TypeofVararg

    if b_has_vararg
        vararg = bp[nb]::Core.TypeofVararg
        vararg_T = vararg.T
        # Check if Vararg has a fixed count N
        vararg_bounded = isdefined(vararg, :N)

        if vararg_bounded
            # Vararg{T, N}: b expects exactly (nb-1) fixed params + N vararg elements
            vararg_N = vararg.N::Int
            required_len = (nb - 1) + vararg_N
            na != required_len && return false

            # Check fixed params (indices 1..nb-1)
            for i in 1:(nb - 1)
                _subtype_param(ap[i], bp[i]) || return false
            end
            # Check vararg elements (indices nb..na)
            for i in nb:na
                _subtype_param(ap[i], vararg_T) || return false
            end
            return true
        else
            # Unbounded Vararg{T}: b expects (nb-1) fixed params + 0 or more vararg elements
            # a must have at least (nb-1) elements
            na < (nb - 1) && return false

            # Check fixed params (indices 1..nb-1)
            for i in 1:(nb - 1)
                _subtype_param(ap[i], bp[i]) || return false
            end
            # Check remaining a elements against vararg_T
            for i in nb:na
                _subtype_param(ap[i], vararg_T) || return false
            end
            return true
        end
    end

    # Check if a has a trailing Vararg (a has Vararg, b doesn't)
    a_has_vararg = na > 0 && ap[na] isa Core.TypeofVararg
    if a_has_vararg
        # Tuple{X, Vararg{Y}} <: Tuple{A,B,C} — a has vararg, b doesn't
        # This can only be true if a's vararg expands to exactly match b's length
        # But with unbounded Vararg, a represents multiple lengths → not a subtype of fixed-length b
        # Exception: bounded Vararg{T,N} where (na-1)+N == nb
        vararg_a = ap[na]::Core.TypeofVararg
        if isdefined(vararg_a, :N)
            vararg_N = vararg_a.N::Int
            expanded_len = (na - 1) + vararg_N
            expanded_len != nb && return false
            # Check fixed params
            for i in 1:(na - 1)
                _subtype_param(ap[i], bp[i]) || return false
            end
            vararg_T = vararg_a.T
            for i in na:nb
                _subtype_param(vararg_T, bp[i]) || return false
            end
            return true
        else
            # Unbounded Vararg on left, no Vararg on right → false
            # (a represents infinitely many tuple lengths, b is one fixed length)
            return false
        end
    end

    # No Vararg on either side: lengths must match exactly
    na != nb && return false

    # Covariant element-wise check
    for i in 1:na
        _subtype_param(ap[i], bp[i]) || return false
    end
    return true
end

"""
    _subtype_param(a, b) :: Bool

Check if tuple parameter `a` is a subtype of tuple parameter `b`.
Parameters can be Types or Vararg (Core.TypeofVararg).
"""
function _subtype_param(@nospecialize(a), @nospecialize(b))::Bool
    # Both are regular types: use wasm_subtype
    if a isa Type && b isa Type
        return wasm_subtype(a, b)
    end
    # If b is a Type but a is not (shouldn't happen for well-formed Tuples after Vararg handling)
    # If a is a Type and b is TypeofVararg, check a <: b.T
    if a isa Type && b isa Core.TypeofVararg
        return wasm_subtype(a, b.T)
    end
    # a is Vararg, b is Type: Vararg{T} <: S iff T <: S
    # (a Vararg parameter in a can match against b's vararg element type)
    if a isa Core.TypeofVararg && b isa Type
        return wasm_subtype(a.T, b)
    end
    # Both Vararg: check element types
    if a isa Core.TypeofVararg && b isa Core.TypeofVararg
        return wasm_subtype(a.T, b.T)
    end
    return false
end
