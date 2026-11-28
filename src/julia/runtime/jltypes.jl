# Julia's UnionAll constructor (julia/src/jltypes.c:907 jl_type_unionall), the foreign call Julia's inliner makes of
# every UnionAll(v, t) whose v is a TypeVar (Compiler/src/ssair/inlining.jl:1745), ported over WasmTarget's type
# values: its entry, jl_type_unionall, is in src/julia/runtime/rtutils.jl's section of Julia's runtime, which the
# code generator calls for that foreign call (src/intrinsics.jl), and its parts are here. A value that is neither a type nor a type variable raises Julia's TypeError, `T where T<:S` is
# S, a body in which the variable does not occur is the body itself, and a body that mentions it a new UnionAll,
# each Julia's own answer. A type value's kind is read by its tag (jl_typetagis) and its parts by its kind's fields
# (src/julia/classes.jl _kind_instance_fields), as the runtime's type code reads them (src/runtime/common/type.jl).
# The new UnionAll (:950 jl_new_struct) is allocated at run time (jl_new_unionall), its nullability Julia's
# `Nothing <: U` (jl_unionall_nothing_subtype) and its egal Julia's structural egal_types (julia/src/builtins.c:167,
# jl_egal_types, which the egal arm calls for two UnionAlls through jl_egal_unionall). A Vararg is a value of no
# class of a closed world (src/julia/classes.jl type_value_unmade), so the C's Vararg arms meet none. precedent(dart: sdk/lib/_internal/wasm/common/type.dart:930
# _TypeUniverse.substituteTypeArgument makes a generic function type, a binder with its type parameters' bounds, at
# run time, `_FunctionType(...)`, compared by its structural == (:464)). Julia's differs: its UnionAll binds one
# variable, and its egal of two UnionAlls compares them up to renaming of that variable, its name kept.

"""
    jl_has_bound_typevars(t, v, shadowed) -> Bool

Whether the type variable `v` occurs free in `t` (julia/src/jltypes.c:220 jl_has_bound_typevars over the
environment {v} jl_has_typevar gives it): a type variable is `v` itself, unless a UnionAll binding `v` encloses it
(the C's environment rebinds `v` to itself there, typeenv_has_ne, read here as `shadowed`); a UnionAll's bounds are
walked outside its binder, its body inside; a DataType's parameters, each value; a Union's members; a Vararg's N
and T where defined; any other value holds none. A DataType's parameters are walked whatever its
hasfreetypevars, the C's shortcut, a field WasmTarget's DataType value does not hold (a parameter with no free
variable has no free `v`). Past the UnionAll loop a type variable reaches no arm and answers false, as the C's.

formal(dev/formal/HasBoundTypevars.tla): the walk answers whether v occurs free, over every term two levels deep
"""
@quarantine pin"julia/src/jltypes.c:220 jl_has_bound_typevars" "Julia's runtime tests whether a type mentions a type variable bound by an environment, walking the type's parts; jl_has_typevar's environment holds one variable" Core.TypeVar function jl_has_bound_typevars(@nospecialize(t::Any), v::TypeVar, shadowed::Bool)::Bool
    while true
        jl_typetagis(t, TypeVar) && return !shadowed && t === v
        while jl_typetagis(t, UnionAll)
            local ua = Runtime.unsafe_cast(UnionAll, t)
            local var = ua.var
            var.lb !== Union{} && jl_has_bound_typevars(var.lb, v, shadowed) && return true
            var.ub !== Any && jl_has_bound_typevars(var.ub, v, shadowed) && return true
            # Temporarily remove this var from env if necessary (the C's newenv binding it to itself)
            var === v && !shadowed && (shadowed = true)
            t = ua.body
        end
        if jl_typetagis(t, DataType)
            local ps = Runtime.unsafe_cast(DataType, t).parameters
            for i in 1:length(ps)
                jl_has_bound_typevars(ps[i], v, shadowed) && return true
            end
            return false
        elseif jl_typetagis(t, Union)
            local u = Runtime.unsafe_cast(Union, t)
            jl_has_bound_typevars(u.a, v, shadowed) && return true
            t = u.b
        else
            # any other value holds none; a Vararg (the C's last arm, its T and N) is a value of no class of a
            # closed world (src/julia/classes.jl type_value_unmade refuses a type holding one), so none is met
            return false
        end
    end
end

# jl_has_typevar (julia/src/jltypes.c:273): whether `v` occurs free in `t`, the environment {v}
@quarantine pin"julia/src/jltypes.c:273 jl_has_typevar" "Julia's runtime tests whether a type mentions a type variable by jl_has_bound_typevars over the environment holding it alone" Core.TypeVar jl_has_typevar(@nospecialize(t::Any), v::TypeVar)::Bool =
    jl_has_bound_typevars(t, v, false)

"""
    jl_new_unionall(v, body, nullable) -> UnionAll

The new UnionAll jl_type_unionall makes where its body mentions `v` (julia/src/jltypes.c:950,
jl_new_struct(jl_unionall_type, v, body)): natively the runtime's own allocation (its call reaches :950, every
earlier arm answered before), in a module the allocation of the UnionAll class's struct (src/intrinsics.jl, the
new_unionall arm), its `var` and `body` Julia's fields and its isDeclaredNullable, the field every kind's layout
holds before Julia's (src/julia/classes.jl _kind_instance_fields), `nullable`: Julia's `Nothing <: U`
(jl_unionall_nothing_subtype), as a constant's is (src/constants.jl, encoded_nullability). Its `===` is Julia's
structural egal of two UnionAlls (jl_egal_unionall), its typeof the UnionAll kind.
"""
@quarantine pin"julia/src/jltypes.c:907 jl_type_unionall" "Julia's runtime makes a new UnionAll where jl_type_unionall's body mentions its variable; in a module the UnionAll class's struct is allocated, as Julia's jl_new_struct allocates jl_unionall_type's" Core.UnionAll @noinline jl_new_unionall(v::TypeVar, @nospecialize(body::Any), nullable::Bool)::UnionAll =
    ccall(:jl_type_unionall, Any, (Any, Any), v, body)::UnionAll

"""
    jl_unionall_nothing_subtype(v, body) -> Bool

Julia's `Nothing <: (body where v)` (julia/src/subtype.c:1419 subtype, the UnionAll on the right an existential
variable, :831 var_gt), the made UnionAll's isDeclaredNullable, over the positions where Nothing can meet the
type: a DataType holds Nothing exactly where it is Nothing or Any (Nothing's supertypes), Union{} never, a Union
where either member does (each branch its own environment), a UnionAll on the right by its body with its variable
existential. An existential variable `w` holds Nothing where var_gt's checks pass: Nothing <: w.ub (subtype_ccheck)
and, at the variable's exit, its lower bound joined with Nothing below its upper bound, which for a lower bound
Union{} or Nothing is Nothing <: w.ub again; a variable no UnionAll of the walk binds is var_gt's free arm,
subtype_left_var(Nothing, w.lb). The two arms that need Julia's full subtyping, an existential variable's other
lower bound and a free variable's lower bound, are the fatal gap, named (jl_nothing_subtype_var_gap).
"""
@quarantine pin"julia/src/subtype.c:831 var_gt" "Julia's subtyping of Nothing against a UnionAll answers each position by its kind, a variable on the right existential; WasmTarget ports that question alone, the made UnionAll's nullability" Core.TypeVar jl_unionall_nothing_subtype(v::TypeVar, @nospecialize(body::Any))::Bool =
    jl_nothing_subtype(body, Core.svec(v, nothing))

# the walk: `bound` the existential variables of the enclosing UnionAlls, a chain svec(var, outer) innermost first
@quarantine pin"julia/src/subtype.c:1419 subtype" "Julia's subtyping of Nothing answers a Union by either member and a UnionAll on the right by its body, its variable existential" Core.TypeVar function jl_nothing_subtype(@nospecialize(x::Any), @nospecialize(bound::Any))::Bool
    if jl_typetagis(x, DataType)
        local d = Runtime.unsafe_cast(DataType, x)
        return d === Nothing || d === Any
    elseif jl_typetagis(x, Union)
        local u = Runtime.unsafe_cast(Union, x)
        return jl_nothing_subtype(u.a, bound) || jl_nothing_subtype(u.b, bound)
    elseif jl_typetagis(x, UnionAll)
        local ua = Runtime.unsafe_cast(UnionAll, x)
        return jl_nothing_subtype(ua.body, Core.svec(ua.var, bound))
    elseif jl_typetagis(x, TypeVar)
        local w = Runtime.unsafe_cast(TypeVar, x)
        local e = bound
        while e !== nothing
            local pair = Runtime.unsafe_cast(Core.SimpleVector, e)
            if pair[1] === w
                local lb = w.lb
                return lb === Union{} || lb === Nothing ? jl_nothing_subtype(w.ub, bound) : jl_nothing_subtype_var_gap(w, true)
            end
            e = pair[2]
        end
        return jl_nothing_subtype_var_gap(w, false)
    end
    # Union{}, and no other value is a type
    return false
end

"""
    jl_nothing_subtype_var_gap(w, existential) -> Bool

The arms of `Nothing <: w` that need Julia's full subtyping (julia/src/subtype.c:831 var_gt): an existential
variable whose lower bound is neither Union{} nor Nothing (its exit's lb <: ub), and a free variable
(subtype_left_var(Nothing, w.lb)). Natively Julia's answer; in a module the fatal gap, named (src/intrinsics.jl).
"""
@quarantine pin"julia/src/subtype.c:831 var_gt" "Julia's subtyping of Nothing against a type variable needs its bounds' subtyping, which the runtime does not port: natively Julia's answer, in a module the fatal gap" Core.TypeVar @noinline jl_nothing_subtype_var_gap(w::TypeVar, existential::Bool)::Bool =
    existential ? (Nothing <: w.ub && w.lb <: w.ub) : Nothing <: w.lb

"""
    jl_egal_types(a, b, env, tvar_names) -> Bool

Julia's egal of two types (julia/src/builtins.c:167 egal_types), which jl_egal answers two UnionAlls by
(jl_egal__bitstag's jl_unionall_tag arm, egal_types(a, b, NULL, 1)): two values of one type tag; two DataTypes
by identity, else by their TypeName (jl_datatype_same_name) and their parameters; a type variable by the
environment, the variable the other side's enclosing UnionAll binds at the same place (`env` a chain
svec(var, val, outer) innermost first), an unbound one only itself; two UnionAlls by their variables' names
(tvar_names), their bounds, and their bodies with the variables paired; two Unions by their members; any other
value by jl_egal (a Vararg, egal_types' last arm, is a value of no class of a closed world). Identity is tested per kind (a DataType's and a type
variable's `===` a reference compare), so no comparison here calls jl_egal on two type values again.

formal(dev/formal/TypesEgal.tla): the walk answers Julia's egal of two types, up to renaming of bound variables
"""
@quarantine pin"julia/src/builtins.c:167 egal_types" "Julia's egal of two types compares them structurally, a type variable by the environment of the UnionAlls enclosing it" Core.UnionAll function jl_egal_types(@nospecialize(a::Any), @nospecialize(b::Any), @nospecialize(env::Any), tvar_names::Bool)::Bool
    local ta = typeof(a)
    ta === typeof(b) || return false
    if ta === DataType
        local da = Runtime.unsafe_cast(DataType, a)
        local db = Runtime.unsafe_cast(DataType, b)
        da === db && return true
        jl_datatype_same_name(da, db) || return false
        local pa = da.parameters
        local pb = db.parameters
        length(pa) == length(pb) || return false
        for i in 1:length(pa)
            jl_egal_types(pa[i], pb[i], env, tvar_names) || return false
        end
        return true
    elseif ta === TypeVar
        local va = Runtime.unsafe_cast(TypeVar, a)
        local vb = Runtime.unsafe_cast(TypeVar, b)
        va === vb && return true
        local pe = env
        while pe !== nothing
            local entry = Runtime.unsafe_cast(Core.SimpleVector, pe)
            entry[1] === va && return entry[2] === vb
            pe = entry[3]
        end
        return false
    elseif ta === UnionAll
        local ua = Runtime.unsafe_cast(UnionAll, a)
        local ub = Runtime.unsafe_cast(UnionAll, b)
        tvar_names && ua.var.name !== ub.var.name && return false
        jl_egal_types(ua.var.lb, ub.var.lb, env, tvar_names) && jl_egal_types(ua.var.ub, ub.var.ub, env, tvar_names) || return false
        return jl_egal_types(ua.body, ub.body, Core.svec(ua.var, ub.var, env), tvar_names)
    elseif ta === Union
        local xa = Runtime.unsafe_cast(Union, a)
        local xb = Runtime.unsafe_cast(Union, b)
        return jl_egal_types(xa.a, xb.a, env, tvar_names) && jl_egal_types(xa.b, xb.b, env, tvar_names)
    end
    # jl_egal__bitstag: any other value, by Julia's egal of its class. egal_types' Vararg arm (builtins.c:212) has no
    # counterpart: a Vararg is a value of no class of a closed world (src/julia/classes.jl type_value_unmade refuses
    # a type holding one, Core.TypeofVararg), so none reaches run time
    return wasm_egal(a, b)
end

"""
    jl_datatype_same_name(a, b) -> Bool

Whether two DataTypes share their TypeName (`dta->name == dtb->name`, julia/src/builtins.c:177): natively their
`name` fields, in a module the closed world's table of each class's TypeName, indexed by the class id each
DataType value holds (src/intrinsics.jl, the datatype_same_name arm), since a DataType value's layout holds no
TypeName (src/julia/classes.jl _kind_instance_fields).
"""
@quarantine pin"julia/src/builtins.c:167 egal_types" "Julia compares two DataTypes' TypeNames; a WasmTarget DataType value holds its class id, the closed world's table maps each class id to its TypeName's index" Core.DataType @noinline jl_datatype_same_name(a::DataType, b::DataType)::Bool =
    a.name === b.name

# Julia's `body where v` (julia/src/jltypes.c:907 jl_type_unionall), the foreign call Julia's inliner makes of every
# UnionAll(v, t) whose v is a TypeVar (Compiler/src/ssair/inlining.jl:1745), which the code generator calls for it
# (src/intrinsics.jl), arm for arm: a value that is neither a type nor a type variable, Julia's TypeError("UnionAll",
# Type, body) (jl_type_error); `v` itself, `T where T<:S` normalized to its upper bound; a body in which `v` does not
# occur (src/julia/runtime/jltypes.jl jl_has_typevar), the body itself; else a new UnionAll (jl_new_unionall), its
# nullability Julia's `Nothing <: U` (jl_unionall_nothing_subtype). The C's first arm, a Vararg wrapped directly
# (:909), meets none: a Vararg is a value of no class of a closed world (src/julia/classes.jl type_value_unmade). In
# a closed world exactly where a statement of the program holds that foreign call (src/julia/subset.jl
# reached_runtime_ports), as dart's runtime member is compiled where the program reaches it
@quarantine pin"julia/src/jltypes.c:907 jl_type_unionall" "Julia's runtime wraps a type in a UnionAll over a type variable, normalizing the forms that need no new object" Core.UnionAll @noinline function jl_type_unionall(v::TypeVar, @nospecialize(body::Any))::Any
    jl_typetagis(body, Type) || jl_typetagis(body, TypeVar) || jl_type_error(:UnionAll, Type, body)
    # normalize `T where T<:S` => S
    body === v && return v.ub
    # where var doesn't occur in body just return body
    jl_has_typevar(body, v) || return body
    return jl_new_unionall(v, body, jl_unionall_nothing_subtype(v, body))::UnionAll
end

# Julia's egal of two UnionAlls (julia/src/builtins.c jl_egal__bitstag's jl_unionall_tag arm, egal_types(a, b,
# NULL, 1)), which the egal arm calls for two values of the UnionAll class, jl_type_unionall making one at run time
# (src/julia/runtime/jltypes.jl jl_new_unionall, jl_egal_types). In a closed world exactly where jl_type_unionall is,
# the one maker of a UnionAll at run time (src/julia/subset.jl reached_runtime_ports); elsewhere every UnionAll is one
# canonical constant and the egal arm's reference compare is Julia's answer
@quarantine pin"julia/src/builtins.c:167 egal_types" "Julia's runtime compares two UnionAlls structurally, egal_types with their variables' names" Core.UnionAll @noinline jl_egal_unionall(@nospecialize(a::Any), @nospecialize(b::Any))::Bool =
    jl_egal_types(a::UnionAll, b::UnionAll, nothing, true)

"""
    jl_type_identity_premise(d) -> Bool

Whether every DataType equal to `d` is `d` itself (src/julia/classes.jl types_equal_identity_premise): natively that
function, Julia's answer, in a module the closed world's table of each class's answer, indexed by the class id a
DataType value holds (src/intrinsics.jl, the type_identity_premise arm), as jl_datatype_same_name reads its TypeName's.
"""
@quarantine pin"julia/src/subtype.c:436 obviously_unequal" "Julia decides two types' equality by identity where obviously_unequal answers; a WasmTarget DataType value holds its class id, the closed world's table maps each class id to its premise" Core.DataType @noinline jl_type_identity_premise(d::DataType)::Bool =
    types_equal_identity_premise(d)

"""
    jl_types_equal_gap(a, b) -> Int32

The pairs of types whose equality Julia answers by its subtyping (julia/src/subtype.c:2353 jl_types_equal's
forall_exists_equal): natively Julia's answer, in a module the fatal gap, named (src/intrinsics.jl), never a value.
"""
@quarantine pin"julia/src/subtype.c:2353 jl_types_equal" "Julia answers the remaining pairs' equality by subtyping, which the runtime does not port: natively Julia's answer, in a module the fatal gap" Core.Type @noinline jl_types_equal_gap(@nospecialize(a::Any), @nospecialize(b::Any))::Int32 =
    ccall(:jl_types_equal, Cint, (Any, Any), a::Type, b::Type)

# Julia's type equality (julia/src/subtype.c:2353 jl_types_equal), Base's == of two types, where no key the
# compile-time cache splits answers (src/julia/classes.jl types_equal_cache, nothing): Julia's own first answers,
# identity (`a == b`), and obviously_unequal's where it decides by identity, two DataTypes one of which has the
# identity premise (types_equal_identity_premise, read by the class id the DataType value holds,
# jl_type_identity_premise), and Union{}, a singleton, equal to itself alone. Any other pair needs Julia's
# subtyping (its forall_exists_equal), the fatal gap, named (jl_types_equal_gap). The answer is the declared Cint.
# In a closed world where a statement of the program is the foreign call jl_types_equal (src/julia/subset.jl
# reached_runtime_ports), which the types_equal arm calls where no key splits the operands
@quarantine pin"julia/src/subtype.c:2353 jl_types_equal" "Julia's runtime answers two types' equality by identity first and by obviously_unequal where it decides, the rest by subtyping, which WasmGC has no runtime for" Core.DataType @noinline function jl_types_equal(@nospecialize(a::Any), @nospecialize(b::Any))::Int32
    local ta = typeof(a)
    local tb = typeof(b)
    if ta === DataType && tb === DataType
        local da = Runtime.unsafe_cast(DataType, a)
        local db = Runtime.unsafe_cast(DataType, b)
        da === db && return Int32(1)
        (jl_type_identity_premise(da) || jl_type_identity_premise(db)) && return Int32(0)
    elseif ta === Core.TypeofBottom || tb === Core.TypeofBottom
        # Union{}, one object: equal to itself alone, and unequal to a DataType of the premise (obviously_unequal's
        # `b == jl_bottom_type` against a DataType, subtype.c:451)
        ta === tb && return Int32(1)
        ta === DataType && jl_type_identity_premise(Runtime.unsafe_cast(DataType, a)) && return Int32(0)
        tb === DataType && jl_type_identity_premise(Runtime.unsafe_cast(DataType, b)) && return Int32(0)
    end
    return jl_types_equal_gap(a, b)
end

"""
    jl_type_hash(v) -> UInt

Julia's hash of a type (julia/src/jltypes.c:1779 jl_type_hash, type_hash at :1742 with `failed` 0), Base's
`_jl_type_hash` (julia/base/hashing.jl:32), the foreign call jl_type_hash: a UnionAll by its body unwrapped; a
DataType its stored hash (`dt->hash`), and where that is 0 the 0 type_hash returns as it sets `failed`; a type
variable its upper bound's; a Union the 0 type_hash returns as it sets `failed`. The DataType's stored hash is read
from the closed world's table by the class id the DataType value holds (jl_datatype_hash_of), the compiling process's
hash (src/julia/runtime/hashing.jl datatype_hash's reading). Its last arm, jl_object_id of any other value, which
Union{} alone reaches, is the gap, named (jl_type_hash_gap): Union{}'s object id is a type value's, which the runtime
does not port (src/julia/runtime/hashing.jl jl_object_id). In a closed world where
a statement of the program is the foreign call jl_type_hash (src/julia/subset.jl reached_runtime_ports), which the
code generator lowers to a call of this port (src/intrinsics.jl, the type_hash arm).
"""
@quarantine pin"julia/src/jltypes.c:1779 jl_type_hash" "Julia's runtime hashes a type by its DataType's stored hash, a Union as failed, any other value by its object id" Core.DataType @noinline function jl_type_hash(@nospecialize(v::Any))::UInt
    local uw = v
    while typeof(uw) === UnionAll
        uw = Runtime.unsafe_cast(UnionAll, uw).body
    end
    local tu = typeof(uw)
    tu === DataType && return UInt(jl_datatype_hash_of(Runtime.unsafe_cast(DataType, uw)))
    tu === TypeVar && return jl_type_hash(Runtime.unsafe_cast(TypeVar, uw).ub)
    tu === Union && return UInt(0)
    # Union{}, jl_type_hash's last arm, its jl_object_id: the gap, named (jl_type_hash_gap)
    return jl_type_hash_gap(v)
end

"""
    jl_datatype_hash_of(d) -> UInt32

A DataType's stored hash (julia/src/julia.h jl_datatype_t's `hash`): in a module the closed world's table of each
class's hash, the compiling process's (src/julia/runtime/hashing.jl datatype_hash), indexed by the class id a
DataType value holds (src/intrinsics.jl, the datatype_hash_of arm); natively the field itself.
"""
@quarantine pin"julia/src/jltypes.c:1742 type_hash" "Julia reads a DataType's stored hash; a WasmTarget DataType value holds its class id, the closed world's table maps each class id to its hash" Core.DataType @noinline jl_datatype_hash_of(d::DataType)::UInt32 =
    reinterpret(UInt32, getfield(d, :hash))

"""
    jl_type_hash_gap(v) -> UInt

jl_type_hash's last arm (julia/src/jltypes.c:1776, jl_object_id of the value), which Union{} alone reaches: a type
value's object id, which the runtime does not port (src/julia/runtime/hashing.jl jl_object_id); natively Julia's
answer, in a module the fatal gap, named.
"""
@quarantine pin"julia/src/jltypes.c:1779 jl_type_hash" "Julia hashes any other value by its object id, a type value's the runtime does not port: natively Julia's answer, in a module the fatal gap" Core.Type @noinline jl_type_hash_gap(@nospecialize(v::Any))::UInt =
    ccall(:jl_type_hash, UInt, (Any,), v::Type)
