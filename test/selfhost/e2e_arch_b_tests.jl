# TEST-003: Architecture B Regression Test Suite — 20 Groups, 100 Test Cases
#
# ZERO server dependency. ALL compilation happens in eval_julia.wasm.
# Each expression is compiled entirely in the browser WASM pipeline:
#   source string → WASM parse → WASM typeinf → WASM codegen → execute
#
# The same mathematical operations as Arch A/C's 20 functions, expressed
# as individual binary arithmetic expressions.
#
# Run: julia +1.12 --project=. test/selfhost/e2e_arch_b_tests.jl

using Test

println("=" ^ 60)
println("TEST-003: Architecture B Regression Tests — 20 groups")
println("  ZERO server. ALL compilation in browser WASM.")
println("=" ^ 60)

# ═══════════════════════════════════════════════════════════════════════════════
# Run Node.js Architecture B tests
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- Running Architecture B tests in Node.js ---")

script_path = joinpath(@__DIR__, "..", "..", "scripts", "run_arch_b_tests.cjs")
node_ok = false

try
    result = read(`node $script_path`, String)
    for line in split(strip(result), '\n')
        println("  $line")
    end
    global node_ok = contains(result, "ALL PASS")
catch e
    println("  Node.js failed: $(sprint(showerror, e)[1:min(200,end)])")
end

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════

println("\n" * "=" ^ 60)
println("TEST-003 Summary:")
println("  Groups: 20")
println("  Test cases: 100")
println("  Architecture B E2E: $node_ok")
println("  Server dependency: ZERO")
println("=" ^ 60)

@testset "TEST-003: Architecture B Regression (20 groups, 100 cases)" begin
    @test node_ok
end

println("\nAll TEST-003 tests complete.")
