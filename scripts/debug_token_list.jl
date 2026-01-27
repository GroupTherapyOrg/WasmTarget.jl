#!/usr/bin/env julia
using Pkg
Pkg.activate(dirname(@__DIR__))

using WasmTarget
using WasmTarget: compile_multi, TypeRegistry

# Check what array types are registered
println("=== Debugging Vector{Token} array type ===\n")

# Compile just token_list_new to see what types get registered
bytes = compile_multi([
    (WasmTarget.token_list_new, (Int32,)),
])

println("Compiled $(length(bytes)) bytes")

# Write and validate
tempfile = "/tmp/token_list_debug.wasm"
write(tempfile, bytes)

println("\n=== WASM structure ===")
run(`wasm-tools print $tempfile`)

println("\n=== Validation ===")
run(`wasm-tools validate $tempfile`)
