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
# The op catalogue (tagged, per-module data — see catalogue.jl) and the seeded
# struct pool are the two halves of the type universe this generator walks.
using ..FuzzCatalogue
using ..FuzzCatalogue: CatEntry
using ..FuzzStructPool

# Op tables live in FuzzCatalogue (tagged CatEntry data). OPS keeps the legacy
# name for coverage reporting; entries still index like (name, argtypes, ret).
const OPS = FuzzCatalogue.CATALOGUE
const OPS_BY_RET = FuzzCatalogue.catalogue_by_ret()

# --- Literal / leaf generators (edge-case biased), generic over the type lattice ---
_lit(::Type{T}) where {T<:Integer} =
    Data.SampledFrom(T[zero(T), one(T), typemax(T), typemin(T), T(2)]) | Data.Integers{T}()
_lit(::Type{T}) where {T<:AbstractFloat} =
    Data.SampledFrom(T[zero(T), one(T), -one(T), T(Inf), T(-Inf), T(NaN), T(0.5), T(2)]) | Data.Floats{T}()
_lit(::Type{Bool})   = Data.SampledFrom([true, false])   # explicit: Bool<:Integer, but Data.Integers{Bool} is unsupported
_lit(::Type{String}) = Data.SampledFrom(["", "a", "abc", "Hello", "héllo", "12345", "  pad  "])
_lit(::Type{Char})   = Data.SampledFrom(['a', 'Z', '0', '9', ' ', 'x', 'é', '!'])

# Which types have a literal leaf.
_has_lit(::Type{<:Integer})        = true
_has_lit(::Type{<:AbstractFloat})  = true
_has_lit(::Type{Char})             = true
_has_lit(::Type{String})           = true
_has_lit(::Type)                   = false

# ExprNode boxes every alternative so Supposition's OneOf has a single element type.
struct ExprNode
    v::Any
end

# Combine arg generators (each Possibility{ExprNode}) into a call ExprNode via
# nested bind. `acc` accumulates UNWRAPPED sub-expressions. Catalogue names that
# start with `.` are FIELD ACCESS (`.nm`, one receiver arg) and render as
# `recv.nm` rather than a call.
function _gen_call(opname::Symbol, arg_gens::Vector)
    sname = string(opname)
    finish(acc) = startswith(sname, ".") ?
        ExprNode(Expr(:., acc[1], QuoteNode(Symbol(sname[2:end])))) :
        ExprNode(Expr(:call, opname, acc...))
    rec(i, acc) =
        i > length(arg_gens) ?
            Data.just(finish(acc)) :
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

# A bounded Dict literal `Dict(k1=>v1, k2=>v2)` and Set literal `Set([a,b,c])`,
# parametric over key/value/element types.
function _gen_dict_literal(::Type{K}, ::Type{V}, depth, env) where {K,V}
    kg = gen_expr(K, depth, env)
    vg = gen_expr(V, depth, env)
    Data.bind(kg) do k1
        Data.bind(vg) do v1
            Data.bind(kg) do k2
                Data.bind(vg) do v2
                    Data.just(ExprNode(Expr(:call, :Dict,
                        Expr(:call, :(=>), k1.v, v1.v), Expr(:call, :(=>), k2.v, v2.v))))
                end
            end
        end
    end
end
_gen_set_literal(::Type{ET}, depth, env) where {ET} =
    map(n -> ExprNode(Expr(:call, :Set, n.v)), _gen_vec_literal(ET, depth, env))

# N-ary literal builder: bind a generator per field, then assemble with `mk`.
function _gen_fields(fts, depth, env, mk)
    rec(i, acc) =
        i > length(fts) ?
            Data.just(ExprNode(mk(acc))) :
            Data.bind(gen_expr(fts[i], depth, env)) do a
                rec(i + 1, (acc..., a.v))
            end
    return rec(1, ())
end
_gen_tuple_literal(::Type{T}, depth, env) where {T} =
    _gen_fields([fieldtype(T, i) for i in 1:fieldcount(T)], depth, env,
                acc -> Expr(:tuple, acc...))
_gen_nt_literal(::Type{T}, depth, env) where {T} =
    _gen_fields([fieldtype(T, i) for i in 1:fieldcount(T)], depth, env,
                acc -> Expr(:tuple, (Expr(:(=), fieldnames(T)[i], acc[i]) for i in eachindex(acc))...))
_gen_struct_literal(p, depth, env) =
    _gen_fields(p.fieldtypes, depth, env, acc -> Expr(:call, p.name, acc...))

# A generated unary lambda `y -> <ret expr in y>` for higher-order ops.
function _gen_lambda(fn::Fn, depth, _env)
    body = gen_expr(fn.ret, max(depth - 1, 0), Dict{Type,Vector{Symbol}}(fn.param => [:y]))
    map(b -> ExprNode(Expr(:->, :y, b.v)), body)
end

# Generate one argument slot: a Type → expression, an Fn → lambda, BinOp → op
# symbol, Val{i} → the literal index i (tuple getindex).
_gen_arg(at::Fn, depth, env)   = _gen_lambda(at, depth, env)
_gen_arg(at::BinOp, depth, env) = map(s -> ExprNode(s), Data.SampledFrom([:+, :*, :min, :max]))
_gen_arg(at::Type, depth, env) =
    at <: Val ? Data.just(ExprNode(at.parameters[1])) : gen_expr(at, depth, env)

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
    if _has_lit(T)
        push!(prods, () -> map(ExprNode, _lit(T)))
    end
    for vs in get(env, T, Symbol[])
        let v = vs
            push!(prods, () -> Data.just(ExprNode(v)))
        end
    end
    # Tuple / NamedTuple literals (M3): any concrete tuple-ish type with
    # generatable fields can be built as a literal.
    if T <: Tuple && isconcretetype(T)
        let FT = T, d = max(depth - 1, 0)
            push!(prods, () -> _gen_tuple_literal(FT, d, env))
        end
    elseif T <: NamedTuple && isconcretetype(T)
        let FT = T, d = max(depth - 1, 0)
            push!(prods, () -> _gen_nt_literal(FT, d, env))
        end
    end
    # Pool-struct construction + field access (M3): generated struct types are
    # ordinary citizens of the universe.
    for p in FuzzStructPool.POOL
        if p.T === T
            let ps = p, d = max(depth - 1, 0)
                push!(prods, () -> _gen_struct_literal(ps, d, env))
            end
        end
    end
    if depth > 0
        for (ft, ST, fname) in FuzzStructPool.pool_field_entries()
            if ft === T
                let S = ST, nm = fname, d = depth - 1
                    push!(prods, () -> map(e -> ExprNode(Expr(:., e.v, QuoteNode(nm))),
                                           gen_expr(S, d, env)))
                end
            end
        end
    end
    # Container constructor leaves, parametric over element/key/value types.
    if T <: AbstractVector
        let ET = eltype(T), d = max(depth - 1, 0)
            push!(prods, () -> _gen_vec_literal(ET, d, env))
        end
    elseif T <: AbstractDict
        let KT = keytype(T), VT = valtype(T), d = max(depth - 1, 0)
            push!(prods, () -> _gen_dict_literal(KT, VT, d, env))
        end
    elseif T <: AbstractSet
        let ET = eltype(T), d = max(depth - 1, 0)
            push!(prods, () -> _gen_set_literal(ET, d, env))
        end
    end
    if depth > 0
        for entry in get(OPS_BY_RET, T, ())
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
    src = "$(fname)(x::$(T0)) = $(_body_repr(body))"
    # Eval as an Expr (NOT via string round-trip): a bare Char/String literal
    # body would stringify into an identifier ('é' → é → UndefVarError).
    fdef = Expr(:(=), Expr(:call, fname, Expr(:(::), :x, T0)), body)
    fn = Core.eval(Main, fdef)
    return (fn, fname, src)
end
# Display/reproducer-faithful rendering. Two hazards when stringifying an Expr
# tree that embeds literal VALUES:
#   * bare Char/String literal bodies would render unquoted → repr those;
#   * SIGNED narrow ints (Int8/16/32) render as bare digits, which RE-PARSE as
#     Int64 — silently changing promotion/overflow semantics in reproducers and
#     canon matching (a gcd(Int32(0), x) gap re-parsed as gcd(0, x) and stopped
#     reproducing). Unsigned (0xa5) and Float32 (1.5f0) literals are
#     self-typing. So wrap signed-narrow leaves in explicit ctor calls first.
_body_repr(body) = body isa Union{Expr,Symbol,Number} ? string(_retype_literals(body)) : repr(body)
_retype_literals(x::Union{Int8,Int16,Int32}) = Expr(:call, nameof(typeof(x)), Int64(x))
_retype_literals(x::Expr) = Expr(x.head, map(_retype_literals, x.args)...)
_retype_literals(x) = x

# Generic edge-biased argument values for ANY universe type (the arg-side
# counterpart of _lit) — lets sweeps point the differential at structs, tuples,
# chars, narrow ints… without hand-written input lists.
_edges(::Type{T}) where {T<:Integer} = T[zero(T), one(T), typemax(T), typemin(T), T(2)]
_edges(::Type{Bool})    = [true, false]
_edges(::Type{T}) where {T<:AbstractFloat} = T[0, 1, -1, T(Inf), T(-Inf), T(NaN), T(0.5)]
_edges(::Type{Char})    = ['a', 'Z', '0', 'é', '!']
_edges(::Type{String})  = ["", "a", "héllo", "12345"]
_edges(::Type{Vector{E}}) where {E} =
    [E[], E[_edges(E)[1]], E[x for x in _edges(E)[1:min(3, end)]]]
function _edges(::Type{T}) where {T}
    if (isstructtype(T) || T <: Tuple) && isconcretetype(T) && fieldcount(T) > 0
        fes = [_edges(fieldtype(T, i)) for i in 1:fieldcount(T)]
        mk(vals) = T <: Tuple ? Tuple(vals) : T <: NamedTuple ? T(Tuple(vals)) : T(vals...)
        return [mk([fes[i][mod1(j + i - 1, length(fes[i]))] for i in eachindex(fes)]) for j in 1:4]
    end
    error("no edge values for type $T")
end

sample_inputs(::Type{T}) where {T} = Tuple[(v,) for v in _edges(T)]
vector_inputs(::Type{E}) where {E} = Tuple[(v,) for v in _edges(Vector{E})]

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
    src = "$(fname)($(var)::$(IN)) = $(_body_repr(body))"
    fdef = Expr(:(=), Expr(:call, fname, Expr(:(::), var, IN)), body)
    fn = Core.eval(Main, fdef)
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
