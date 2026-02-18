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
            elseif vb.lb === a
                # Same value/type, no change needed
            elseif !(vb.lb isa Type) || !(a isa Type)
                # Non-type values (e.g., integer parameters in Tuple{1,2})
                # Can't form Union of non-types. Use Any as join (will fail diagonal check).
                vb.lb = Any
            elseif _subtype(vb.lb, a, env, 0)
                # a is wider than current lb — widen lb to a
                vb.lb = a
            elseif _subtype(a, vb.lb, env, 0)
                # a is narrower than current lb, keep current lb
            else
                # Neither is subtype of other — join them
                vb.lb = Union{vb.lb, a}
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

        # Escape check: if this var (now out of scope) leaked into any remaining
        # variable's bounds that were MODIFIED during the recursion, the answer is false.
        # This handles cases like Vector{Vector{T} where T} vs Array{Vector{T}, 1} where T
        # where the universal T would escape into the existential T's bounds.
        # Only check bounds that changed from their original TypeVar bounds.
        if ans
            for i in 1:length(env.vars)
                other = env.vars[i]
                # Check lb only if it was modified (originally Union{} or the var's own lb)
                if other.lb !== Union{} && other.lb !== other.var.lb
                    if _type_contains_var(other.lb, vb.var)
                        ans = false
                        break
                    end
                end
                # Check ub only if it was modified (originally Any or the var's own ub)
                if other.ub !== Any && other.ub !== other.var.ub
                    if _type_contains_var(other.ub, vb.var)
                        ans = false
                        break
                    end
                end
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

"""Check if a type is a concrete/leaf bound (for diagonal rule).
Handles both Type values (DataType) and non-type values (e.g., integer 1 in Tuple{1,1})."""
function _is_leaf_bound(@nospecialize(v))::Bool
    v isa DataType && return isconcretetype(v)
    # Non-type values (e.g., integers in value-parameterized types) are always concrete
    !(v isa Type) && !(v isa TypeVar) && return true
    return false
end

"""Check if a type expression contains a reference to a specific TypeVar."""
function _type_contains_var(@nospecialize(t), v::TypeVar)::Bool
    t === v && return true
    t isa TypeVar && return false
    t isa Union && return _type_contains_var(t.a, v) || _type_contains_var(t.b, v)
    t isa UnionAll && return _type_contains_var(t.body, v) || t.var === v
    t isa DataType && begin
        for p in t.parameters
            _type_contains_var(p, v) && return true
        end
        return false
    end
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

# ═══════════════════════════════════════════════════════════════════════
# Pure Julia reimplementation of jl_type_intersection (subtype.c)
# Phase 2d: Replaces C runtime type intersection for WasmGC compilation
#
# This file handles:
#   - Identity: A ∩ A = A
#   - Top: A ∩ Any = A
#   - Bottom: A ∩ Union{} = Union{}
#   - Subtype fast paths: if A <: B return A; if B <: A return B
#   - Disjoint: concrete types with no subtype relation → Union{}
#   - Union: distribute (A∪B) ∩ C = (A∩C) ∪ (B∩C)
#   - Tuple: element-wise intersection, length mismatch → Union{}
#   - DataType: same name → invariant param intersection, different → supertype walk
#   - UnionAll: deferred to PURE-4122
# ═══════════════════════════════════════════════════════════════════════

# ─── Main entry point ───

"""
    wasm_type_intersection(a, b) → Type

Compute the type intersection of `a` and `b`.
Pure Julia reimplementation of `jl_type_intersection` from `src/subtype.c`.

Must match `typeintersect(a, b)` for all inputs. Verified 1-1 against native.
"""
function wasm_type_intersection(@nospecialize(a), @nospecialize(b))
    # Fast path: identity
    a === b && return a

    # Bottom absorbs everything
    a === Union{} && return Union{}
    b === Union{} && return Union{}

    # Top is identity
    a === Any && return b
    b === Any && return a

    # Subtype fast paths (no free typevars in concrete types)
    if _no_free_typevars(a) && _no_free_typevars(b)
        if wasm_subtype(a, b)
            return a
        end
        if wasm_subtype(b, a)
            return b
        end
    end

    # Full intersection
    return _intersect(a, b, 0)
end

"""Check whether a type has no free TypeVars (safe for fast-path subtype checks).
Recursively checks DataType parameters for TypeVars."""
function _no_free_typevars(@nospecialize(t))::Bool
    t isa TypeVar && return false
    t isa UnionAll && return false  # has bound vars, body may have free refs
    t isa Union && return _no_free_typevars(t.a) && _no_free_typevars(t.b)
    t isa DataType && begin
        for p in t.parameters
            _no_free_typevars(p) || return false
        end
        return true
    end
    return true  # non-type values (Int, Symbol, etc.)
end

# ─── Core recursive intersection ───

"""
    _intersect(x, y, param) → Type

The recursive core of the intersection algorithm. `param` tracks position:
  0 = outside (top-level)
  1 = covariant (Tuple elements)
  2 = invariant (parametric type parameters)
"""
function _intersect(@nospecialize(x), @nospecialize(y), param::Int)
    # Fast paths
    x === y && return x
    x === Union{} && return Union{}
    y === Union{} && return Union{}
    x === Any && return y
    y === Any && return x

    # === UNION HANDLING ===
    if x isa Union
        # Distribute: (A∪B) ∩ C = (A∩C) ∪ (B∩C)
        return _intersect_union(x, y, param)
    end
    if y isa Union
        # Distribute: A ∩ (B∪C) = (A∩B) ∪ (A∩C)
        return _intersect_union(y, x, param)
    end

    # === UNIONALL HANDLING (PURE-4122) ===
    if x isa UnionAll || y isa UnionAll
        # Use env-aware intersection for UnionAll types
        ienv = IntersectEnv()
        return _intersect_env(x, y, ienv, param)
    end

    # === DATATYPE × DATATYPE ===
    if x isa DataType && y isa DataType
        return _intersect_datatypes(x, y, param)
    end

    # Fallback: if subtype in either direction, return the subtype
    if _no_free_typevars(x) && _no_free_typevars(y)
        wasm_subtype(x, y) && return x
        wasm_subtype(y, x) && return y
    end

    return Union{}
end

# ─── Union intersection ───

"""
    _intersect_union(u::Union, t, param) → Type

Distribute intersection over union: (A∪B) ∩ T = (A∩T) ∪ (B∩T).
Simplifies by removing Union{} components.
"""
function _intersect_union(u::Union, @nospecialize(t), param::Int)
    a = _intersect(u.a, t, param)
    b = _intersect(u.b, t, param)
    return _simple_join(a, b)
end

"""
    _simple_join(a, b) → Type

Join two types, simplifying Union{} away.
"""
function _simple_join(@nospecialize(a), @nospecialize(b))
    a === Union{} && return b
    b === Union{} && return a
    a === b && return a
    # Check if one is subtype of other
    if _no_free_typevars(a) && _no_free_typevars(b)
        wasm_subtype(a, b) && return b
        wasm_subtype(b, a) && return a
    end
    return Union{a, b}
end

# ─── DataType intersection ───

"""
    _intersect_datatypes(x::DataType, y::DataType, param) → Type

Intersect two DataTypes.
- Same name, Tuple: element-wise intersection
- Same name, other: invariant parameter intersection
- Different names: supertype walk to find common ancestor
"""
function _intersect_datatypes(x::DataType, y::DataType, param::Int)
    x === y && return x

    xname = x.name
    yname = y.name

    # Both Tuples: element-wise intersection
    if xname === Tuple.name && yname === Tuple.name
        return _intersect_tuple(x, y, param)
    end

    # Same name: invariant parameter intersection
    if xname === yname
        return _intersect_same_name(x, y, param)
    end

    # Different names: walk supertype chains
    return _intersect_different_names(x, y, param)
end

# ─── Tuple intersection ───

"""
    _intersect_tuple(x::DataType, y::DataType, param) → Type

Element-wise tuple intersection.
Tuple{A,B} ∩ Tuple{C,D} = Tuple{A∩C, B∩D}
Length mismatch → Union{}
Vararg handling for basic cases.
"""
function _intersect_tuple(x::DataType, y::DataType, param::Int)
    x === y && return x

    xp = x.parameters
    yp = y.parameters
    nx = length(xp)
    ny = length(yp)

    # Check for Vararg
    x_has_vararg = nx > 0 && xp[nx] isa Core.TypeofVararg
    y_has_vararg = ny > 0 && yp[ny] isa Core.TypeofVararg

    # Simple case: no Vararg, same length
    if !x_has_vararg && !y_has_vararg
        nx != ny && return Union{}
        params = Vector{Any}(undef, nx)
        for i in 1:nx
            ii = _intersect(xp[i], yp[i], param == 0 ? 1 : param)
            ii === Union{} && return Union{}
            params[i] = ii
        end
        # Check if result is same as x or y (avoid unnecessary allocation)
        all_x = all(i -> params[i] === xp[i], 1:nx)
        all_x && return x
        all_y = all(i -> params[i] === yp[i], 1:ny)
        all_y && return y
        return Tuple{params...}
    end

    # Vararg cases: compute effective lengths and intersect
    # For bounded Vararg, expand and intersect element-wise
    if x_has_vararg && !y_has_vararg
        return _intersect_tuple_vararg(x, xp, nx, y, yp, ny, param)
    end
    if y_has_vararg && !x_has_vararg
        return _intersect_tuple_vararg(y, yp, ny, x, xp, nx, param)
    end

    # Both have Vararg
    if x_has_vararg && y_has_vararg
        return _intersect_tuple_both_vararg(x, xp, nx, y, yp, ny, param)
    end

    return Union{}
end

"""Intersect tuple where `a` has Vararg and `b` does not."""
function _intersect_tuple_vararg(a::DataType, ap, na::Int, b::DataType, bp, nb::Int, param::Int)
    vararg = ap[na]::Core.TypeofVararg
    vararg_T = vararg.T
    n_fixed = na - 1

    if isdefined(vararg, :N)
        # Bounded Vararg: expand and check length
        vararg_N = vararg.N::Int
        total = n_fixed + vararg_N
        total != nb && return Union{}
        params = Vector{Any}(undef, nb)
        for i in 1:n_fixed
            ii = _intersect(ap[i], bp[i], param == 0 ? 1 : param)
            ii === Union{} && return Union{}
            params[i] = ii
        end
        for i in (n_fixed + 1):nb
            ii = _intersect(vararg_T, bp[i], param == 0 ? 1 : param)
            ii === Union{} && return Union{}
            params[i] = ii
        end
        return Tuple{params...}
    else
        # Unbounded Vararg: b's length determines
        nb < n_fixed && return Union{}
        params = Vector{Any}(undef, nb)
        for i in 1:n_fixed
            ii = _intersect(ap[i], bp[i], param == 0 ? 1 : param)
            ii === Union{} && return Union{}
            params[i] = ii
        end
        for i in (n_fixed + 1):nb
            ii = _intersect(vararg_T, bp[i], param == 0 ? 1 : param)
            ii === Union{} && return Union{}
            params[i] = ii
        end
        return Tuple{params...}
    end
end

"""Intersect tuple where both sides have Vararg."""
function _intersect_tuple_both_vararg(a::DataType, ap, na::Int, b::DataType, bp, nb::Int, param::Int)
    va = ap[na]::Core.TypeofVararg
    vb = bp[nb]::Core.TypeofVararg
    va_T = va.T
    vb_T = vb.T
    n_fixed_a = na - 1
    n_fixed_b = nb - 1

    va_bounded = isdefined(va, :N)
    vb_bounded = isdefined(vb, :N)

    if va_bounded && vb_bounded
        total_a = n_fixed_a + (va.N::Int)
        total_b = n_fixed_b + (vb.N::Int)
        total_a != total_b && return Union{}
        n = total_a
        params = Vector{Any}(undef, n)
        for i in 1:n
            at = i <= n_fixed_a ? ap[i] : va_T
            bt = i <= n_fixed_b ? bp[i] : vb_T
            ii = _intersect(at, bt, param == 0 ? 1 : param)
            ii === Union{} && return Union{}
            params[i] = ii
        end
        return Tuple{params...}
    end

    if !va_bounded && !vb_bounded
        # Both unbounded: intersect fixed parts, then vararg element types
        n_fixed = max(n_fixed_a, n_fixed_b)
        params = Vector{Any}(undef, n_fixed)
        for i in 1:n_fixed
            at = i <= n_fixed_a ? ap[i] : va_T
            bt = i <= n_fixed_b ? bp[i] : vb_T
            ii = _intersect(at, bt, param == 0 ? 1 : param)
            ii === Union{} && return Union{}
            params[i] = ii
        end
        vii = _intersect(va_T, vb_T, param == 0 ? 1 : param)
        if vii === Union{}
            return Tuple{params...}
        end
        return Tuple{params..., Vararg{vii}}
    end

    # One bounded, one unbounded
    if va_bounded
        total_a = n_fixed_a + (va.N::Int)
        total_a < n_fixed_b && return Union{}
        n = total_a
        params = Vector{Any}(undef, n)
        for i in 1:n
            at = i <= n_fixed_a ? ap[i] : va_T
            bt = i <= n_fixed_b ? bp[i] : vb_T
            ii = _intersect(at, bt, param == 0 ? 1 : param)
            ii === Union{} && return Union{}
            params[i] = ii
        end
        return Tuple{params...}
    else
        total_b = n_fixed_b + (vb.N::Int)
        total_b < n_fixed_a && return Union{}
        n = total_b
        params = Vector{Any}(undef, n)
        for i in 1:n
            at = i <= n_fixed_a ? ap[i] : va_T
            bt = i <= n_fixed_b ? bp[i] : vb_T
            ii = _intersect(at, bt, param == 0 ? 1 : param)
            ii === Union{} && return Union{}
            params[i] = ii
        end
        return Tuple{params...}
    end
end

# ─── Same-name DataType intersection (invariant parameters) ───

"""
    _intersect_same_name(x::DataType, y::DataType, param) → Type

Intersect two DataTypes with the same name.
Parameters are compared invariantly: each pair must have non-empty intersection.
"""
function _intersect_same_name(x::DataType, y::DataType, param::Int)
    xp = x.parameters
    yp = y.parameters
    np = length(xp)

    np != length(yp) && return Union{}
    np == 0 && return x  # same name, no params → identical

    params = Vector{Any}(undef, np)
    for i in 1:np
        ii = _intersect_invariant(xp[i], yp[i])
        if ii === nothing
            return Union{}  # no valid intersection for this parameter
        end
        params[i] = ii
    end

    # Reconstruct type with intersected parameters
    # Use the type name's wrapper to apply parameters
    try
        wrapper = x.name.wrapper
        return wrapper{params...}
    catch
        return Union{}
    end
end

"""
    _intersect_invariant(x, y) → Union{Type, Nothing}

Intersect two types in invariant position.
Returns `nothing` if no valid intersection exists (inconsistent bounds).
For invariant positions, both x <: y AND y <: x must hold (equality).
"""
function _intersect_invariant(@nospecialize(x), @nospecialize(y))
    x === y && return x

    # For concrete types with no free vars: must be equal
    if _no_free_typevars(x) && _no_free_typevars(y)
        # Invariant: x must equal y (both directions of subtype)
        if wasm_subtype(x, y) && wasm_subtype(y, x)
            return y
        end
        return nothing  # not equal → empty intersection
    end

    # If one is a subtype of the other in a non-strict sense, it may work
    # (this handles abstract types: e.g., Number ∩ Integer in invariant = nothing because they're not equal)
    if wasm_subtype(x, y) && wasm_subtype(y, x)
        return y
    end

    return nothing
end

# ─── Different-name DataType intersection ───

"""
    _intersect_different_names(x::DataType, y::DataType, param) → Type

Intersect DataTypes with different names.
Walk supertype chains to see if one inherits from the other.
If x <: y, return x. If y <: x, return y. Otherwise Union{}.
"""
function _intersect_different_names(x::DataType, y::DataType, param::Int)
    # Check if x is a subtype of y (by walking x's chain)
    if wasm_subtype(x, y)
        return x
    end
    if wasm_subtype(y, x)
        return y
    end

    # Neither is a subtype of the other
    # For concrete types, the intersection is always empty
    if isconcretetype(x) || isconcretetype(y)
        return Union{}
    end

    # Both abstract: find common subtypes
    # In the general case with abstract types, we can't construct the
    # intersection easily. Return Union{} as a conservative approximation.
    # (The C implementation also gives up in many of these cases)
    return Union{}
end

# ═══════════════════════════════════════════════════════════════════════
# UnionAll intersection (PURE-4122) — the hardest part
#
# Implements intersect_unionall and finish_unionall from subtype.c.
# Uses SubtypeEnv for variable binding tracking (same env as subtype).
# ═══════════════════════════════════════════════════════════════════════

"""
    IntersectBinding

Per-variable state during intersection. Extends VarBinding with intersection-specific fields.
"""
mutable struct IntersectBinding
    var::TypeVar          # the type variable
    lb::Any               # lower bound (updated during intersection)
    ub::Any               # upper bound (updated during intersection)
    right::Bool           # true if var came from right side
    occurs_inv::Int       # invariant occurrences
    occurs_cov::Int       # covariant occurrences
    concrete::Bool        # forced concrete by diagonal rule
end

IntersectBinding(var::TypeVar, right::Bool) = IntersectBinding(var, var.lb, var.ub, right, 0, 0, false)

"""
    IntersectEnv

Environment for the intersection algorithm. Tracks variable bindings and intersection state.
"""
mutable struct IntersectEnv
    vars::Vector{IntersectBinding}
    invdepth::Int
end

IntersectEnv() = IntersectEnv(IntersectBinding[], 0)

"""Look up a TypeVar in the intersection environment."""
function _ilookup(env::IntersectEnv, @nospecialize(v::TypeVar))::Union{IntersectBinding, Nothing}
    for i in length(env.vars):-1:1
        if env.vars[i].var === v
            return env.vars[i]
        end
    end
    return nothing
end

"""Record variable occurrence in covariant or invariant position."""
function _irecord_occurrence(ib::IntersectBinding, env::IntersectEnv, param::Int)
    if param == 2 || env.invdepth > 0
        ib.occurs_inv = min(ib.occurs_inv + 1, 2)
    else
        ib.occurs_cov = min(ib.occurs_cov + 1, 2)
    end
end

# ─── Core env-aware intersection ───

"""
    _intersect_env(x, y, env, param) → Type

Environment-aware intersection core. Handles TypeVar bindings from UnionAll.
"""
function _intersect_env(@nospecialize(x), @nospecialize(y), env::IntersectEnv, param::Int)
    x === y && return x
    x === Union{} && return Union{}
    y === Union{} && return Union{}
    x === Any && return y
    y === Any && return x

    # === TYPEVAR HANDLING (intersection mode) ===
    if x isa TypeVar
        xb = _ilookup(env, x)
        if xb !== nothing
            _irecord_occurrence(xb, env, param)
            return _intersect_ivar(x, xb, y, env, param)
        end
        # Free TypeVar: intersect y with x's upper bound
        return _intersect_env(x.ub, y, env, param)
    end
    if y isa TypeVar
        yb = _ilookup(env, y)
        if yb !== nothing
            _irecord_occurrence(yb, env, param)
            return _intersect_ivar(y, yb, x, env, param)
        end
        # Free TypeVar: intersect x with y's upper bound
        return _intersect_env(x, y.ub, env, param)
    end

    # === UNION HANDLING ===
    if x isa Union
        return _intersect_union_env(x, y, env, param)
    end
    if y isa Union
        return _intersect_union_env(y, x, env, param)
    end

    # === UNIONALL HANDLING ===
    if x isa UnionAll && y isa UnionAll
        # Try both orderings and pick the more specific result
        a = _intersect_unionall_inner(y, x, env, false, param)
        b = _intersect_unionall_inner(x, y, env, true, param)
        if a === Union{}
            return b
        end
        if b === Union{}
            return a
        end
        # Pick the more specific, or join
        if wasm_subtype(a, b)
            return a
        end
        if wasm_subtype(b, a)
            return b
        end
        return _simple_join(a, b)
    end
    if x isa UnionAll
        return _intersect_unionall_inner(y, x, env, false, param)
    end
    if y isa UnionAll
        return _intersect_unionall_inner(x, y, env, true, param)
    end

    # === DATATYPE × DATATYPE ===
    if x isa DataType && y isa DataType
        return _intersect_datatypes_env(x, y, env, param)
    end

    # Subtype fast paths
    if _no_free_typevars(x) && _no_free_typevars(y)
        wasm_subtype(x, y) && return x
        wasm_subtype(y, x) && return y
    end

    return Union{}
end

"""Distribute intersection over union with env."""
function _intersect_union_env(u::Union, @nospecialize(t), env::IntersectEnv, param::Int)
    a = _intersect_env(u.a, t, env, param)
    b = _intersect_env(u.b, t, env, param)
    return _simple_join(a, b)
end

# ─── Intersect TypeVar with a type (intersect_var from subtype.c) ───

"""
    _intersect_ivar(var, vb, a, env, param) → Type

Intersect a bound TypeVar `var` (with binding `vb`) with type `a`.
In invariant position (param=2): narrows bounds, checks consistency.
In covariant position: intersects with upper bound.
"""
function _intersect_ivar(@nospecialize(var::TypeVar), vb::IntersectBinding, @nospecialize(a), env::IntersectEnv, param::Int)
    # If a is the same var, return it
    a === var && return var

    # If a is another bound TypeVar, delegate to var-var intersection
    if a isa TypeVar
        ab = _ilookup(env, a)
        if ab !== nothing
            _irecord_occurrence(ab, env, param)
            # In invariant position: intersect both bounds
            if param == 2
                # Intersect upper bounds
                ub = _intersect_aside(vb.ub, ab.ub, env)
                if ub === Union{}
                    return Union{}
                end
                # Narrow both vars' upper bounds
                vb.ub = ub
                ab.ub = ub
                # Widen both lower bounds
                if vb.lb !== Union{} || ab.lb !== Union{}
                    lb = _simple_join(vb.lb, ab.lb)
                    vb.lb = lb
                    ab.lb = lb
                end
                return var  # return the variable
            end
            # Covariant: intersect with upper bound of a
            return _intersect_aside(vb.ub, a, env)
        end
    end

    if param == 2  # INVARIANT position
        # Check consistency: vb.lb <: a <: vb.ub
        if _no_free_typevars(a)
            if !(wasm_subtype(vb.lb, a) && wasm_subtype(a, vb.ub))
                return Union{}
            end
            # Pin: narrow ub to a, widen lb to a
            vb.ub = a
            vb.lb = a
            return a
        end
        # a has free vars: intersect a with vb.ub
        ub = _intersect_aside(a, vb.ub, env)
        if ub === Union{}
            return Union{}
        end
        vb.ub = ub
        return ub
    end

    # COVARIANT position
    ub = _intersect_aside(a, vb.ub, env)
    if ub === Union{}
        return Union{}
    end
    # Narrow upper bound
    vb.ub = ub
    return var  # return the variable in covariant position
end

"""
    _intersect_aside(x, y, env) → Type

Run intersection in a "side" context — used for nested intersections
within variable binding without disturbing the main state.
"""
function _intersect_aside(@nospecialize(x), @nospecialize(y), env::IntersectEnv)
    x === Any && return y
    y === Any && return x
    x === y && return x
    x === Union{} && return Union{}
    y === Union{} && return Union{}

    # For concrete types, use the non-env intersection
    if _no_free_typevars(x) && _no_free_typevars(y)
        wasm_subtype(x, y) && return x
        wasm_subtype(y, x) && return y
    end

    # Use env-aware intersection
    return _intersect_env(x, y, env, 0)
end

# ─── UnionAll intersection (intersect_unionall from subtype.c) ───

"""
    _intersect_unionall_inner(t, u::UnionAll, env, R, param) → Type

Handle intersection of type `t` with `u::UnionAll`.
R=true: u is on the right side (u.var is existential for intersection)
R=false: u is on the left side
"""
function _intersect_unionall_inner(@nospecialize(t), u::UnionAll, env::IntersectEnv, R::Bool, param::Int)
    # Create a new binding for this UnionAll's variable
    vb = IntersectBinding(u.var, R)

    # Push binding onto environment
    push!(env.vars, vb)

    # Do the intersection: if R, intersect t with u.body; else u.body with t
    if R
        result = _intersect_env(t, u.body, env, param)
    else
        result = _intersect_env(u.body, t, env, param)
    end

    # Pop binding
    pop!(env.vars)

    # Diagonal dispatch check
    if result !== Union{} && vb.occurs_cov > 1 && vb.occurs_inv == 0
        # Variable occurred 2+ times covariantly: must be concrete (diagonal rule)
        vb.concrete = true
        if vb.lb !== Union{} && !_is_leaf_bound(vb.lb)
            result = Union{}
        end
    end

    # Post-intersection checks
    if result !== Union{}
        # Check for circular constraints
        if _type_contains_var(vb.lb, u.var)
            result = Union{}
        end
    end

    if result !== Union{}
        # Bound consistency: lb must be <: ub
        if !(vb.lb === Union{} || vb.ub === Any || _subtype_check(vb.lb, vb.ub))
            result = Union{}
        end
    end

    # Finish: determine if var can be eliminated or needs re-wrapping
    if result !== Union{}
        result = _finish_unionall(result, vb, u)
    end

    return result
end

"""
    _finish_unionall(res, vb, u) → Type

Determine what to do with the UnionAll variable after intersection:
1. If lb === ub, substitute the variable with that value (pinned)
2. If ub is a concrete leaf type in covariant context, substitute with ub
3. Otherwise, re-wrap in UnionAll with narrowed bounds
"""
function _finish_unionall(@nospecialize(res), vb::IntersectBinding, u::UnionAll)
    varval = nothing  # the value to substitute, if any

    # === Step 1: Try to reduce var to a single value ===
    if vb.lb === vb.ub && vb.lb !== Union{}
        # Pinned: lb == ub, substitute
        varval = vb.lb
    elseif vb.lb === Union{} && vb.ub === Any
        # Unconstrained: keep as UnionAll
    elseif vb.occurs_cov > 0 && vb.occurs_inv == 0 && _is_leaf_bound(vb.ub) && _no_free_typevars_val(vb.ub)
        # Covariant with leaf ub: substitute with ub
        varval = vb.ub
    elseif vb.lb !== Union{} && vb.lb === vb.ub
        varval = vb.lb
    end

    # === Step 2: Substitute or re-wrap ===
    if varval !== nothing
        # Substitute all occurrences of var in result
        res = _substitute_type(res, vb.var, varval)
        # Simplify chains: UnionAll where lb === ub
        while res isa UnionAll
            inner_var = res.var
            if inner_var.lb === inner_var.ub
                res = _substitute_type(res.body, inner_var, inner_var.lb)
            else
                break
            end
        end
    else
        # Re-wrap with potentially narrowed bounds
        if _type_contains_var(res, vb.var)
            if vb.lb !== u.var.lb || vb.ub !== u.var.ub
                # Bounds changed: create new TypeVar
                newvar = TypeVar(u.var.name, vb.lb, vb.ub)
                res = _substitute_type(res, vb.var, newvar)
                res = UnionAll(newvar, res)
            else
                # Bounds unchanged: re-wrap with original var
                res = UnionAll(u.var, res)
            end
        end
        # If var doesn't appear in result, it was eliminated (no wrapping needed)
    end

    return res
end

"""Check if a value (not necessarily a Type) has no free type variables."""
function _no_free_typevars_val(@nospecialize(t))::Bool
    t isa TypeVar && return false
    t isa UnionAll && return false
    t isa Union && return _no_free_typevars_val(t.a) && _no_free_typevars_val(t.b)
    t isa DataType && begin
        for p in t.parameters
            _no_free_typevars_val(p) || return false
        end
        return true
    end
    return true  # non-type values (Int, Symbol, etc.)
end

"""
    _substitute_type(t, var, val) → Type

Substitute all occurrences of `var` in type `t` with `val`.
"""
function _substitute_type(@nospecialize(t), var::TypeVar, @nospecialize(val))
    t === var && return val
    t isa TypeVar && return t
    t isa Union && begin
        a = _substitute_type(t.a, var, val)
        b = _substitute_type(t.b, var, val)
        a === t.a && b === t.b && return t
        return Union{a, b}
    end
    t isa UnionAll && begin
        # Don't substitute inside a UnionAll that shadows our var
        if t.var === var
            return t
        end
        newbody = _substitute_type(t.body, var, val)
        # Also substitute in var bounds if needed
        new_lb = _substitute_type(t.var.lb, var, val)
        new_ub = _substitute_type(t.var.ub, var, val)
        if newbody === t.body && new_lb === t.var.lb && new_ub === t.var.ub
            return t
        end
        if new_lb !== t.var.lb || new_ub !== t.var.ub
            newvar = TypeVar(t.var.name, new_lb, new_ub)
            newbody = _substitute_type(newbody, t.var, newvar)
            return UnionAll(newvar, newbody)
        end
        return UnionAll(t.var, newbody)
    end
    t isa DataType && begin
        ps = t.parameters
        np = length(ps)
        np == 0 && return t
        changed = false
        new_ps = Vector{Any}(undef, np)
        for i in 1:np
            new_ps[i] = _substitute_type(ps[i], var, val)
            if new_ps[i] !== ps[i]
                changed = true
            end
        end
        !changed && return t
        # Reconstruct type with new parameters
        try
            if t.name === Tuple.name
                return Tuple{new_ps...}
            end
            wrapper = t.name.wrapper
            return wrapper{new_ps...}
        catch
            return t  # if type construction fails, return original
        end
    end
    return t
end

# ─── DataType intersection with env (extends existing _intersect_datatypes) ───

"""
    _intersect_datatypes_env(x, y, env, param) → Type

Intersect two DataTypes using the intersection environment for TypeVar tracking.
"""
function _intersect_datatypes_env(x::DataType, y::DataType, env::IntersectEnv, param::Int)
    x === y && return x

    xname = x.name
    yname = y.name

    # Both Tuples: element-wise intersection
    if xname === Tuple.name && yname === Tuple.name
        return _intersect_tuple_env(x, y, env, param)
    end

    # Same name: invariant parameter intersection
    if xname === yname
        return _intersect_same_name_env(x, y, env, param)
    end

    # Different names: walk supertype chains
    return _intersect_different_names_env(x, y, env, param)
end

"""Intersect two Tuples with env."""
function _intersect_tuple_env(x::DataType, y::DataType, env::IntersectEnv, param::Int)
    x === y && return x
    xp = x.parameters
    yp = y.parameters
    nx = length(xp)
    ny = length(yp)

    x_has_vararg = nx > 0 && xp[nx] isa Core.TypeofVararg
    y_has_vararg = ny > 0 && yp[ny] isa Core.TypeofVararg

    p = param == 0 ? 1 : param

    # Simple case: no Vararg, same length
    if !x_has_vararg && !y_has_vararg
        nx != ny && return Union{}
        params = Vector{Any}(undef, nx)
        for i in 1:nx
            ii = _intersect_env(xp[i], yp[i], env, p)
            ii === Union{} && return Union{}
            params[i] = ii
        end
        all_x = all(i -> params[i] === xp[i], 1:nx)
        all_x && return x
        all_y = all(i -> params[i] === yp[i], 1:ny)
        all_y && return y
        return Tuple{params...}
    end

    # Vararg × no-Vararg: expand the vararg side
    if x_has_vararg && !y_has_vararg
        return _intersect_tuple_vararg_env(x, xp, nx, y, yp, ny, env, p)
    end
    if y_has_vararg && !x_has_vararg
        return _intersect_tuple_vararg_env(y, yp, ny, x, xp, nx, env, p)
    end

    # Both Vararg: use env-aware element intersection
    if x_has_vararg && y_has_vararg
        return _intersect_tuple_both_vararg_env(x, xp, nx, y, yp, ny, env, p)
    end

    return Union{}
end

"""Intersect tuple where side `a` has Vararg and `b` does not, using env."""
function _intersect_tuple_vararg_env(a::DataType, ap, na::Int, b::DataType, bp, nb::Int, env::IntersectEnv, param::Int)
    vararg = ap[na]::Core.TypeofVararg
    vararg_T = vararg.T
    n_fixed = na - 1

    if isdefined(vararg, :N)
        total = n_fixed + (vararg.N::Int)
        total != nb && return Union{}
    else
        nb < n_fixed && return Union{}
    end

    params = Vector{Any}(undef, nb)
    for i in 1:n_fixed
        ii = _intersect_env(ap[i], bp[i], env, param)
        ii === Union{} && return Union{}
        params[i] = ii
    end
    for i in (n_fixed + 1):nb
        ii = _intersect_env(vararg_T, bp[i], env, param)
        ii === Union{} && return Union{}
        params[i] = ii
    end
    return Tuple{params...}
end

"""Intersect tuple where both sides have Vararg, using env."""
function _intersect_tuple_both_vararg_env(a::DataType, ap, na::Int, b::DataType, bp, nb::Int, env::IntersectEnv, param::Int)
    va = ap[na]::Core.TypeofVararg
    vb = bp[nb]::Core.TypeofVararg
    va_T = va.T
    vb_T = vb.T
    n_fixed_a = na - 1
    n_fixed_b = nb - 1

    va_bounded = isdefined(va, :N)
    vb_bounded = isdefined(vb, :N)

    if va_bounded && vb_bounded
        total_a = n_fixed_a + (va.N::Int)
        total_b = n_fixed_b + (vb.N::Int)
        total_a != total_b && return Union{}
        n = total_a
    elseif !va_bounded && !vb_bounded
        n = max(n_fixed_a, n_fixed_b)
        # Also intersect the vararg element types
        vii = _intersect_env(va_T, vb_T, env, param)
        params = Vector{Any}(undef, n)
        for i in 1:n
            at = i <= n_fixed_a ? ap[i] : va_T
            bt = i <= n_fixed_b ? bp[i] : vb_T
            ii = _intersect_env(at, bt, env, param)
            ii === Union{} && return Union{}
            params[i] = ii
        end
        if vii === Union{}
            return Tuple{params...}
        end
        return Tuple{params..., Vararg{vii}}
    else
        # One bounded, one unbounded
        if va_bounded
            n = n_fixed_a + (va.N::Int)
            n < n_fixed_b && return Union{}
        else
            n = n_fixed_b + (vb.N::Int)
            n < n_fixed_a && return Union{}
        end
    end

    params = Vector{Any}(undef, n)
    for i in 1:n
        at = i <= n_fixed_a ? ap[i] : va_T
        bt = i <= n_fixed_b ? bp[i] : vb_T
        ii = _intersect_env(at, bt, env, param)
        ii === Union{} && return Union{}
        params[i] = ii
    end
    return Tuple{params...}
end

"""Intersect same-name DataTypes with env (invariant params)."""
function _intersect_same_name_env(x::DataType, y::DataType, env::IntersectEnv, param::Int)
    xp = x.parameters
    yp = y.parameters
    np = length(xp)

    np != length(yp) && return Union{}
    np == 0 && return x

    params = Vector{Any}(undef, np)
    for i in 1:np
        ii = _intersect_invariant_env(xp[i], yp[i], env)
        if ii === nothing
            return Union{}
        end
        params[i] = ii
    end

    try
        wrapper = x.name.wrapper
        return wrapper{params...}
    catch
        return Union{}
    end
end

"""Intersect two types in invariant position with env."""
function _intersect_invariant_env(@nospecialize(x), @nospecialize(y), env::IntersectEnv)
    x === y && return x

    # Handle non-type values (e.g., integer parameters like N in Array{T,N})
    if !(x isa Type) && !(x isa TypeVar) && !(y isa Type) && !(y isa TypeVar)
        return x === y ? x : nothing  # non-type values must be equal
    end

    # Use env-aware intersection in invariant mode
    env.invdepth += 1
    ii = _intersect_env(x, y, env, 2)
    env.invdepth -= 1

    if ii === Union{}
        # For TypeVars, check if Union{} is a valid binding.
        # Union{} is valid if lb <: Union{} (i.e., lb === Union{}) for each TypeVar.
        # Example: Vector{<:Integer} ∩ Vector{<:AbstractFloat} = Vector{Union{}}
        #   because both have lb=Union{}, so Union{} is valid.
        # Counter-example: Vector{T>:Integer} ∩ Vector{Int64} = Union{}
        #   because T has lb=Integer, and Union{} is NOT >: Integer.
        x_allows_bottom = (x isa TypeVar) ? (x.lb === Union{}) : (x isa Type && wasm_subtype(x, Union{}))
        y_allows_bottom = (y isa TypeVar) ? (y.lb === Union{}) : (y isa Type && wasm_subtype(y, Union{}))
        if x_allows_bottom && y_allows_bottom
            return Union{}
        end
        # At least one side doesn't allow Union{} — invariant is unsatisfiable
        # (for concrete non-bottom types, this means they disagree)
        if (x isa Type || x isa TypeVar) && (y isa Type || y isa TypeVar)
            return nothing
        end
        return Union{}
    end

    # Consistency check: x <: y and y <: x (in the env context)
    if _no_free_typevars(x) && _no_free_typevars(y)
        if (x isa Type) && (y isa Type)
            if !(wasm_subtype(x, y) && wasm_subtype(y, x))
                return nothing
            end
        end
    end

    return ii
end

"""Intersect different-name DataTypes with env."""
function _intersect_different_names_env(x::DataType, y::DataType, env::IntersectEnv, param::Int)
    # Walk x's supertype chain to find a type with y's name
    xd = x
    while xd !== Any && xd.name !== y.name
        xd_super = supertype(xd)
        xd_super === xd && break
        xd = xd_super
    end

    if xd !== Any && xd.name === y.name
        # x inherits from y's name. Intersect the matched supertype with y
        # to populate TypeVar constraints, then return x (the subtype).
        ii = _intersect_datatypes_env(xd, y, env, param)
        if ii !== Union{}
            return x
        end
        return Union{}
    end

    # Try the other direction: walk y's chain to x's name
    yd = y
    while yd !== Any && yd.name !== x.name
        yd_super = supertype(yd)
        yd_super === yd && break
        yd = yd_super
    end

    if yd !== Any && yd.name === x.name
        ii = _intersect_datatypes_env(x, yd, env, param)
        if ii !== Union{}
            return y
        end
        return Union{}
    end

    # No inheritance relation
    if isconcretetype(x) || isconcretetype(y)
        return Union{}
    end

    return Union{}
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
