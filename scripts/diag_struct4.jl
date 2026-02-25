#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    bytes = WasmTarget.compile_multi([(WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType))])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    # Use wasm-tools dump to get binary view near the offset
    dumpbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools dump $tmpf`, stdout=dumpbuf))
    dump_str = String(take!(dumpbuf))
    dump_lines = split(dump_str, "\n")

    # Search for 0x3ef in the dump (might be 0x3ef9)
    for (i, line) in enumerate(dump_lines)
        if contains(line, "0x3ef") || contains(line, "0x3f0")
            lo = max(1, i - 10)
            hi = min(length(dump_lines), i + 5)
            for j in lo:hi
                marker = j == i ? " >>> " : "     "
                println("$marker $j: $(dump_lines[j])")
            end
            println("---")
            break
        end
    end

    # Better approach: dump WAT, find struct.new in func 1 that uses externref
    outbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools print $tmpf`, stdout=outbuf))
    wat = String(take!(outbuf))
    lines = split(wat, "\n")

    # func 1 is from line 240 to wherever the next func starts
    # Look for struct.new/struct.set patterns in func 1
    in_func1 = false
    println("\n=== struct.new/struct.set/ref.cast in func 1 (first 30) ===")
    cnt = 0
    for (i, line) in enumerate(lines)
        if i == 240
            in_func1 = true
        end
        if in_func1 && i > 240
            stripped = lstrip(line)
            if startswith(stripped, "(func ")
                break
            end
            if contains(line, "struct.new") || contains(line, "struct.set") || contains(line, "ref.cast")
                cnt += 1
                println("$i: $line")
                if cnt >= 30
                    break
                end
            end
        end
    end

    # Now look for the FIRST struct.new that has a preceding local.get for externref
    # The pattern is: local.get of externref-typed local → used as argument to struct.new expecting (ref null $type)
    println("\n=== Local types in func 1 ===")
    for (i, line) in enumerate(lines)
        if i >= 240 && contains(line, "(local ")
            println("$i: $line")
        end
        if i > 260 && !contains(line, "(local ")
            break
        end
    end

    rm(tmpf; force=true)
end
main()
