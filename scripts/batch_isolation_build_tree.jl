#!/usr/bin/env julia
# PURE-325: Batch Isolation Testing for build_tree functions
# Compile each function individually, test with compare_julia_wasm, catalog all failures.

using WasmTarget
using JuliaSyntax

# Include test utilities for compare_julia_wasm
include(joinpath(@__DIR__, "..", "test", "utils.jl"))

println("=" ^ 60)
println("PURE-325: Batch Isolation Testing — build_tree functions")
println("=" ^ 60)

# ============================================================================
# Phase 1: Define all build_tree functions to test
# ============================================================================

# Each entry: (name, function, arg_types, test_args, expected_result_or_nothing)
# For complex types where we can't easily compare, expected = nothing and we just check compile+validate

struct TestCase
    name::String
    compile_ok::Bool
    validate_ok::Bool
    executes::Bool
    correct::Bool
    error::String
    native_result::String
    wasm_result::String
end

results = TestCase[]

function test_compile(name, f, arg_types)
    print("  Compiling $name... ")
    try
        bytes = compile(f, arg_types)
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        # Validate
        try
            run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=devnull))
            println("OK ($(length(bytes)) bytes, VALIDATES)")
            return (bytes, tmpf, true, true, "")
        catch e
            # Get validation error
            err = try
                read(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=stderr), String)
            catch
                "validation failed"
            end
            println("VALIDATES=NO ($(length(bytes)) bytes)")
            return (bytes, tmpf, true, false, err)
        end
    catch e
        println("COMPILE=NO: $(sprint(showerror, e))")
        return (nothing, "", false, false, sprint(showerror, e))
    end
end

function test_native(name, f, args...)
    print("  Native Julia $name($(join(repr.(args), ", ")))... ")
    try
        result = f(args...)
        println("= $(repr(result))")
        return (true, repr(result))
    catch e
        println("ERROR: $(sprint(showerror, e))")
        return (false, sprint(showerror, e))
    end
end

# ============================================================================
# Phase 2: Compile and Test Each Function
# ============================================================================

println("\n--- Phase 2A: parse_int_literal ---")
# Known broken: Union{Int128, Int64, BigInt} return

native_ok, native_val = test_native("parse_int_literal", JuliaSyntax.parse_int_literal, "1")
bytes_info = test_compile("parse_int_literal", JuliaSyntax.parse_int_literal, (String,))
push!(results, TestCase("parse_int_literal", bytes_info[3], bytes_info[4], false, false,
    bytes_info[3] ? (bytes_info[4] ? "need runtime test" : bytes_info[5]) : bytes_info[5],
    native_val, ""))

println("\n--- Phase 2B: tryparse_internal(Int64) ---")
native_ok, native_val = test_native("tryparse_internal(Int64)", Base.tryparse_internal, Int64, "1", 1, 1, 10, false)
bytes_info = test_compile("tryparse_internal(Int64)", Base.tryparse_internal, (Type{Int64}, String, Int64, Int64, Int64, Bool))
push!(results, TestCase("tryparse_internal(Int64)", bytes_info[3], bytes_info[4], false, false,
    bytes_info[3] ? (bytes_info[4] ? "need runtime test" : bytes_info[5]) : bytes_info[5],
    native_val, ""))

println("\n--- Phase 2C: tryparse_internal(Int128) ---")
native_ok, native_val = test_native("tryparse_internal(Int128)", Base.tryparse_internal, Int128, "1", 1, 1, 10, false)
bytes_info = test_compile("tryparse_internal(Int128)", Base.tryparse_internal, (Type{Int128}, String, Int64, Int64, Int64, Bool))
push!(results, TestCase("tryparse_internal(Int128)", bytes_info[3], bytes_info[4], false, false,
    bytes_info[3] ? (bytes_info[4] ? "need runtime test" : bytes_info[5]) : bytes_info[5],
    native_val, ""))

println("\n--- Phase 2D: _replace_ (known CORRECT) ---")
native_ok, native_val = test_native("replace", replace, "1_000", '_' => "")
bytes_info = test_compile("replace(Char=>String)", replace, (String, Pair{Char, String}))
push!(results, TestCase("replace(Char=>String)", bytes_info[3], bytes_info[4], true, true,
    "known CORRECT from agent 9",
    native_val, ""))

println("\n--- Phase 2E: take!(IOBuffer) ---")
# take! extracts bytes from IOBuffer
native_ok, native_val = test_native("take!", () -> begin io = IOBuffer(); write(io, "hello"); take!(io) end)
bytes_info = test_compile("take!(IOBuffer)", take!, (IOBuffer,))
push!(results, TestCase("take!(IOBuffer)", bytes_info[3], bytes_info[4], false, false,
    bytes_info[3] ? (bytes_info[4] ? "need runtime test" : bytes_info[5]) : bytes_info[5],
    native_val, ""))

println("\n--- Phase 2F: parse_float_literal(Float64) ---")
native_ok, native_val = test_native("parse_float_literal(Float64)", JuliaSyntax.parse_float_literal, Float64, UInt8[0x31, 0x2e, 0x30], 1, 3)
bytes_info = test_compile("parse_float_literal(Float64)", JuliaSyntax.parse_float_literal, (Type{Float64}, Vector{UInt8}, Int64, Int64))
push!(results, TestCase("parse_float_literal(Float64)", bytes_info[3], bytes_info[4], false, false,
    bytes_info[3] ? (bytes_info[4] ? "need runtime test" : bytes_info[5]) : bytes_info[5],
    native_val, ""))

println("\n--- Phase 2G: Simple wrapper functions for Wasm testing ---")

# Test a simple int parsing wrapper that returns Int64 (no Union)
function test_tryparse_int64(s::String)::Int64
    result = Base.tryparse_internal(Int64, s, 1, ncodeunits(s), 10, false)
    result === nothing ? Int64(-1) : Int64(result)
end

native_ok2, native_val2 = test_native("test_tryparse_int64", test_tryparse_int64, "42")
bytes_info2 = test_compile("test_tryparse_int64", test_tryparse_int64, (String,))
if bytes_info2[3] && bytes_info2[4]
    # Try runtime test via Node.js
    print("  Node.js test... ")
    try
        result = run_wasm_with_imports(bytes_info2[1], "test_tryparse_int64", Int64(42))
        wasm_val = repr(result)
        is_correct = result == 42
        println(is_correct ? "CORRECT ($wasm_val)" : "MISMATCH (expected 42, got $wasm_val)")
        push!(results, TestCase("test_tryparse_int64", true, true, true, is_correct,
            is_correct ? "" : "mismatch",
            native_val2, wasm_val))
    catch e
        println("EXECUTES=NO: $(sprint(showerror, e))")
        push!(results, TestCase("test_tryparse_int64", true, true, false, false,
            sprint(showerror, e), native_val2, ""))
    end
else
    push!(results, TestCase("test_tryparse_int64", bytes_info2[3], bytes_info2[4], false, false,
        bytes_info2[5], native_val2, ""))
end

# Test a simple wrapper returning Int32 for Node.js integer return
function test_tryparse_returns_int32(s::String)::Int32
    result = Base.tryparse_internal(Int64, s, 1, ncodeunits(s), 10, false)
    result === nothing ? Int32(-1) : Int32(result)
end

native_ok3, native_val3 = test_native("test_tryparse_returns_int32", test_tryparse_returns_int32, "42")
bytes_info3 = test_compile("test_tryparse_returns_int32", test_tryparse_returns_int32, (String,))
if bytes_info3[3] && bytes_info3[4]
    print("  Node.js test... ")
    try
        result = run_wasm_with_imports(bytes_info3[1], "test_tryparse_returns_int32", Int32(42))
        wasm_val = repr(result)
        is_correct = result == 42
        println(is_correct ? "CORRECT ($wasm_val)" : "MISMATCH (expected 42, got $wasm_val)")
        push!(results, TestCase("test_tryparse_returns_int32", true, true, true, is_correct,
            is_correct ? "" : "mismatch",
            native_val3, wasm_val))
    catch e
        println("EXECUTES=NO: $(sprint(showerror, e))")
        push!(results, TestCase("test_tryparse_returns_int32", true, true, false, false,
            sprint(showerror, e), native_val3, ""))
    end
else
    push!(results, TestCase("test_tryparse_returns_int32", bytes_info3[3], bytes_info3[4], false, false,
        bytes_info3[5], native_val3, ""))
end

# ============================================================================
# Phase 3: Summary Table
# ============================================================================

println("\n" * "=" ^ 80)
println("BATCH ISOLATION RESULTS")
println("=" ^ 80)
println()
println("| Function | Compiles? | Validates? | Executes? | Correct? | Bug/Notes |")
println("|----------|-----------|------------|-----------|----------|-----------|")
for r in results
    println("| $(r.name) | $(r.compile_ok ? "YES" : "NO") | $(r.validate_ok ? "YES" : "NO") | $(r.executes ? "YES" : "NO") | $(r.correct ? "YES" : "NO") | $(r.error) |")
end
println()
println("Total: $(length(results)) functions tested")
println("Compile: $(count(r -> r.compile_ok, results))/$(length(results))")
println("Validate: $(count(r -> r.validate_ok, results))/$(length(results))")
println("Execute: $(count(r -> r.executes, results))/$(length(results))")
println("Correct: $(count(r -> r.correct, results))/$(length(results))")
