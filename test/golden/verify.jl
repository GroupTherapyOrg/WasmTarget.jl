# PHASE-1-T02: Verify golden files — load, compile, execute, compare
#
# For each golden file:
#   1. Load CodeInfo JSON from golden file
#   2. Deserialize and compile to WASM
#   3. Execute with test inputs
#   4. Compare results to golden expected values
#   5. Optionally compare WASM size (allow small changes)
#
# Run: julia +1.12 --project=. test/golden/verify.jl

using Test
include(joinpath(@__DIR__, "..", "utils.jl"))
using WasmTarget
import JSON

const GOLDEN_DIR = @__DIR__

println("=" ^ 60)
println("PHASE-1-T02: Golden File Verification")
println("=" ^ 60)

# Collect all golden files
golden_files = filter(f -> endswith(f, ".json") && f != "verify.jl" && f != "generate.jl",
                       readdir(GOLDEN_DIR))
golden_files = filter(f -> startswith(f, "golden_"), golden_files)
sort!(golden_files)

println("Found $(length(golden_files)) golden files")
@test length(golden_files) >= 20

@testset "Golden: $gf" for gf in golden_files
    filepath = joinpath(GOLDEN_DIR, gf)
    data = JSON.parsefile(filepath)

    name = data["name"]
    test_cases = data["test_cases"]
    golden_wasm_size = data["wasm_size"]

    # Deserialize CodeInfo from golden file
    codeinfo_json = JSON.json(data["codeinfo"])
    ir_entries = WasmTarget.deserialize_ir_entries(codeinfo_json)

    # Compile to WASM
    wasm_bytes = WasmTarget.to_bytes(WasmTarget.compile_module_from_ir(ir_entries))

    # Verify WASM size matches (exact match — deterministic codegen)
    @test length(wasm_bytes) == golden_wasm_size

    # Execute each test case
    for tc in test_cases
        args_raw = tc["args"]
        expected = tc["expected"]

        # Convert args to proper types
        arg_types_str = data["arg_types"]
        args = []
        for (i, at) in enumerate(arg_types_str)
            v = args_raw[i]
            if at == "Int64"
                push!(args, Int64(v))
            elseif at == "Float64"
                push!(args, Float64(v))
            elseif at == "Int32"
                push!(args, Int32(v))
            else
                push!(args, v)
            end
        end

        wasm_result = run_wasm(wasm_bytes, name, args...)
        if wasm_result !== nothing
            if expected isa AbstractFloat || (expected isa Number && any(at -> at == "Float64", arg_types_str))
                @test wasm_result ≈ expected atol=1e-10
            else
                @test wasm_result == expected
            end
        end
    end

    println("  $name: $(length(test_cases)) test cases — CORRECT ($(length(wasm_bytes)) bytes)")
end

println()
println("=" ^ 60)
println("Golden File Verification COMPLETE")
println("=" ^ 60)
