# ============================================================================
# Bridge round-trip validation — run standalone:
#   julia --project=test/fuzz test/fuzz/test_bridge.jl
# ============================================================================
#
# Two tiers:
#   CORE     — types the main suite already proves WasmTarget supports
#              (scalars of every width, floats, tuples/namedtuples, structs,
#              flat vectors). These MUST round-trip: a failure here is a bridge
#              bug (or a compiler regression) and reds this file.
#   FRONTIER — shapes whose compiler support is unproven (nested vectors,
#              vectors of structs, strings/chars from arbitrary exprs…). These
#              are REPORTED, not asserted: each failing frontier row is a real
#              finding to ledger, exactly what the apparatus exists to surface.

using Test

include(joinpath(@__DIR__, "harness.jl")); using .FuzzHarness
include(joinpath(@__DIR__, "bridge.jl"));  using .FuzzBridge

# ── Test fixture types ───────────────────────────────────────────────────────
struct BPoint; x::Float64; y::Float64; end
struct BNest; p::BPoint; n::Int64; end
struct BPara{T}; a::T; b::T; end
mutable struct BMut; v::Int64; w::Float64; end

# ── Targets (concrete inferred return types; scalar args) ────────────────────
br_i64(x::Int64)      = x * 3 - 1
br_i32(x::Int64)      = Int32(x % 1000)
br_i16(x::Int64)      = Int16(x % 100)
br_i8(x::Int64)       = Int8(x % 50)
br_u8(x::Int64)       = UInt8(x & 255)
br_u32(x::Int64)      = UInt32(x & 0xFFFFFFFF)
br_u64(x::Int64)      = reinterpret(UInt64, x)
br_bool(x::Int64)     = x > 0
br_f64(x::Float64)    = x * 2.0 + 0.5
br_f32(x::Float64)    = Float32(x) * 2.0f0
br_f64_big(x::Float64) = Float64(typemax(Int64)) + x      # the JSON-0.21 killer
br_f64_nan(x::Float64) = x / x                            # NaN at 0.0, ±Inf at ±0-adjacent
br_tuple(x::Int64)    = (x, x + 1, Float64(x) / 3)
br_nt(x::Int64)       = (a = x, b = Float64(x) * 1.5, c = x > 0)
br_point(x::Float64)  = BPoint(x, -x)
br_nest(x::Float64)   = BNest(BPoint(x, x * 2), Int64(7))
br_para(x::Float64)   = BPara{Float64}(x, x * x)
br_mut(x::Int64)      = BMut(x, Float64(x))
br_vec_i(x::Int64)    = Int64[x, x + 1, x * 2]
br_vec_f(x::Float64)  = Float64[x, -x, x * x]
# frontier ↓
br_char(x::Int64)     = Char(65 + abs(x % 26))
br_str(x::Int64)      = string(x)
br_vecvec(x::Int64)   = [Int64[x], Int64[x, x + 1]]
br_vec_struct(x::Float64) = BPoint[BPoint(x, 1.0), BPoint(2.0, x)]
br_tup_nest(x::Int64) = ((x, x + 1), (Float64(x), x > 0))
br_vec_tup(x::Int64)  = [(x, Float64(x)), (x + 1, 0.5)]

const CORE = [
    # (former frontier — all proven to round-trip; new frontier = Dict/Set/ranges/unions)
    (br_char, (Int64,),   [(0,), (25,), (-3,)]),
    (br_str,  (Int64,),   [(12345,), (-7,)]),
    (br_vecvec, (Int64,), [(3,)]),
    (br_vec_struct, (Float64,), [(1.5,)]),
    (br_tup_nest, (Int64,), [(2,)]),
    (br_vec_tup, (Int64,), [(2,)]),
    (br_i64,  (Int64,),   [(5,), (-3,), (typemax(Int64) ÷ 4,)]),
    (br_i32,  (Int64,),   [(5,), (-999,)]),
    (br_i16,  (Int64,),   [(7,), (-42,)]),
    (br_i8,   (Int64,),   [(3,), (-49,)]),
    (br_u8,   (Int64,),   [(255,), (0,), (129,)]),
    (br_u32,  (Int64,),   [(Int64(0xFFFFFFFF),), (1,)]),
    (br_u64,  (Int64,),   [(-1,), (42,)]),
    (br_bool, (Int64,),   [(1,), (-1,), (0,)]),
    (br_f64,  (Float64,), [(1.5,), (-0.0,), (Inf,), (NaN,)]),
    (br_f32,  (Float64,), [(1.5,), (-2.25,)]),
    (br_f64_big, (Float64,), [(0.0,), (1.0e18,)]),
    (br_f64_nan, (Float64,), [(0.0,), (2.0,)]),
    (br_tuple, (Int64,),  [(5,), (-7,)]),
    (br_nt,   (Int64,),   [(5,), (0,)]),
    (br_point, (Float64,), [(1.25,), (-0.0,), (NaN,)]),
    (br_nest, (Float64,), [(2.5,)]),
    (br_para, (Float64,), [(3.0,), (-1.5,)]),
    (br_mut,  (Int64,),   [(9,), (-9,)]),
    (br_vec_i, (Int64,),  [(4,), (-1,)]),
    (br_vec_f, (Float64,), [(2.0,), (NaN,)]),
]

const FRONTIER = Any[]   # next: Dict, Set, ranges, small Unions, Nothing/Missing

# ── Driver ───────────────────────────────────────────────────────────────────
function check_case(fn, argtypes, inputs)
    rt = Base.code_typed(fn, argtypes)[1][2]
    isconcretetype(rt) || return (:abstract_ret, rt)
    bridge_supported(rt) || return (:unsupported_desc, rt)
    desc = descriptor(rt)[1]
    res = bridge_run(fn, argtypes, inputs; rettype = rt)
    res === :no_node && return (:no_node, nothing)
    res isa Pair && return (res.first, res.second)
    for (i, tup) in enumerate(inputs)
        native = fn(tup...)
        st, payload = res[i]
        st === :ok || return (:trap, (tup, payload))
        tree_matches(desc, native, payload) || return (:mismatch, (tup, native, payload))
    end
    return (:ok, nothing)
end

if !FuzzHarness.NODE_OK
    @info "Node.js unavailable — bridge round-trip cannot run"
    exit(0)
end

println("== CORE (must round-trip) ==")
@testset "bridge core round-trips" begin
    for (fn, at, ins) in CORE
        st, detail = check_case(fn, at, ins)
        st === :ok || println("  ✗ $(nameof(fn)): $st — $detail")
        @test st === :ok
    end
end

println("\n== FRONTIER (reported, not asserted) ==")
frontier_ok = String[]
frontier_bad = String[]
for (fn, at, ins) in FRONTIER
    st, detail = check_case(fn, at, ins)
    line = "$(nameof(fn)) → $st" * (st === :ok ? "" : " ($(first(string(detail), 140)))")
    push!(st === :ok ? frontier_ok : frontier_bad, line)
    println("  ", st === :ok ? "✓ " : "△ ", line)
end
println("\nfrontier: $(length(frontier_ok)) round-trip, $(length(frontier_bad)) boundary findings (candidates for the ledger)")
