#!/usr/bin/env julia
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

function main()
    # Use register_vector_type! — simplest, error in func 3
    bytes = WasmTarget.compile_multi([(WasmTarget.register_vector_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Type))])
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)

    outbuf = IOBuffer()
    Base.run(pipeline(`wasm-tools print $tmpf`, stdout=outbuf))
    wat = String(take!(outbuf))
    lines = split(wat, "\n")

    # Find all func declarations with names
    for (i, line) in enumerate(lines)
        if startswith(lstrip(line), "(func ")
            println("$i: $line")
        end
    end

    # Find func 3, show first 20 lines + search for i64.const 1 + ref.cast
    func_starts = Int[]
    for (i, line) in enumerate(lines)
        if startswith(lstrip(line), "(func ")
            push!(func_starts, i)
        end
    end

    if length(func_starts) >= 3
        fstart = func_starts[3]
        fend = length(func_starts) > 3 ? func_starts[4]-1 : length(lines)
        println("\n--- func 3 header (first 20 lines) ---")
        for i in fstart:min(fstart+19, fend)
            println("  $i: $(lines[i])")
        end

        # Find i64.const 1 near ref.cast
        println("\n--- i64.const near ref.cast in func 3 ---")
        for i in fstart:fend
            if contains(lines[i], "i64.const 1") && i < fend
                # Check next few lines for ref.cast
                for j in i:min(i+3, fend)
                    if contains(lines[j], "ref.cast")
                        for k in max(fstart, i-3):min(fend, j+3)
                            marker = k == i || k == j ? " >>> " : "     "
                            println("$marker$k: $(lines[k])")
                        end
                        println()
                        break
                    end
                end
            end
        end
    end

    rm(tmpf; force=true)
end
main()
