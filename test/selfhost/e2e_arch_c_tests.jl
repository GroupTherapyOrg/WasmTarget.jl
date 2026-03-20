# TEST-002: Architecture C Regression Test Suite — 20 Functions
#
# Same 20 functions as TEST-001 but via Architecture C:
#   server parse+lower only → browser thin_typeinf (WASM) + codegen → execute
#
# Run: julia +1.12 --project=. test/selfhost/e2e_arch_c_tests.jl

using Test
using WasmTarget
using WasmTarget: compile_module_from_ir, to_bytes, serialize_ir_entries

# Load typeinf infrastructure (NO typeinf_wasm.jl yet — get IR first)
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "typeid_registry.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "return_type_table.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "thin_typeinf.jl"))

println("=" ^ 60)
println("TEST-002: Architecture C Regression Tests — 20 functions")
println("=" ^ 60)

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1: Build thin_typeinf WASM module (BEFORE loading typeinf overrides)
# ═══════════════════════════════════════════════════════════════════════════════

wasm_functions = [
    (WasmTarget.wasm_create_i32_vector, (Int32,), "wasm_create_i32_vector"),
    (WasmTarget.wasm_set_i32!, (Vector{Int32}, Int32, Int32), "wasm_set_i32"),
    (WasmTarget.wasm_i32_vector_length, (Vector{Int32},), "wasm_i32_vector_length"),
    (WasmTarget.wasm_create_any_vector, (Int32,), "wasm_create_any_vector"),
    (WasmTarget.wasm_set_any_expr!, (Vector{Any}, Int32, Expr), "wasm_set_any_expr"),
    (WasmTarget.wasm_set_any_return!, (Vector{Any}, Int32, Core.ReturnNode), "wasm_set_any_return"),
    (WasmTarget.wasm_any_vector_length, (Vector{Any},), "wasm_any_vector_length"),
    (WasmTarget.wasm_create_expr, (Symbol, Vector{Any}), "wasm_create_expr"),
    (WasmTarget.wasm_create_return_node, (Int32,), "wasm_create_return_node"),
    (WasmTarget.wasm_set_any_ssa!, (Vector{Any}, Int32, Int32), "wasm_set_any_ssa"),
    (WasmTarget.wasm_set_any_arg!, (Vector{Any}, Int32, Int32), "wasm_set_any_arg"),
    (WasmTarget.wasm_set_any_i64!, (Vector{Any}, Int32, Int64), "wasm_set_any_i64"),
    (WasmTarget.wasm_symbol_call, (), "wasm_symbol_call"),
    (composite_hash, (Int32, Vector{Int32}), "composite_hash"),
    (lookup_return_type, (Vector{Int32}, UInt32), "lookup_return_type"),
    (wasm_resolve_val_typeid, (Any, Vector{Int32}, Vector{Int32}, Int32, Int32, Int32, Int32), "wasm_resolve_val_typeid"),
    (wasm_thin_typeinf, (Vector{Any}, Vector{Int32}, Vector{Int32}, Vector{Int32}, Int32, Int32, Int32, Int32), "wasm_thin_typeinf"),
]

println("\n--- Step 1: Build thin_typeinf WASM module ---")
entries = Tuple[]
for (f, atypes, name) in wasm_functions
    ci, rt = Base.code_typed(f, atypes; optimize=true)[1]
    push!(entries, (ci, rt, atypes, name, f))
end
mod = compile_module_from_ir(entries)
module_bytes = to_bytes(mod)
wasm_path = joinpath(@__DIR__, "..", "..", "arch-c-regression.wasm")
write(wasm_path, module_bytes)
println("  Module: $(round(length(module_bytes)/1024, digits=1)) KB, $(length(mod.exports)) exports")

validate_ok = try
    run(pipeline(`wasm-tools validate --features=gc $wasm_path`, stderr=devnull, stdout=devnull))
    true
catch
    false
end
println("  wasm-tools validate: $(validate_ok ? "PASS" : "FAIL")")

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2: Define 20 test functions and serialize (AFTER WASM IR extraction)
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

println("\n--- Step 2: Serialize $(length(test_functions)) test functions ---")

ir_entries = Tuple[]
for (f, atypes, name, _) in test_functions
    ci, rt = Base.code_typed(f, atypes; optimize=true)[1]
    push!(ir_entries, (ci, rt, atypes, name))
end

json_str = serialize_ir_entries(collect(ir_entries))

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3: Build return type table and TypeID data (load typeinf AFTER code_typed)
# ═══════════════════════════════════════════════════════════════════════════════

include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "typeinf_wasm.jl"))

test_sigs = Any[
    Tuple{typeof(*), Int64, Int64},
    Tuple{typeof(+), Int64, Int64},
    Tuple{typeof(-), Int64, Int64},
]
table = populate_transitive(test_sigs)
registry = build_typeid_registry(table)
rt_table = build_return_type_table_with_intrinsics(table, registry)

tid_i64 = get_type_id(registry, Int64)
tid_i32 = get_type_id(registry, Int32)
tid_f64 = get_type_id(registry, Float64)
tid_bool = get_type_id(registry, Bool)

# Build callee TypeID map (intrinsic name → TypeID)
callee_tid_map = Dict{String,Int32}()
for name in ["mul_int", "add_int", "sub_int"]
    intrinsic_fn = getfield(Base, Symbol(name))
    callee_tid_map[name] = get_type_id(registry, intrinsic_fn)
end

println("  TypeIDs: Int64=$tid_i64, mul_int=$(callee_tid_map["mul_int"]), add_int=$(callee_tid_map["add_int"]), sub_int=$(callee_tid_map["sub_int"])")

# ═══════════════════════════════════════════════════════════════════════════════
# Step 4: Build combined JSON with test data + TypeID info
# ═══════════════════════════════════════════════════════════════════════════════

import JSON
json_obj = JSON.parse(json_str)

# Add test cases
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

# Add TypeID constants
json_obj["typeid_constants"] = Dict(
    "Int64" => tid_i64, "Int32" => tid_i32,
    "Float64" => tid_f64, "Bool" => tid_bool,
)

# Add return type table
json_obj["rt_table"] = collect(Int64, rt_table)

# Add callee TypeIDs
json_obj["callee_typeids"] = Dict(k => Int64(v) for (k, v) in callee_tid_map)

json_path = joinpath(@__DIR__, "..", "..", "arch_c_test_data.json")
open(json_path, "w") do f
    write(f, JSON.json(json_obj))
end
println("  JSON: $(filesize(json_path)) bytes")

# ═══════════════════════════════════════════════════════════════════════════════
# Step 5: Run Node.js Architecture C tests
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 3: Run Architecture C tests in Node.js ---")

script_path = joinpath(@__DIR__, "..", "..", "scripts", "run_arch_c_tests.cjs")
node_ok = false

try
    result = read(`node $script_path $json_path $wasm_path`, String)
    for line in split(strip(result), '\n')
        println("  $line")
    end
    global node_ok = contains(result, "ALL PASS")
catch e
    println("  ✗ Node.js failed: $(sprint(showerror, e)[1:min(300,end)])")
end

# Clean up
try rm(json_path) catch end
try rm(wasm_path) catch end

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

println("\n" * "=" ^ 60)
println("TEST-002 Summary:")
println("  Functions: $(length(test_functions))")
println("  wasm-tools validate: $validate_ok")
println("  Architecture C E2E: $node_ok")
println("=" ^ 60)

@testset "TEST-002: Architecture C Regression (20 functions)" begin
    @test length(test_functions) == 20
    @test validate_ok
    @test node_ok
end

println("\nAll TEST-002 tests complete.")
