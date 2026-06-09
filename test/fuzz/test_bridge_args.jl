# ============================================================================
# Argument-side bridge round-trip validation — run standalone:
#   julia --project=test/fuzz test/fuzz/test_bridge_args.jl
# ============================================================================
# CORE rows must pass; FRONTIER rows are reported (each failure = a finding).

using Test

include(joinpath(@__DIR__, "harness.jl"));      using .FuzzHarness
include(joinpath(@__DIR__, "bridge.jl"));       using .FuzzBridge
include(joinpath(@__DIR__, "bridge_args.jl"));  using .FuzzBridgeArgs

struct APoint; x::Float64; y::Float64; end
mutable struct ACounter; n::Int64; end

# args in → value out (every arg shape crosses INTO wasm)
ba_2i(a::Int64, b::Int64)           = a * b + 1
ba_f(a::Float64, b::Float64)        = a / b
ba_f32(a::Float32)                  = a * 2.0f0
ba_mix(a::Int64, b::Float64, c::Bool) = c ? Float64(a) + b : b - Float64(a)
ba_u8(a::UInt8)                     = Int64(a) * 2
ba_char(c::Char)                    = Int64(codepoint(c)) + 1
ba_str(s::String)                   = Int64(ncodeunits(s))
ba_vec(v::Vector{Int64})            = sum(v)
ba_vecf(v::Vector{Float64})         = length(v) < 1 ? 0.0 : v[1] + v[end]
ba_point(p::APoint)                 = p.x * p.y
ba_tup(t::Tuple{Int64,Float64})     = t[1] + Int64(round(t[2]))
ba_vecvec(v::Vector{Vector{Int64}}) = length(v) < 1 ? Int64(0) : sum(v[1])
ba_vstruct(v::Vector{APoint})       = length(v) < 1 ? 0.0 : v[1].x + v[end].y
# mutation parity
ba_push(v::Vector{Int64})           = (push!(v, Int64(42)); length(v))
ba_setidx(v::Vector{Float64})       = (v[1] = -v[1]; v[1])
ba_mut(c::ACounter)                 = (c.n += 5; c.n)
ba_sort(v::Vector{Int64})           = (sort!(v); v[1])

const CORE = [
    (ba_2i,    (Int64, Int64),       [(3, 4), (-5, typemax(Int64) ÷ 8)]),
    (ba_f,     (Float64, Float64),   [(1.0, 3.0), (-0.0, Inf), (NaN, 2.0)]),
    (ba_f32,   (Float32,),           [(1.5f0,), (-2.25f0,)]),
    (ba_mix,   (Int64, Float64, Bool), [(3, 0.5, true), (-2, 1.5, false)]),
    (ba_u8,    (UInt8,),             [(UInt8(255),), (UInt8(0),)]),
    (ba_char,  (Char,),              [('A',), ('é',), ('🎈',)]),
    (ba_str,   (String,),            [("hello",), ("",), ("héllo🎈",)]),
    (ba_vec,   (Vector{Int64},),     [([1, 2, 3],), (Int64[],)]),
    (ba_vecf,  (Vector{Float64},),   [([1.5, -0.5],), ([NaN],)]),
    (ba_point, (APoint,),            [(APoint(2.0, 3.0),), (APoint(-0.0, NaN),)]),
    (ba_tup,   (Tuple{Int64,Float64},), [((3, 1.4),), ((-2, -1.6),)]),
    (ba_push,  (Vector{Int64},),     [([1, 2],), (Int64[],)]),
    (ba_setidx, (Vector{Float64},),  [([2.5, 1.0],)]),
    (ba_mut,   (ACounter,),          [(ACounter(10),), (ACounter(-3),)]),
    (ba_sort,  (Vector{Int64},),     [([3, 1, 2],), ([5],)]),
]

const FRONTIER = [
    (ba_vecvec,  (Vector{Vector{Int64}},), [([[1, 2], [3]],)]),
    (ba_vstruct, (Vector{APoint},),        [([APoint(1.0, 2.0), APoint(3.0, 4.0)],)]),
]

function check_case(fn, argtypes, inputs)
    rt = Base.code_typed(fn, argtypes)[1][2]
    isconcretetype(rt) || return (:abstract_ret, rt)
    bridge_supported(rt) || return (:unsupported_ret, rt)
    all(args_supported, argtypes) || return (:unsupported_arg, argtypes)
    rdesc = descriptor(rt)[1]
    pdescs = [FuzzBridgeArgs.ismutable_shape(T) ? descriptor(T)[1] : nothing for T in argtypes]
    res = bridge_run_args(fn, argtypes, [deepcopy(t) for t in inputs]; rettype = rt)
    res === :no_node && return (:no_node, nothing)
    res === :unsupported && return (:unsupported, nothing)
    res isa Pair && return (res.first, res.second)
    for (i, tup) in enumerate(inputs)
        post_native = deepcopy(tup)                      # native runs on its own copy
        native = fn(post_native...)
        st = res[i][1]
        st === :ok || return (:trap, (tup, res[i][2]))
        tree_matches(rdesc, native, res[i][2]) ||
            return (:ret_mismatch, (tup, native, tree_decode(rdesc, res[i][2])))
        post = res[i][3]
        for j in eachindex(tup)
            pdescs[j] === nothing && continue
            tree_matches(pdescs[j], post_native[j], post[j]) ||
                return (:mutation_mismatch, (tup, j, post_native[j], tree_decode(pdescs[j], post[j])))
        end
    end
    return (:ok, nothing)
end

if !FuzzHarness.NODE_OK
    @info "Node.js unavailable"; exit(0)
end

println("== CORE (args + mutation parity) ==")
@testset "bridge args round-trips" begin
    for (fn, at, ins) in CORE
        st, detail = check_case(fn, at, ins)
        st === :ok || println("  ✗ $(nameof(fn)): $st — $(first(string(detail), 160))")
        @test st === :ok
    end
end

println("\n== FRONTIER (reported) ==")
for (fn, at, ins) in FRONTIER
    st, detail = check_case(fn, at, ins)
    println("  ", st === :ok ? "✓ " : "△ ", "$(nameof(fn)) → $st",
            st === :ok ? "" : " ($(first(string(detail), 140)))")
end
