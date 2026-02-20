#!/usr/bin/env julia
# find_values_remaining.jl — dump WAT and search for offset 0xe8c

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

target_line = first(filter(l -> contains(l, "apply_type_nothrow"), data_lines))
entry = resolve_entry(target_line)
println("Compiling [$(entry.idx)] $(entry.mod).$(entry.name)...")

bytes = compile(entry.func, entry.arg_types)
tmpf = tempname() * ".wasm"
write(tmpf, bytes)

# Dump with offsets using wasm-tools dump (shows binary layout)
println("\nRunning wasm-tools dump to find offset 0xe8c...")
dump_buf = IOBuffer()
try
    Base.run(pipeline(`wasm-tools dump $tmpf`, stdout=dump_buf))
    dump_content = String(take!(dump_buf))
    dump_lines = split(dump_content, '\n')

    # Find lines around 0xe8c
    target_offset = 0xe8c
    println("Looking for offset 0x$(string(target_offset, base=16))...")

    # Filter lines containing nearby offsets
    for (i, l) in enumerate(dump_lines)
        # Look for offsets in range 0xe7x to 0xe9x
        if contains(l, "0xe7") || contains(l, "0xe8") || contains(l, "0xe9")
            println("Line $i: $l")
        end
    end
catch e
    println("dump failed: $e")
    # Try WAT print instead
    println("\nTrying wasm-tools print...")
    wat_buf = IOBuffer()
    Base.run(pipeline(`wasm-tools print $tmpf`, stdout=wat_buf))
    wat = String(take!(wat_buf))
    wat_lines = split(wat, '\n')
    println("WAT lines $(length(wat_lines)), showing 200-350:")
    for (i, l) in enumerate(wat_lines[200:min(350, end)])
        println("$(i+199): $l")
    end
end
