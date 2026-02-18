#!/usr/bin/env julia
# Debug: Print the IR for test_egal_return to understand the === comparison
using WasmTarget
include(joinpath(@__DIR__, "..", "src", "typeinf", "subtype.jl"))
include(joinpath(@__DIR__, "..", "src", "typeinf", "matching.jl"))

test_egal_return() = begin
    x = wasm_type_intersection(Int64, Number)
    return Int32(x === Int64)
end

test_isect_1() = Int32(wasm_type_intersection(Int64, Number) === Int64)

println("=== IR for test_egal_return ===")
ir1 = code_typed(test_egal_return, ())[1]
println(ir1[1])
println("\nReturn type: ", ir1[2])

println("\n=== IR for test_isect_1 ===")
ir2 = code_typed(test_isect_1, ())[1]
println(ir2[1])
println("\nReturn type: ", ir2[2])
