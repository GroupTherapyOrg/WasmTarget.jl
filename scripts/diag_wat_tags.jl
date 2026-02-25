#!/usr/bin/env julia
using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    fn = eval(Meta.parse("WasmTarget.register_tuple_type!"))
    bytes = WasmTarget.compile_multi([(fn, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type{Tuple{Int64}}))])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    watbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools print $tmpf`, stdout=watbuf))
    wat = String(take!(watbuf))
    lines = split(wat, "\n")

    # Print tag definitions
    println("=== TAG DEFINITIONS ===")
    for (i, line) in enumerate(lines)
        if contains(line, "(tag") || contains(line, "(type (;72;)") || contains(line, "(type (;61;)")
            println("$i: ", line)
        end
    end

    # Print first 100 lines of the WAT (types and imports section)
    println("\n=== FIRST 100 LINES ===")
    for i in 1:min(100, length(lines))
        println("$i: ", lines[i])
    end

    # Also check: what is immediately before the struct.new 72 line
    println("\n=== CONTEXT AROUND struct.new 72 ===")
    for (i, line) in enumerate(lines)
        if contains(line, "struct.new 72")
            s = max(1, i-15)
            e = min(length(lines), i+5)
            for j in s:e
                marker = j == i ? " <<<" : ""
                println("$j: ", lines[j], marker)
            end
        end
    end

    rm(tmpf; force=true)
end
main()
