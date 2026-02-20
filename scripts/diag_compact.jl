#!/usr/bin/env julia
# diag_compact.jl — PURE-6021d
# Diagnose compact!(IRCode, Bool) and non_dce_finish!(IncrementalCompact) VALIDATE_ERRs

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
using JuliaSyntax
using Dates

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))
@isdefined(Compiler) || (@eval const Compiler = Core.Compiler)
@isdefined(IRCode) || (@eval const IRCode = Core.Compiler.IRCode)
@isdefined(IncrementalCompact) || (@eval const IncrementalCompact = Core.Compiler.IncrementalCompact)

println("=== PURE-6021d: Diagnose compact! and non_dce_finish! ===")
println("Started: $(Dates.now())")
println()

function get_wasm_error(f, arg_types)
    bytes = try
        compile(f, arg_types)
    catch e
        return nothing, "COMPILE_ERROR: $(sprint(showerror, e)[1:200])"
    end

    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    errbuf = IOBuffer()
    try
        run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
        return bytes, "VALIDATES ✓"
    catch
        err = String(take!(errbuf))
        return bytes, "VALIDATE_ERROR: $(err)"
    end
end

function get_wat_around_func(bytes, func_num; context=30)
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    wat = try
        String(read(`wasm-tools print $tmpf`, String))
    catch e
        return "WAT error: $e"
    end
    lines = split(wat, '\n')

    # Find the function definitions (count func keywords in type section + code section)
    # wasm-tools print shows functions as (func $name (type ...) ...)
    func_count = 0
    target_line = nothing
    for (i, line) in enumerate(lines)
        stripped = strip(line)
        if startswith(stripped, "(func ")
            func_count += 1
            if func_count == func_num
                target_line = i
                break
            end
        end
    end

    if target_line === nothing
        return "Could not find func $func_num in WAT (total funcs seen: $func_count)"
    end

    start_l = max(1, target_line - 5)
    end_l = min(length(lines), target_line + context)
    return join(lines[start_l:end_l], '\n')
end

function get_julia_ir(f, arg_types)
    try
        results = code_typed(f, arg_types; optimize=true)
        if isempty(results)
            return "No IR found"
        end
        ir, rt = results[1]
        lines = String[]
        push!(lines, "Return type: $rt")
        for i in 1:min(50, length(ir.stmts))
            inst = ir.stmts[i][:inst]
            typ = ir.stmts[i][:type]
            push!(lines, "  %$i ::$typ = $inst")
        end
        if length(ir.stmts) > 50
            push!(lines, "  ... ($(length(ir.stmts) - 50) more stmts)")
        end
        return join(lines, '\n')
    catch e
        return "code_typed error: $(sprint(showerror, e)[1:200])"
    end
end

# ── Diagnose compact!(IRCode, Bool) ──────────────────────────────────────────
println("=== [121] compact!(IRCode, Bool) ===")
f_compact = Core.Compiler.compact!
args_compact = (Core.Compiler.IRCode, Bool)
bytes_compact, msg_compact = get_wasm_error(f_compact, args_compact)
println("Status: $msg_compact")

if bytes_compact !== nothing
    println("\nWAT context around func 4:")
    println(get_wat_around_func(bytes_compact, 4; context=40))
    println("\nJulia IR:")
    println(get_julia_ir(f_compact, args_compact))
end
println()

# ── Diagnose non_dce_finish!(IncrementalCompact) ──────────────────────────────
println("=== [270] non_dce_finish!(IncrementalCompact) ===")
f_nondce = Core.Compiler.non_dce_finish!
args_nondce = (Core.Compiler.IncrementalCompact,)
bytes_nondce, msg_nondce = get_wasm_error(f_nondce, args_nondce)
println("Status: $msg_nondce")

if bytes_nondce !== nothing
    println("\nWAT context around func 3:")
    println(get_wat_around_func(bytes_nondce, 3; context=40))
    println("\nJulia IR:")
    println(get_julia_ir(f_nondce, args_nondce))
end
println()

# ── Diagnose builtin_effects ──────────────────────────────────────────────────
println("=== [111] builtin_effects(InferenceLattice, ...) ===")
bl = Core.Compiler.InferenceLattice{Core.Compiler.ConditionalsLattice{Core.Compiler.PartialsLattice{Core.Compiler.ConstsLattice}}}
f_be = Core.Compiler.builtin_effects
args_be = (bl, Core.Builtin, Vector{Any}, Any)
bytes_be, msg_be = get_wasm_error(f_be, args_be)
println("Status: $msg_be")

if bytes_be !== nothing
    println("\nFirst 5 lines of validate error (from wasm-tools print):")
    # Get first error context
    println(get_wat_around_func(bytes_be, 15; context=20))
end
println()

println("Done: $(Dates.now())")
