#!/usr/bin/env julia
# Diagnose "expected (ref null $type), found externref" in detail
using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

# Pick register_union_type! — relatively small function
func = WasmTarget.register_union_type!
arg_types = (WasmTarget.WasmModule, WasmTarget.TypeRegistry, Union)

bytes = WasmTarget.compile_multi([(func, arg_types)])
tmpf = tempname() * ".wasm"
write(tmpf, bytes)

# Get validation error
errbuf = IOBuffer()
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errbuf, stdout=devnull))
catch; end
err = strip(String(take!(errbuf)))
println("ERROR: $err")
println()

# Extract func number and offset
fm = match(r"func (\d+) failed", err)
om = match(r"at offset (0x[0-9a-f]+)", err)
println("Func: ", fm !== nothing ? fm[1] : "?")
println("Offset: ", om !== nothing ? om[1] : "?")
println()

# Dump WAT
watbuf = IOBuffer()
Base.run(pipeline(`wasm-tools print $tmpf`, stdout=watbuf))
wat = String(take!(watbuf))
lines = split(wat, '\n')

# Find all externref locals and ref null locals in the failing function
if fm !== nothing
    func_num = parse(Int, fm[1])
    import_count = count(l -> contains(l, "(import"), lines)

    func_count = -1
    in_func = false
    func_lines = String[]
    func_start = 0

    for (i, line) in enumerate(lines)
        if startswith(strip(line), "(func ")
            func_count += 1
            if func_count == func_num - import_count
                in_func = true
                func_start = i
            elseif in_func
                break
            end
        end
        if in_func
            push!(func_lines, line)
        end
    end

    println("Function starts at WAT line $func_start, $(length(func_lines)) lines total")

    # Find any.convert_extern and extern.convert_any usage
    println("\n=== extern.convert_any occurrences ===")
    for (i, line) in enumerate(func_lines)
        if contains(line, "extern.convert_any")
            println("  L$(func_start + i - 1): ", strip(line))
        end
    end

    println("\n=== any.convert_extern occurrences ===")
    for (i, line) in enumerate(func_lines)
        if contains(line, "any.convert_extern")
            println("  L$(func_start + i - 1): ", strip(line))
        end
    end

    # Find struct.get where externref might be produced
    println("\n=== struct.get near error area ===")
    # Print 80 lines around the error offset area
    # Find ref.cast and struct.get patterns
    for (i, line) in enumerate(func_lines)
        sl = strip(line)
        if contains(sl, "struct.get") || contains(sl, "struct.set") || contains(sl, "ref.cast") || contains(sl, "ref.null")
            if i > max(1, length(func_lines) ÷ 4) && i < 3 * length(func_lines) ÷ 4
                println("  L$(func_start + i - 1): $sl")
            end
        end
    end

    # Find the specific error context - search for patterns that would produce externref
    # where (ref null $type) is expected
    println("\n=== Searching for externref->ref mismatch patterns ===")
    for (i, line) in enumerate(func_lines)
        sl = strip(line)
        # struct.get on an externref field followed by ref.cast or struct operations
        if contains(sl, "extern.convert_any") && i+3 <= length(func_lines)
            println("  --- at L$(func_start + i - 1) ---")
            for j in max(1,i-3):min(length(func_lines), i+5)
                println("    L$(func_start + j - 1): ", strip(func_lines[j]))
            end
        end
    end

    # Print first 100 lines of the function (locals/params section)
    println("\n=== Function header (first 50 lines) ===")
    for i in 1:min(50, length(func_lines))
        println(func_lines[i])
    end
end

rm(tmpf; force=true)
