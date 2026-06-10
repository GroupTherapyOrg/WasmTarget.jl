# ============================================================================
# FuzzStatements — type-directed STATEMENT-level generation (M4)
# ============================================================================
#
# A layer above expressions: blocks that bind locals, branch as values, loop
# with accumulators, comprehend, early-return, and short-circuit — well-typed
# by construction, threading a typed environment. This is where phi nodes,
# loop-carried variables, and block result typing live — historically the
# buggiest corner of any codegen backend.
#
# Variable names are derived from the RECURSION PATH (not a global counter) so
# the same Supposition choice sequence always renders the same source — corpus
# replay and known-gap matching stay stable.
#
# Loops are bounded by literal trip counts (1–3): generated programs always
# terminate natively; a non-terminating wasm is a real divergence the pool
# watchdog converts to `:trap`.

module FuzzStatements

export gen_block, gen_program_stmts

using Supposition
using Supposition: Data
using ..FuzzGen
using ..FuzzGen: ExprNode, gen_expr, _gen_call, _gen_arg
using ..FuzzCatalogue: catalogue_throwy_by_ret

# Types worth binding to locals (drives cross-type dataflow through blocks).
const BIND_TYPES = Type[Int64, Float64, Bool, Int32, Vector{Int64}, Vector{Float64}, String]
# Accumulator-friendly types for loop production.
const ACC_TYPES = (Int64, Float64, Int32, Float32)

_extend(env, U::Type, v::Symbol) = begin
    e2 = Dict{Type,Vector{Symbol}}(k => copy(vs) for (k, vs) in env)   # explicit key type: a comprehension would infer Dict{DataType,…} and miss gen_expr's signature
    push!(get!(e2, U, Symbol[]), v)
    e2
end

"""
    gen_block(T, depth, env, path; allow_return=false) -> Possibility{ExprNode}

A block whose VALUE has type `T`. `path` uniquifies bound names deterministically.
"""
function gen_block(::Type{T}, depth::Int, env::Dict{Type,Vector{Symbol}},
                   path::String = "b"; allow_return::Bool = false) where {T}
    prods = Function[
        () -> gen_expr(T, depth, env),                 # plain expression
    ]
    if depth > 0
        push!(prods, () -> _let_block(T, depth, env, path))
        push!(prods, () -> _if_value(T, depth, env, path))
        push!(prods, () -> _ternary(T, depth, env, path))
        if T in ACC_TYPES
            push!(prods, () -> _while_acc(T, depth, env, path))
            push!(prods, () -> _for_acc(T, depth, env, path))
        end
        if T <: Vector && isconcretetype(T) && eltype(T) in (Int64, Float64)
            push!(prods, () -> _comprehension(T, depth, env, path))
        end
        if T === Bool
            push!(prods, () -> _shortcircuit(depth, env, path))
        end
        if allow_return
            push!(prods, () -> _early_return(T, depth, env, path))
        end
        # try/catch as a value (M5): try-bodies biased toward throw-tagged ops.
        push!(prods, () -> _try_catch(T, depth, env, path))
        if T in ACC_TYPES
            push!(prods, () -> _try_finally(T, depth, env, path))
        end
    end
    return Data.bind(Data.SampledFrom(eachindex(prods))) do i
        prods[i]()
    end
end

# v = <U-expr>; <T-block using v>
function _let_block(::Type{T}, depth, env, path) where {T}
    Data.bind(Data.SampledFrom(BIND_TYPES)) do U
        v = Symbol("v_", path)
        Data.bind(gen_expr(U, depth - 1, env)) do val
            Data.bind(gen_block(T, depth - 1, _extend(env, U, v), path * "l")) do rest
                Data.just(ExprNode(Expr(:block, Expr(:(=), v, val.v), rest.v)))
            end
        end
    end
end

# if c; <T-block>; else <T-block>; end — in value position
function _if_value(::Type{T}, depth, env, path) where {T}
    Data.bind(gen_expr(Bool, depth - 1, env)) do c
        Data.bind(gen_block(T, depth - 1, env, path * "t")) do a
            Data.bind(gen_block(T, depth - 1, env, path * "e")) do b
                Data.just(ExprNode(Expr(:if, c.v, Expr(:block, a.v), Expr(:block, b.v))))
            end
        end
    end
end

_ternary(::Type{T}, depth, env, path) where {T} =
    Data.bind(gen_expr(Bool, depth - 1, env)) do c
        Data.bind(gen_expr(T, depth - 1, env)) do a
            Data.bind(gen_expr(T, depth - 1, env)) do b
                Data.just(ExprNode(Expr(:if, c.v, a.v, b.v)))
            end
        end
    end

# acc = init; i = 0; while i < n; acc = upd(acc, i); i += 1; end; acc
function _while_acc(::Type{T}, depth, env, path) where {T}
    acc = Symbol("acc_", path); i = Symbol("i_", path)
    env2 = _extend(_extend(env, T, acc), Int64, i)
    Data.bind(gen_expr(T, depth - 1, env)) do init
        Data.bind(Data.SampledFrom(1:3)) do n
            Data.bind(gen_expr(T, depth - 1, env2)) do upd
                Data.just(ExprNode(Expr(:block,
                    Expr(:(=), acc, init.v),
                    Expr(:(=), i, :(Int64(0))),
                    Expr(:while, :($i < Int64($n)),
                         Expr(:block, Expr(:(=), acc, upd.v),
                              Expr(:(=), i, :($i + Int64(1))))),
                    acc)))
            end
        end
    end
end

# acc = init; for i in 1:n; acc = upd(acc, i); end; acc
function _for_acc(::Type{T}, depth, env, path) where {T}
    acc = Symbol("acc_", path); i = Symbol("i_", path)
    env2 = _extend(_extend(env, T, acc), Int64, i)
    Data.bind(gen_expr(T, depth - 1, env)) do init
        Data.bind(Data.SampledFrom(1:3)) do n
            Data.bind(gen_expr(T, depth - 1, env2)) do upd
                Data.just(ExprNode(Expr(:block,
                    Expr(:(=), acc, init.v),
                    Expr(:for, Expr(:(=), i, :(Int64(1):Int64($n))),
                         Expr(:block, Expr(:(=), acc, upd.v))),
                    acc)))
            end
        end
    end
end

# [ <E-expr(i)> for i in 1:n ]  — element expr strictly E-typed
function _comprehension(::Type{VT}, depth, env, path) where {VT}
    E = eltype(VT)
    i = Symbol("i_", path)
    env2 = _extend(env, Int64, i)
    Data.bind(Data.SampledFrom(1:3)) do n
        Data.bind(gen_expr(E, depth - 1, env2)) do el
            Data.just(ExprNode(Expr(:comprehension,
                Expr(:generator, el.v, Expr(:(=), i, :(Int64(1):Int64($n)))))))
        end
    end
end

_shortcircuit(depth, env, path) =
    Data.bind(Data.SampledFrom([:&&, :||])) do op
        Data.bind(gen_expr(Bool, depth - 1, env)) do a
            Data.bind(gen_expr(Bool, depth - 1, env)) do b
                Data.just(ExprNode(Expr(op, a.v, b.v)))
            end
        end
    end

# if c; return <T-expr>; end; <T-block>
function _early_return(::Type{T}, depth, env, path) where {T}
    Data.bind(gen_expr(Bool, depth - 1, env)) do c
        Data.bind(gen_expr(T, depth - 1, env)) do r
            Data.bind(gen_block(T, depth - 1, env, path * "r")) do rest
                Data.just(ExprNode(Expr(:block,
                    Expr(:if, c.v, Expr(:block, Expr(:return, r.v))),
                    rest.v)))
            end
        end
    end
end

# ── try/catch (M5) ───────────────────────────────────────────────────────────
const THROWY_BY_RET = catalogue_throwy_by_ret()

# A T-valued expression biased toward actually THROWING: prefer a throw-tagged
# catalogue op (its args still come from the edge-biased generators — ÷0, empty
# vectors, out-of-range narrows arise naturally), or guard-error, or plain block.
function _throwy_block(::Type{T}, depth, env, path) where {T}
    prods = Function[]
    for e in get(THROWY_BY_RET, T, ())
        let nm = e.name, ats = e.argtypes, d = max(depth - 1, 0)
            push!(prods, () -> _gen_call(nm, Any[_gen_arg(at, d, env) for at in ats]))
        end
    end
    # cond && error("fz"); <T-expr> — an explicit user-thrown path
    push!(prods, () -> Data.bind(gen_expr(Bool, max(depth - 1, 0), env)) do c
        Data.bind(gen_expr(T, max(depth - 1, 0), env)) do r
            Data.just(ExprNode(Expr(:block,
                Expr(:&&, c.v, :(error("fz"))), r.v)))
        end
    end)
    push!(prods, () -> gen_block(T, max(depth - 1, 0), env, path * "p"))
    return Data.bind(Data.SampledFrom(eachindex(prods))) do i
        prods[i]()
    end
end

# value = try <throwy T-block> catch; <T-block> end
function _try_catch(::Type{T}, depth, env, path) where {T}
    Data.bind(_throwy_block(T, depth, env, path * "y")) do t
        Data.bind(gen_block(T, max(depth - 1, 0), env, path * "c")) do c
            Data.just(ExprNode(Expr(:try, Expr(:block, t.v), false, Expr(:block, c.v))))
        end
    end
end

# acc = init; r = try <throwy> finally acc = fin end; r + acc
# (finally must run on BOTH paths; if the body throws, the whole expr throws
# natively and must trap in wasm — after running the finally.)
function _try_finally(::Type{T}, depth, env, path) where {T}
    acc = Symbol("fin_", path); r = Symbol("r_", path)
    Data.bind(gen_expr(T, max(depth - 1, 0), env)) do init
        Data.bind(gen_expr(T, max(depth - 1, 0), env)) do fin
            Data.bind(_throwy_block(T, depth, env, path * "y")) do body
                Data.just(ExprNode(Expr(:block,
                    Expr(:(=), acc, init.v),
                    Expr(:(=), r, Expr(:try, Expr(:block, body.v), false, false,
                                       Expr(:block, Expr(:(=), acc, fin.v)))),
                    Expr(:call, :+, r, acc))))
            end
        end
    end
end

"""
    gen_program_stmts(T0; depth=3, ret=T0) -> Possibility

A statement-level program body for `f(x::T0)::ret` — blocks, branches, loops,
comprehensions, early returns, all type-directed.
"""
gen_program_stmts(::Type{T0}; depth::Int = 3, ret::Type = T0) where {T0} =
    map(n -> n.v, gen_block(ret, depth, Dict{Type,Vector{Symbol}}(T0 => [:x]), "b";
                            allow_return = true))

end # module FuzzStatements
