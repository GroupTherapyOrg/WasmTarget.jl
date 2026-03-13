using WasmTarget

# Test 1: nested try/catch where inner catches, outer is not reached
function nested_try_basic(x::Int32)::Int32
    result = Int32(0)
    try
        try
            if x < Int32(0)
                error("inner")
            end
            result = x + Int32(1)
        catch
            result = Int32(-1)  # inner catch handles it
        end
    catch
        result = Int32(-99)  # outer catch — should NOT be reached
    end
    return result
end

# Test 2: inner catch rethrows, outer catch handles it
function nested_try_rethrow(x::Int32)::Int32
    try
        try
            if x < Int32(0)
                error("bad")
            end
            return x + Int32(1)
        catch
            error("rethrown")  # throws new exception, caught by outer
        end
    catch
        return Int32(-99)  # outer catch handles rethrown exception
    end
    return Int32(0)
end

# Test 3: simple nested - inner try succeeds, no exception
function nested_try_noerr(x::Int32)::Int32
    try
        try
            return x * Int32(2)
        catch
            return Int32(-1)
        end
    catch
        return Int32(-2)
    end
    return Int32(0)
end

# Native ground truth
println("=== Native Julia Ground Truth ===")
println("nested_try_basic(5) = ", nested_try_basic(Int32(5)))
println("nested_try_basic(-3) = ", nested_try_basic(Int32(-3)))
println("nested_try_basic(0) = ", nested_try_basic(Int32(0)))
println("nested_try_rethrow(5) = ", nested_try_rethrow(Int32(5)))
println("nested_try_rethrow(-3) = ", nested_try_rethrow(Int32(-3)))
println("nested_try_noerr(7) = ", nested_try_noerr(Int32(7)))

# Look at IR
println("\n=== IR: nested_try_basic ===")
ci = Base.code_typed(nested_try_basic, (Int32,))[1]
for (i, stmt) in enumerate(ci.first.code)
    println("  $i: $stmt :: $(ci.first.ssavaluetypes[i])")
end

println("\n=== IR: nested_try_rethrow ===")
ci2 = Base.code_typed(nested_try_rethrow, (Int32,))[1]
for (i, stmt) in enumerate(ci2.first.code)
    println("  $i: $stmt :: $(ci2.first.ssavaluetypes[i])")
end

println("\n=== IR: nested_try_noerr ===")
ci3 = Base.code_typed(nested_try_noerr, (Int32,))[1]
for (i, stmt) in enumerate(ci3.first.code)
    println("  $i: $stmt :: $(ci3.first.ssavaluetypes[i])")
end
