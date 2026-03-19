# PHASE-1-009: CodeInfo Transport — Server→Browser Serialization Tests
#
# Tests that CodeInfo can be serialized to JSON, deserialized back,
# and compiled to produce IDENTICAL WASM bytes as the original.
# Ground truth verified: roundtripped WASM produces CORRECT results.

using Test
include(joinpath(@__DIR__, "..", "utils.jl"))
using WasmTarget

println("=" ^ 60)
println("PHASE-1-009: CodeInfo Transport Tests")
println("=" ^ 60)

# ============================================================================
# Helper: full roundtrip test
# ============================================================================

"""
    test_transport_roundtrip(f, arg_types, test_args, func_name)

Full roundtrip test:
1. Get CodeInfo via code_typed
2. Preprocess (resolve GlobalRefs)
3. Serialize to JSON
4. Deserialize back
5. Compile both original and roundtripped
6. Compare WASM bytes (must be identical)
7. Execute both and compare results (must match native Julia)
"""
function test_transport_roundtrip(f, arg_types::Tuple, test_args, func_name::String)
    # Step 1: Get CodeInfo
    ci, rt = Base.code_typed(f, arg_types; optimize=true)[1]
    entries = [(ci, rt, arg_types, func_name)]

    # Step 2: Preprocess
    preprocessed = WasmTarget.preprocess_ir_entries(entries)

    # Step 3: Serialize
    json_str = WasmTarget.serialize_ir_entries(preprocessed)
    @test length(json_str) > 0

    # Step 4: Deserialize
    roundtripped = WasmTarget.deserialize_ir_entries(json_str)
    @test length(roundtripped) == 1

    # Step 5: Compile both
    bytes_orig = WasmTarget.to_bytes(WasmTarget.compile_module_from_ir(preprocessed))
    bytes_rt = WasmTarget.to_bytes(WasmTarget.compile_module_from_ir(roundtripped))

    # Step 6: Verify WASM bytes identical
    @test bytes_orig == bytes_rt

    # Step 7: Ground truth — native Julia vs WASM execution
    native_result = f(test_args...)
    wasm_result = run_wasm(bytes_rt, func_name, test_args...)
    if wasm_result !== nothing
        @test wasm_result == native_result
        return (pass=true, native=native_result, wasm=wasm_result,
                json_size=length(json_str), wasm_size=length(bytes_rt))
    else
        return (pass=true, native=native_result, wasm=nothing,
                json_size=length(json_str), wasm_size=length(bytes_rt))
    end
end

# ============================================================================
# Test Set 1: Arithmetic functions
# ============================================================================

@testset "CodeInfo Transport — Arithmetic" begin
    test_add(x::Int64, y::Int64) = x + y
    r = test_transport_roundtrip(test_add, (Int64, Int64), (3, 4), "test_add")
    println("  test_add(3, 4) = $(r.native) — $(r.wasm === nothing ? "no Node.js" : r.wasm == r.native ? "CORRECT" : "MISMATCH")")

    test_sub(x::Int64, y::Int64) = x - y
    r = test_transport_roundtrip(test_sub, (Int64, Int64), (10, 3), "test_sub")
    println("  test_sub(10, 3) = $(r.native) — $(r.wasm === nothing ? "no Node.js" : r.wasm == r.native ? "CORRECT" : "MISMATCH")")

    test_mul(x::Int64, y::Int64) = x * y
    r = test_transport_roundtrip(test_mul, (Int64, Int64), (6, 7), "test_mul")
    println("  test_mul(6, 7) = $(r.native) — $(r.wasm === nothing ? "no Node.js" : r.wasm == r.native ? "CORRECT" : "MISMATCH")")
end

# ============================================================================
# Test Set 2: Conditionals
# ============================================================================

@testset "CodeInfo Transport — Conditionals" begin
    test_max(x::Int64, y::Int64) = x > y ? x : y
    r = test_transport_roundtrip(test_max, (Int64, Int64), (10, 20), "test_max")
    println("  test_max(10, 20) = $(r.native) — $(r.wasm === nothing ? "no Node.js" : r.wasm == r.native ? "CORRECT" : "MISMATCH")")

    test_abs(x::Int64) = x < Int64(0) ? -x : x
    r = test_transport_roundtrip(test_abs, (Int64,), (-42,), "test_abs")
    println("  test_abs(-42) = $(r.native) — $(r.wasm === nothing ? "no Node.js" : r.wasm == r.native ? "CORRECT" : "MISMATCH")")

    test_clamp(x::Int64) = x < Int64(0) ? Int64(0) : (x > Int64(100) ? Int64(100) : x)
    r = test_transport_roundtrip(test_clamp, (Int64,), (150,), "test_clamp")
    println("  test_clamp(150) = $(r.native) — $(r.wasm === nothing ? "no Node.js" : r.wasm == r.native ? "CORRECT" : "MISMATCH")")
end

# ============================================================================
# Test Set 3: Loops
# ============================================================================

@testset "CodeInfo Transport — Loops" begin
    # Use while-loops (for-loops with ranges hit pre-existing unreachable bug)
    function test_sum_while(n::Int64)::Int64
        s = Int64(0)
        i = Int64(1)
        while i <= n
            s += i
            i += Int64(1)
        end
        return s
    end
    r = test_transport_roundtrip(test_sum_while, (Int64,), (10,), "test_sum_while")
    println("  test_sum_while(10) = $(r.native) — $(r.wasm === nothing ? "no Node.js" : r.wasm == r.native ? "CORRECT" : "MISMATCH")")

    function test_fact_while(n::Int64)::Int64
        result = Int64(1)
        i = Int64(1)
        while i <= n
            result *= i
            i += Int64(1)
        end
        return result
    end
    r = test_transport_roundtrip(test_fact_while, (Int64,), (6,), "test_fact_while")
    println("  test_fact_while(6) = $(r.native) — $(r.wasm === nothing ? "no Node.js" : r.wasm == r.native ? "CORRECT" : "MISMATCH")")
end

# ============================================================================
# Test Set 4: Float operations
# ============================================================================

@testset "CodeInfo Transport — Floats" begin
    test_circle_area(r::Float64) = 3.14159265358979 * r * r
    r = test_transport_roundtrip(test_circle_area, (Float64,), (2.0,), "test_circle_area")
    println("  test_circle_area(2.0) = $(r.native) — $(r.wasm === nothing ? "no Node.js" : r.wasm == r.native ? "CORRECT" : "MISMATCH")")

    test_fahrenheit(c::Float64) = c * 1.8 + 32.0
    r = test_transport_roundtrip(test_fahrenheit, (Float64,), (100.0,), "test_fahrenheit")
    println("  test_fahrenheit(100.0) = $(r.native) — $(r.wasm === nothing ? "no Node.js" : r.wasm == r.native ? "CORRECT" : "MISMATCH")")
end

# ============================================================================
# Test Set 5: Struct access
# ============================================================================

struct TransportTestPoint
    x::Int64
    y::Int64
end

@testset "CodeInfo Transport — Structs" begin
    # Struct args can't be passed via run_wasm, so test byte identity + separate execution
    test_point_sum(p::TransportTestPoint) = p.x + p.y
    ci, rt = Base.code_typed(test_point_sum, (TransportTestPoint,); optimize=true)[1]
    entries = [(ci, rt, (TransportTestPoint,), "test_point_sum")]
    preprocessed = WasmTarget.preprocess_ir_entries(entries)

    json_str = WasmTarget.serialize_ir_entries(preprocessed)
    @test length(json_str) > 0
    roundtripped = WasmTarget.deserialize_ir_entries(json_str)

    bytes_orig = WasmTarget.to_bytes(WasmTarget.compile_module_from_ir(preprocessed))
    bytes_rt = WasmTarget.to_bytes(WasmTarget.compile_module_from_ir(roundtripped))
    @test bytes_orig == bytes_rt
    println("  test_point_sum: WASM bytes IDENTICAL ($(length(bytes_rt)) bytes)")

    # Test struct type appears correctly in serialized JSON
    data = JSON.parse(json_str)
    @test any(at -> contains(at, "TransportTestPoint"), data["entries"][1]["arg_types"])
    println("  Struct type preserved in JSON: TransportTestPoint")
end

# ============================================================================
# Test Set 6: Multi-function module roundtrip
# ============================================================================

# Define multi-function test functions at module scope
mf_add(x::Int64, y::Int64) = x + y
mf_max(x::Int64, y::Int64) = x > y ? x : y
mf_poly(x::Int64) = x * x + Int64(2) * x + Int64(1)

@testset "CodeInfo Transport — Multi-function" begin
    entries = []
    for (f, atypes, name) in [(mf_add, (Int64, Int64), "mf_add"),
                               (mf_max, (Int64, Int64), "mf_max"),
                               (mf_poly, (Int64,), "mf_poly")]
        ci, rt = Base.code_typed(f, atypes; optimize=true)[1]
        push!(entries, (ci, rt, atypes, name))
    end

    preprocessed = WasmTarget.preprocess_ir_entries(entries)
    json_str = WasmTarget.serialize_ir_entries(preprocessed)
    roundtripped = WasmTarget.deserialize_ir_entries(json_str)

    bytes_orig = WasmTarget.to_bytes(WasmTarget.compile_module_from_ir(preprocessed))
    bytes_rt = WasmTarget.to_bytes(WasmTarget.compile_module_from_ir(roundtripped))

    @test bytes_orig == bytes_rt

    # Ground truth execution
    for (name, f, args, expected) in [
        ("mf_add", mf_add, (100, 200), 300),
        ("mf_max", mf_max, (-5, 10), 10),
        ("mf_poly", mf_poly, (3,), 16),
    ]
        native = f(args...)
        @test native == expected
        wasm_result = run_wasm(bytes_rt, name, args...)
        if wasm_result !== nothing
            @test wasm_result == expected
            println("  $name($(join(args, ", "))) = $expected — CORRECT")
        else
            println("  $name($(join(args, ", "))) = $expected — no Node.js")
        end
    end
end

# ============================================================================
# Test Set 7: JSON format validation
# ============================================================================

@testset "CodeInfo Transport — JSON format" begin
    test_f(x::Int64) = x + 1
    ci, rt = Base.code_typed(test_f, (Int64,); optimize=true)[1]
    entries = [(ci, rt, (Int64,), "test_f")]
    preprocessed = WasmTarget.preprocess_ir_entries(entries)
    json_str = WasmTarget.serialize_ir_entries(preprocessed)

    # Parse and validate structure
    data = JSON.parse(json_str)
    @test data["version"] == 1
    @test length(data["entries"]) == 1

    entry = data["entries"][1]
    @test entry["name"] == "test_f"
    @test entry["return_type"] == "Int64"
    @test entry["arg_types"] == ["Int64"]
    @test length(entry["code"]) > 0
    @test length(entry["ssavaluetypes"]) == length(entry["code"])
    @test entry["slottypes"] !== nothing
    @test length(entry["slotnames"]) >= 2  # #self# + x

    # Verify code nodes have _t tags
    for stmt in entry["code"]
        @test haskey(stmt, "_t")
        @test stmt["_t"] in ["expr", "return", "goto", "gotoifnot", "phi", "pi", "nothing", "opaque"]
    end

    println("  JSON structure validated")
    println("  JSON size: $(length(json_str)) bytes")
end

# ============================================================================
# Test Set 8: Serialize with frozen compilation path
# ============================================================================

@testset "CodeInfo Transport — Frozen path" begin
    # Build frozen state
    ff_add(x::Int64, y::Int64) = x + y
    ff_max(x::Int64, y::Int64) = x > y ? x : y

    # Build frozen state from representative functions
    representative = []
    for (f, atypes) in [(ff_add, (Int64, Int64)), (ff_max, (Int64, Int64))]
        ci, rt = Base.code_typed(f, atypes; optimize=true)[1]
        push!(representative, (ci, rt, atypes, string(f)))
    end
    frozen = WasmTarget.build_frozen_state(representative)

    # Now serialize a different function and compile via frozen path
    ff_sub(x::Int64, y::Int64) = x - y
    ci, rt = Base.code_typed(ff_sub, (Int64, Int64); optimize=true)[1]
    entries = [(ci, rt, (Int64, Int64), "ff_sub")]
    preprocessed = WasmTarget.preprocess_ir_entries(entries)

    json_str = WasmTarget.serialize_ir_entries(preprocessed)
    roundtripped = WasmTarget.deserialize_ir_entries(json_str)

    # Compile via frozen path — both original and roundtripped
    bytes_orig = WasmTarget.to_bytes(WasmTarget.compile_module_from_ir_frozen(preprocessed, frozen))
    bytes_rt = WasmTarget.to_bytes(WasmTarget.compile_module_from_ir_frozen(roundtripped, frozen))
    @test bytes_orig == bytes_rt

    # Ground truth
    native = ff_sub(100, 37)
    wasm_result = run_wasm(bytes_rt, "ff_sub", 100, 37)
    if wasm_result !== nothing
        @test wasm_result == native
        println("  ff_sub(100, 37) = $native — CORRECT (frozen path)")
    else
        println("  ff_sub(100, 37) = $native — no Node.js")
    end
end

# ============================================================================
# Test Set 9: Ground truth file output
# ============================================================================

gt_add_one(x::Int64) = x + Int64(1)
gt_double(x::Int64) = x * Int64(2)
gt_negate(x::Int64) = -x
gt_skip_test(x::Int64) = x > Int64(0) ? x : Int64(0)

@testset "CodeInfo Transport — Ground truth files" begin
    gt_dir = joinpath(@__DIR__, "..", "ground_truth")
    mkpath(gt_dir)

    test_funcs = [
        (:gt_add_one, gt_add_one, (Int64,), (5,)),
        (:gt_double, gt_double, (Int64,), (21,)),
        (:gt_negate, gt_negate, (Int64,), (42,)),
        (:gt_skip_test, gt_skip_test, (Int64,), (-3,)),
    ]

    for (name, f, atypes, test_args) in test_funcs
        ci, rt = Base.code_typed(f, atypes; optimize=true)[1]
        entries = [(ci, rt, atypes, string(name))]
        preprocessed = WasmTarget.preprocess_ir_entries(entries)
        json_str = WasmTarget.serialize_ir_entries(preprocessed)

        # Save JSON
        gt_file = joinpath(gt_dir, "$(name).json")
        open(gt_file, "w") do io
            write(io, json_str)
        end
        @test isfile(gt_file)

        # Verify roundtrip from file
        loaded_json = read(gt_file, String)
        loaded_entries = WasmTarget.deserialize_ir_entries(loaded_json)
        bytes = WasmTarget.to_bytes(WasmTarget.compile_module_from_ir(loaded_entries))

        native = f(test_args...)
        wasm_result = run_wasm(bytes, string(name), test_args...)
        if wasm_result !== nothing
            @test wasm_result == native
            println("  $name($(join(test_args, ", "))) = $native — CORRECT (from file)")
        else
            println("  $name($(join(test_args, ", "))) = $native — no Node.js")
        end
    end
end

# ============================================================================
# Test Set 10: Skip test — verify identity holds for complex IR
# ============================================================================

@testset "CodeInfo Transport — Complex IR patterns" begin
    # Function with multiple phi nodes and branches
    function complex_branch(x::Int64)::Int64
        if x > Int64(10)
            a = x * Int64(2)
        else
            a = x + Int64(5)
        end
        if a > Int64(20)
            return a - Int64(10)
        else
            return a
        end
    end

    ci, rt = Base.code_typed(complex_branch, (Int64,); optimize=true)[1]
    entries = [(ci, rt, (Int64,), "complex_branch")]
    preprocessed = WasmTarget.preprocess_ir_entries(entries)

    json_str = WasmTarget.serialize_ir_entries(preprocessed)
    roundtripped = WasmTarget.deserialize_ir_entries(json_str)

    bytes_orig = WasmTarget.to_bytes(WasmTarget.compile_module_from_ir(preprocessed))
    bytes_rt = WasmTarget.to_bytes(WasmTarget.compile_module_from_ir(roundtripped))
    @test bytes_orig == bytes_rt

    # Ground truth for multiple inputs
    for input in (Int64(5), Int64(15), Int64(25))
        native = complex_branch(input)
        wasm_result = run_wasm(bytes_rt, "complex_branch", input)
        if wasm_result !== nothing
            @test wasm_result == native
            println("  complex_branch($input) = $native — CORRECT")
        end
    end
end

println()
println("=" ^ 60)
println("PHASE-1-009: CodeInfo Transport Tests COMPLETE")
println("=" ^ 60)
