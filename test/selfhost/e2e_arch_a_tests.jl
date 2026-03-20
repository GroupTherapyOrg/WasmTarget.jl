# TEST-001: Architecture A Regression Test Suite — 20 Functions
#
# For each function: server serialize_ir_entries → JSON → Node.js JS mini-compiler → execute
# Must use WASM codegen path (JS mini-compiler from deserialize_codeinfo.cjs), NOT native compile.
#
# Run: julia +1.12 --project=. test/selfhost/e2e_arch_a_tests.jl

using Test
using WasmTarget
using WasmTarget: serialize_ir_entries

println("=" ^ 60)
println("TEST-001: Architecture A Regression Tests — 20 functions")
println("=" ^ 60)

# ═══════════════════════════════════════════════════════════════════════════════
# Define 20 test functions (all i64 arithmetic, no branches)
# ═══════════════════════════════════════════════════════════════════════════════

f_square_plus_one(x::Int64) = x * x + Int64(1)
f_add_one(x::Int64) = x + Int64(1)
f_double(x::Int64) = x * Int64(2)
f_square(x::Int64) = x * x
f_cube(x::Int64) = x * x * x
f_sum2(x::Int64, y::Int64) = x + y
f_diff(x::Int64, y::Int64) = x - y
f_prod(x::Int64, y::Int64) = x * y
f_sum3(x::Int64, y::Int64, z::Int64) = x + y + z
f_poly2(x::Int64) = x * x + x + Int64(1)
f_diff_of_sq(x::Int64, y::Int64) = x * x - y * y
f_prod_sum(x::Int64, y::Int64) = x * y + x + y
f_triple(x::Int64) = x + x + x
f_ten_x_plus_5(x::Int64) = x * Int64(10) + Int64(5)
f_identity(x::Int64) = x
f_constant(x::Int64) = Int64(42)
f_sum_of_sq(x::Int64, y::Int64) = x * x + y * y
f_quadratic(x::Int64) = Int64(3) * x * x + Int64(2) * x + Int64(1)
f_sub_one(x::Int64) = x - Int64(1)
f_mul_add(x::Int64, y::Int64, z::Int64) = x * y + z

# Function list with arg types, name, and test cases
test_functions = [
    (f_square_plus_one, (Int64,), "f_square_plus_one",
     [(5, 26), (0, 1), (-3, 10), (10, 101), (1, 2)]),
    (f_add_one, (Int64,), "f_add_one",
     [(0, 1), (5, 6), (-1, 0), (100, 101), (-100, -99)]),
    (f_double, (Int64,), "f_double",
     [(0, 0), (5, 10), (-3, -6), (100, 200), (1, 2)]),
    (f_square, (Int64,), "f_square",
     [(0, 0), (5, 25), (-3, 9), (10, 100), (1, 1)]),
    (f_cube, (Int64,), "f_cube",
     [(0, 0), (3, 27), (-2, -8), (5, 125), (1, 1)]),
    (f_sum2, (Int64, Int64), "f_sum2",
     [((1, 2), 3), ((0, 0), 0), ((-5, 5), 0), ((10, 20), 30), ((100, -50), 50)]),
    (f_diff, (Int64, Int64), "f_diff",
     [((5, 3), 2), ((0, 0), 0), ((3, 5), -2), ((10, 1), 9), ((-5, -3), -2)]),
    (f_prod, (Int64, Int64), "f_prod",
     [((3, 4), 12), ((0, 5), 0), ((-3, 4), -12), ((7, 7), 49), ((1, 100), 100)]),
    (f_sum3, (Int64, Int64, Int64), "f_sum3",
     [((1, 2, 3), 6), ((0, 0, 0), 0), ((-1, -2, -3), -6), ((10, 20, 30), 60), ((1, 1, 1), 3)]),
    (f_poly2, (Int64,), "f_poly2",
     [(0, 1), (1, 3), (5, 31), (-1, 1), (10, 111)]),
    (f_diff_of_sq, (Int64, Int64), "f_diff_of_sq",
     [((5, 3), 16), ((0, 0), 0), ((3, 5), -16), ((10, 1), 99), ((7, 7), 0)]),
    (f_prod_sum, (Int64, Int64), "f_prod_sum",
     [((2, 3), 11), ((0, 0), 0), ((1, 1), 3), ((5, 10), 65), ((-1, -1), -1)]),
    (f_triple, (Int64,), "f_triple",
     [(0, 0), (1, 3), (5, 15), (-3, -9), (100, 300)]),
    (f_ten_x_plus_5, (Int64,), "f_ten_x_plus_5",
     [(0, 5), (1, 15), (5, 55), (-1, -5), (10, 105)]),
    (f_identity, (Int64,), "f_identity",
     [(0, 0), (42, 42), (-1, -1), (999, 999), (1, 1)]),
    (f_constant, (Int64,), "f_constant",
     [(0, 42), (1, 42), (-1, 42), (999, 42), (5, 42)]),
    (f_sum_of_sq, (Int64, Int64), "f_sum_of_sq",
     [((3, 4), 25), ((0, 0), 0), ((1, 1), 2), ((5, 12), 169), ((-3, 4), 25)]),
    (f_quadratic, (Int64,), "f_quadratic",
     [(0, 1), (1, 6), (2, 17), (5, 86), (-1, 2)]),
    (f_sub_one, (Int64,), "f_sub_one",
     [(1, 0), (0, -1), (5, 4), (100, 99), (-1, -2)]),
    (f_mul_add, (Int64, Int64, Int64), "f_mul_add",
     [((2, 3, 4), 10), ((0, 5, 1), 1), ((5, 5, 5), 30), ((-2, 3, 1), -5), ((10, 10, 10), 110)]),
]

# ═══════════════════════════════════════════════════════════════════════════════
# Serialize all functions to JSON
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 1: Serialize $(length(test_functions)) functions ---")

ir_entries = Tuple[]
for (f, atypes, name, _) in test_functions
    ci, rt = Base.code_typed(f, atypes; optimize=true)[1]
    push!(ir_entries, (ci, rt, atypes, name))
    println("  $name: $(length(ci.code)) stmts")
end

json_str = serialize_ir_entries(collect(ir_entries))

# Build test_cases array matching entries
import JSON
json_obj = JSON.parse(json_str)

# Add test_cases to JSON
test_cases_json = []
for (_, atypes, _, cases) in test_functions
    cases_arr = []
    for tc in cases
        if length(atypes) == 1
            input, expected = tc
            push!(cases_arr, Dict("inputs" => [input], "expected" => expected))
        else
            inputs, expected = tc
            push!(cases_arr, Dict("inputs" => collect(inputs), "expected" => expected))
        end
    end
    push!(test_cases_json, cases_arr)
end
json_obj["test_cases"] = test_cases_json

json_path = joinpath(@__DIR__, "..", "..", "arch_a_test_data.json")
open(json_path, "w") do f
    write(f, JSON.json(json_obj))
end
println("  JSON: $(filesize(json_path)) bytes")

# ═══════════════════════════════════════════════════════════════════════════════
# Run Node.js test
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 2: Run Architecture A tests in Node.js ---")

script_path = joinpath(@__DIR__, "..", "..", "scripts", "run_arch_a_tests.cjs")
node_ok = false

try
    result = read(`node $script_path $json_path`, String)
    for line in split(strip(result), '\n')
        println("  $line")
    end
    global node_ok = contains(result, "ALL PASS")
catch e
    println("  ✗ Node.js failed: $(sprint(showerror, e)[1:min(200,end)])")
end

# Clean up
try rm(json_path) catch end

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

println("\n" * "=" ^ 60)
println("TEST-001 Summary:")
println("  Functions: $(length(test_functions))")
println("  Architecture A E2E: $node_ok")
println("=" ^ 60)

@testset "TEST-001: Architecture A Regression (20 functions)" begin
    @test length(test_functions) == 20
    @test node_ok
end

println("\nAll TEST-001 tests complete.")
