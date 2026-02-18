#!/usr/bin/env julia
# PURE-5001: Compile test wrappers for stage execution testing
#
# Each test wrapper calls a stage function with a known input and returns
# a simple result (Int32) that can be verified from JS.
#
# This avoids the WasmGC nominal typing issue: strings and structs are
# created INSIDE the same module, so types match.

using WasmTarget
using JuliaSyntax
using JuliaLowering

# Load typeinf infrastructure
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
using Core.Compiler: InferenceState

println("=" ^ 60)
println("PURE-5001: Stage Execution Test Compilation")
println("=" ^ 60)

# ═══════════════════════════════════════════════════════════════
# Stage 1 test: parse_expr_string("1+1") → check result is Expr
# ═══════════════════════════════════════════════════════════════

# Test: parse "1+1", check that it returns something (not nothing)
function test_parse_returns() :: Int32
    result = JuliaSyntax.parsestmt(Expr, "1+1")
    return result isa Expr ? Int32(1) : Int32(0)
end

# Test: parse "42" → should return a literal integer
function test_parse_literal() :: Int32
    result = JuliaSyntax.parsestmt(Expr, "42")
    return result isa Integer ? Int32(1) : Int32(0)
end

# Test: parse "1+2" → should be a call expression
function test_parse_call() :: Int32
    result = JuliaSyntax.parsestmt(Expr, "1+2")
    return result isa Expr ? Int32(1) : Int32(0)
end

# ═══════════════════════════════════════════════════════════════
# Compile all test wrappers into one module
# ═══════════════════════════════════════════════════════════════

test_functions = [
    (test_parse_returns, ()),
    (test_parse_literal, ()),
    (test_parse_call, ()),
]

println("\nCompiling test wrappers...")
bytes = try
    b = compile_multi(test_functions)
    println("  compile_multi SUCCESS: $(length(b)) bytes")
    b
catch e
    println("  COMPILE_ERROR: $(sprint(showerror, e))")
    exit(1)
end

# Validate
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
try
    run(`wasm-tools validate --features=gc $tmpf`)
    println("  VALIDATES ✓")
catch
    valerr = try readchomp(`bash -c "wasm-tools validate --features=gc $tmpf 2>&1 || true"`) catch; "" end
    println("  VALIDATE_ERROR: $(first(valerr, 400))")
end

# Save
outpath = joinpath(@__DIR__, "stage_tests.wasm")
write(outpath, bytes)
println("  SAVED: scripts/stage_tests.wasm ($(length(bytes)) bytes)")

# List exports
nfuncs = try
    out = read(pipeline(`wasm-tools print $outpath`, `grep -c "(func "`), String)
    parse(Int, strip(out))
catch; -1 end
nexports = try
    out = read(pipeline(`wasm-tools print $outpath`, `grep -c "(export "`), String)
    parse(Int, strip(out))
catch; -1 end
println("  Functions: $nfuncs, Exports: $nexports")

# List export names
exports = try
    out = read(pipeline(`wasm-tools print $outpath`, `grep "(export"`), String)
    strip(out)
catch; "" end
println("\n  Exports:\n$exports")

# Node.js test
include(joinpath(@__DIR__, "..", "test", "utils.jl"))
if NODE_CMD !== nothing
    println("\n--- Node.js execution test ---")
    test_cases = [
        ("test_parse_returns (parse '1+1' → Expr?)", "test_parse_returns", Int32(1)),
        ("test_parse_literal (parse '42' → Integer?)", "test_parse_literal", Int32(1)),
        ("test_parse_call (parse '1+2' → Expr?)", "test_parse_call", Int32(1)),
    ]
    pass = 0
    for (label, fname, expected) in test_cases
        print("  $label → ")
        try
            actual = run_wasm(bytes, fname)
            if actual == expected
                println("EXECUTES + CORRECT ✓")
                pass += 1
            else
                println("EXECUTES but WRONG (got $actual, expected $expected)")
            end
        catch e
            emsg = sprint(showerror, e)
            if contains(emsg, "unreachable") || contains(emsg, "trap")
                println("TRAP: $(first(emsg, 100))")
            elseif contains(emsg, "timeout") || contains(emsg, "hang")
                println("HANG")
            else
                println("ERROR: $(first(emsg, 100))")
            end
        end
    end
    println("\nResults: $pass/$(length(test_cases))")
else
    println("\n--- Node.js not available ---")
end

rm(tmpf, force=true)
println("\nDone.")
