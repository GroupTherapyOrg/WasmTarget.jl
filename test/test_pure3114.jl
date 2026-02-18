using WasmTarget, Core.Compiler

function test_compile_validate(name, f, argtypes)
    println("=== $name ===")
    try
        bytes = compile(f, argtypes)
        println("Compiled: $(length(bytes)) bytes")
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        p = run(ignorestatus(`wasm-tools validate --features=gc $tmpf`))
        if p.exitcode == 0
            println("VALIDATES")
        else
            println("VALIDATION FAILED")
            # Try to get the error message
            err = read(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=stdout), String)
            println(err)
        end
        return (bytes, tmpf)
    catch e
        println("COMPILE ERROR: ", sprint(showerror, e))
        return (nothing, nothing)
    end
end

println("--- PURE-3114: Batch 4 compilation ---\n")

r1 = test_compile_validate("1. getfield_tfunc",
    Core.Compiler.getfield_tfunc,
    (Core.Compiler.JLTypeLattice, Any, Any))

println()
r2 = test_compile_validate("2. return_cached_result",
    Core.Compiler.return_cached_result,
    (Core.Compiler.NativeInterpreter, Method, Core.CodeInstance, Core.Compiler.InferenceState, Bool, Bool))

println()
r3 = test_compile_validate("3. tmerge_limited",
    Core.Compiler.tmerge_limited,
    (Core.Compiler.InferenceLattice, Any, Any))

println()
r4 = test_compile_validate("4. update_exc_bestguess!",
    Core.Compiler.update_exc_bestguess!,
    (Core.Compiler.NativeInterpreter, Any, Core.Compiler.InferenceState))
