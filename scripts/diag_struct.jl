#!/usr/bin/env julia
# Diagnose register_struct_type! validation error
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    println("=== Diagnosing register_struct_type! ===")
    bytes = WasmTarget.compile_multi([(WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType))])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    println("Compiled: $(length(bytes)) bytes")

    # Use wasm-tools dump for binary-level offset view
    dumpbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools dump $tmpf`, stdout=dumpbuf))
    dump_text = String(take!(dumpbuf))
    dump_lines = split(dump_text, "\n")

    # Search for offset 0x3f2f
    target = "0x3f2f"
    for (i, line) in enumerate(dump_lines)
        if contains(line, target)
            lo = max(1, i - 10)
            hi = min(length(dump_lines), i + 10)
            for j in lo:hi
                marker = j == i ? " >>> " : "     "
                println("$marker $j: $(dump_lines[j])")
            end
            break
        end
    end

    # Also get WAT and search near the offset
    println("\n--- WAT search ---")
    outbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools print $tmpf`, stdout=outbuf))
    wat = String(take!(outbuf))
    lines = split(wat, "\n")

    for (i, line) in enumerate(lines)
        if contains(line, "3f2f")
            lo = max(1, i - 20)
            hi = min(length(lines), i + 5)
            for j in lo:hi
                marker = j == i ? " >>> " : "     "
                println("$marker $j: $(lines[j])")
            end
            break
        end
    end

    # If no exact offset match, look for the pattern: externref used where ref expected
    # Find struct.new or struct.set with externref operand
    println("\n--- Looking for externref → ref mismatch patterns in func 1 ---")
    in_func1 = false
    func1_count = 0
    for (i, line) in enumerate(lines)
        if contains(line, "(func \$func_1")
            in_func1 = true
            continue
        end
        if in_func1
            func1_count += 1
            # Look for extern.internalize/convert_any followed by struct usage
            if contains(line, "extern") || contains(line, "struct.new") || contains(line, "struct.set") || contains(line, "ref.cast")
                println("$i: $line")
            end
            if func1_count > 5000
                break
            end
            # Detect end of function
            if startswith(lstrip(line), "(func ")
                break
            end
        end
    end

    rm(tmpf; force=true)
end

main()
