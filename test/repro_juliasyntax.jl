using WasmTarget
using JuliaSyntax

# Test 1: Vector resize!
function test_resize()
    v = Int32[1, 2, 3]
    resize!(v, 5)
    return length(v)
end

# Test 2: ParseStream (just creation for now, as it might fail)
function test_parsestream()
    # ParseStream requires a string
    ps = ParseStream("x = 1")
    return ps
end

# Test 3: JuliaSyntax.parsestmt (the goal)
function test_parsestmt()
    # parsestmt(SyntaxNode, "x = 1")
    return JuliaSyntax.parsestmt(JuliaSyntax.SyntaxNode, "x = 1")
end

println("--- COMPILING resize! ---")
try
    wasm = WasmTarget.compile(test_resize, ())
    println("SUCCESS: resize!")
catch e
    println("FAILED: resize!")
    showerror(stdout, e)
    println()
end

println("\n--- COMPILING ParseStream ---")
try
    wasm = WasmTarget.compile(test_parsestream, ())
    println("SUCCESS: ParseStream")
catch e
    println("FAILED: ParseStream")
    showerror(stdout, e)
    println()
end

println("\n--- COMPILING parsestmt ---")
try
    wasm = WasmTarget.compile(test_parsestmt, ())
    println("SUCCESS: parsestmt")
catch e
    println("FAILED: parsestmt")
    showerror(stdout, e)
    println()
end
