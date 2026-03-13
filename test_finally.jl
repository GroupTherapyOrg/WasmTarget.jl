using WasmTarget

# Test 1: Simple finally that runs on normal path
function try_finally_normal(x::Int32)::Int32
    result = Int32(0)
    try
        result = x + Int32(1)
    finally
        result = result + Int32(100)
    end
    return result
end

# Test 2: Finally with exception path
function try_finally_exception(x::Int32)::Int32
    result = Int32(0)
    try
        if x < Int32(0)
            error("bad")
        end
        result = x + Int32(1)
    catch
        result = Int32(-1)
    finally
        result = result + Int32(100)
    end
    return result
end

# Test 3: Finally with return inside try
function try_finally_return(x::Int32)::Int32
    try
        return x + Int32(1)
    finally
        # This runs but doesn't change the return value
        # (unless it also returns, which overrides)
    end
    return Int32(0)
end

# Test 4: Finally runs cleanup on exception
function try_finally_cleanup(x::Int32)::Int32
    cleanup_ran = Int32(0)
    try
        try
            if x < Int32(0)
                error("bad")
            end
            return x
        finally
            cleanup_ran = Int32(1)
        end
    catch
        return cleanup_ran + Int32(100)
    end
    return Int32(0)
end

println("=== Native Ground Truth ===")
println("try_finally_normal(5) = ", try_finally_normal(Int32(5)))
println("try_finally_exception(5) = ", try_finally_exception(Int32(5)))
println("try_finally_exception(-3) = ", try_finally_exception(Int32(-3)))
println("try_finally_return(5) = ", try_finally_return(Int32(5)))
println("try_finally_cleanup(5) = ", try_finally_cleanup(Int32(5)))
println("try_finally_cleanup(-3) = ", try_finally_cleanup(Int32(-3)))

# IR
for (name, f, args) in [
    ("try_finally_normal", try_finally_normal, (Int32,)),
    ("try_finally_exception", try_finally_exception, (Int32,)),
    ("try_finally_return", try_finally_return, (Int32,)),
    ("try_finally_cleanup", try_finally_cleanup, (Int32,))
]
    println("\n=== IR: $name ===")
    ci = Base.code_typed(f, args)[1]
    for (i, stmt) in enumerate(ci.first.code)
        println("  $i: $stmt :: $(ci.first.ssavaluetypes[i])")
    end
end
