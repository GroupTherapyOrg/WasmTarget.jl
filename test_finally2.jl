include("test/utils.jl")
using WasmTarget

# Test 1: Simple finally that runs on normal path (Julia optimizes away try)
function try_finally_normal(x::Int32)::Int32
    result = Int32(0)
    try
        result = x + Int32(1)
    finally
        result = result + Int32(100)
    end
    return result
end

# Test 2: try/catch/finally with exception path
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

# Test 3: finally with return inside try (Julia optimizes away)
function try_finally_return(x::Int32)::Int32
    try
        return x + Int32(1)
    finally
        # runs but doesn't change return
    end
    return Int32(0)
end

# Test 4: Finally runs cleanup on exception (nested try/catch with rethrow)
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

all_pass = true
for (f, name, cases) in [
    (try_finally_normal, "try_finally_normal", [(Int32(5), 106)]),
    (try_finally_exception, "try_finally_exception", [(Int32(5), 106), (Int32(-3), 99)]),
    (try_finally_return, "try_finally_return", [(Int32(5), 6)]),
    (try_finally_cleanup, "try_finally_cleanup", [(Int32(5), 5), (Int32(-3), 101)])
]
    println("\n=== Compiling $name ===")
    try
        bytes = WasmTarget.compile(f, (Int32,))
        println("Compiled: $(length(bytes)) bytes")
        for (arg, expected) in cases
            result = run_wasm(bytes, name, arg)
            ok = result == expected
            status = ok ? "CORRECT" : "MISMATCH (expected $expected)"
            println("Wasm: $name($arg) = $result — $status")
            if !ok
                global all_pass = false
            end
        end
    catch e
        println("ERROR: ", e)
        global all_pass = false
    end
end

println("\nAll tests: $(all_pass ? "PASS" : "FAIL")")
