#!/usr/bin/env julia
# test_6021_fix.jl — Test that BoundsError fix works for construct_ssa! etc.

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

@isdefined(Compiler) || (@eval const Compiler = Core.Compiler)
@isdefined(InternalCodeCache) || (@eval const InternalCodeCache = Core.Compiler.InternalCodeCache)
@isdefined(WorldRange) || (@eval const WorldRange = Core.Compiler.WorldRange)
@isdefined(InferenceResult) || (@eval const InferenceResult = Core.Compiler.InferenceResult)

println("Testing bounds fix for construct_ssa!, domsort_ssa!")
println()

# Use actual types from manifest
test_cases = [
    # 135 | Compiler | construct_ssa! | (Core.CodeInfo, IRCode, OptimizationState{WasmInterpreter}, GenericDomTree{false}, Vector{SlotInfo}, PartialsLattice{ConstsLattice})
    (Core.Compiler.construct_ssa!,
     (Core.CodeInfo, Core.Compiler.IRCode, Core.Compiler.OptimizationState{WasmInterpreter}, Core.Compiler.GenericDomTree{false}, Vector{Core.Compiler.SlotInfo}, Core.Compiler.PartialsLattice{Core.Compiler.ConstsLattice}),
     "construct_ssa!"),
    # 140 | Compiler | domsort_ssa! | (IRCode, GenericDomTree{false})
    (Core.Compiler.domsort_ssa!,
     (Core.Compiler.IRCode, Core.Compiler.GenericDomTree{false}),
     "domsort_ssa!"),
]

for (func, argtypes, name) in test_cases
    print("$name: ")
    flush(stdout)
    try
        task = Threads.@spawn compile(func, argtypes)
        result = timedwait(() -> istaskdone(task), 30.0)
        if result == :timed_out
            println("TIMEOUT")
        else
            bytes = fetch(task)
            tmpf = tempname() * ".wasm"
            write(tmpf, bytes)
            errbuf = IOBuffer()
            ok = false
            try
                Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
                ok = true
            catch; end
            if ok
                println("VALIDATES ($(length(bytes)) bytes)")
            else
                msg = String(take!(errbuf))
                println("VALIDATE_ERROR: ", msg[1:min(200, length(msg))])
            end
        end
    catch e
        println("COMPILE_ERROR: ", sprint(showerror, e)[1:300])
    end
end

println()
println("Done.")
