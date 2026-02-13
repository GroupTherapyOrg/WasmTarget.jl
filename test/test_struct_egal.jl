using WasmTarget
include(joinpath(@__DIR__, "utils.jl"))

# Test === on immutable structs
struct MyPos
    x::UInt32
    y::UInt32
end

# Same values -> should be true in Julia
function test_egal_same(a::Int32, b::Int32)::Int32
    p1 = MyPos(UInt32(a), UInt32(b))
    p2 = MyPos(UInt32(a), UInt32(b))
    return Int32(p1 === p2 ? 1 : 0)
end

# Different values -> should be false
function test_egal_diff(a::Int32, b::Int32)::Int32
    p1 = MyPos(UInt32(a), UInt32(b))
    p2 = MyPos(UInt32(a), UInt32(b + Int32(1)))
    return Int32(p1 === p2 ? 1 : 0)
end

# Native Julia ground truth
println("Native: test_egal_same(1, 2) = ", test_egal_same(Int32(1), Int32(2)), " (should be 1)")
println("Native: test_egal_diff(1, 2) = ", test_egal_diff(Int32(1), Int32(2)), " (should be 0)")

# Compile and test
r1 = compare_julia_wasm(test_egal_same, Int32(1), Int32(2))
println("Wasm: test_egal_same(1, 2) = ", r1.actual, " (", r1.pass ? "CORRECT" : "MISMATCH", ")")

r2 = compare_julia_wasm(test_egal_diff, Int32(1), Int32(2))
println("Wasm: test_egal_diff(1, 2) = ", r2.actual, " (", r2.pass ? "CORRECT" : "MISMATCH", ")")
