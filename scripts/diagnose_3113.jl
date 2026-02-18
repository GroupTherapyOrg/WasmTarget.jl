using WasmTarget, Core.Compiler

function diagnose(name, f, argtypes)
    println("=== $name ===")
    try
        bytes = compile(f, argtypes)
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        println("Compiled: $(length(bytes)) bytes")
        result = run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=stdout), wait=false)
        wait(result)
        if result.exitcode == 0
            println("VALIDATES OK")
        else
            println("VALIDATION FAILED (exit code $(result.exitcode))")
        end
    catch e
        println("COMPILE ERROR: $e")
        if e isa MethodError
            println("  Available methods:")
            for m in methods(f)
                println("    $m")
            end
        end
    end
    println()
end

# 1. record_ssa_assign!
diagnose("record_ssa_assign!",
    Core.Compiler.record_ssa_assign!,
    (Core.Compiler.AbstractLattice, Int64, Any, Core.Compiler.InferenceState))

# 2. stupdate!
diagnose("stupdate!",
    Core.Compiler.stupdate!,
    (Core.Compiler.AbstractLattice, Vector{Core.Compiler.VarState}, Vector{Core.Compiler.VarState}))

# 3. tuple_tail_elem
diagnose("tuple_tail_elem",
    Core.Compiler.tuple_tail_elem,
    (Core.Compiler.AbstractLattice, Any, Vector{Any}))

# 4. type_annotate!
diagnose("type_annotate!",
    Core.Compiler.type_annotate!,
    (Core.Compiler.AbstractInterpreter, Core.Compiler.InferenceState))
