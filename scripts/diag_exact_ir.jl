#!/usr/bin/env julia
# Dump exact IR for the function that becomes func 14 in builtin_effects compilation
# Goal: see exactly what checked_smul_int call looks like (head, args[1] type/mod)

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

const Compiler = Core.Compiler

# We need to compile and intercept the CompilationContext
# Let's hook into compile_module to see what functions get compiled

PL = Compiler.PartialsLattice{Compiler.ConstsLattice}
argtypes = (PL, Core.Builtin, Vector{Any}, Any)

# First, compile and get the module
println("Compiling builtin_effects(PartialsLattice)...")
flush(stdout)
bytes = compile(Compiler.builtin_effects, argtypes)
println("Compiled: $(length(bytes)) bytes")

# Write WASM and get WAT
tmpf = joinpath(tempdir(), "be_exact.wasm")
write(tmpf, bytes)

# Validate to get the error
errbuf = IOBuffer()
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
    println("VALIDATES OK!")
    exit(0)
catch
end
err_msg = String(take!(errbuf))
println("Error: $err_msg")

# Now let's look at the IR for the DEPENDENCY functions
# The compile_module function compiles the target + all dependencies
# Let's trace what gets compiled by looking at the WAT function names

watf = joinpath(tempdir(), "be_exact.wat")
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=watf, stderr=devnull))
wat = read(watf, String)
wat_lines = split(wat, '\n')

# Extract function signatures (first line of each func)
println("\n=== Function declarations in module ===")
for (i, line) in enumerate(wat_lines)
    if occursin("(func ", line) && occursin("(;", line)
        println("  $i: $(strip(line))")
    end
end

# Now find func 14 header
println("\n=== Func 14 header ===")
func_count = 0
func14_header = ""
for (i, line) in enumerate(wat_lines)
    if occursin("(func ", line) && occursin("(;", line)
        func_count += 1
        if func_count == 14
            println("  Line $i: $(strip(line))")
            func14_header = strip(line)
            break
        end
    end
end

# Now use Julia's type inference to find which function this might be
# Let's look at ALL the methods that would be compiled as dependencies
# by examining the compile process

# Actually, let's approach differently: look at what SSA types are used
# We need to inspect the raw CodeInfo for the function
# Let's get all CodeInfo for memorynew_nothrow if it exists

println("\n=== Searching for memorynew_nothrow ===")
for m in methods(Compiler.memorynew_nothrow)
    sig = m.sig
    println("  Method: $sig")
    mi = Base.method_instances(m)
    for mi_item in mi
        println("    MI: $(mi_item.specTypes)")
    end
end

# Get CodeInfo
println("\n=== Raw IR for memorynew_nothrow(Vector{Any}) ===")
flush(stdout)
try
    ci_results = Base.code_typed(Compiler.memorynew_nothrow, (Type{Vector{Any}},))
    if !isempty(ci_results)
        ci, rettype = ci_results[1]
        code = ci.code
        ssatypes = ci.ssavaluetypes
        println("$(length(code)) statements, return type: $rettype")

        # Find all Any-typed SSAs and their usage in checked_smul_int or similar
        for (i, stmt) in enumerate(code)
            t = ssatypes isa Vector && i <= length(ssatypes) ? ssatypes[i] : "unknown"
            if t === Any || (stmt isa Expr && stmt.head === :call && length(stmt.args) >= 2 &&
                let f = stmt.args[1]
                    (f isa GlobalRef && (occursin("check", string(f.name)) || occursin("mul", string(f.name)))) ||
                    (f isa GlobalRef && f.name in (:checked_smul_int, :checked_umul_int, :mul_int))
                end)
                # Print this statement with full detail
                println("\n  SSA $i :: $t")
                println("    stmt type: $(typeof(stmt))")
                if stmt isa Expr
                    println("    head: $(stmt.head)")
                    for (ai, arg) in enumerate(stmt.args)
                        println("    arg[$ai]: $(typeof(arg)) = $arg")
                        if arg isa GlobalRef
                            println("      module: $(arg.mod), name: $(arg.name)")
                        end
                    end
                elseif stmt isa Core.PiNode
                    println("    PiNode val=$(stmt.val) typ=$(stmt.typ)")
                elseif stmt isa Core.PhiNode
                    println("    PhiNode edges=$(stmt.edges)")
                else
                    println("    value: $stmt")
                end
            end
        end
    end
catch ex
    println("Error getting CodeInfo: $(sprint(showerror, ex))")
    # Try alternative approach
    println("\nTrying all methods of memorynew_nothrow...")
    for m in methods(Compiler.memorynew_nothrow)
        println("  $(m.sig)")
    end
end

println("\nDone.")
