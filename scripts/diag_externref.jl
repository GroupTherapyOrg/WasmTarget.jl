#!/usr/bin/env julia
# Diagnose "expected externref, found (ref $type)" errors in detail
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

# Pick ONE simple failing function to diagnose in detail
println("=== Diagnosing is_self_referential_type ===")
func = WasmTarget.is_self_referential_type
arg_types = (DataType,)

# Compile
bytes = WasmTarget.compile_multi([(func, arg_types)])
tmpf = tempname() * ".wasm"
write(tmpf, bytes)
println("Compiled: $(length(bytes)) bytes")

# Validate with full error
errbuf = IOBuffer()
ok = false
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
    ok = true
catch; end

if !ok
    err = strip(String(take!(errbuf)))
    println("VALIDATION ERROR:")
    println(err)
    println()

    # Extract offset
    m = match(r"at offset (0x[0-9a-f]+)", err)
    if m !== nothing
        offset = m[1]
        println("Error at offset: $offset")

        # Dump WAT around the error
        println("\n=== WAT dump (searching near offset) ===")
        watbuf = IOBuffer()
        try
            Base.run(pipeline(`wasm-tools print $tmpf`, stdout=watbuf))
            wat = String(take!(watbuf))

            # Find the error func number
            fm = match(r"func (\d+) failed", err)
            if fm !== nothing
                func_num = fm[1]
                println("Failing func: $func_num")

                # Find the func in WAT and print it
                lines = split(wat, '\n')
                in_func = false
                func_count = -1  # -1 because imports also count
                # Count imports first
                import_count = count(l -> contains(l, "(import"), lines)
                target_func = parse(Int, func_num)

                # Actually just search for the func definition
                printing = false
                line_count = 0
                for (i, line) in enumerate(lines)
                    if startswith(strip(line), "(func ")
                        func_count += 1
                        if func_count == target_func - import_count
                            printing = true
                        elseif printing
                            break
                        end
                    end
                    if printing
                        println(line)
                        line_count += 1
                        if line_count > 200
                            println("  ... (truncated)")
                            break
                        end
                    end
                end
            end
        catch e
            println("WAT dump failed: $e")
        end
    end
else
    println("VALIDATES! (unexpected)")
end
rm(tmpf; force=true)
