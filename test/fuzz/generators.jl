# ============================================================================
# Type-directed expression-tree generators
# ============================================================================
#
# A generated program is `fname(x::T0) = <body>` returning a SCALAR (Int64/Float64),
# but the body may build and consume `Vector{Int64}`, `Vector{Float64}`, `String`,
# and `Bool` values INTERNALLY. Keeping the function's argument and result scalar
# means the execution harness needs no GC-object marshalling — collections/strings
# live entirely inside the wasm function and are reduced back to a scalar.
#
# `gen_expr(T, depth, env)` returns a `Possibility{ExprNode}` yielding an expression
# of Julia type `T`, where `env::Dict{Type,Vector{Symbol}}` lists the variables in
# scope (the outer `:x`, or a lambda's `:y`). Trees type-check by construction, so
# native Julia accepts them (the precondition for differential testing). Op args are
# combined with nested `bind`; higher-order ops (map/filter/count) take a generated
# lambda via the `Fn` marker.

module FuzzGen

export gen_program, sample_inputs, make_function

using Supposition
using Supposition: Data

# A function-typed argument slot: a generated unary lambda `param -> <ret expr>`.
struct Fn
    param::Type
    ret::Type
end

const VInt   = Vector{Int64}
const VFloat = Vector{Float64}

# --- Op tables: (name, argtypes::Tuple{Union{Type,Fn}...}, rettype) ---------
const OPS = Any[
    # Int64 scalar
    (:+,    (Int64, Int64), Int64),
    (:-,    (Int64, Int64), Int64),
    (:*,    (Int64, Int64), Int64),
    (:abs,  (Int64,),       Int64),
    (:sign, (Int64,),       Int64),
    (:min,  (Int64, Int64), Int64),
    (:max,  (Int64, Int64), Int64),
    (:div,  (Int64, Int64), Int64),
    (:rem,  (Int64, Int64), Int64),
    (:gcd,  (Int64, Int64), Int64),
    # Float64 scalar
    (:+,    (Float64, Float64), Float64),
    (:-,    (Float64, Float64), Float64),
    (:*,    (Float64, Float64), Float64),
    (:/,    (Float64, Float64), Float64),
    (:abs,  (Float64,),         Float64),
    (:sqrt, (Float64,),         Float64),
    (:cbrt, (Float64,),         Float64),
    (:sin,  (Float64,),         Float64),
    (:cos,  (Float64,),         Float64),
    (:exp,  (Float64,),         Float64),
    (:log,  (Float64,),         Float64),
    (:floor,(Float64,),         Float64),
    (:ceil, (Float64,),         Float64),
    (:min,  (Float64, Float64), Float64),
    (:max,  (Float64, Float64), Float64),
    (:hypot,(Float64, Float64), Float64),
    # Mixed-type conversions
    (:Float64, (Int64,),   Float64),
    # Bool (comparisons / logic) — consumed by filter/count predicates
    (:(==), (Int64, Int64), Bool),
    (:<,    (Int64, Int64), Bool),
    (:>,    (Int64, Int64), Bool),
    (:<=,   (Int64, Int64), Bool),
    (:iseven, (Int64,),     Bool),
    (:isodd,  (Int64,),     Bool),
    (:&,    (Bool, Bool),   Bool),
    (:|,    (Bool, Bool),   Bool),
    (:!,    (Bool,),        Bool),
    # Vector{Int64} → Vector{Int64}
    (:sort,    (VInt,),               VInt),
    (:reverse, (VInt,),               VInt),
    (:unique,  (VInt,),               VInt),
    (:map,     (Fn(Int64, Int64), VInt), VInt),
    (:filter,  (Fn(Int64, Bool),  VInt), VInt),
    # Vector{Int64} → Int64
    (:sum,     (VInt,),               Int64),
    (:prod,    (VInt,),               Int64),
    (:maximum, (VInt,),               Int64),
    (:minimum, (VInt,),               Int64),
    (:length,  (VInt,),               Int64),
    (:first,   (VInt,),               Int64),
    (:last,    (VInt,),               Int64),
    (:count,   (Fn(Int64, Bool),  VInt), Int64),
    # Vector{Float64} → Vector{Float64} / Float64
    (:sort,    (VFloat,),             VFloat),
    (:reverse, (VFloat,),             VFloat),
    (:map,     (Fn(Float64, Float64), VFloat), VFloat),
    (:sum,     (VFloat,),             Float64),
    (:maximum, (VFloat,),             Float64),
    (:minimum, (VFloat,),             Float64),
    (:length,  (VFloat,),             Int64),
    # String → String
    (:uppercase, (String,),          String),
    (:lowercase, (String,),          String),
    (:reverse,   (String,),          String),
    (:strip,     (String,),          String),
    (:*,         (String, String),   String),
    (:string,    (Int64,),           String),
    (:string,    (Float64,),         String),
    # String → Int64
    (:length,     (String,),         Int64),
    (:ncodeunits, (String,),         Int64),
]

# --- Literal / leaf generators (edge-case biased) --------------------------
_lit(::Type{Int64}) =
    Data.SampledFrom(Int64[0, 1, -1, 2, -2, 10, typemax(Int64), typemin(Int64)]) |
    Data.Integers{Int64}()
_lit(::Type{Float64}) =
    Data.SampledFrom(Float64[0.0, 1.0, -1.0, 2.0, 0.5, -0.5, Inf, -Inf, NaN, 1e300, 3.141592653589793]) |
    Data.Floats{Float64}()
_lit(::Type{Bool})   = Data.SampledFrom([true, false])
_lit(::Type{String}) = Data.SampledFrom(["", "a", "abc", "Hello", "héllo", "12345", "  pad  "])

# ExprNode boxes every alternative so Supposition's OneOf has a single element type.
struct ExprNode
    v::Any
end

# Combine arg generators (each Possibility{ExprNode}) into a call ExprNode via
# nested bind. `acc` accumulates UNWRAPPED sub-expressions.
function _gen_call(opname::Symbol, arg_gens::Vector)
    rec(i, acc) =
        i > length(arg_gens) ?
            Data.just(ExprNode(Expr(:call, opname, acc...))) :
            Data.bind(arg_gens[i]) do a
                rec(i + 1, (acc..., a.v))
            end
    return rec(1, ())
end

# A bounded 3-element vector literal `[e1, e2, e3]` (kept small so wasm stays fast).
function _gen_vec_literal(::Type{ET}, depth, env) where {ET}
    elem = gen_expr(ET, depth, env)
    Data.bind(elem) do a
        Data.bind(elem) do b
            Data.bind(elem) do c
                Data.just(ExprNode(Expr(:vect, a.v, b.v, c.v)))
            end
        end
    end
end

# A generated unary lambda `y -> <ret expr in y>` for higher-order ops.
function _gen_lambda(fn::Fn, depth, _env)
    body = gen_expr(fn.ret, max(depth - 1, 0), Dict{Type,Vector{Symbol}}(fn.param => [:y]))
    map(b -> ExprNode(Expr(:->, :y, b.v)), body)
end

# Generate one argument slot (a Type → expression, or an Fn → lambda).
_gen_arg(at::Fn, depth, env)  = _gen_lambda(at, depth, env)
_gen_arg(at::Type, depth, env) = gen_expr(at, depth, env)

"""
    gen_expr(T, depth, env) -> Possibility{ExprNode}

Expression of Julia type `T`, depth-bounded, using variables in `env`.
"""
const _LIT_TYPES = Dict{Type,Bool}(Int64 => true, Float64 => true, Bool => true, String => true)

function gen_expr(::Type{T}, depth::Int, env::Dict{Type,Vector{Symbol}}) where {T}
    # Leaves: literals of T + any in-scope variable of type T (boxed in ExprNode).
    leafgens = Any[]
    haskey(_LIT_TYPES, T) && push!(leafgens, _lit(T))
    for vs in get(env, T, Symbol[])
        push!(leafgens, Data.just(vs))
    end

    node_gens = Any[]
    isempty(leafgens) || push!(node_gens, map(ExprNode, reduce(|, leafgens)))
    # Vector constructor leaf — ALWAYS available (elements one level down), so
    # vector types have a production even at depth 0.
    if T === VInt
        push!(node_gens, _gen_vec_literal(Int64, max(depth - 1, 0), env))
    elseif T === VFloat
        push!(node_gens, _gen_vec_literal(Float64, max(depth - 1, 0), env))
    end

    if depth > 0
        for (name, argts, rett) in OPS
            rett === T || continue
            arg_gens = Any[_gen_arg(at, depth - 1, env) for at in argts]
            push!(node_gens, _gen_call(name, Vector{Any}(arg_gens)))
        end
    end
    isempty(node_gens) && error("no generator for type $T at depth $depth")
    return reduce(|, node_gens)
end

"""
    gen_program(T0; depth=4) -> Possibility

Yields a scalar `body` for a function `f(x::T0)::T0` (collections/strings internal).
"""
gen_program(::Type{T0}; depth::Int=4) where {T0} =
    map(n -> n.v, gen_expr(T0, depth, Dict{Type,Vector{Symbol}}(T0 => [:x])))

# --- Building & sampling ----------------------------------------------------
const _PROG_COUNTER = Ref(0)

function make_function(body, ::Type{T0}) where {T0}
    _PROG_COUNTER[] += 1
    fname = Symbol("fuzz_fn_", _PROG_COUNTER[])
    src = "$(fname)(x::$(T0)) = $(body)"
    fn = Core.eval(Main, Meta.parse(src))
    return (fn, fname, src)
end

sample_inputs(::Type{Int64}) =
    [(0,), (1,), (-1,), (2,), (-3,), (7,), (-128,), (1000,),
     (typemax(Int64),), (typemin(Int64),), (typemax(Int64) - 1,)]

sample_inputs(::Type{Float64}) =
    [(0.0,), (1.0,), (-1.0,), (2.0,), (0.5,), (-0.5,), (3.5,), (-3.5,),
     (1e300,), (-1e300,), (1e-300,), (Inf,), (-Inf,), (NaN,), (100.0,), (1e8,)]

end # module FuzzGen
