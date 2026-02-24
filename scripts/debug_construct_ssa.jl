using WasmTarget

# Compile construct_ssa! individually to trace the struct_new 164 issue
# The types used by construct_ssa!:
arg_types = (Core.Compiler.IncrementalCompact, Vector{Any}, Vector{Any}, Type, Bool, Bool)

println("Compiling construct_ssa! individually...")
try
    bytes = WasmTarget.compile(Core.Compiler.construct_ssa!, arg_types)
    outfile = "/tmp/construct_ssa.wasm"
    write(outfile, bytes)
    println("Size: $(length(bytes)) bytes")

    # Validate
    println("Validating...")
    result = run(pipeline(`wasm-tools validate $outfile --features=gc,function-references,bulk-memory,reference-types,mutable-global,tail-call`, stderr=stdout), wait=false)
    wait(result)
    if result.exitcode == 0
        println("VALIDATES ✓")
    else
        println("VALIDATE_ERROR ✗")
    end
catch e
    println("ERROR: ", sprint(showerror, e))
    println(sprint(Base.show_backtrace, catch_backtrace()))
end
