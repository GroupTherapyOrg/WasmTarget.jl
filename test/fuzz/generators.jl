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
export gen_natural, make_function_natural, vector_inputs

using Supposition
using Supposition: Data

# A function-typed argument slot: a generated unary lambda `param -> <ret expr>`.
struct Fn
    param::Type
    ret::Type
end

# A binary-operator argument slot (for reduce/foldl): renders as a bare op symbol.
struct BinOp end

const VInt   = Vector{Int64}
const VFloat = Vector{Float64}
const DictII = Dict{Int64,Int64}
const SetI   = Set{Int64}

# --- Op tables: (name, argtypes::Tuple{Union{Type,Fn}...}, rettype) ---------
const OPS = Any[
    # ---- Int64 scalar (Numeric) ----
    (:+, (Int64, Int64), Int64), (:-, (Int64, Int64), Int64), (:*, (Int64, Int64), Int64),
    (:abs, (Int64,), Int64), (:sign, (Int64,), Int64), (:-, (Int64,), Int64),
    (:min, (Int64, Int64), Int64), (:max, (Int64, Int64), Int64),
    (:div, (Int64, Int64), Int64), (:rem, (Int64, Int64), Int64), (:mod, (Int64, Int64), Int64),
    (:fld, (Int64, Int64), Int64), (:cld, (Int64, Int64), Int64),
    (:gcd, (Int64, Int64), Int64), (:lcm, (Int64, Int64), Int64),
    (:clamp, (Int64, Int64, Int64), Int64), (:^, (Int64, Int64), Int64),
    (:zero, (Int64,), Int64), (:one, (Int64,), Int64), (:abs2, (Int64,), Int64),
    (:&, (Int64, Int64), Int64), (:|, (Int64, Int64), Int64), (:xor, (Int64, Int64), Int64),
    (:<<, (Int64, Int64), Int64), (:>>, (Int64, Int64), Int64), (:~, (Int64,), Int64),
    # ---- Float64 scalar (Numeric + Math) ----
    (:+, (Float64, Float64), Float64), (:-, (Float64, Float64), Float64),
    (:*, (Float64, Float64), Float64), (:/, (Float64, Float64), Float64),
    (:-, (Float64,), Float64), (:abs, (Float64,), Float64), (:sign, (Float64,), Float64),
    (:min, (Float64, Float64), Float64), (:max, (Float64, Float64), Float64),
    (:sqrt, (Float64,), Float64), (:cbrt, (Float64,), Float64), (:hypot, (Float64, Float64), Float64),
    (:sin, (Float64,), Float64), (:cos, (Float64,), Float64), (:tan, (Float64,), Float64),
    (:asin, (Float64,), Float64), (:acos, (Float64,), Float64), (:atan, (Float64,), Float64),
    (:sinh, (Float64,), Float64), (:cosh, (Float64,), Float64), (:tanh, (Float64,), Float64),
    (:exp, (Float64,), Float64), (:exp2, (Float64,), Float64), (:expm1, (Float64,), Float64),
    (:log, (Float64,), Float64), (:log2, (Float64,), Float64), (:log10, (Float64,), Float64),
    (:log1p, (Float64,), Float64),
    (:sinpi, (Float64,), Float64), (:cospi, (Float64,), Float64),
    (:deg2rad, (Float64,), Float64), (:rad2deg, (Float64,), Float64),
    (:floor, (Float64,), Float64), (:ceil, (Float64,), Float64),
    (:round, (Float64,), Float64), (:trunc, (Float64,), Float64),
    (:copysign, (Float64, Float64), Float64), (:^, (Float64, Float64), Float64),
    (:mod, (Float64, Float64), Float64), (:rem, (Float64, Float64), Float64),
    (:clamp, (Float64, Float64, Float64), Float64), (:inv, (Float64,), Float64),
    (:atan, (Float64, Float64), Float64),
    # ---- Mixed-type conversions ----
    (:Float64, (Int64,), Float64), (:float, (Int64,), Float64),
    # ---- Bool (comparisons / predicates / logic) ----
    (:(==), (Int64, Int64), Bool), (:(!=), (Int64, Int64), Bool),
    (:<, (Int64, Int64), Bool), (:>, (Int64, Int64), Bool),
    (:<=, (Int64, Int64), Bool), (:>=, (Int64, Int64), Bool),
    (:iseven, (Int64,), Bool), (:isodd, (Int64,), Bool),
    (:iszero, (Int64,), Bool), (:isone, (Int64,), Bool), (:signbit, (Int64,), Bool),
    (:(==), (Float64, Float64), Bool), (:<, (Float64, Float64), Bool), (:>, (Float64, Float64), Bool),
    (:isnan, (Float64,), Bool), (:isinf, (Float64,), Bool), (:isfinite, (Float64,), Bool),
    (:iszero, (Float64,), Bool), (:signbit, (Float64,), Bool),
    (:&, (Bool, Bool), Bool), (:|, (Bool, Bool), Bool), (:!, (Bool,), Bool), (:xor, (Bool, Bool), Bool),
    # ---- Vector{Int64} → Vector{Int64} ----
    (:sort, (VInt,), VInt), (:reverse, (VInt,), VInt), (:unique, (VInt,), VInt),
    (:cumsum, (VInt,), VInt), (:map, (Fn(Int64, Int64), VInt), VInt),
    (:filter, (Fn(Int64, Bool), VInt), VInt), (:push!, (VInt, Int64), VInt),
    (:pushfirst!, (VInt, Int64), VInt),
    # ---- Vector{Int64} → Int64 / Bool ----
    (:sum, (VInt,), Int64), (:prod, (VInt,), Int64),
    (:maximum, (VInt,), Int64), (:minimum, (VInt,), Int64),
    (:length, (VInt,), Int64), (:first, (VInt,), Int64), (:last, (VInt,), Int64),
    (:argmax, (VInt,), Int64), (:argmin, (VInt,), Int64),
    (:count, (Fn(Int64, Bool), VInt), Int64),
    (:any, (Fn(Int64, Bool), VInt), Bool), (:all, (Fn(Int64, Bool), VInt), Bool),
    (:in, (Int64, VInt), Bool), (:isempty, (VInt,), Bool),
    # ---- Vector{Float64} ----
    (:sort, (VFloat,), VFloat), (:reverse, (VFloat,), VFloat),
    (:map, (Fn(Float64, Float64), VFloat), VFloat),
    (:sum, (VFloat,), Float64), (:prod, (VFloat,), Float64),
    (:maximum, (VFloat,), Float64), (:minimum, (VFloat,), Float64),
    (:length, (VFloat,), Int64),
    # ---- String → String ----
    (:uppercase, (String,), String), (:lowercase, (String,), String),
    (:reverse, (String,), String), (:strip, (String,), String),
    (:lstrip, (String,), String), (:rstrip, (String,), String),
    (:chomp, (String,), String), (:titlecase, (String,), String),
    (:uppercasefirst, (String,), String), (:lowercasefirst, (String,), String),
    (:*, (String, String), String), (:string, (Int64,), String), (:string, (Float64,), String),
    # ---- String → Int64 / Bool ----
    (:length, (String,), Int64), (:ncodeunits, (String,), Int64),
    (:isempty, (String,), Bool), (:isascii, (String,), Bool),
    (:startswith, (String, String), Bool), (:endswith, (String, String), Bool),
    (:contains, (String, String), Bool), (:occursin, (String, String), Bool),
    (:cmp, (String, String), Int64),
    # ---- Dict{Int64,Int64} (built internally) ----
    (:length,  (DictII,),               Int64),
    (:get,     (DictII, Int64, Int64),  Int64),   # get(d, key, default)
    (:getindex,(DictII, Int64),         Int64),   # d[key] — KeyError if missing (oracle target)
    (:haskey,  (DictII, Int64),         Bool),
    (:isempty, (DictII,),               Bool),
    # ---- Set{Int64} (built internally) ----
    (:length,  (SetI,),                 Int64),
    (:in,      (Int64, SetI),           Bool),
    (:isempty, (SetI,),                 Bool),
    # ---- Char ----
    (:isdigit,      (Char,), Bool), (:isspace, (Char,), Bool), (:isletter, (Char,), Bool),
    (:isuppercase,  (Char,), Bool), (:islowercase, (Char,), Bool), (:isascii, (Char,), Bool),
    (:uppercase,    (Char,), Char), (:lowercase, (Char,), Char),
    (:Int,          (Char,), Int64),
    (:<,            (Char, Char), Bool), (:(==), (Char, Char), Bool),
    # ---- Higher-order with binary op (reduce/foldl) ----
    (:reduce, (BinOp(), VInt),   Int64),
    (:foldl,  (BinOp(), VInt),   Int64),
    (:reduce, (BinOp(), VFloat), Float64),
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
_lit(::Type{Char})   = Data.SampledFrom(['a', 'Z', '0', '9', ' ', 'x', 'é', '!'])

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

# A bounded Dict literal `Dict(k1=>v1, k2=>v2)` and Set literal `Set([a,b,c])`.
function _gen_dict_literal(depth, env)
    k = gen_expr(Int64, depth, env)
    Data.bind(k) do k1
        Data.bind(k) do v1
            Data.bind(k) do k2
                Data.bind(k) do v2
                    Data.just(ExprNode(Expr(:call, :Dict,
                        Expr(:call, :(=>), k1.v, v1.v), Expr(:call, :(=>), k2.v, v2.v))))
                end
            end
        end
    end
end
_gen_set_literal(depth, env) =
    map(n -> ExprNode(Expr(:call, :Set, n.v)), _gen_vec_literal(Int64, depth, env))

# A generated unary lambda `y -> <ret expr in y>` for higher-order ops.
function _gen_lambda(fn::Fn, depth, _env)
    body = gen_expr(fn.ret, max(depth - 1, 0), Dict{Type,Vector{Symbol}}(fn.param => [:y]))
    map(b -> ExprNode(Expr(:->, :y, b.v)), body)
end

# Generate one argument slot: a Type → expression, an Fn → lambda, BinOp → op symbol.
_gen_arg(at::Fn, depth, env)   = _gen_lambda(at, depth, env)
_gen_arg(at::BinOp, depth, env) = map(s -> ExprNode(s), Data.SampledFrom([:+, :*, :min, :max]))
_gen_arg(at::Type, depth, env) = gen_expr(at, depth, env)

"""
    gen_expr(T, depth, env) -> Possibility{ExprNode}

Expression of Julia type `T`, depth-bounded, using variables in `env`.
"""
const _LIT_TYPES = Dict{Type,Bool}(Int64 => true, Float64 => true, Bool => true, String => true, Char => true)

function gen_expr(::Type{T}, depth::Int, env::Dict{Type,Vector{Symbol}}) where {T}
    # LAZY construction: collect production *thunks* (each returns a Possibility),
    # then pick one at GENERATION time via bind. Eagerly expanding every op at every
    # level would build ≈ops^depth generator objects (intractable at depth ≥4); with
    # bind, only the sampled path expands, so construction is O(#productions) and a
    # sample is O(depth).
    prods = Function[]
    if haskey(_LIT_TYPES, T)
        push!(prods, () -> map(ExprNode, _lit(T)))
    end
    for vs in get(env, T, Symbol[])
        let v = vs
            push!(prods, () -> Data.just(ExprNode(v)))
        end
    end
    if T === VInt
        push!(prods, () -> _gen_vec_literal(Int64, max(depth - 1, 0), env))
    elseif T === VFloat
        push!(prods, () -> _gen_vec_literal(Float64, max(depth - 1, 0), env))
    elseif T === DictII
        push!(prods, () -> _gen_dict_literal(max(depth - 1, 0), env))
    elseif T === SetI
        push!(prods, () -> _gen_set_literal(max(depth - 1, 0), env))
    end
    if depth > 0
        for entry in OPS
            entry[3] === T || continue
            let nm = entry[1]::Symbol, ats = entry[2], d = depth - 1
                push!(prods, () -> _gen_call(nm, Any[_gen_arg(at, d, env) for at in ats]))
            end
        end
    end
    isempty(prods) && error("no generator for type $T at depth $depth")
    length(prods) == 1 && return prods[1]()
    return Data.bind(Data.SampledFrom(eachindex(prods))) do idx
        prods[idx]()
    end
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

# --- Natural-signature programs: f(v::IN) = <RET expr using v> ---------------
# The input is a real value (e.g. a Vector passed via the marshalling bridge),
# `var` is in scope in the body. RET is the body's type (inferred at compile).
gen_natural(::Type{IN}, ::Type{RET}; depth::Int = 4, var::Symbol = :v) where {IN,RET} =
    map(n -> n.v, gen_expr(RET, depth, Dict{Type,Vector{Symbol}}(IN => [var])))

function make_function_natural(body, ::Type{IN}; var::Symbol = :v) where {IN}
    _PROG_COUNTER[] += 1
    fname = Symbol("fuzz_nat_", _PROG_COUNTER[])
    src = "$(fname)($(var)::$(IN)) = $(body)"
    fn = Core.eval(Main, Meta.parse(src))
    return (fn, fname, src)
end

# Edge-biased inputs for Vector arguments: empty, singleton, sorted, reverse,
# duplicate-laden, extreme values, longer.
vector_inputs(::Type{Int64}) = Tuple[
    (Int64[],), ([0],), ([1],), ([-1],), ([5, 3, 8, 1],), ([3, 3, 3],),
    ([-9, 2, 0, 2, -9],), ([typemax(Int64), typemin(Int64), 0],),
    ([10, 9, 8, 7, 6, 5, 4, 3, 2, 1],), ([1, 2, 3, 4, 5],), ([-100, 100],),
]
vector_inputs(::Type{Float64}) = Tuple[
    (Float64[],), ([0.0],), ([1.5, -2.5, 3.5],), ([Inf, -Inf, NaN],),
    ([1.0, 1.0, 1.0],), ([-0.0, 0.0],), ([1e300, -1e300, 0.5],),
    ([5.0, 4.0, 3.0, 2.0, 1.0],), ([3.14, 2.71, 1.41],),
]

end # module FuzzGen
