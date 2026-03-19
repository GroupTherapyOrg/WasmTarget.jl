# regression_typeinf.jl — PHASE-2-T02: Typeinf regression test suite
#
# Edge cases for browser (WasmInterpreter) typeinf:
# 1. Various arithmetic types
# 2. Conditional branches
# 3. Loops
# 4. Float operations
# 5. Multi-argument functions
# 6. Nested calls
# 7. User-defined structs
# 8. Bitwise operations
# 9. Division/remainder
# 10. Boolean-returning functions
#
# Uses compare_server_vs_browser_typeinf batch API (loads overrides once).
#
# Run: julia +1.12 --project=. test/selfhost/regression_typeinf.jl

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "utils.jl"))

# ─── Test functions ────────────────────────────────────────────────────────────

# 1. Simple addition
reg_add(x::Int64)::Int64 = x + Int64(1)

# 2. Subtraction
reg_sub(a::Int64, b::Int64)::Int64 = a - b

# 3. Multiplication
reg_mul(x::Int64)::Int64 = x * Int64(3)

# 4. Float addition
reg_fadd(a::Float64, b::Float64)::Float64 = a + b

# 5. Float multiplication
reg_fmul(a::Float64, b::Float64)::Float64 = a * b

# 6. Conditional (ternary)
reg_abs(x::Int64)::Int64 = x >= Int64(0) ? x : -x

# 7. Nested conditional
reg_sign(x::Int64)::Int64 = x > Int64(0) ? Int64(1) : (x < Int64(0) ? Int64(-1) : Int64(0))

# 8. Loop (sum)
reg_sum(n::Int64)::Int64 = begin
    s = Int64(0)
    i = Int64(1)
    while i <= n
        s = s + i
        i = i + Int64(1)
    end
    return s
end

# 9. Float conditional
reg_clamp(x::Float64)::Float64 = x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x)

# 10. FMA (fused multiply-add)
reg_fma(a::Float64, b::Float64, c::Float64)::Float64 = a * b + c

# 11. Integer division + remainder
reg_divmod(a::Int64, b::Int64)::Int64 = a ÷ b + a % b

# 12. XOR
reg_xor(a::Int64, b::Int64)::Int64 = a ⊻ b

# 13. Boolean expression (returns Int64 for marshaling)
reg_gt(a::Int64, b::Int64)::Int64 = a > b ? Int64(1) : Int64(0)

# 14. Multi-step computation
reg_quad(x::Int64)::Int64 = x * x + Int64(2) * x + Int64(1)

# 15. Float subtraction
reg_dist(x1::Float64, x2::Float64)::Float64 = begin
    d = x1 - x2
    d * d
end

# 16. User struct
struct RegPoint
    x::Float64
    y::Float64
end

reg_point_sum(x::Float64, y::Float64)::Float64 = begin
    p = RegPoint(x, y)
    p.x + p.y
end

# 17. Struct field access
reg_point_x(x::Float64, y::Float64)::Float64 = begin
    p = RegPoint(x, y)
    p.x
end

# 18. Two-arg integer
reg_max(a::Int64, b::Int64)::Int64 = a > b ? a : b

# 19. Loop with conditional
reg_count_pos(n::Int64)::Int64 = begin
    count = Int64(0)
    i = Int64(-5)
    while i <= n
        if i > Int64(0)
            count = count + Int64(1)
        end
        i = i + Int64(1)
    end
    return count
end

# 20. Identity (simplest possible)
reg_id(x::Int64)::Int64 = x

# ─── Run batch comparison ──────────────────────────────────────────────────────

functions = [
    (reg_add,       (Int64,),                       "reg_add",        [(Int64(5),), (Int64(0),), (Int64(-3),)]),
    (reg_sub,       (Int64, Int64),                  "reg_sub",        [(Int64(10), Int64(3)), (Int64(0), Int64(0))]),
    (reg_mul,       (Int64,),                       "reg_mul",        [(Int64(7),), (Int64(0),)]),
    (reg_fadd,      (Float64, Float64),              "reg_fadd",       [(3.0, 4.0), (0.0, 0.0)]),
    (reg_fmul,      (Float64, Float64),              "reg_fmul",       [(2.0, 3.0), (0.5, 4.0)]),
    (reg_abs,       (Int64,),                       "reg_abs",        [(Int64(5),), (Int64(-5),), (Int64(0),)]),
    (reg_sign,      (Int64,),                       "reg_sign",       [(Int64(42),), (Int64(-7),), (Int64(0),)]),
    (reg_sum,       (Int64,),                       "reg_sum",        [(Int64(5),), (Int64(10),), (Int64(0),)]),
    (reg_clamp,     (Float64,),                     "reg_clamp",      [(-0.5,), (0.5,), (1.5,)]),
    (reg_fma,       (Float64, Float64, Float64),     "reg_fma",        [(2.0, 3.0, 1.0), (0.0, 0.0, 5.0)]),
    (reg_divmod,    (Int64, Int64),                  "reg_divmod",     [(Int64(17), Int64(5)), (Int64(10), Int64(3))]),
    (reg_xor,       (Int64, Int64),                  "reg_xor",        [(Int64(0xff), Int64(0x0f)), (Int64(0), Int64(0))]),
    (reg_gt,        (Int64, Int64),                  "reg_gt",         [(Int64(5), Int64(3)), (Int64(3), Int64(5)), (Int64(3), Int64(3))]),
    (reg_quad,      (Int64,),                       "reg_quad",       [(Int64(3),), (Int64(0),), (Int64(-1),)]),
    (reg_dist,      (Float64, Float64),              "reg_dist",       [(5.0, 3.0), (0.0, 0.0)]),
    (reg_point_sum, (Float64, Float64),              "reg_point_sum",  [(3.0, 4.0), (0.0, 0.0)]),
    (reg_point_x,   (Float64, Float64),              "reg_point_x",    [(1.0, 2.0)]),
    (reg_max,       (Int64, Int64),                  "reg_max",        [(Int64(5), Int64(3)), (Int64(3), Int64(5))]),
    (reg_count_pos, (Int64,),                       "reg_count_pos",  [(Int64(5),), (Int64(0),)]),
    (reg_id,        (Int64,),                       "reg_id",         [(Int64(42),), (Int64(0),)]),
]

println("=== PHASE-2-T02: Typeinf Regression Test Suite ===\n")

results = compare_server_vs_browser_typeinf(functions)

# Print results
typeinf_pass = 0
exec_pass = 0
total_exec = 0
for r in results
    all_exec_ok = all(er -> er.pass, r.exec_results)
    if r.types_match
        global typeinf_pass += 1
    end
    n_exec_ok = count(er -> er.pass, r.exec_results)
    global exec_pass += n_exec_ok
    global total_exec += length(r.exec_results)

    status = r.pass ? "✓" : "✗"
    println("  $status $(r.name): type=$(r.server_type) match=$(r.types_match) exec=$(n_exec_ok)/$(length(r.exec_results))")
end
println("\nTypeinf match: $typeinf_pass/$(length(results))")
println("Execution: $exec_pass/$total_exec correct")

# ─── Tests ────────────────────────────────────────────────────────────────────

@testset "Phase 2 TypeInf Regression — PHASE-2-T02" begin
    @testset "TypeInf type accuracy" begin
        for r in results
            @test r.types_match
        end
    end

    @testset "Execution correctness" begin
        for r in results
            for er in r.exec_results
                @test er.pass
            end
        end
    end

    @testset "Summary" begin
        @test typeinf_pass >= 20  # All 20 functions match
        @test exec_pass == total_exec  # All test cases pass
    end
end

println("\n=== PHASE-2-T02: Regression test complete ===")
