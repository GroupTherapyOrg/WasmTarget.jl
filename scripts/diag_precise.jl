#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function diag_func(name, func, arg_types)
    println("=== $name ===")
    bytes = WasmTarget.compile_multi([(func, arg_types)])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    errbuf = IOBuffer()
    try
        Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
        println("VALIDATES OK")
        rm(tmpf; force=true)
        return
    catch
    end

    err = strip(String(take!(errbuf)))
    println("ERROR: $err")
    println()

    # Get offset
    m = match(r"at offset (0x[0-9a-f]+)", err)
    if isnothing(m)
        rm(tmpf; force=true)
        return
    end
    offset_val = parse(Int, m[1][3:end]; base=16)
    println("Offset decimal: $offset_val")

    # Use wasm-tools dump --full to find the offset
    dumpbuf = IOBuffer()
    try
        Base.run(pipeline(`wasm-tools dump --full $tmpf`, stdout=dumpbuf))
        dump_str = String(take!(dumpbuf))
        dump_lines = split(dump_str, "\n")

        # Binary search for closest offset
        best_idx = 0
        for (i, line) in enumerate(dump_lines)
            m2 = match(r"^\s*(0x[0-9a-f]+)\s", line)
            if !isnothing(m2)
                line_offset = parse(Int, m2[1][3:end]; base=16)
                if line_offset <= offset_val
                    best_idx = i
                end
                if line_offset > offset_val
                    break
                end
            end
        end

        if best_idx > 0
            lo = max(1, best_idx - 15)
            hi = min(length(dump_lines), best_idx + 5)
            println("\n--- DUMP near offset ---")
            for j in lo:hi
                marker = j == best_idx ? " >>> " : "     "
                println("$marker$(dump_lines[j])")
            end
        end
    catch e
        println("dump failed: $e")
    end

    rm(tmpf; force=true)
end

# Test just two representative functions
diag_func("register_struct_type!", WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType))
println("\n" * "="^60 * "\n")
diag_func("fix_broken_select_instructions", WasmTarget.fix_broken_select_instructions, (Vector{UInt8},))
