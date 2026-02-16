using WasmTarget, Core.Compiler

functions = [
    ("isready", Core.Compiler.isready, (Core.Compiler.Future,)),
    ("abstract_eval_phi", Core.Compiler.abstract_eval_phi, (Core.Compiler.NativeInterpreter, Core.PhiNode, Core.Compiler.StatementState, Core.Compiler.InferenceState)),
    ("record_slot_assign!", Core.Compiler.record_slot_assign!, (Core.Compiler.InferenceState,)),
    ("abstract_eval_basic_statement", Core.Compiler.abstract_eval_basic_statement, (Core.Compiler.NativeInterpreter, Any, Core.Compiler.StatementState, Core.Compiler.InferenceState)),
]

for (name, func, args) in functions
    println("=== $name ===")
    try
        bytes = compile(func, args)
        f = tempname() * ".wasm"
        write(f, bytes)
        println("Compiled: $(length(bytes)) bytes")
        result = read(pipeline(`wasm-tools validate --features=gc $f`, stderr=stdout), String)
        if isempty(result)
            println("VALIDATES ✓")
        else
            # Print only first few lines of error
            lines = split(result, "\n")
            for l in lines[1:min(5, length(lines))]
                println(l)
            end
        end
    catch e
        println("COMPILE ERROR: ", sprint(showerror, e))
    end
    println()
end
