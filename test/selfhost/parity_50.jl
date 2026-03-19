# parity_50.jl — PHASE-3-T01: Self-hosting parity test suite
#
# 50 functions: compile via server-only path AND full self-hosting path.
# Compare: execution results must match native Julia.
#
# Run: julia +1.12 --project=. test/selfhost/parity_50.jl

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "utils.jl"))

println("=== PHASE-3-T01: Self-Hosting Parity — 50 Functions ===\n")

# ═══════════════════════════════════════════════════════════════════════════════
# Define 50 test functions covering all supported Julia features
# ═══════════════════════════════════════════════════════════════════════════════

# --- Arithmetic (10) ---
p01_add(x::Int64, y::Int64)::Int64 = x + y
p02_sub(x::Int64, y::Int64)::Int64 = x - y
p03_mul(x::Int64, y::Int64)::Int64 = x * y
p04_div(x::Int64, y::Int64)::Int64 = x ÷ y
p05_mod(x::Int64, y::Int64)::Int64 = x % y
p06_neg(x::Int64)::Int64 = -x
p07_add_f64(x::Float64, y::Float64)::Float64 = x + y
p08_mul_f64(x::Float64, y::Float64)::Float64 = x * y
p09_inc(x::Int64)::Int64 = x + Int64(1)
p10_square(x::Int64)::Int64 = x * x

# --- Conditionals (8) ---
p11_abs(x::Int64)::Int64 = x >= Int64(0) ? x : -x
p12_max(x::Int64, y::Int64)::Int64 = x > y ? x : y
p13_min(x::Int64, y::Int64)::Int64 = x < y ? x : y
p14_sign(x::Int64)::Int64 = x > Int64(0) ? Int64(1) : (x < Int64(0) ? Int64(-1) : Int64(0))
p15_clamp(x::Float64)::Float64 = x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x)
p16_even(x::Int64)::Int64 = x % Int64(2) == Int64(0) ? Int64(1) : Int64(0)
p17_pos(x::Int64)::Int64 = x > Int64(0) ? Int64(1) : Int64(0)
p18_zero(x::Int64)::Int64 = x == Int64(0) ? Int64(1) : Int64(0)

# --- Bitwise (5) ---
p19_xor(x::Int64, y::Int64)::Int64 = x ⊻ y
p20_and(x::Int64, y::Int64)::Int64 = x & y
p21_or(x::Int64, y::Int64)::Int64 = x | y
p22_shl(x::Int64)::Int64 = x << Int64(1)
p23_shr(x::Int64)::Int64 = x >> Int64(1)

# --- Float operations (5) ---
p24_fma(a::Float64, b::Float64, c::Float64)::Float64 = a * b + c
p25_f_abs(x::Float64)::Float64 = x < 0.0 ? -x : x
p26_reciprocal(x::Float64)::Float64 = 1.0 / x
p27_avg(a::Float64, b::Float64)::Float64 = (a + b) / 2.0
p28_dist(x1::Float64, x2::Float64)::Float64 = (x1 - x2) < 0.0 ? x2 - x1 : x1 - x2

# --- Multi-arg (5) ---
p29_sum3(a::Int64, b::Int64, c::Int64)::Int64 = a + b + c
p30_weighted(a::Float64, b::Float64, w::Float64)::Float64 = a * w + b * (1.0 - w)
p31_divmod(a::Int64, b::Int64)::Int64 = a ÷ b + a % b
p32_min3(a::Int64, b::Int64, c::Int64)::Int64 = begin
    m = a < b ? a : b
    m < c ? m : c
end
p33_clamp_range(x::Int64, lo::Int64, hi::Int64)::Int64 = x < lo ? lo : (x > hi ? hi : x)

# --- Nested expressions (5) ---
p34_poly2(x::Int64)::Int64 = x * x + Int64(2) * x + Int64(1)
p35_poly3(x::Int64)::Int64 = x * x * x + x * x + x + Int64(1)
p36_compose(x::Int64)::Int64 = (x + Int64(1)) * (x + Int64(1))
p37_diff_sq(a::Int64, b::Int64)::Int64 = (a + b) * (a - b)
p38_bool_to_int(x::Int64, y::Int64)::Int64 = (x > y ? Int64(1) : Int64(0)) + (x == y ? Int64(1) : Int64(0))

# --- Conversion/casting (4) ---
p39_i32_to_i64(x::Int32)::Int64 = Int64(x)
p40_f64_to_i64(x::Float64)::Int64 = Int64(trunc(x))
p41_i64_to_f64(x::Int64)::Float64 = Float64(x)
p42_double_i32(x::Int32)::Int32 = x + x

# --- Loop patterns (4) ---
p43_sum_n(n::Int64)::Int64 = begin
    s = Int64(0); i = Int64(1)
    while i <= n; s += i; i += Int64(1); end; s
end
p44_factorial(n::Int64)::Int64 = begin
    f = Int64(1); i = Int64(1)
    while i <= n; f *= i; i += Int64(1); end; f
end
p45_count_bits(x::Int64)::Int64 = begin
    c = Int64(0); v = x
    while v > Int64(0); c += v & Int64(1); v >>= Int64(1); end; c
end
p46_power(base::Int64, exp::Int64)::Int64 = begin
    r = Int64(1); i = Int64(0)
    while i < exp; r *= base; i += Int64(1); end; r
end

# --- Mixed type (4) ---
p47_mixed(x::Int64)::Int64 = x * Int64(3) + Int64(7)
p48_scale(x::Float64, s::Float64)::Float64 = x * s
p49_lerp(a::Float64, b::Float64, t::Float64)::Float64 = a + (b - a) * t
p50_norm_int(x::Int64, max::Int64)::Float64 = Float64(x) / Float64(max)

# ═══════════════════════════════════════════════════════════════════════════════
# Test all 50 functions
# ═══════════════════════════════════════════════════════════════════════════════

all_tests = [
    # (function, args_list, name)
    (p01_add, [(Int64(3), Int64(4)), (Int64(-1), Int64(1))], "add"),
    (p02_sub, [(Int64(10), Int64(3)), (Int64(0), Int64(5))], "sub"),
    (p03_mul, [(Int64(6), Int64(7)), (Int64(-2), Int64(3))], "mul"),
    (p04_div, [(Int64(17), Int64(5)), (Int64(10), Int64(2))], "div"),
    (p05_mod, [(Int64(17), Int64(5)), (Int64(10), Int64(3))], "mod"),
    (p06_neg, [(Int64(5),), (Int64(-3),)], "neg"),
    (p07_add_f64, [(1.5, 2.5), (-1.0, 1.0)], "add_f64"),
    (p08_mul_f64, [(2.0, 3.0), (0.5, 4.0)], "mul_f64"),
    (p09_inc, [(Int64(0),), (Int64(-1),)], "inc"),
    (p10_square, [(Int64(5),), (Int64(-3),)], "square"),
    (p11_abs, [(Int64(5),), (Int64(-5),), (Int64(0),)], "abs"),
    (p12_max, [(Int64(3), Int64(7)), (Int64(7), Int64(3))], "max"),
    (p13_min, [(Int64(3), Int64(7)), (Int64(7), Int64(3))], "min"),
    (p14_sign, [(Int64(5),), (Int64(-3),), (Int64(0),)], "sign"),
    (p15_clamp, [(-0.5,), (0.5,), (1.5,)], "clamp"),
    (p16_even, [(Int64(4),), (Int64(3),)], "even"),
    (p17_pos, [(Int64(5),), (Int64(-1),), (Int64(0),)], "pos"),
    (p18_zero, [(Int64(0),), (Int64(1),)], "zero"),
    (p19_xor, [(Int64(0xff), Int64(0x0f)),], "xor"),
    (p20_and, [(Int64(0xff), Int64(0x0f)),], "and"),
    (p21_or, [(Int64(0xf0), Int64(0x0f)),], "or"),
    (p22_shl, [(Int64(1),), (Int64(5),)], "shl"),
    (p23_shr, [(Int64(16),), (Int64(5),)], "shr"),
    (p24_fma, [(2.0, 3.0, 1.0),], "fma"),
    (p25_f_abs, [(-3.14,), (2.71,)], "f_abs"),
    (p26_reciprocal, [(2.0,), (0.5,)], "reciprocal"),
    (p27_avg, [(10.0, 20.0),], "avg"),
    (p28_dist, [(1.0, 5.0), (5.0, 1.0)], "dist"),
    (p29_sum3, [(Int64(1), Int64(2), Int64(3)),], "sum3"),
    (p30_weighted, [(10.0, 20.0, 0.3),], "weighted"),
    (p31_divmod, [(Int64(17), Int64(5)),], "divmod"),
    (p32_min3, [(Int64(5), Int64(3), Int64(7)),], "min3"),
    (p33_clamp_range, [(Int64(5), Int64(0), Int64(10)), (Int64(-1), Int64(0), Int64(10)), (Int64(15), Int64(0), Int64(10))], "clamp_range"),
    (p34_poly2, [(Int64(3),), (Int64(0),)], "poly2"),
    (p35_poly3, [(Int64(2),),], "poly3"),
    (p36_compose, [(Int64(4),),], "compose"),
    (p37_diff_sq, [(Int64(5), Int64(3)),], "diff_sq"),
    (p38_bool_to_int, [(Int64(5), Int64(3)), (Int64(3), Int64(3)), (Int64(1), Int64(5))], "bool_to_int"),
    (p39_i32_to_i64, [(Int32(42),),], "i32_to_i64"),
    (p40_f64_to_i64, [(3.7,), (-2.9,)], "f64_to_i64"),
    (p41_i64_to_f64, [(Int64(42),),], "i64_to_f64"),
    (p42_double_i32, [(Int32(21),),], "double_i32"),
    (p43_sum_n, [(Int64(10),), (Int64(0),)], "sum_n"),
    (p44_factorial, [(Int64(5),), (Int64(1),)], "factorial"),
    (p45_count_bits, [(Int64(255),), (Int64(0),)], "count_bits"),
    (p46_power, [(Int64(2), Int64(10)),], "power"),
    (p47_mixed, [(Int64(5),),], "mixed"),
    (p48_scale, [(3.0, 2.5),], "scale"),
    (p49_lerp, [(0.0, 10.0, 0.3),], "lerp"),
    (p50_norm_int, [(Int64(25), Int64(100)),], "norm_int"),
]

pass_count = 0
fail_count = 0
total_cases = 0

for (f, args_list, name) in all_tests
    for args in args_list
        global total_cases += 1
        try
            r = compare_julia_wasm(f, args...)
            if r.pass
                global pass_count += 1
            else
                global fail_count += 1
                println("  ✗ $name($(join(args, ","))) — expected=$(r.expected) got=$(r.actual)")
            end
        catch e
            global fail_count += 1
            println("  ✗ $name($(join(args, ","))) — error: $(sprint(showerror, e)[1:min(80,end)])")
        end
    end
end

println("  Results: $pass_count/$total_cases CORRECT ($fail_count failed)\n")

@testset "PHASE-3-T01: Self-hosting parity — 50 functions" begin
    @test pass_count == total_cases
    @test fail_count == 0
    @test total_cases >= 50
end

println("\n=== PHASE-3-T01 test complete ===")
