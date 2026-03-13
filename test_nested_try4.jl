include("test/utils.jl")
using WasmTarget

# Test 3: Three-level nesting
function nested_try_3level(x::Int32)::Int32
    try
        try
            try
                if x < Int32(0)
                    error("deepest")
                end
                return x + Int32(1)
            catch
                error("middle rethrow")
            end
        catch
            error("outer rethrow")
        end
    catch
        return Int32(-999)
    end
    return Int32(0)
end

# Test 4: Sequential try/catch blocks (not nested)
function sequential_try(x::Int32)::Int32
    result = Int32(0)
    try
        if x < Int32(0)
            error("first")
        end
        result = x + Int32(10)
    catch
        result = Int32(-1)
    end
    try
        if result > Int32(100)
            error("second")
        end
        result = result + Int32(5)
    catch
        result = Int32(-2)
    end
    return result
end

# Test 5: Inner catch returning normally, outer try succeeds
function nested_try_inner_handles(x::Int32)::Int32
    try
        val = Int32(0)
        try
            if x < Int32(0)
                error("handled by inner")
            end
            val = x * Int32(2)
        catch
            val = Int32(42)  # inner catch handles, doesn't rethrow
        end
        return val + Int32(1)  # this should always execute
    catch
        return Int32(-999)  # should never be reached
    end
    return Int32(0)
end

println("=== Native Ground Truth ===")
println("nested_try_3level(5) = ", nested_try_3level(Int32(5)))
println("nested_try_3level(-3) = ", nested_try_3level(Int32(-3)))
println("sequential_try(5) = ", sequential_try(Int32(5)))
println("sequential_try(-3) = ", sequential_try(Int32(-3)))
println("sequential_try(200) = ", sequential_try(Int32(200)))
println("nested_try_inner_handles(5) = ", nested_try_inner_handles(Int32(5)))
println("nested_try_inner_handles(-3) = ", nested_try_inner_handles(Int32(-3)))

# Check IR for 3-level
println("\n=== IR: nested_try_3level ===")
ci = Base.code_typed(nested_try_3level, (Int32,))[1]
for (i, stmt) in enumerate(ci.first.code)
    println("  $i: $stmt :: $(ci.first.ssavaluetypes[i])")
end

println("\n=== IR: sequential_try ===")
ci2 = Base.code_typed(sequential_try, (Int32,))[1]
for (i, stmt) in enumerate(ci2.first.code)
    println("  $i: $stmt :: $(ci2.first.ssavaluetypes[i])")
end

println("\n=== IR: nested_try_inner_handles ===")
ci3 = Base.code_typed(nested_try_inner_handles, (Int32,))[1]
for (i, stmt) in enumerate(ci3.first.code)
    println("  $i: $stmt :: $(ci3.first.ssavaluetypes[i])")
end

# Compile and test
println("\n=== Compiling nested_try_3level ===")
try
    bytes = WasmTarget.compile(nested_try_3level, (Int32,))
    println("Compiled: $(length(bytes)) bytes")
    r1 = run_wasm(bytes, "nested_try_3level", Int32(5))
    println("Wasm: nested_try_3level(5) = $r1 — $(r1 == 6 ? "CORRECT" : "MISMATCH (expected 6)")")
    r2 = run_wasm(bytes, "nested_try_3level", Int32(-3))
    println("Wasm: nested_try_3level(-3) = $r2 — $(r2 == -999 ? "CORRECT" : "MISMATCH (expected -999)")")
catch e
    println("ERROR: ", e)
end

println("\n=== Compiling sequential_try ===")
try
    bytes = WasmTarget.compile(sequential_try, (Int32,))
    println("Compiled: $(length(bytes)) bytes")
    r1 = run_wasm(bytes, "sequential_try", Int32(5))
    println("Wasm: sequential_try(5) = $r1 — $(r1 == 20 ? "CORRECT" : "MISMATCH (expected 20)")")
    r2 = run_wasm(bytes, "sequential_try", Int32(-3))
    println("Wasm: sequential_try(-3) = $r2 — $(r2 == 4 ? "CORRECT" : "MISMATCH (expected 4)")")
    r3 = run_wasm(bytes, "sequential_try", Int32(200))
    println("Wasm: sequential_try(200) = $r3 — $(r3 == -2 ? "CORRECT" : "MISMATCH (expected -2)")")
catch e
    println("ERROR: ", e)
end

println("\n=== Compiling nested_try_inner_handles ===")
try
    bytes = WasmTarget.compile(nested_try_inner_handles, (Int32,))
    println("Compiled: $(length(bytes)) bytes")
    r1 = run_wasm(bytes, "nested_try_inner_handles", Int32(5))
    println("Wasm: nested_try_inner_handles(5) = $r1 — $(r1 == 11 ? "CORRECT" : "MISMATCH (expected 11)")")
    r2 = run_wasm(bytes, "nested_try_inner_handles", Int32(-3))
    println("Wasm: nested_try_inner_handles(-3) = $r2 — $(r2 == 43 ? "CORRECT" : "MISMATCH (expected 43)")")
catch e
    println("ERROR: ", e)
end
