# test_deserialize_roundtrip.jl — GAMMA-003: JS Deserializer + WASM Codegen Roundtrip
#
# Full pipeline test:
#   1. Server: serialize_ir_entries('f(x::Int64) = x * x + 1') → JSON
#   2. Node.js: load codegen WASM → deserialize JSON → compile → execute
#   3. Verify: f(5n) === 26n via WASM codegen (ZERO native Julia in codegen path)
#
# Run: julia +1.12 --project=. test/selfhost/test_deserialize_roundtrip.jl

using Test
using WasmTarget

println("=" ^ 60)
println("GAMMA-003: JS Deserializer + WASM Codegen Roundtrip")
println("=" ^ 60)

# ═══════════════════════════════════════════════════════════════════════════════
# Step 1: Generate CodeInfo JSON for f(x::Int64) = x * x + 1
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 1: Generate CodeInfo JSON ---")

f_test(x::Int64) = x * x + 1
ci, rt = only(Base.code_typed(f_test, (Int64,); optimize=true))
json_str = WasmTarget.serialize_ir_entries([(ci, rt, (Int64,), "f")])

json_path = joinpath(tempdir(), "gamma003_codeinfo.json")
write(json_path, json_str)
println("  ✓ Serialized to JSON ($(length(json_str)) bytes)")
println("  Statements: $(length(ci.code))")
for (i, stmt) in enumerate(ci.code)
    println("    %$i = $stmt")
end

# ═══════════════════════════════════════════════════════════════════════════════
# Step 2: Ensure codegen E2E WASM module exists
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 2: Check codegen WASM module ---")

wasm_path = joinpath(@__DIR__, "..", "..", "self-hosted-codegen-e2e.wasm")
if !isfile(wasm_path)
    println("  ✗ self-hosted-codegen-e2e.wasm not found")
    println("  Run: julia +1.12 --project=. test/selfhost/test_codegen_e2e_module.jl")
    error("Missing codegen module")
end
println("  ✓ Found $(basename(wasm_path)) ($(round(filesize(wasm_path)/1024, digits=1)) KB)")

# ═══════════════════════════════════════════════════════════════════════════════
# Step 3: Run Node.js roundtrip test
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Step 3: Node.js roundtrip test ---")

scripts_dir = joinpath(@__DIR__, "..", "..", "scripts")
test_script = joinpath(scripts_dir, "test_deserialize.cjs")

node_ok = false
try
    local result = strip(read(`node $test_script $json_path $wasm_path`, String))
    println(result)
    global node_ok = contains(result, "f(5) = 26") && contains(result, "0 failed")
catch e
    # Try to get stderr for better error messages
    try
        local err_result = read(pipeline(`node $test_script $json_path $wasm_path`, stderr=stdout), String)
        println(err_result)
    catch
    end
    println("  ✗ Node.js error: $(string(e)[1:min(500,end)])")
end

# Clean up
rm(json_path, force=true)

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

println("\n" * "=" ^ 60)
println("GAMMA-003 Summary:")
println("  JSON serialization: ✓")
println("  Codegen module exists: ✓")
println("  Node.js roundtrip (JSON → WASM codegen → f(5)=26): $(node_ok ? "✓" : "✗")")
println("=" ^ 60)

@testset "GAMMA-003: JS Deserializer Roundtrip" begin
    @test length(json_str) > 0
    @test isfile(wasm_path)
    @test node_ok
end
