#!/usr/bin/env julia
using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

# Monkey-patch: wrap compile_multi to intercept and find the struct.new 72 source
# Instead, let's look at what type corresponds to struct{(mut externref)}

function main()
    fn = WasmTarget.register_tuple_type!
    arg_types = (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type{Tuple{Int64}})
    
    # Manually set up compilation context to observe type registration
    mod = WasmTarget.WasmModule()
    reg = WasmTarget.TypeRegistry()
    
    # Compile
    bytes = WasmTarget.compile_multi([(fn, arg_types)])
    
    # Now check all types in the module
    println("=== ALL STRUCT TYPES WITH EXACTLY 1 EXTERNREF FIELD ===")
    for (i, t) in enumerate(mod.types)
        # mod.types from the new module won't help — compile_multi creates its own
    end
    
    # Actually, let's check the compiled module's types by parsing the WAT
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    watbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools print $tmpf`, stdout=watbuf))
    wat = String(take!(watbuf))
    
    # Find type 72 and check what creates it
    # Also check: all struct types that have exactly one field of externref
    println("=== TYPES WITH SINGLE EXTERNREF FIELD ===")
    for line in split(wat, "\n")
        m = match(r"\(type \(;(\d+);\) \(struct \(field \(mut externref\)\)\)\)", line)
        if m !== nothing
            println("Type $(m[1]): struct{(mut externref)}")
        end
    end
    
    # Check what SSA/statement produces struct.new with type 72 by examining the wasm hex
    # Let's look at what function is func 0 (after imports)
    lines = split(wat, "\n")
    import_count = count(l -> contains(l, "(import"), lines)
    println("\nImport count: $import_count")
    
    # The failing func is func 1. With 1 import, func 1 = first defined func.
    # Find it and print the FULL function:
    func_count = -1
    in_func = false
    func_lines = String[]
    for (i, line) in enumerate(lines)
        if startswith(strip(line), "(func ")
            func_count += 1
            if func_count == 0  # First defined function (func 1 with 1 import)
                in_func = true
            elseif in_func
                break
            end
        end
        if in_func
            push!(func_lines, line)
        end
    end
    
    # Print lines around struct.new 72 with more context
    for (i, line) in enumerate(func_lines)
        if contains(line, "struct.new 72")
            # Print 30 lines before
            s = max(1, i-30)
            for j in s:i+5
                if j <= length(func_lines)
                    marker = j == i ? " <<<" : ""
                    println("L$j: ", func_lines[j], marker)
                end
            end
            println()
        end
    end
    
    rm(tmpf; force=true)
end
main()
