#!/usr/bin/env julia
# PURE-6023: Compile fresh arith module with current codebase
# Tests whether _wasm_eval_arith still works after dead code guard changes

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
    @inbounds return Int32(v[Int(idx)])
end

sbv = getfield(Main, Symbol("set_byte_vec!"))

funcs = [
    (_wasm_eval_arith, (Vector{UInt8},)),
    (_wasm_parse_arith, (JuliaSyntax.ParseStream,)),
    (_wasm_parse_int_from_range, (Vector{UInt8}, UnitRange{Int64})),
    (make_byte_vec, (Int32,)),
    (sbv, (Vector{UInt8}, Int32, Int32)),
    (eval_julia_result_length, (Vector{UInt8},)),
    (eval_julia_result_byte, (Vector{UInt8}, Int32)),
]

println("Compiling arith module (fresh)...")
t = time()
bytes = WasmTarget.compile_multi(funcs)
dt = time() - t
write("/tmp/eval_arith_fresh.wasm", bytes)
println("  Size: $(length(bytes)) bytes ($(round(length(bytes)/1024, digits=1)) KB)")
println("  Time: $(round(dt, digits=1))s")

errbuf = IOBuffer()
local validate_ok = false
try
    Base.run(pipeline(`wasm-tools validate --features=gc /tmp/eval_arith_fresh.wasm`, stderr=errbuf, stdout=devnull))
    validate_ok = true
catch; end
println("  Validate: $(validate_ok ? "PASS" : "FAIL")")
if !validate_ok
    println("  $(String(take!(errbuf)))")
end
