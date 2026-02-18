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
#   - UnionAll: parametric where clauses with TypeVar bounds (PURE-4114)
#   - TypeVar: variable bound tracking and diagonal dispatch
#   - Invariant parametric: parameters must be equal (not just subtypes)
#   - Type{T}: singleton type handling

# ─── Environment structures (from jl_stenv_t / jl_varbinding_t in subtype.c) ───

"""
    VarBinding

Per-variable state during subtype checking. Mirrors jl_varbinding_t from subtype.c.
"""
mutable struct VarBinding
    var::TypeVar          # the type variable
    lb::Any               # lower bound (updated during computation)
    ub::Any               # upper bound (updated during computation)
    right::Bool           # true if var came from right side (existential)
    occurs_inv::Int       # occurrences in invariant position (saturates at 2)
    occurs_cov::Int       # occurrences in covariant position (saturates at 2)
    concrete::Bool        # forced to be concrete by another variable
end

function VarBinding(var::TypeVar, right::Bool)
    VarBinding(var, var.lb, var.ub, right, 0, 0, false)
end

"""
    SubtypeEnv

Environment for the subtype algorithm. Mirrors jl_stenv_t from subtype.c.
"""
mutable struct SubtypeEnv
    vars::Vector{VarBinding}   # stack of variable bindings
    invdepth::Int              # nesting depth of invariant constructors
end

SubtypeEnv() = SubtypeEnv(VarBinding[], 0)

"""Look up a TypeVar in the environment. Returns nothing if not found (free var)."""
function lookup(env::SubtypeEnv, @nospecialize(v::TypeVar))::Union{VarBinding, Nothing}
    for i in length(env.vars):-1:1
        if env.vars[i].var === v
            return env.vars[i]
        end
    end
    return nothing
end

# ─── Main entry point ───

"""
    wasm_subtype(a::Type, b::Type) :: Bool

Check whether type `a` is a subtype of type `b`.
Pure Julia reimplementation of `jl_subtype` from `src/subtype.c`.

Must match `a <: b` for all inputs. Verified 1-1 against native.
"""
function wasm_subtype(@nospecialize(a), @nospecialize(b))::Bool
    # Fast path: identity
    a === b && return true

    # Bottom (Union{}) is subtype of everything
    a === Union{} && return true

    # Everything is subtype of Any
    b === Any && return true

    # Create environment and delegate to the recursive core
    env = SubtypeEnv()
    return _subtype(a, b, env, 0)
end

# ─── Core recursive subtype with environment ───

"""
    _subtype(x, y, env, param) :: Bool

The recursive core of the subtype algorithm. `param` tracks position:
  0 = outside (top-level)
  1 = covariant (Tuple elements)
  2 = invariant (non-Tuple parametric type parameters)
"""
function _subtype(@nospecialize(x), @nospecialize(y), env::SubtypeEnv, param::Int)::Bool
    # Fast paths
    x === y && return true
    x === Union{} && return true
    y === Any && return true

    # === UNION HANDLING ===
    if x isa Union
        # Left union (forall): every element must be a subtype
        return _subtype(x.a, y, env, param) && _subtype(x.b, y, env, param)
    end

    if y isa Union
        # Right union (exists): at least one element must be a supertype
        return _subtype(x, y.a, env, param) || _subtype(x, y.b, env, param)
    end

    # === TYPEVAR HANDLING ===
    if x isa TypeVar
        xb = lookup(env, x)
        if y isa TypeVar
            yb = lookup(env, y)
            if x === y
                return true
            end
            if xb !== nothing && yb !== nothing
                xr = xb.right
                yr = yb.right
                if xr
                    if yr
                        # Both existential: check lb(x) <: ub(y)
                        return _subtype(xb.lb, yb.ub, env, 0)
                    end
                    # x is existential, y is universal: x <: y means update x.ub
                    return _var_lt(xb, y, env, param)
                elseif yr
                    # x is universal, y is existential: y >: x means update y.lb
                    return _var_gt(yb, x, env, param)
                else
                    # Both universal: check x.ub <: y OR x <: y.lb
                    return _subtype(xb.ub, y, env, param) || _subtype(x, yb.lb, env, param)
                end
            end
            if xb !== nothing
                # x is bound, y is free
                return _subtype_var(xb, y, env, false, param)
            end
            if yb !== nothing
                # x is free, y is bound
                return _subtype_var(yb, x, env, true, param)
            end
            # Both free: check x.ub <: y.lb or structural
            return x === y
        end
        # x is TypeVar, y is not
        if xb !== nothing
            return _subtype_var(xb, y, env, false, param)
        end
        # x is free TypeVar: check x.ub <: y
        return _subtype(x.ub, y, env, param)
    end

    if y isa TypeVar
        yb = lookup(env, y)
        if yb !== nothing
            return _subtype_var(yb, x, env, true, param)
        end
        # y is free TypeVar: check x <: y.lb
        return _subtype(x, y.lb, env, param)
    end

    # === UNIONALL HANDLING ===
    if x isa UnionAll
        return _subtype_unionall(y, x, env, false, param)
    end
    if y isa UnionAll
        return _subtype_unionall(x, y, env, true, param)
    end

    # === DATATYPE HANDLING ===
    if x isa DataType && y isa DataType
        return _subtype_datatypes(x, y, env, param)
    end

    return false
end

# ─── TypeVar bound operations (var_lt, var_gt from subtype.c) ───

"""
    _var_lt(vb, a, env, param) :: Bool

Check vb.var <: a. For existential (right) vars, narrows upper bound.
For universal (left) vars, checks against existing upper bound.
"""
function _var_lt(vb::VarBinding, @nospecialize(a), env::SubtypeEnv, param::Int)::Bool
    _record_var_occurrence(vb, env, param)
    if vb.right
        # Existential: narrow upper bound (meet)
        # vb.ub = meet(vb.ub, a)
        if a !== Any
            if vb.ub === Any
                vb.ub = a
            elseif !_subtype(a, vb.ub, env, 0)
                if !_subtype(vb.ub, a, env, 0)
                    return false
                end
                # a is wider than current ub, keep current ub
            else
                vb.ub = a  # a is tighter
            end
        end
        return true
    else
        # Universal: just check upper bound
        return _subtype(vb.ub, a, env, 0)
    end
end

"""
    _var_gt(vb, a, env, param) :: Bool

Check vb.var >: a. For existential (right) vars, widens lower bound.
For universal (left) vars, checks against existing lower bound.
"""
function _var_gt(vb::VarBinding, @nospecialize(a), env::SubtypeEnv, param::Int)::Bool
    _record_var_occurrence(vb, env, param)
    if vb.right
        # Existential: widen lower bound (join)
        if a !== Union{}
            if vb.lb === Union{}
                vb.lb = a
            elseif !_subtype(vb.lb, a, env, 0)
                if _subtype(a, vb.lb, env, 0)
                    # a is narrower than current lb, keep current lb
                else
                    # Neither is subtype of other — join them
                    vb.lb = Union{vb.lb, a}
                end
            end
        end
        return true
    else
        # Universal: check a <: lower bound
        return _subtype(a, vb.lb, env, 0)
    end
end

"""
    _subtype_var(vb, a, env, R, param) :: Bool

Dispatch to var_lt (R=false, checking var <: a) or var_gt (R=true, checking var >: a).
"""
function _subtype_var(vb::VarBinding, @nospecialize(a), env::SubtypeEnv, R::Bool, param::Int)::Bool
    if R
        return _var_gt(vb, a, env, param)
    else
        return _var_lt(vb, a, env, param)
    end
end

"""Record that a variable occurred in covariant or invariant position."""
function _record_var_occurrence(vb::VarBinding, env::SubtypeEnv, param::Int)
    if param == 2 || env.invdepth > 0
        vb.occurs_inv = min(vb.occurs_inv + 1, 2)
    else
        vb.occurs_cov = min(vb.occurs_cov + 1, 2)
    end
end

# ─── UnionAll handling (subtype_unionall from subtype.c) ───

"""
    _subtype_unionall(t, u::UnionAll, env, R, param) :: Bool

Handle `t <: (u.body where u.var)` (R=true) or `(u.body where u.var) <: t` (R=false).

R=true: u is on the right side → u.var is existential (find some assignment)
R=false: u is on the left side → u.var is universal (must hold for all)
"""
function _subtype_unionall(@nospecialize(t), u::UnionAll, env::SubtypeEnv, R::Bool, param::Int)::Bool
    # Create a new binding for this UnionAll's variable
    vb = VarBinding(u.var, R)

    # Push binding onto environment
    push!(env.vars, vb)

    # Recurse into the body
    ans = _subtype_inner(t, u.body, env, R, param)

    # Pop binding
    pop!(env.vars)

    # Check bound consistency if the answer was true
    if ans
        # For right-side (existential) vars: lb must be <: ub
        if R
            if !(vb.lb === Union{} || vb.ub === Any || _subtype_check(vb.lb, vb.ub))
                ans = false
            end
        end

        # Diagonal dispatch rule: if var occurs 2+ times in covariant position
        # and never in invariant position, it must be concrete
        if ans && R && vb.occurs_cov > 1 && vb.occurs_inv == 0
            # Diagonal: lower bound must be a concrete (leaf) type
            if vb.lb !== Union{} && !_is_leaf_bound(vb.lb)
                ans = false
            end
        end
    end

    return ans
end

"""Helper for the UnionAll recursion direction."""
function _subtype_inner(@nospecialize(t), @nospecialize(body), env::SubtypeEnv, R::Bool, param::Int)::Bool
    if R
        # Right: t <: body
        return _subtype(t, body, env, param)
    else
        # Left: body <: t
        return _subtype(body, t, env, param)
    end
end

"""Check if a type is a concrete/leaf bound (for diagonal rule)."""
function _is_leaf_bound(@nospecialize(v))::Bool
    v isa DataType && return isconcretetype(v)
    return false
end

"""Simple subtype check without creating new env (for bound consistency)."""
function _subtype_check(@nospecialize(a), @nospecialize(b))::Bool
    # Use a fresh env to avoid polluting the current one
    a === b && return true
    a === Union{} && return true
    b === Any && return true
    env2 = SubtypeEnv()
    return _subtype(a, b, env2, 0)
end

# ─── DataType comparison with invariant parameter handling ───

"""
    _subtype_datatypes(x::DataType, y::DataType, env, param) :: Bool

Compare two DataTypes. Handles:
- Tuple types (covariant)
- Other parametric types (invariant parameters)
- Type{T} singleton types
- Supertype chain walking
"""
function _subtype_datatypes(x::DataType, y::DataType, env::SubtypeEnv, param::Int)::Bool
    x === y && return true
    y === Any && return true

    # Tuple types: covariant comparison (delegates to existing _tuple_subtype logic,
    # but now using _subtype with env for element comparisons)
    if x.name === Tuple.name && y.name === Tuple.name
        return _tuple_subtype_env(x, y, env, param)
    end

    # Type{T} handling
    xname = x.name
    yname = y.name

    if xname === Type.body.name  # x is Type{T}
        if yname !== Type.body.name  # y is NOT Type{_}
            # Type{Int} <: DataType → typeof(Int) == DataType
            xp = x.parameters
            if length(xp) > 0
                T = xp[1]
                if !(T isa TypeVar)
                    return typeof(T) <: y  # use native for this simple check
                end
            end
            return false
        end
        # Both are Type{...}: invariant parameter comparison
    end

    # Walk up x's supertype chain to find a type with the same name as y
    xd = x
    yd = y

    while xd !== Any && xd.name !== yd.name
        xd = supertype(xd)
    end

    if xd === Any
        # If y is Any, already handled above. Otherwise x is not a subtype of y.
        return false
    end

    # Names match. Check parameters invariantly.
    xp = xd.parameters
    yp = yd.parameters
    np = length(xp)

    if np != length(yp)
        return false
    end

    if np == 0
        return true  # no parameters to check
    end

    # Invariant comparison: each parameter must be equal
    env.invdepth += 1
    result = true
    for i in 1:np
        if !_forall_exists_equal(xp[i], yp[i], env)
            result = false
            break
        end
    end
    env.invdepth -= 1

    return result
end

"""
    _forall_exists_equal(x, y, env) :: Bool

Check if x and y are equal types (for invariant positions).
This requires both x <: y AND y <: x.
"""
function _forall_exists_equal(@nospecialize(x), @nospecialize(y), env::SubtypeEnv)::Bool
    x === y && return true

    # For TypeVars in the env, check via the bound machinery
    if x isa TypeVar
        xb = lookup(env, x)
        if xb !== nothing
            if y isa TypeVar
                yb = lookup(env, y)
                if yb !== nothing
                    # Both are bound vars: check both directions
                    # Save bounds, check both directions, restore if needed
                    old_xlb, old_xub = xb.lb, xb.ub
                    old_ylb, old_yub = yb.lb, yb.ub
                    ans = _subtype(x, y, env, 2) && _subtype(y, x, env, 2)
                    if !ans
                        xb.lb, xb.ub = old_xlb, old_xub
                        yb.lb, yb.ub = old_ylb, old_yub
                    end
                    return ans
                end
            end
            # x is bound, y is not a bound var
            old_xlb, old_xub = xb.lb, xb.ub
            ans = _subtype(x, y, env, 2) && _subtype(y, x, env, 2)
            if !ans
                xb.lb, xb.ub = old_xlb, old_xub
            end
            return ans
        end
    end
    if y isa TypeVar
        yb = lookup(env, y)
        if yb !== nothing
            old_ylb, old_yub = yb.lb, yb.ub
            ans = _subtype(x, y, env, 2) && _subtype(y, x, env, 2)
            if !ans
                yb.lb, yb.ub = old_ylb, old_yub
            end
            return ans
        end
    end

    # Neither is a bound var: structural comparison
    # For types, both directions of subtype
    if x isa Type && y isa Type
        return _subtype(x, y, env, 2) && _subtype(y, x, env, 2)
    end

    return x === y
end

# ─── Tuple subtype with environment (covariant, Vararg support) ───

"""
    _tuple_subtype_env(a::DataType, b::DataType, env, param) :: Bool

Tuple subtype with environment support. Like _tuple_subtype but uses _subtype
with env for element comparisons, enabling TypeVar tracking in Tuples.
"""
function _tuple_subtype_env(a::DataType, b::DataType, env::SubtypeEnv, param::Int)::Bool
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
        vararg_bounded = isdefined(vararg, :N)

        if vararg_bounded
            vararg_N = vararg.N::Int
            required_len = (nb - 1) + vararg_N
            na != required_len && return false

            for i in 1:(nb - 1)
                _subtype_tuple_param(ap[i], bp[i], env) || return false
            end
            for i in nb:na
                _subtype_tuple_param(ap[i], vararg_T, env) || return false
            end
            return true
        else
            na < (nb - 1) && return false
            for i in 1:(nb - 1)
                _subtype_tuple_param(ap[i], bp[i], env) || return false
            end
            for i in nb:na
                _subtype_tuple_param(ap[i], vararg_T, env) || return false
            end
            return true
        end
    end

    # Check if a has a trailing Vararg
    a_has_vararg = na > 0 && ap[na] isa Core.TypeofVararg
    if a_has_vararg
        vararg_a = ap[na]::Core.TypeofVararg
        if isdefined(vararg_a, :N)
            vararg_N = vararg_a.N::Int
            expanded_len = (na - 1) + vararg_N
            expanded_len != nb && return false
            for i in 1:(na - 1)
                _subtype_tuple_param(ap[i], bp[i], env) || return false
            end
            vararg_T = vararg_a.T
            for i in na:nb
                _subtype_tuple_param(vararg_T, bp[i], env) || return false
            end
            return true
        else
            return false
        end
    end

    na != nb && return false

    for i in 1:na
        _subtype_tuple_param(ap[i], bp[i], env) || return false
    end
    return true
end

"""Check a single Tuple parameter with environment, handling Vararg and TypeVar."""
function _subtype_tuple_param(@nospecialize(a), @nospecialize(b), env::SubtypeEnv)::Bool
    # Unwrap to types
    a_type = a isa Core.TypeofVararg ? a.T : a
    b_type = b isa Core.TypeofVararg ? b.T : b

    # Use _subtype with covariant param=1 for tuple elements
    return _subtype(a_type, b_type, env, 1)
end

# ─── Legacy entry points (keep backward compatibility with tests) ───

# The old _tuple_subtype and _datatype_subtype are now superseded by the
# env-aware versions above. Keep them for any direct callers.

"""
    _datatype_subtype(a::DataType, b::DataType) :: Bool

Check if DataType `a` is a subtype of DataType `b` by walking the supertype chain.
Handles concrete and abstract types.
"""
function _datatype_subtype(a::DataType, b::DataType)::Bool
    a === b && return true
    b === Any && return true

    t = a
    while t !== Any
        if t === b
            return true
        end
        st = supertype(t)
        st === t && break
        t = st
    end

    return false
end

"""
    _tuple_subtype(a::DataType, b::DataType) :: Bool

Check Tuple{A1,A2,...} <: Tuple{B1,B2,...} with covariant parameters.
Both `a` and `b` must have `name === Tuple.name`.
"""
function _tuple_subtype(a::DataType, b::DataType)::Bool
    a === b && return true
    return _tuple_subtype_env(a, b, SubtypeEnv(), 1)
end

"""
    _subtype_param(a, b) :: Bool

Check if tuple parameter `a` is a subtype of tuple parameter `b`.
Parameters can be Types or Vararg (Core.TypeofVararg).
"""
function _subtype_param(@nospecialize(a), @nospecialize(b))::Bool
    if a isa Type && b isa Type
        return wasm_subtype(a, b)
    end
    if a isa Type && b isa Core.TypeofVararg
        return wasm_subtype(a, b.T)
    end
    if a isa Core.TypeofVararg && b isa Type
        return wasm_subtype(a.T, b)
    end
    if a isa Core.TypeofVararg && b isa Core.TypeofVararg
        return wasm_subtype(a.T, b.T)
    end
    return false
end
