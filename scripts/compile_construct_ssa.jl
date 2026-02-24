using WasmTarget
using JuliaSyntax

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

arg_types = (Core.CodeInfo, Core.Compiler.IRCode, Core.Compiler.OptimizationState{WasmInterpreter}, Core.Compiler.GenericDomTree{false}, Vector{Core.Compiler.SlotInfo}, Core.Compiler.PartialsLattice{Core.Compiler.ConstsLattice})

println("Compiling construct_ssa! individually...")
try
    bytes = WasmTarget.compile(Core.Compiler.construct_ssa!, arg_types)
    outfile = joinpath(@__DIR__, "..", "output", "construct_ssa.wasm")
    write(outfile, bytes)
    println("Size: $(length(bytes)) bytes")

    # Validate
    println("Validating...")
    proc = run(pipeline(`wasm-tools validate $outfile`, stderr=stdout), wait=false)
    wait(proc)
    if proc.exitcode == 0
        println("VALIDATES")
    else
        println("VALIDATE_ERROR")
    end
catch e
    println("ERROR: ", sprint(showerror, e))
end
