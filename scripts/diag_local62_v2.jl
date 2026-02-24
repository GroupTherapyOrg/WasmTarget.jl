#!/usr/bin/env julia
# Trace exactly which SSA value becomes WASM local 62 in func 14
# by hooking into allocate_ssa_locals! with temporary debug output

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

const Compiler = Core.Compiler

# We need to find which Julia function corresponds to func 14
# Func 14 has signature: (param (ref null 8)) (result i32)
# Let's compile and trace by adding a hook

# First, let's find what function becomes func 14 by looking at compile_module
# The compile_module function compiles the target + dependencies
# Each dependency gets a func index

# Let's patch allocate_ssa_locals! to log when it allocates externref locals
# that are used in arithmetic context

# Actually, let's just compile and examine the compilation context
# We can use the internal API

PL = Compiler.PartialsLattice{Compiler.ConstsLattice}
argtypes_tuple = (PL, Core.Builtin, Vector{Any}, Any)

# Find all methods that would be compiled
println("=== Compiling builtin_effects(PartialsLattice) with debug logging ===")
flush(stdout)

# Monkey-patch to add logging around local allocation
original_allocate_ssa_locals = WasmTarget.allocate_ssa_locals!

debug_func_idx = Ref(0)
debug_target_func = Ref(14)  # func we're interested in

function debug_allocate_ssa_locals!(ctx)
    debug_func_idx[] += 1
    result = original_allocate_ssa_locals(ctx)

    # Check if any locals are externref
    has_externref = false
    externref_locals = Int[]
    for (i, lt) in enumerate(ctx.locals)
        local_idx = ctx.n_params + i - 1
        if lt === WasmTarget.ExternRef
            push!(externref_locals, local_idx)
            has_externref = true
        end
    end

    if has_externref && length(ctx.code_info.code) > 50
        println("\n  func_$(debug_func_idx[]): $(length(ctx.code_info.code)) stmts, $(length(ctx.locals)) locals, $(length(externref_locals)) externref")

        # Check if local 62 is externref
        for erl in externref_locals
            if erl == 62
                println("    *** LOCAL 62 IS EXTERNREF ***")
                # Find which SSA maps to local 62
                for (ssa_id, local_idx) in ctx.ssa_locals
                    if local_idx == 62
                        stmt = ctx.code_info.code[ssa_id]
                        ssatypes = ctx.code_info.ssavaluetypes
                        t = ssatypes isa Vector && ssa_id <= length(ssatypes) ? ssatypes[ssa_id] : "unknown"
                        println("    SSA $ssa_id (type $t) → local 62")
                        println("    stmt: $(typeof(stmt)) = $stmt")
                        if stmt isa Expr
                            println("    head: $(stmt.head)")
                            for (ai, arg) in enumerate(stmt.args)
                                println("    arg[$ai]: $(typeof(arg)) = $arg")
                                if arg isa GlobalRef
                                    println("      mod=$(arg.mod) name=$(arg.name)")
                                end
                            end
                        end

                        # Find ALL uses of this SSA
                        ssa_val = Core.SSAValue(ssa_id)
                        println("    Uses of SSA $ssa_id:")
                        for (j, use_stmt) in enumerate(ctx.code_info.code)
                            uses_it = false
                            if use_stmt isa Expr
                                for arg in use_stmt.args
                                    if arg === ssa_val
                                        uses_it = true
                                    end
                                end
                            elseif use_stmt isa Core.PiNode && use_stmt.val === ssa_val
                                uses_it = true
                            elseif use_stmt isa Core.ReturnNode && isdefined(use_stmt, :val) && use_stmt.val === ssa_val
                                uses_it = true
                            elseif use_stmt isa Core.GotoIfNot && use_stmt.cond === ssa_val
                                uses_it = true
                            elseif use_stmt isa Core.PhiNode
                                for vi in 1:length(use_stmt.values)
                                    if isassigned(use_stmt.values, vi) && use_stmt.values[vi] === ssa_val
                                        uses_it = true
                                    end
                                end
                            end
                            if uses_it
                                ut = ssatypes isa Vector && j <= length(ssatypes) ? ssatypes[j] : "unknown"
                                println("      SSA $j ($ut): $(typeof(use_stmt)) = $(use_stmt)")
                                if use_stmt isa Expr
                                    println("        head=$(use_stmt.head)")
                                    for (ai, arg) in enumerate(use_stmt.args)
                                        if arg isa GlobalRef
                                            println("        arg[$ai] GlobalRef mod=$(arg.mod) name=$(arg.name)")
                                        end
                                    end
                                end
                            end
                        end
                        break
                    end
                end
                # Also check phi_locals
                for (ssa_id, local_idx) in ctx.phi_locals
                    if local_idx == 62
                        stmt = ctx.code_info.code[ssa_id]
                        ssatypes = ctx.code_info.ssavaluetypes
                        t = ssatypes isa Vector && ssa_id <= length(ssatypes) ? ssatypes[ssa_id] : "unknown"
                        println("    PHI SSA $ssa_id (type $t) → local 62")
                        println("    stmt: $stmt")
                    end
                end
            end
        end
    end

    return result
end

# Replace the function
@eval WasmTarget allocate_ssa_locals!(ctx) = $debug_allocate_ssa_locals!(ctx)

# Now compile
bytes = compile(Compiler.builtin_effects, argtypes_tuple)
println("\nCompiled: $(length(bytes)) bytes")

# Validate
tmpf = joinpath(tempdir(), "be_debug.wasm")
write(tmpf, bytes)
errbuf = IOBuffer()
ok = false
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
    ok = true
catch
end
if ok
    println("VALIDATES!")
else
    println("VALIDATE_ERROR: $(String(take!(errbuf)))")
end

println("\nDone.")
