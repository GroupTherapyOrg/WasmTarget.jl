#!/usr/bin/env julia
using Pkg
Pkg.activate(dirname(@__DIR__))

using WasmTarget
using WasmTarget: compile_multi, TypeRegistry, WasmModule, get_array_type!, julia_to_wasm_type

# Check how Token is classified
println("=== Token Type Classification ===")
Token = WasmTarget.Token
println("Token = $Token")
println("isconcretetype(Token) = $(isconcretetype(Token))")
println("isstructtype(Token) = $(isstructtype(Token))")
println("Token <: AbstractVector = $(Token <: AbstractVector)")
println("Token isa DataType = $(Token isa DataType)")
println("Token isa DataType && isstructtype(Token) = $(Token isa DataType && isstructtype(Token))")

# Check the Wasm type
println("\n=== Wasm Type Mapping ===")
wasm_type = julia_to_wasm_type(Token)
println("julia_to_wasm_type(Token) = $wasm_type")

# Check for Int32 (what strings use)
println("\njulia_to_wasm_type(Int32) = $(julia_to_wasm_type(Int32))")

# Now let's trace through get_array_type! by looking at registry state
println("\n=== Array Type Creation ===")

# Create a minimal compilation
bytes = compile_multi([
    (WasmTarget.token_eof, ()),
    (WasmTarget.token_list_new, (Int32,)),
])

println("Compiled $(length(bytes)) bytes")

# Write out and check
tempfile = "/tmp/debug_array_types.wasm"
write(tempfile, bytes)

println("\n=== Type Section ===")
run(`wasm-tools print $tempfile`)
