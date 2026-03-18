# PHASE-1-007: Test GlobalRef pre-resolution (production code)
# Verifies that preprocess_ir_entries eliminates all GlobalRef values
# and that pre-processed CodeInfo produces identical WASM output.

using Test

include(joinpath(@__DIR__, "..", "utils.jl"))
using WasmTarget
using WasmTarget: get_typed_ir, compile_module_from_ir, to_bytes,
                  collect_globalrefs, resolve_globalrefs, substitute_globalrefs,
                  preprocess_ir_entries, build_frozen_state, compile_module_from_ir_frozen

# ============================================================================
# Test functions
# ============================================================================

test_add(x::Int64, y::Int64)::Int64 = x + y

function test_max(a::Int64, b::Int64)::Int64
    a > b ? a : b
end

function test_sum_to(n::Int64)::Int64
    s = Int64(0)
    i = Int64(1)
    while i <= n
        s += i
        i += Int64(1)
    end
    s
end

test_mul(x::Float64, y::Float64)::Float64 = x * y

function test_poly(x::Int64)::Int64
    x * x + Int64(2) * x + Int64(1)
end

function make_ir_entries(funcs)
    entries = []
    for (f, arg_types, name) in funcs
        code_info, return_type = get_typed_ir(f, arg_types)
        push!(entries, (code_info, return_type, arg_types, name))
    end
    return entries
end

# ============================================================================
# Test 1: Production collect_globalrefs works
# ============================================================================
@testset "Production collect_globalrefs" begin
    ci, _ = get_typed_ir(test_add, (Int64, Int64))
    refs = collect_globalrefs(ci)
    @test length(refs) > 0
    println("  test_add: $(length(refs)) GlobalRefs")

    ci2, _ = get_typed_ir(test_sum_to, (Int64,))
    refs2 = collect_globalrefs(ci2)
    @test length(refs2) > 0
    println("  test_sum_to: $(length(refs2)) GlobalRefs")
end

# ============================================================================
# Test 2: Production preprocess_ir_entries eliminates all GlobalRefs
# ============================================================================
@testset "preprocess_ir_entries — zero GlobalRefs" begin
    funcs = [
        (test_add, (Int64, Int64), "test_add"),
        (test_max, (Int64, Int64), "test_max"),
        (test_sum_to, (Int64,), "test_sum_to"),
        (test_mul, (Float64, Float64), "test_mul"),
        (test_poly, (Int64,), "test_poly"),
    ]
    ir_entries = make_ir_entries(funcs)
    preprocessed = preprocess_ir_entries(ir_entries)

    for (ci, _, _, name) in preprocessed
        remaining = collect_globalrefs(ci)
        @test length(remaining) == 0
        println("  $name: $(length(remaining)) GlobalRefs remaining")
    end
end

# ============================================================================
# Test 3: Preprocessed entries produce identical WASM
# ============================================================================
@testset "Preprocessed — identical WASM" begin
    funcs = [
        (test_add, (Int64, Int64), "test_add"),
        (test_max, (Int64, Int64), "test_max"),
        (test_sum_to, (Int64,), "test_sum_to"),
        (test_mul, (Float64, Float64), "test_mul"),
        (test_poly, (Int64,), "test_poly"),
    ]
    ir_entries = make_ir_entries(funcs)
    preprocessed = preprocess_ir_entries(ir_entries)

    bytes_original = to_bytes(compile_module_from_ir(ir_entries))
    bytes_preprocessed = to_bytes(compile_module_from_ir(preprocessed))

    @test bytes_original == bytes_preprocessed
    println("  Original: $(length(bytes_original)) bytes")
    println("  Preprocessed: $(length(bytes_preprocessed)) bytes")
    println("  IDENTICAL: $(bytes_original == bytes_preprocessed)")
end

# ============================================================================
# Test 4: Preprocessed + frozen = correct execution
# ============================================================================
@testset "Preprocessed + frozen — correct execution" begin
    funcs = [
        (test_add, (Int64, Int64), "test_add"),
        (test_sum_to, (Int64,), "test_sum_to"),
        (test_poly, (Int64,), "test_poly"),
    ]
    ir_entries = make_ir_entries(funcs)
    preprocessed = preprocess_ir_entries(ir_entries)

    frozen = build_frozen_state(preprocessed)
    mod = compile_module_from_ir_frozen(preprocessed, frozen)
    bytes = to_bytes(mod)

    if NODE_CMD !== nothing
        result_add = run_wasm(bytes, "test_add", Int64(100), Int64(200))
        result_sum = run_wasm(bytes, "test_sum_to", Int64(10))
        result_poly = run_wasm(bytes, "test_poly", Int64(5))

        @test result_add == 300
        @test result_sum == 55
        @test result_poly == 36

        println("  Native: test_add(100,200) = $(test_add(Int64(100),Int64(200)))")
        println("  Wasm:   test_add(100,200) = $result_add — CORRECT")
        println("  Native: test_sum_to(10) = $(test_sum_to(Int64(10)))")
        println("  Wasm:   test_sum_to(10) = $result_sum — CORRECT")
        println("  Native: test_poly(5) = $(test_poly(Int64(5)))")
        println("  Wasm:   test_poly(5) = $result_poly — CORRECT")
    end
end

# ============================================================================
# Test 5: Full pipeline — preprocess + freeze + compile + execute
# ============================================================================
@testset "Full self-hosting pipeline simulation" begin
    # Step 1: Build time — get IR and preprocess
    funcs = [
        (test_add, (Int64, Int64), "test_add"),
        (test_max, (Int64, Int64), "test_max"),
    ]
    ir_entries = make_ir_entries(funcs)
    preprocessed = preprocess_ir_entries(ir_entries)

    # Verify no GlobalRefs remain
    for (ci, _, _, _) in preprocessed
        @test length(collect_globalrefs(ci)) == 0
    end

    # Step 2: Build time — create frozen state
    frozen = build_frozen_state(preprocessed)

    # Step 3: "Runtime" — compile with frozen state (simulates browser codegen)
    mod = compile_module_from_ir_frozen(preprocessed, frozen)
    bytes = to_bytes(mod)

    # Step 4: Execute
    if NODE_CMD !== nothing
        result = run_wasm(bytes, "test_add", Int64(7), Int64(8))
        @test result == 15
        result2 = run_wasm(bytes, "test_max", Int64(42), Int64(17))
        @test result2 == 42
        println("  Pipeline: test_add(7,8) = $result — CORRECT")
        println("  Pipeline: test_max(42,17) = $result2 — CORRECT")
    end
end

println("\n=== PHASE-1-007: All GlobalRef resolution tests complete ===")
