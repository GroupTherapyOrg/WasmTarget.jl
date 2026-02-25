#!/usr/bin/env julia
using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    # Test get_concrete_wasm_type — simpler function  
    fn = eval(Meta.parse("WasmTarget.get_concrete_wasm_type"))
    bytes = WasmTarget.compile_multi([(fn, (Type, WasmTarget.WasmModule, WasmTarget.TypeRegistry))])
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
        
        watbuf = IOBuffer()
        Base.run(pipeline(`wasm-tools print $tmpf`, stdout=watbuf))
        wat = String(take!(watbuf))
        lines = split(wat, "\n")
        
        fm = match(r"func (\d+) failed", err)
        if fm !== nothing
            func_num = parse(Int, fm[1])
            import_count = count(l -> contains(l, "(import"), lines)
            println("Failing func: $func_num, import count: $import_count")
            
            # Get error offset
            om = match(r"at offset (0x[0-9a-f]+)", err)
            if om !== nothing
                println("Error offset: $(om[1])")
            end
            
            # Find the specific error location — print 15 lines before each extern.convert_any or ref_cast near the error
            # Actually, search for "found externref" context
            func_count = -1
            in_func = false
            func_lines_arr = String[]
            for (i, line) in enumerate(lines)
                if startswith(strip(line), "(func ")
                    func_count += 1
                    if func_count == func_num - import_count
                        in_func = true
                    elseif in_func
                        break
                    end
                end
                if in_func
                    push!(func_lines_arr, "$i: $line")
                end
            end
            
            # Print first 50 lines of the function
            println("\n=== FIRST 50 LINES OF FUNC ===")
            for i in 1:min(50, length(func_lines_arr))
                println(func_lines_arr[i])
            end
        end
    else
        println("VALIDATES!")
    end
    rm(tmpf; force=true)
end
main()
