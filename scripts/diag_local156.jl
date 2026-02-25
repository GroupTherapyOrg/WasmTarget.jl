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
    
    # Parse the locals line (94) to find what type local 156 is
    # Params: 0=ref null 38, 1=ref null 55, 2=i32 (3 params)
    # Locals start at index 3
    # We need local 156, which is local[156-3] = local[153] (0-indexed from locals start)
    local_line = strip(lines[94])
    # Extract all type specs from "(local ...)"
    m = match(r"\(local (.+)\)", local_line)
    if m !== nothing
        types_str = m[1]
        # Parse types - each can be "i32", "i64", "(ref null N)", "externref", etc.
        types = String[]
        i = 1
        while i <= length(types_str)
            if types_str[i] == '('
                # Find matching paren
                j = i
                depth = 0
                while j <= length(types_str)
                    if types_str[j] == '('
                        depth += 1
                    elseif types_str[j] == ')'
                        depth -= 1
                        if depth == 0
                            push!(types, types_str[i:j])
                            i = j + 1
                            break
                        end
                    end
                    j += 1
                end
            elseif types_str[i] == ' '
                i += 1
            else
                # Simple type like i32, i64, etc.
                j = i
                while j <= length(types_str) && types_str[j] != ' '
                    j += 1
                end
                push!(types, types_str[i:j-1])
                i = j
            end
        end
        
        # local 156 = param count (3) + local index
        local_idx = 156 - 3
        if local_idx >= 1 && local_idx <= length(types)
            println("Local 156 (index $local_idx in locals): $(types[local_idx])")
        end
        println("Total locals: $(length(types))")
        # Print locals around index 153
        for idx in max(1, local_idx-3):min(length(types), local_idx+3)
            global_idx = idx + 3  # add param count
            println("  local $global_idx: $(types[idx])")
        end
    end
    
    rm(tmpf; force=true)
end
main()
