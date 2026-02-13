#!/usr/bin/env julia
# PURE-324 attempt 8: Test parsestmt in stages to identify which stub crashes
using WasmTarget
using JuliaSyntax

# Stage A: Just parse_expr_string (the full thing)
function parse_expr_string(s::String)
    JuliaSyntax.parsestmt(Expr, s)
end

println("=== Compiling parse_expr_string (full parsestmt) ===")
println("Capturing stub warnings...")
bytes = compile(parse_expr_string, (String,))
println("Compiled: $(length(bytes)) bytes")

# Write to temp file for testing
tmpf = joinpath(@__DIR__, "..", "browser", "parsestmt_test.wasm")
write(tmpf, bytes)
println("Written to: $tmpf")

# Validate
tmpwasm = tempname() * ".wasm"
write(tmpwasm, bytes)
try
    run(`wasm-tools validate --features=gc $tmpwasm`)
    println("VALIDATES: YES")
catch e
    println("VALIDATES: NO — $e")
end

# Count funcs
nfuncs = 0
try
    nfuncs = parse(Int, strip(read(`bash -c "wasm-tools print $tmpwasm | grep -c '(func'"`, String)))
    println("Functions: $nfuncs")
catch
    println("Could not count functions")
end
