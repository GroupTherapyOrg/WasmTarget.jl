using WasmTarget

# Test 1: Basic nested (Julia optimizes to single try)
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

# Compile and test each function individually
println("=== Compiling nested_try_basic ===")
try
    bytes = WasmTarget.compile(nested_try_basic, (Int32,))
    write("test_nested_basic.wasm", bytes)
    println("Compiled OK, $(length(bytes)) bytes")

    # Run via node
    result1 = read(`node -e "
        const fs = require('fs');
        const bytes = fs.readFileSync('test_nested_basic.wasm');
        WebAssembly.instantiate(bytes).then(m => {
            console.log('nested_try_basic(5) =', m.instance.exports.nested_try_basic(5));
            console.log('nested_try_basic(-3) =', m.instance.exports.nested_try_basic(-3));
            console.log('nested_try_basic(0) =', m.instance.exports.nested_try_basic(0));
        });
    "`, String)
    println(result1)
catch e
    println("ERROR: ", e)
    println(sprint(showerror, e, catch_backtrace()))
end

println("\n=== Compiling nested_try_rethrow ===")
try
    bytes = WasmTarget.compile(nested_try_rethrow, (Int32,))
    write("test_nested_rethrow.wasm", bytes)
    println("Compiled OK, $(length(bytes)) bytes")

    # Validate
    run(`wasm-tools validate test_nested_rethrow.wasm`)
    println("wasm-tools validate: PASS")

    # Run via node
    result2 = read(`node -e "
        const fs = require('fs');
        const bytes = fs.readFileSync('test_nested_rethrow.wasm');
        WebAssembly.instantiate(bytes).then(m => {
            console.log('nested_try_rethrow(5) =', m.instance.exports.nested_try_rethrow(5));
            console.log('nested_try_rethrow(-3) =', m.instance.exports.nested_try_rethrow(-3));
        });
    "`, String)
    println(result2)
catch e
    println("ERROR: ", e)
    println(sprint(showerror, e, catch_backtrace()))
end
