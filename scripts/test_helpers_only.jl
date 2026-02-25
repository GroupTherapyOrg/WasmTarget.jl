#!/usr/bin/env julia
# Test: compile JUST the helper functions (no eval_julia_to_bytes_vec)
# to see if set_byte_vec! works when not in the large integration module.

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget
using JuliaSyntax

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

function eval_julia_result_length(v::Vector{UInt8})::Int32
    return Int32(length(v))
end
function eval_julia_result_byte(v::Vector{UInt8}, idx::Int32)::Int32
    return Int32(v[idx])
end

funcs = [
    (make_byte_vec, (Int32,)),
    (set_byte_vec!, (Vector{UInt8}, Int32, Int32)),
    (eval_julia_result_length, (Vector{UInt8},)),
    (eval_julia_result_byte, (Vector{UInt8}, Int32)),
]
println("Compiling just helpers...")
bytes = WasmTarget.compile_multi(funcs)
write("/tmp/helpers_only.wasm", bytes)
println("Size: $(length(bytes)) bytes")

errbuf = IOBuffer()
ok = false
try
    Base.run(pipeline(`wasm-tools validate --features=gc /tmp/helpers_only.wasm`, stderr=errbuf, stdout=devnull))
    ok = true
catch; end
if ok
    println("Validate: PASS")
else
    println("Validate: FAIL")
    println(String(take!(errbuf)))
end
