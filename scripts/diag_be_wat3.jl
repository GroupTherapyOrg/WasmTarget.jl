#!/usr/bin/env julia
# diag_be_wat3.jl — Show lines 50-100 of func 15 and find local.set 62

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget, JuliaSyntax

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))
@isdefined(Compiler) || (@eval const Compiler = Core.Compiler)

bl = Core.Compiler.InferenceLattice{Core.Compiler.ConditionalsLattice{Core.Compiler.PartialsLattice{Core.Compiler.ConstsLattice}}}

println("Compiling builtin_effects...")
bytes = compile(Core.Compiler.builtin_effects, (bl, Core.Builtin, Vector{Any}, Any))
println("Compiled: $(length(bytes)) bytes")

function run_analysis(bytes)
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    wat = String(read(`wasm-tools print $tmpf`, String))
    lines = split(wat, '\n')

    # Find func 15 start
    func15_start = nothing
    for (i, line) in enumerate(lines)
        if contains(line, "(func (;15;)")
            func15_start = i
            break
        end
    end

    println("func 15 starts at line $func15_start")

    # Show lines 50-100 of func 15
    println("\n=== Lines 50-100 of func 15 (WAT lines $(func15_start+49)-$(func15_start+99)) ===")
    for i in (func15_start+49):min(func15_start+99, length(lines))
        println("$i: $(lines[i])")
    end

    # Show lines 100-150
    println("\n=== Lines 100-150 of func 15 ===")
    for i in (func15_start+99):min(func15_start+149, length(lines))
        println("$i: $(lines[i])")
    end

    # Show lines 150-200
    println("\n=== Lines 150-200 of func 15 ===")
    for i in (func15_start+149):min(func15_start+199, length(lines))
        println("$i: $(lines[i])")
    end

    # Also look at func 15 IR — count functions compiled and show which is func 15
    println("\n=== Functions in module (first 20) ===")
    func_count = 0
    for (i, line) in enumerate(lines)
        stripped = strip(line)
        if startswith(stripped, "(func ")
            func_count += 1
            if func_count <= 20
                println("  Func $(func_count-1) (;$(func_count-1);) at line $i: $(lines[i][1:min(80,length(lines[i]))])")
            end
            if func_count == 20
                break
            end
        end
    end
end

run_analysis(bytes)

# Get the Julia IR for what could be func 15
# It's a single-arg function taking Vector{Any} (or struct containing it)
# Let's check what gets compiled
println("\n=== Code typed for known helpers ===")

# Check array_len or similar
try
    results = code_typed(Core.Compiler.effects_for_sublattice, (Core.Compiler.InferenceLattice{Core.Compiler.ConditionalsLattice{Core.Compiler.PartialsLattice{Core.Compiler.ConstsLattice}}}, Core.Compiler.Effects); optimize=true)
    ci, rt = results[1]
    println("effects_for_sublattice: return=$rt stmts=$(length(ci.code))")
catch e
    println("effects_for_sublattice error: $e")
end
