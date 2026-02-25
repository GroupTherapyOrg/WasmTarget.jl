#!/usr/bin/env julia
# diag_wat33.jl — Dump WAT around error offsets for failing functions
using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

# Pick get_concrete_wasm_type as representative (func 21, offset 0xead8)
println("=== Compiling get_concrete_wasm_type ===")
flush(stdout)
wasm_bytes = WasmTarget.compile_multi([(WasmTarget.get_concrete_wasm_type, (Type, WasmTarget.WasmModule, WasmTarget.TypeRegistry))])
tmpf = tempname() * ".wasm"
write(tmpf, wasm_bytes)
println("Written to $tmpf ($(length(wasm_bytes)) bytes)")

# Dump the WAT and find the error location
println("\n=== Dumping WAT around offset 0xead8 (func 21) ===")
flush(stdout)
wat = read(`wasm-tools print $tmpf`, String)
lines = split(wat, '\n')

# Find lines mentioning func 21 or near offset ead8
# Also search for (@offset patterns near the error)
target_offset = 0xead8
for (i, line) in enumerate(lines)
    # wasm-tools print shows offsets like (@ead8)
    m = match(r"\(@([0-9a-f]+)\)", line)
    if m !== nothing
        offset = parse(UInt64, m[1]; base=16)
        if abs(Int(offset) - Int(target_offset)) < 100
            start_line = max(1, i - 5)
            end_line = min(length(lines), i + 5)
            for j in start_line:end_line
                marker = j == i ? ">>>" : "   "
                println("$marker L$j: $(lines[j])")
            end
            println("---")
            break
        end
    end
end

# Also dump just func 21
println("\n=== func 21 signature ===")
flush(stdout)
func_count = 0
in_func21 = false
func21_lines = String[]
for (i, line) in enumerate(lines)
    if contains(line, "(func ")
        func_count += 1
        if func_count == 22  # 0-indexed, so func 21 is the 22nd
            in_func21 = true
        elseif in_func21
            break
        end
    end
    if in_func21
        push!(func21_lines, line)
    end
end
# Print first 10 lines and last 30 lines around error area
if length(func21_lines) > 0
    println("  Func 21: $(length(func21_lines)) lines")
    for line in func21_lines[1:min(5, end)]
        println("  $line")
    end
    # Find lines with offset near target
    println("  ...")
    for (i, line) in enumerate(func21_lines)
        m = match(r"\(@([0-9a-f]+)\)", line)
        if m !== nothing
            offset = parse(UInt64, m[1]; base=16)
            if abs(Int(offset) - Int(target_offset)) < 50
                start_i = max(1, i - 10)
                end_i = min(length(func21_lines), i + 5)
                for j in start_i:end_i
                    marker = j == i ? ">>>" : "   "
                    println("$marker  $(func21_lines[j])")
                end
                break
            end
        end
    end
end

rm(tmpf; force=true)
println("\nDone.")
