#!/usr/bin/env julia
# Dump the IR of builtin_effects — try different approach

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

const Compiler = Core.Compiler

# Get code_typed directly
println("Getting code_typed for builtin_effects(PartialsLattice)...")
flush(stdout)

PL = Compiler.PartialsLattice{Compiler.ConstsLattice}
ci = Base.code_typed(Compiler.builtin_effects, (PL, Core.Builtin, Vector{Any}, Any); optimize=true)

if isempty(ci)
    println("code_typed returned empty, trying with @code_typed approach...")
    # Try with instance
    lattice = Compiler.PartialsLattice(Compiler.ConstsLattice())
    ci = Base.code_typed(Compiler.builtin_effects, (typeof(lattice), Core.Builtin, Vector{Any}, Any); optimize=true)
end

if !isempty(ci)
    code_info, ret_type = ci[1]
    println("Return type: $ret_type")
    println("Stmts: $(length(code_info.code))")
    flush(stdout)

    # Find SSAs typed Any or Union{} that participate in UInt64 operations
    println("\n=== SSAs typed Any/Union{} used by Int64/UInt64 stmts ===")
    for (i, stmt) in enumerate(code_info.code)
        ssa_type = code_info.ssavaluetypes[i]
        if ssa_type in (Int64, UInt64, Int, UInt)
            if stmt isa Expr
                for arg in stmt.args
                    if arg isa Core.SSAValue
                        arg_type = code_info.ssavaluetypes[arg.id]
                        if arg_type === Any || arg_type === Union{}
                            println("SSA $i ($ssa_type): uses SSA $(arg.id) ($arg_type)")
                            println("  stmt: $(stmt.head) $(stmt.args[1:min(4,length(stmt.args))])")
                            # What defines SSA arg.id?
                            def_stmt = code_info.code[arg.id]
                            println("  def of SSA $(arg.id): $(typeof(def_stmt)) = $def_stmt")
                        end
                    end
                end
            end
        end
    end

    # Find the i64.mul pattern: look for mul_int / and_int / etc with mistyped args
    println("\n=== Intrinsic calls with potential type mismatch ===")
    for (i, stmt) in enumerate(code_info.code)
        if stmt isa Expr && stmt.head === :call
            func = stmt.args[1]
            if func isa GlobalRef && func.name in (:mul_int, :and_int, :or_int, :xor_int, :shl_int, :lshr_int, :add_int, :sub_int)
                ssa_type = code_info.ssavaluetypes[i]
                println("SSA $i ($ssa_type): $(func.name)")
                for (j, arg) in enumerate(stmt.args[2:end])
                    if arg isa Core.SSAValue
                        at = code_info.ssavaluetypes[arg.id]
                        marker = (at === Any || at === Union{}) ? " *** MISMATCH ***" : ""
                        println("  arg $j: SSA $(arg.id) ($at)$marker")
                    end
                end
            end
        end
    end

    # Also look for phi nodes where one edge is in dead code
    println("\n=== Phi nodes with edges from dead/Any-typed code ===")
    for (i, stmt) in enumerate(code_info.code)
        if stmt isa Core.PhiNode && haskey(Dict(enumerate(code_info.ssavaluetypes)), i)
            phi_type = code_info.ssavaluetypes[i]
            has_mismatch = false
            for (j, edge) in enumerate(stmt.edges)
                if isassigned(stmt.values, j)
                    val = stmt.values[j]
                    if val isa Core.SSAValue
                        vt = code_info.ssavaluetypes[val.id]
                        if vt === Any || vt === Union{}
                            has_mismatch = true
                        end
                    end
                end
            end
            if has_mismatch
                println("SSA $i ($phi_type): PhiNode")
                for (j, edge) in enumerate(stmt.edges)
                    if isassigned(stmt.values, j)
                        val = stmt.values[j]
                        vt = val isa Core.SSAValue ? code_info.ssavaluetypes[val.id] : typeof(val)
                        println("  edge $edge → val=$val ($vt)")
                    end
                end
            end
        end
    end
else
    println("Still empty. Listing methods:")
    for m in methods(Compiler.builtin_effects)
        println("  $(m.sig)")
    end
end
