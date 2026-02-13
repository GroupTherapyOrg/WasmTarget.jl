using WasmTarget
include(joinpath(@__DIR__, "utils.jl"))

# Test 1: Simple while loop with ∉ pattern (Int32 to avoid BigInt issues)
function test_while_notin(flag::Int32)::Int32
    count = Int32(0)
    while flag != Int32(0) && flag != Int32(5)
        count += Int32(1)
        flag -= Int32(1)
    end
    return count
end

# Test using compare_julia_wasm
r1 = compare_julia_wasm(test_while_notin, Int32(3))
println("test_while_notin(3): native=$(r1.expected) wasm=$(r1.actual) $(r1.pass ? "CORRECT" : "MISMATCH")")

r2 = compare_julia_wasm(test_while_notin, Int32(0))
println("test_while_notin(0): native=$(r2.expected) wasm=$(r2.actual) $(r2.pass ? "CORRECT" : "MISMATCH")")

r3 = compare_julia_wasm(test_while_notin, Int32(5))
println("test_while_notin(5): native=$(r3.expected) wasm=$(r3.actual) $(r3.pass ? "CORRECT" : "MISMATCH")")

# Test 2: While loop with more complex ∉ check involving structs
# This is closer to what parse_stmts does with Kind values
struct MyKind
    val::UInt16
end

const EndMarker = MyKind(UInt16(752))
const NewlineWs = MyKind(UInt16(2))

function test_kind_loop(k_val::Int32)::Int32
    k = MyKind(UInt16(k_val))
    count = Int32(0)
    while k.val != EndMarker.val && k.val != NewlineWs.val
        count += Int32(1)
        k = MyKind(k.val - UInt16(1))
    end
    return count
end

r4 = compare_julia_wasm(test_kind_loop, Int32(752))
println("test_kind_loop(752/EndMarker): native=$(r4.expected) wasm=$(r4.actual) $(r4.pass ? "CORRECT" : "MISMATCH")")

r5 = compare_julia_wasm(test_kind_loop, Int32(2))
println("test_kind_loop(2/NewlineWs): native=$(r5.expected) wasm=$(r5.actual) $(r5.pass ? "CORRECT" : "MISMATCH")")

r6 = compare_julia_wasm(test_kind_loop, Int32(5))
println("test_kind_loop(5): native=$(r6.expected) wasm=$(r6.actual) $(r6.pass ? "CORRECT" : "MISMATCH")")
