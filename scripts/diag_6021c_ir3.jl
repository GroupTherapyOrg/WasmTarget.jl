#!/usr/bin/env julia
# diag_6021c_ir3.jl — Get Julia IR + WASM locals for builtin_effects and compact!
# to understand which SSA value maps to the problematic locals
#
# testCommand: julia +1.12 --project=. scripts/diag_6021c_ir3.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
using JuliaSyntax
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))
@isdefined(Compiler) || (@eval const Compiler = Core.Compiler)
@isdefined(IRCode) || (@eval const IRCode = Core.Compiler.IRCode)

manifest_path = joinpath(@__DIR__, "eval_julia_manifest.txt")
all_lines = readlines(manifest_path)
data_lines = filter(l -> !startswith(l, "#") && !isempty(strip(l)), all_lines)

function get_entry(prefix)
    line = data_lines[findfirst(l -> startswith(l, prefix), data_lines)]
    parts = split(line, " | ")
    idx = Base.parse(Int, strip(parts[1]))
    mod_name = strip(parts[2])
    func_name = strip(parts[3])
    arg_types_str = strip(parts[4])
    mod = eval(Meta.parse(mod_name))
    func = getfield(mod, Symbol(func_name))
    arg_types = eval(Meta.parse(arg_types_str))
    arg_types isa Tuple || (arg_types = (arg_types,))
    (idx=idx, name=func_name, func=func, arg_types=arg_types)
end

println("=== Julia IR for compact! [121] ===")
e121 = get_entry("121 |")
try
    results = code_typed(e121.func, e121.arg_types; optimize=true)
    ci, rt = results[1]
    println("Return type: $rt ($(length(ci.code)) stmts)")
    for (i, stmt) in enumerate(ci.code)
        t = ci.ssavaluetypes[i]
        println("  %$i ::$t = $stmt")
    end
catch e
    println("ERROR: $e")
end

println()
println("=== Julia IR for builtin_effects [111] — first 100 stmts ===")
e111 = get_entry("111 |")
try
    results = code_typed(e111.func, e111.arg_types; optimize=true)
    ci, rt = results[1]
    println("Return type: $rt ($(length(ci.code)) stmts)")
    # Only show first 100 stmts
    for (i, stmt) in enumerate(ci.code)
        i > 100 && break
        t = ci.ssavaluetypes[i]
        println("  %$i ::$t = $stmt")
    end
catch e
    println("ERROR: $e")
end

println()
println("=== WASM locals for builtin_effects [111] (first 100) ===")
try
    # Compile and get the module to inspect locals
    bytes = compile(e111.func, e111.arg_types)
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    println("Compiled: $(length(bytes)) bytes")

    # Print first 200 lines to get locals section
    wat_buf = IOBuffer()
    Base.run(pipeline(`wasm-tools print $tmpf`, stdout=wat_buf))
    wat = String(take!(wat_buf))
    wat_lines = split(wat, '\n')
    println("WAT: $(length(wat_lines)) lines")

    # Find func 15 (the one with the error)
    f15_start = findfirst(l -> contains(l, "(func \$func_15") || contains(l, "func (;15;)"), wat_lines)
    if !isnothing(f15_start)
        println("func 15 starts at line $f15_start")
        # Print locals section (next 60 lines after func start)
        for i in f15_start:min(f15_start+60, length(wat_lines))
            println("$i: $(wat_lines[i])")
        end
    else
        # Try to find func with the error by searching for i64_mul
        mul_lines = findall(l -> contains(l, "i64.mul"), wat_lines)
        println("i64.mul found at lines: $(mul_lines[1:min(5,end)])")
        if !isempty(mul_lines)
            target = mul_lines[1]  # First i64.mul - may be the error one
            println("\n--- Context around first i64.mul (line $target) ---")
            for i in max(1,target-5):min(length(wat_lines),target+3)
                println("$i: $(wat_lines[i])")
            end
        end
    end
    rm(tmpf; force=true)
catch e
    println("ERROR: $e")
end

println()
println("=== Done ===")
