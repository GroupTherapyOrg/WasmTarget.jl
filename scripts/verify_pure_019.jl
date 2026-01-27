using WasmTarget

# Define a function that uses NamedTuple construction
function test_named_tuple()
    # Explicit Int32 to avoid Any types if possible, though tuple inference should handle it
    tup = (Int32(10), Int32(20))
    nt = NamedTuple{(:a, :b)}(tup)
    return nt.a
end

try
    println("Compiling NamedTuple test...")
    bytes = compile(test_named_tuple, ())
    println("SUCCESS: Compiled $(length(bytes)) bytes")
    
    # Optional: basic validation check if we had tools, but compilation success is the first bar
    exit(0)
catch e
    println("ERROR: Compilation failed")
    showerror(stdout, e, catch_backtrace())
    println()
    exit(1)
end
