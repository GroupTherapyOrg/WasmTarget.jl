# PHASE-1M-002: Test frozen compilation context
# Verifies that pre-computed TypeRegistry + FunctionRegistry produce
# identical WASM output as fresh compilation.
#
# Ground truth procedure: compile with fresh context, compile with frozen context,
# compare WASM bytes. Also verify WASM executes correctly via Node.js.

using Test

# Load WasmTarget
include(joinpath(@__DIR__, "..", "utils.jl"))
using WasmTarget
using WasmTarget: get_typed_ir, compile_module_from_ir, build_frozen_state,
                  compile_module_from_ir_frozen, to_bytes, FrozenCompilationState

# ============================================================================
# Representative test functions
# ============================================================================

# 1. Simple arithmetic
test_add(x::Int64, y::Int64)::Int64 = x + y

# 2. Conditionals
function test_max(a::Int64, b::Int64)::Int64
    if a > b
        return a
    else
        return b
    end
end

# 3. Simple loop
function test_sum_to(n::Int64)::Int64
    s = Int64(0)
    i = Int64(1)
    while i <= n
        s = s + i
        i = i + Int64(1)
    end
    return s
end

# 4. Float arithmetic
test_circle_area(r::Float64)::Float64 = 3.14159265358979 * r * r

# 5. Multiple operations
function test_poly(x::Int64)::Int64
    return x * x + Int64(2) * x + Int64(1)
end

# ============================================================================
# Helper: get IR entries for a list of functions
# ============================================================================
function make_ir_entries(funcs)
    entries = []
    for (f, arg_types, name) in funcs
        code_info, return_type = get_typed_ir(f, arg_types)
        push!(entries, (code_info, return_type, arg_types, name))
    end
    return entries
end

# ============================================================================
# Test 1: FrozenCompilationState struct exists and is constructable
# ============================================================================
@testset "FrozenCompilationState basics" begin
    funcs = [
        (test_add, (Int64, Int64), "test_add"),
    ]
    ir_entries = make_ir_entries(funcs)

    frozen = build_frozen_state(ir_entries)
    @test frozen isa FrozenCompilationState
    @test frozen.mod isa WasmTarget.WasmModule
    @test frozen.type_registry isa WasmTarget.TypeRegistry

    # Registry should have types registered (base struct, numeric boxes, etc.)
    @test length(frozen.mod.types) > 0
    println("  FrozenCompilationState created with $(length(frozen.mod.types)) types, $(length(frozen.mod.globals)) globals")
end

# ============================================================================
# Test 2: Frozen produces identical WASM bytes for single arithmetic function
# ============================================================================
@testset "Frozen vs fresh — arithmetic" begin
    funcs = [(test_add, (Int64, Int64), "test_add")]
    ir_entries = make_ir_entries(funcs)

    # Fresh compilation
    mod_fresh = compile_module_from_ir(ir_entries)
    bytes_fresh = to_bytes(mod_fresh)

    # Frozen compilation
    frozen = build_frozen_state(ir_entries)
    mod_frozen = compile_module_from_ir_frozen(ir_entries, frozen)
    bytes_frozen = to_bytes(mod_frozen)

    @test bytes_fresh == bytes_frozen
    println("  Arithmetic: fresh=$(length(bytes_fresh)) bytes, frozen=$(length(bytes_frozen)) bytes — IDENTICAL=$(bytes_fresh == bytes_frozen)")

    # Ground truth: verify execution
    if NODE_CMD !== nothing
        result = run_wasm(bytes_frozen, "test_add", Int64(3), Int64(4))
        @test result == 7
        println("  Native: test_add(3, 4) = $(test_add(Int64(3), Int64(4)))")
        println("  Wasm:   test_add(3, 4) = $result — CORRECT")
    end
end

# ============================================================================
# Test 3: Frozen produces identical WASM for conditionals
# ============================================================================
@testset "Frozen vs fresh — conditionals" begin
    funcs = [(test_max, (Int64, Int64), "test_max")]
    ir_entries = make_ir_entries(funcs)

    bytes_fresh = to_bytes(compile_module_from_ir(ir_entries))
    frozen = build_frozen_state(ir_entries)
    bytes_frozen = to_bytes(compile_module_from_ir_frozen(ir_entries, frozen))

    @test bytes_fresh == bytes_frozen
    println("  Conditionals: IDENTICAL=$(bytes_fresh == bytes_frozen)")

    if NODE_CMD !== nothing
        result = run_wasm(bytes_frozen, "test_max", Int64(10), Int64(20))
        @test result == 20
        println("  Native: test_max(10, 20) = $(test_max(Int64(10), Int64(20)))")
        println("  Wasm:   test_max(10, 20) = $result — CORRECT")
    end
end

# ============================================================================
# Test 4: Frozen produces identical WASM for loops
# ============================================================================
@testset "Frozen vs fresh — loops" begin
    funcs = [(test_sum_to, (Int64,), "test_sum_to")]
    ir_entries = make_ir_entries(funcs)

    bytes_fresh = to_bytes(compile_module_from_ir(ir_entries))
    frozen = build_frozen_state(ir_entries)
    bytes_frozen = to_bytes(compile_module_from_ir_frozen(ir_entries, frozen))

    @test bytes_fresh == bytes_frozen
    println("  Loops: IDENTICAL=$(bytes_fresh == bytes_frozen)")

    if NODE_CMD !== nothing
        result = run_wasm(bytes_frozen, "test_sum_to", Int64(10))
        @test result == 55
        println("  Native: test_sum_to(10) = $(test_sum_to(Int64(10)))")
        println("  Wasm:   test_sum_to(10) = $result — CORRECT")
    end
end

# ============================================================================
# Test 5: Frozen produces identical WASM for floats
# ============================================================================
@testset "Frozen vs fresh — floats" begin
    funcs = [(test_circle_area, (Float64,), "test_circle_area")]
    ir_entries = make_ir_entries(funcs)

    bytes_fresh = to_bytes(compile_module_from_ir(ir_entries))
    frozen = build_frozen_state(ir_entries)
    bytes_frozen = to_bytes(compile_module_from_ir_frozen(ir_entries, frozen))

    @test bytes_fresh == bytes_frozen
    println("  Floats: IDENTICAL=$(bytes_fresh == bytes_frozen)")

    if NODE_CMD !== nothing
        result = run_wasm(bytes_frozen, "test_circle_area", 2.0)
        expected = test_circle_area(2.0)
        @test result ≈ expected
        println("  Native: test_circle_area(2.0) = $expected")
        println("  Wasm:   test_circle_area(2.0) = $result — CORRECT")
    end
end

# ============================================================================
# Test 6: Multi-function module — frozen produces identical WASM
# ============================================================================
@testset "Frozen vs fresh — multi-function" begin
    funcs = [
        (test_add, (Int64, Int64), "test_add"),
        (test_max, (Int64, Int64), "test_max"),
        (test_sum_to, (Int64,), "test_sum_to"),
        (test_circle_area, (Float64,), "test_circle_area"),
        (test_poly, (Int64,), "test_poly"),
    ]
    ir_entries = make_ir_entries(funcs)

    bytes_fresh = to_bytes(compile_module_from_ir(ir_entries))
    frozen = build_frozen_state(ir_entries)
    bytes_frozen = to_bytes(compile_module_from_ir_frozen(ir_entries, frozen))

    @test bytes_fresh == bytes_frozen
    println("  Multi-function (5 funcs): fresh=$(length(bytes_fresh)), frozen=$(length(bytes_frozen)) — IDENTICAL=$(bytes_fresh == bytes_frozen)")

    if NODE_CMD !== nothing
        result_add = run_wasm(bytes_frozen, "test_add", Int64(100), Int64(200))
        result_max = run_wasm(bytes_frozen, "test_max", Int64(5), Int64(3))
        result_sum = run_wasm(bytes_frozen, "test_sum_to", Int64(100))
        result_poly = run_wasm(bytes_frozen, "test_poly", Int64(5))
        @test result_add == 300
        @test result_max == 5
        @test result_sum == 5050
        @test result_poly == 36
        println("  test_add(100, 200) = $result_add — CORRECT")
        println("  test_max(5, 3) = $result_max — CORRECT")
        println("  test_sum_to(100) = $result_sum — CORRECT")
        println("  test_poly(5) = $result_poly — CORRECT")
    end
end

# ============================================================================
# Test 7: Frozen state reuse — compile DIFFERENT functions with same frozen state
# ============================================================================
@testset "Frozen state reuse — different functions" begin
    # Build frozen state from a SUPERSET of representative functions
    setup_funcs = [
        (test_add, (Int64, Int64), "test_add"),
        (test_max, (Int64, Int64), "test_max"),
        (test_sum_to, (Int64,), "test_sum_to"),
        (test_circle_area, (Float64,), "test_circle_area"),
        (test_poly, (Int64,), "test_poly"),
    ]
    frozen = build_frozen_state(make_ir_entries(setup_funcs))

    # Now compile a SUBSET using the frozen state
    subset_funcs = [(test_add, (Int64, Int64), "test_add"), (test_poly, (Int64,), "test_poly")]
    subset_entries = make_ir_entries(subset_funcs)

    # This should work — the frozen state has all needed types
    mod = compile_module_from_ir_frozen(subset_entries, frozen)
    bytes = to_bytes(mod)
    @test length(bytes) > 0
    println("  Reuse: compiled 2-func subset from 5-func frozen state — $(length(bytes)) bytes")

    if NODE_CMD !== nothing
        result = run_wasm(bytes, "test_add", Int64(7), Int64(8))
        @test result == 15
        result2 = run_wasm(bytes, "test_poly", Int64(3))
        @test result2 == 16
        println("  test_add(7, 8) = $result — CORRECT")
        println("  test_poly(3) = $result2 — CORRECT")
    end
end

# ============================================================================
# Test 8: Frozen state is NOT mutated by compilation
# ============================================================================
@testset "Frozen state immutability" begin
    funcs = [(test_add, (Int64, Int64), "test_add")]
    ir_entries = make_ir_entries(funcs)
    frozen = build_frozen_state(ir_entries)

    # Record state before
    n_types_before = length(frozen.mod.types)
    n_globals_before = length(frozen.mod.globals)
    n_functions_before = length(frozen.mod.functions)

    # Compile with frozen state
    compile_module_from_ir_frozen(ir_entries, frozen)

    # State should be unchanged (deepcopy protects it)
    @test length(frozen.mod.types) == n_types_before
    @test length(frozen.mod.globals) == n_globals_before
    @test length(frozen.mod.functions) == n_functions_before
    println("  Immutability: types=$(n_types_before), globals=$(n_globals_before), functions=$(n_functions_before) — UNCHANGED after compilation")
end

println("\n=== PHASE-1M-002: All frozen context tests complete ===")
