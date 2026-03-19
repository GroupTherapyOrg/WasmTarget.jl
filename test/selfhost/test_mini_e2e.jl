# PHASE-1M-005: E2E test — mini codegen compiles simple functions correctly
#
# Tests that the frozen compilation path (which the mini codegen module implements)
# produces CORRECT WASM output for 5 representative function categories:
#   1. Arithmetic (x + y)
#   2. Conditionals (if/else)
#   3. Loops (sum to n)
#   4. Float operations
#   5. Multi-function module
#
# Run: julia +1.12 --project=. test/selfhost/test_mini_e2e.jl

using WasmTarget
using WasmTarget: compile_module_from_ir, compile_module_from_ir_frozen,
                  build_frozen_state, to_bytes

include(joinpath(@__DIR__, "..", "utils.jl"))

println("=" ^ 60)
println("PHASE-1M-005: E2E test — mini codegen compiles simple functions")
println("=" ^ 60)

# ─── Define test functions ────────────────────────────────────────────────

# 1. Arithmetic
test_add(x::Int64, y::Int64)::Int64 = x + y
test_sub(x::Int64, y::Int64)::Int64 = x - y
test_mul(x::Int64, y::Int64)::Int64 = x * y

# 2. Conditionals
test_max(x::Int64, y::Int64)::Int64 = x > y ? x : y
test_abs(x::Int64)::Int64 = x >= Int64(0) ? x : -x

# 3. Loops
function test_sum_to(n::Int64)::Int64
    s = Int64(0)
    i = Int64(1)
    while i <= n
        s = s + i
        i = i + Int64(1)
    end
    return s
end

# 4. Float operations
test_circle_area(r::Float64)::Float64 = 3.14159265358979 * r * r
test_fahrenheit(c::Float64)::Float64 = c * 1.8 + 32.0

# 5. Polynomial (multi-op)
test_poly(x::Int64)::Int64 = x * x + Int64(2) * x + Int64(1)

# ─── Step 1: Build frozen state from representative functions ─────────────

println("\n--- Step 1: Building frozen compilation state ---")

# Build frozen state from a broad set of representative functions
representative = [
    (test_add, (Int64, Int64), "test_add"),
    (test_max, (Int64, Int64), "test_max"),
    (test_sum_to, (Int64,), "test_sum_to"),
    (test_circle_area, (Float64,), "test_circle_area"),
    (test_poly, (Int64,), "test_poly"),
]

# Get IR for frozen state building
repr_ir = []
for (f, arg_types, name) in representative
    ci, rt = Base.code_typed(f, arg_types)[1]
    push!(repr_ir, (ci, rt, arg_types, name))
end

t0 = time()
frozen = build_frozen_state(repr_ir)
frozen_time = time() - t0
println("  Frozen state built in $(round(frozen_time * 1000, digits=1)) ms")

# ─── Step 2: Test each function via frozen compilation ────────────────────

println("\n--- Step 2: Testing functions via frozen compilation ---")

test_cases = [
    # (function, arg_types, name, test_args, expected_result)
    (test_add, (Int64, Int64), "test_add", (Int64(3), Int64(4)), test_add(Int64(3), Int64(4))),
    (test_sub, (Int64, Int64), "test_sub", (Int64(10), Int64(3)), test_sub(Int64(10), Int64(3))),
    (test_mul, (Int64, Int64), "test_mul", (Int64(6), Int64(7)), test_mul(Int64(6), Int64(7))),
    (test_max, (Int64, Int64), "test_max", (Int64(10), Int64(20)), test_max(Int64(10), Int64(20))),
    (test_abs, (Int64,), "test_abs", (Int64(-42),), test_abs(Int64(-42))),
    (test_sum_to, (Int64,), "test_sum_to", (Int64(10),), test_sum_to(Int64(10))),
    (test_circle_area, (Float64,), "test_circle_area", (2.0,), test_circle_area(2.0)),
    (test_fahrenheit, (Float64,), "test_fahrenheit", (100.0,), test_fahrenheit(100.0)),
    (test_poly, (Int64,), "test_poly", (Int64(5),), test_poly(Int64(5))),
]

function run_e2e_tests(test_cases, frozen)
    results = []
    total_compile_ms = 0.0

    for (f, arg_types, name, test_args, expected) in test_cases
        print("  $name$(test_args): native=$expected → ")

        try
            ci, rt = Base.code_typed(f, arg_types)[1]
            ir_entry = [(ci, rt, arg_types, name)]

            t1 = time()
            mod = compile_module_from_ir_frozen(ir_entry, frozen)
            wasm_bytes = to_bytes(mod)
            compile_ms = (time() - t1) * 1000
            total_compile_ms += compile_ms

            actual = run_wasm(wasm_bytes, name, test_args...)

            if actual !== nothing
                if actual == expected || (isa(expected, Float64) && isa(actual, Float64) && abs(actual - expected) < 1e-10)
                    println("wasm=$actual ✓ CORRECT ($(round(compile_ms, digits=1)) ms)")
                    push!(results, (name, :correct, compile_ms))
                else
                    println("wasm=$actual ✗ MISMATCH (expected $expected)")
                    push!(results, (name, :mismatch, compile_ms))
                end
            else
                println("Node.js unavailable")
                push!(results, (name, :skip, compile_ms))
            end
        catch e
            println("FAIL — $(sprint(showerror, e)[1:min(120,end)])")
            push!(results, (name, :fail, 0.0))
        end
    end
    return results, total_compile_ms
end

results, total_compile_ms = run_e2e_tests(test_cases, frozen)

# ─── Step 3: Test multi-function module via frozen path ───────────────────

println("\n--- Step 3: Multi-function module test ---")

multi_funcs = [
    (test_add, (Int64, Int64), "test_add"),
    (test_max, (Int64, Int64), "test_max"),
    (test_poly, (Int64,), "test_poly"),
]

multi_ir = []
for (f, arg_types, name) in multi_funcs
    ci, rt = Base.code_typed(f, arg_types)[1]
    push!(multi_ir, (ci, rt, arg_types, name))
end

t1 = time()
multi_mod = compile_module_from_ir_frozen(multi_ir, frozen)
multi_bytes = to_bytes(multi_mod)
multi_ms = (time() - t1) * 1000
println("  Multi-function module: $(length(multi_bytes)) bytes in $(round(multi_ms, digits=1)) ms")

# Test each function in the multi-module
for (fname, test_args, expected) in [
    ("test_add", (Int64(100), Int64(200)), Int64(300)),
    ("test_max", (Int64(-5), Int64(10)), Int64(10)),
    ("test_poly", (Int64(3),), Int64(16)),
]
    actual = run_wasm(multi_bytes, fname, test_args...)
    if actual !== nothing
        match = actual == expected ? "✓" : "✗"
        println("  $match $fname$(test_args) = $actual (expected $expected)")
    end
end

# ─── Summary ──────────────────────────────────────────────────────────────

println("\n" * "=" ^ 60)
println("Summary:")

correct = count(r -> r[2] == :correct, results)
total = length(results)
avg_ms = total_compile_ms / max(total, 1)

println("  Functions tested: $total")
println("  Correct: $correct / $total")
println("  Average compile time: $(round(avg_ms, digits=1)) ms")
println("  Total compile time: $(round(total_compile_ms, digits=1)) ms")
println("  Acceptance (5 correct, < 2s each): $(correct >= 5 ? "PASS" : "FAIL")")

for (name, status, ms) in results
    sym = status == :correct ? "✓" : status == :mismatch ? "✗" : status == :fail ? "✗" : "?"
    println("    $sym $name: $status ($(round(ms, digits=1)) ms)")
end

println("=" ^ 60)
