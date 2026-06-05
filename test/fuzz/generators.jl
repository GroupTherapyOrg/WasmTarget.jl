# ============================================================================
# Type-directed expression-tree generators
# ============================================================================
#
# A generated program is `fname(x::T0) = <body>`, where `<body>` is a well-typed
# expression tree built bottom-up so it ALWAYS type-checks in native Julia (the
# precondition for differential testing — random untyped nesting would just be
# rejected by Julia before WasmTarget ever runs).
#
# `gen_expr(T, depth)` returns a `Possibility` yielding an expression of type `T`:
#   * a leaf  — the input var `:x` (when its type matches) or a literal of `T`
#   * a node  — `op(gen_expr(argtype, depth-1)...)` over every op returning `T`
# Generators for different result types are mutually recursive and bounded by
# `depth`, so the tree is finite. Op args are combined with nested `bind` (which,
# unlike `@composed`, nests inside closures).

module FuzzGen

export gen_program, sample_inputs, INT_OPS, FLOAT_OPS, make_function

using Supposition
using Supposition: Data

# --- Op tables: (name, argtypes::Tuple, rettype) ---------------------------
# v1 keeps two numeric universes (Int64, Float64). Cross-type/vector/string ops
# are follow-ups. We deliberately INCLUDE ops with reachable trap branches
# (sqrt, log, /, div) so the differential oracle exercises them.

const INT_OPS = [
    (:+,   (Int64, Int64), Int64),
    (:-,   (Int64, Int64), Int64),
    (:*,   (Int64, Int64), Int64),
    (:abs, (Int64,),       Int64),
    (:sign,(Int64,),       Int64),
    (:min, (Int64, Int64), Int64),
    (:max, (Int64, Int64), Int64),
    (:div, (Int64, Int64), Int64),   # div-by-zero: Julia throws, wasm traps
    (:rem, (Int64, Int64), Int64),
    (:gcd, (Int64, Int64), Int64),
]

const FLOAT_OPS = [
    (:+,    (Float64, Float64), Float64),
    (:-,    (Float64, Float64), Float64),
    (:*,    (Float64, Float64), Float64),
    (:/,    (Float64, Float64), Float64),
    (:abs,  (Float64,),         Float64),
    (:sqrt, (Float64,),         Float64),   # sqrt(neg): Julia throws DomainError
    (:cbrt, (Float64,),         Float64),
    (:sin,  (Float64,),         Float64),   # large arg → paynehanek
    (:cos,  (Float64,),         Float64),
    (:exp,  (Float64,),         Float64),
    (:log,  (Float64,),         Float64),   # log(neg): DomainError
    (:floor,(Float64,),         Float64),
    (:ceil, (Float64,),         Float64),
    (:min,  (Float64, Float64), Float64),
    (:max,  (Float64, Float64), Float64),
    (:hypot,(Float64, Float64), Float64),
]

# --- Literal leaf generators (edge-case biased) ----------------------------
_int_literals() =
    Data.SampledFrom(Int64[0, 1, -1, 2, -2, 10, typemax(Int64), typemin(Int64)]) |
    Data.Integers{Int64}()

_float_literals() =
    Data.SampledFrom(Float64[0.0, 1.0, -1.0, 2.0, 0.5, -0.5, Inf, -Inf, NaN, 1e300, -1e300, 3.141592653589793]) |
    Data.Floats{Float64}()

_literals(::Type{Int64})   = _int_literals()
_literals(::Type{Float64}) = _float_literals()
_ops(::Type{Int64})        = INT_OPS
_ops(::Type{Float64})      = FLOAT_OPS

# Supposition's OneOf requires a single element type across alternatives. Leaves
# yield atoms (Int64/Symbol/Float64) while call-nodes yield Expr, so we box every
# alternative in `ExprNode` (a `::Any` field) — the OneOf is then uniformly
# `ExprNode` — and unwrap once at the top (`gen_program`).
struct ExprNode
    v::Any
end

# Combine arg generators (each Possibility{ExprNode}) into a call ExprNode via
# nested bind (no @composed nesting). `acc` accumulates UNWRAPPED sub-expressions.
function _gen_call(opname::Symbol, arg_gens::Vector)
    rec(i, acc) =
        i > length(arg_gens) ?
            Data.just(ExprNode(Expr(:call, opname, acc...))) :
            Data.bind(arg_gens[i]) do a
                rec(i + 1, (acc..., a.v))
            end
    return rec(1, ())
end

"""
    gen_expr(T, depth; input_type=T) -> Possibility{ExprNode}

Expression of Julia type `T`, depth-bounded. `input_type` is the function's single
parameter type; `:x` appears as a leaf only where it type-matches.
"""
function gen_expr(::Type{T}, depth::Int; input_type::Type=T) where {T}
    atoms = T === input_type ? (_literals(T) | Data.just(:x)) : _literals(T)
    leaves = map(ExprNode, atoms)
    depth <= 0 && return leaves
    node_gens = Any[leaves]
    for (name, argts, rett) in _ops(T)
        rett === T || continue
        arg_gens = [gen_expr(at, depth - 1; input_type=input_type) for at in argts]
        push!(node_gens, _gen_call(name, arg_gens))
    end
    return reduce(|, node_gens)
end

"""
    gen_program(T0; depth=3) -> Possibility

Yields a `body` expression for a function `f(x::T0)::T0` (unwrapped from ExprNode).
"""
gen_program(::Type{T0}; depth::Int=3) where {T0} =
    map(n -> n.v, gen_expr(T0, depth; input_type=T0))

# --- Building & sampling ----------------------------------------------------
const _PROG_COUNTER = Ref(0)

"""
    make_function(body, T0) -> (fn, fname::Symbol, src::String)

Eval `fname(x::T0) = body` into a fresh-named top-level method and return it.
"""
function make_function(body, ::Type{T0}) where {T0}
    _PROG_COUNTER[] += 1
    fname = Symbol("fuzz_fn_", _PROG_COUNTER[])
    src = "$(fname)(x::$(T0)) = $(body)"
    fn = Core.eval(Main, Meta.parse(src))
    return (fn, fname, src)
end

"""
    sample_inputs(T0) -> Vector{Tuple}

Edge-case-biased fixed inputs each generated function is evaluated on.
"""
sample_inputs(::Type{Int64}) =
    [(0,), (1,), (-1,), (2,), (-3,), (7,), (-128,), (1000,),
     (typemax(Int64),), (typemin(Int64),), (typemax(Int64) - 1,)]

sample_inputs(::Type{Float64}) =
    [(0.0,), (1.0,), (-1.0,), (2.0,), (0.5,), (-0.5,), (3.5,), (-3.5,),
     (1e300,), (-1e300,), (1e-300,), (Inf,), (-Inf,), (NaN,), (100.0,), (1e8,)]

end # module FuzzGen
