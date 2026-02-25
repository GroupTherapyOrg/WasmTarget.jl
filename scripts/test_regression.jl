#!/usr/bin/env julia
# test_regression.jl — PURE-6025
# Check if the UnionAll fix caused a regression in _wasm_eval_arith

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using WasmTarget, JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

function eval_julia_result_length(v::Vector{UInt8})::Int32
    return Int32(length(v))
end
function eval_julia_result_byte(v::Vector{UInt8}, idx::Int32)::Int32
    return Int32(v[idx])
end

seed = [
    (_wasm_eval_arith, (Vector{UInt8},)),
    (eval_julia_test_eval_arith, (Vector{UInt8},)),
    (eval_julia_result_length, (Vector{UInt8},)),
    (eval_julia_result_byte, (Vector{UInt8}, Int32)),
    (make_byte_vec, (Int32,)),
    (set_byte_vec!, (Vector{UInt8}, Int32, Int32)),
    (_wasm_parse_arith, (JuliaSyntax.ParseStream,)),
]

println("Compiling _wasm_eval_arith...")
bytes = WasmTarget.compile_multi(seed)
println("$(length(bytes)) bytes")

tmpf = tempname() * ".wasm"
write(tmpf, bytes)

errbuf = IOBuffer()
validate_ok = let
    ok = false
    try
        Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
        ok = true
    catch; end
    ok
end

if validate_ok
    println("VALIDATES ✓ — no regression")
else
    err = String(take!(errbuf))
    println("VALIDATE_ERROR — REGRESSION!")
    for line in split(err, '\n')
        println(line)
    end
end
rm(tmpf; force=true)
