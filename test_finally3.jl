include("test/utils.jl")
using WasmTarget

# Test: return inside try + finally runs on both paths
function finally_both_paths(x::Int32)::Int32
    try
        try
            if x < Int32(0)
                error("neg")
            end
            return x
        finally
            # finally body runs on both normal and exception paths
        end
    catch
        return Int32(-1)
    end
    return Int32(0)
end

println("Native: finally_both_paths(5) = ", finally_both_paths(Int32(5)))
println("Native: finally_both_paths(-3) = ", finally_both_paths(Int32(-3)))

bytes = WasmTarget.compile(finally_both_paths, (Int32,))
r1 = run_wasm(bytes, "finally_both_paths", Int32(5))
println("Wasm: finally_both_paths(5) = $r1 -- $(r1 == 5 ? "CORRECT" : "MISMATCH")")
r2 = run_wasm(bytes, "finally_both_paths", Int32(-3))
println("Wasm: finally_both_paths(-3) = $r2 -- $(r2 == -1 ? "CORRECT" : "MISMATCH")")
