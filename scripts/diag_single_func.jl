#!/usr/bin/env julia
# diag_single_func.jl — compile one function and show WAT + error context
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget
include(joinpath(@__DIR__, "..", "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(@__DIR__, "..", "src", "eval_julia.jl"))
@isdefined(Compiler) || (@eval const Compiler = Core.Compiler)

manifest_path = joinpath(@__DIR__, "eval_julia_manifest.txt")
lines = readlines(manifest_path)
data_lines = filter(l -> !startswith(l, "#") && !isempty(strip(l)), lines)

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
    catch; return nothing end
    return (idx=idx, mod=mod_name, name=func_name, func=func, arg_types=arg_types)
end

# Find apply_type_nothrow (first entry)
target_line = first(filter(l -> contains(l, "apply_type_nothrow"), data_lines))
entry = resolve_entry(target_line)
println("Testing: [$(entry.idx)] $(entry.mod).$(entry.name)")
println("Arg types: $(entry.arg_types)")
println()

bytes = compile(entry.func, entry.arg_types)
println("Compiled: $(length(bytes)) bytes")

tmpf = tempname() * ".wasm"
write(tmpf, bytes)

errbuf = IOBuffer()
ok = false
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
    ok = true
catch; end

if ok
    println("VALIDATES")
else
    msg = String(take!(errbuf))
    println("VALIDATE_ERROR:")
    println(msg)

    # Find the hex offset
    m = match(r"at offset 0x([0-9a-f]+)", msg)
    if !isnothing(m)
        hex_offset = m.captures[1]
        println("\nError at hex offset 0x$hex_offset")

        # Dump WAT and search for nearby context
        wat_output = IOBuffer()
        try
            Base.run(pipeline(`wasm-tools print $tmpf`, stdout=wat_output))
            wat = String(take!(wat_output))
            wat_lines = split(wat, '\n')
            println("WAT: $(length(wat_lines)) lines, $(length(wat)) chars")
            # Show first 100 lines of WAT
            println("\n--- First 100 lines of WAT ---")
            for (i, l) in enumerate(wat_lines[1:min(100, end)])
                println("$i: $l")
            end
        catch e
            println("WAT dump failed: $e")
        end
    end
end
