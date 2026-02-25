#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    bytes = WasmTarget.compile_multi([(WasmTarget.get_numeric_box_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, WasmTarget.NumType))])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    
    outbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools print $tmpf`, stdout=outbuf))
    wat = String(take!(outbuf))
    lines = split(wat, "\n")
    
    # func 1 runs from line 93 to line 881 (func 2 starts at 882)
    # Print all lines with externref, any.convert, or struct.new
    println("--- func 1: all externref/any.convert/array.set/call lines ---")
    for i in 93:881
        stripped = strip(lines[i])
        if contains(stripped, "extern") || contains(stripped, "any.convert") || 
           contains(stripped, "array.set 14") || contains(stripped, "array.get 14") ||
           contains(stripped, "call ") || contains(stripped, "struct.new 25") ||
           contains(stripped, "local.set 155") || contains(stripped, "local.get 155")
            println("L$i: $stripped")
        end
    end
    
    # Check locals: where is the externref local?
    # The last local is externref. Count all locals...
    println("\n--- local count analysis ---")
    # Parse locals from the WAT
    local_line = lines[94]
    # Count occurrence of each type
    println("externref appears: $(count("externref", local_line)) times in locals")
    
    rm(tmpf; force=true)
end
main()
