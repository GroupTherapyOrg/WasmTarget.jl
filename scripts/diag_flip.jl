#!/usr/bin/env julia
using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    fn = eval(Meta.parse("WasmTarget.register_tuple_type!"))
    bytes = WasmTarget.compile_multi([(fn, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type{Tuple{Int64}}))])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    
    errbuf = IOBuffer()
    ok = false
    try
        Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
        ok = true
    catch; end
    
    if !ok
        err = strip(String(take!(errbuf)))
        println("ERROR: ", err)
        
        # Get WAT and find the error context
        watbuf = IOBuffer()
        Base.run(pipeline(`wasm-tools print $tmpf`, stdout=watbuf))
        wat = String(take!(watbuf))
        lines = split(wat, "\n")
        
        # Find func that failed
        fm = match(r"func (\d+) failed", err)
        if fm !== nothing
            func_num = parse(Int, fm[1])
            import_count = count(l -> contains(l, "(import"), lines)
            
            # Find and print the full error context
            println("\nFailing func: $func_num")
            
            # Find ALL extern.convert_any in the function
            func_count = -1
            in_func = false
            println("\n=== extern.convert_any IN FUNC $func_num ===")
            for (i, line) in enumerate(lines)
                if startswith(strip(line), "(func ")
                    func_count += 1
                    if func_count == func_num - import_count
                        in_func = true
                    elseif in_func
                        break
                    end
                end
                if in_func && contains(line, "extern.convert_any")
                    s = max(1, i-3)
                    e = min(length(lines), i+3)
                    for j in s:e
                        marker = j == i ? " <<<" : ""
                        println("$j: ", lines[j], marker)
                    end
                    println()
                end
            end
        end
    else
        println("VALIDATES!")
    end
    rm(tmpf; force=true)
end
main()
