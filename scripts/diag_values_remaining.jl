#!/usr/bin/env julia
# diag_values_remaining.jl — PURE-6021
# Compile apply_type_nothrow to debug "values remaining on stack"

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))

@isdefined(Compiler) || (@eval const Compiler = Core.Compiler)

# apply_type_nothrow: func 102/103 in manifest
# Multiple overloads listed - let's get the types from manifest
manifest_path = joinpath(@__DIR__, "eval_julia_manifest.txt")
lines = readlines(manifest_path)
data_lines = filter(l -> !startswith(l, "#") && !isempty(strip(l)), lines)

# Find apply_type_nothrow entries
target_lines = filter(l -> contains(l, "apply_type_nothrow"), data_lines)
println("Found $(length(target_lines)) apply_type_nothrow entries:")
for l in target_lines
    println("  ", l)
end
println()

# Try to compile one of them
function resolve_entry(line)
    parts = split(line, " | ")
    length(parts) < 4 && return nothing
    idx = Base.parse(Int, strip(parts[1]))
    mod_name = strip(parts[2])
    func_name = strip(parts[3])
    arg_types_str = strip(parts[4])
    mod = try eval(Meta.parse(mod_name)) catch; return nothing end
    mod isa Module || return nothing
    func = try getfield(mod, Symbol(func_name)) catch; return nothing end
    arg_types = try
        t = eval(Meta.parse(arg_types_str))
        t isa Tuple ? t : (t,)
    catch e
        println("  Failed to parse arg types: ", e)
        return nothing
    end
    return (idx=idx, mod=mod_name, name=func_name, func=func, arg_types=arg_types)
end

for line in target_lines[1:min(2, end)]
    entry = resolve_entry(line)
    isnothing(entry) && continue
    println("Compiling [$(entry.idx)] $(entry.mod).$(entry.name)$(entry.arg_types)...")

    try
        bytes = compile(entry.func, entry.arg_types)
        println("  Compiled: $(length(bytes)) bytes")

        # Write to temp file
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)

        # Validate
        errbuf = IOBuffer()
        ok = false
        try
            Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
            ok = true
        catch; end

        if ok
            println("  VALIDATES")
        else
            msg = String(take!(errbuf))
            println("  VALIDATE_ERROR: ", msg)

            # Dump WAT to find the offset
            println("  Dumping WAT for debugging...")
            watf = tmpf * ".wat"
            try
                Base.run(pipeline(`wasm-tools print $tmpf`, stdout=watf))
                # Find the offset mentioned in error
                offset_match = match(r"0x([0-9a-f]+)", msg)
                if !isnothing(offset_match)
                    offset_hex = offset_match.captures[1]
                    println("  Error at offset 0x$offset_hex")
                    # Count lines near that offset
                    wat_content = readlines(watf)
                    println("  WAT has $(length(wat_content)) lines")
                    println("  Showing first 50 lines of WAT:")
                    for (i, l) in enumerate(wat_content[1:min(50, end)])
                        println("    $i: $l")
                    end
                end
            catch e
                println("  WAT dump failed: $e")
            end
        end
    catch e
        println("  COMPILE_ERROR: ", sprint(showerror, e)[1:300])
    end
    println()
end
