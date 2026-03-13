include("test/utils.jl")
using WasmTarget

# Test 1: Basic nested (Julia optimizes to single try - EnterNode with phi)
function nested_try_basic(x::Int32)::Int32
    result = Int32(0)
    try
        try
            if x < Int32(0)
                error("inner")
            end
            result = x + Int32(1)
        catch
            result = Int32(-1)
        end
    catch
        result = Int32(-99)
    end
    return result
end

# Test 2: Inner rethrow caught by outer (true nesting)
function nested_try_rethrow(x::Int32)::Int32
    try
        try
            if x < Int32(0)
                error("bad")
            end
            return x + Int32(1)
        catch
            error("rethrown")
        end
    catch
        return Int32(-99)
    end
    return Int32(0)
end

println("=== Native Ground Truth ===")
println("nested_try_basic(5) = ", nested_try_basic(Int32(5)))
println("nested_try_basic(-3) = ", nested_try_basic(Int32(-3)))
println("nested_try_basic(0) = ", nested_try_basic(Int32(0)))
println("nested_try_rethrow(5) = ", nested_try_rethrow(Int32(5)))
println("nested_try_rethrow(-3) = ", nested_try_rethrow(Int32(-3)))

println("\n=== Compiling nested_try_basic ===")
bytes1 = WasmTarget.compile(nested_try_basic, (Int32,))
println("Compiled: $(length(bytes1)) bytes")
r1 = run_wasm(bytes1, "nested_try_basic", Int32(5))
println("Wasm: nested_try_basic(5) = $r1 — $(r1 == 6 ? "CORRECT" : "MISMATCH")")
r2 = run_wasm(bytes1, "nested_try_basic", Int32(-3))
println("Wasm: nested_try_basic(-3) = $r2 — $(r2 == -1 ? "CORRECT" : "MISMATCH")")
r3 = run_wasm(bytes1, "nested_try_basic", Int32(0))
println("Wasm: nested_try_basic(0) = $r3 — $(r3 == 1 ? "CORRECT" : "MISMATCH")")

println("\n=== Compiling nested_try_rethrow ===")
bytes2 = WasmTarget.compile(nested_try_rethrow, (Int32,))
println("Compiled: $(length(bytes2)) bytes")
r4 = run_wasm(bytes2, "nested_try_rethrow", Int32(5))
println("Wasm: nested_try_rethrow(5) = $r4 — $(r4 == 6 ? "CORRECT" : "MISMATCH")")
r5 = run_wasm(bytes2, "nested_try_rethrow", Int32(-3))
println("Wasm: nested_try_rethrow(-3) = $r5 — $(r5 == -99 ? "CORRECT" : "MISMATCH")")
