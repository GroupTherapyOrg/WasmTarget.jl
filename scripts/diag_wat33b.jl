#!/usr/bin/env julia
# diag_wat33b.jl — Use wasm-tools dump to find instructions at error offsets
using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

# Compile get_concrete_wasm_type
wasm_bytes = WasmTarget.compile_multi([(WasmTarget.get_concrete_wasm_type, (Type, WasmTarget.WasmModule, WasmTarget.TypeRegistry))])
tmpf = tempname() * ".wasm"
write(tmpf, wasm_bytes)
println("Compiled $(length(wasm_bytes)) bytes to $tmpf")
flush(stdout)

# Use wasm-tools dump (hex/disassembly) to find offset 0xead8
println("\n=== wasm-tools dump around offset 0xead8 ===")
flush(stdout)
dump_output = read(`wasm-tools dump $tmpf`, String)
dump_lines = split(dump_output, '\n')

target = 0xead8
for (i, line) in enumerate(dump_lines)
    m = match(r"^0x([0-9a-fA-F]+)", strip(line))
    if m !== nothing
        offset = parse(UInt64, m[1]; base=16)
        if abs(Int(offset) - Int(target)) < 30
            start_i = max(1, i - 5)
            end_i = min(length(dump_lines), i + 5)
            for j in start_i:end_i
                marker = abs(Int(offset) - Int(target)) < 5 && j == i ? ">>>" : "   "
                println("$marker $(dump_lines[j])")
            end
            println()
            break
        end
    end
end

# Also: compile fix_broken_select_instructions (i64 vs ref $type, offset 0xa3e)
println("=== Compiling fix_broken_select_instructions ===")
flush(stdout)
wasm_bytes2 = WasmTarget.compile_multi([(WasmTarget.fix_broken_select_instructions, (Vector{UInt8},))])
tmpf2 = tempname() * ".wasm"
write(tmpf2, wasm_bytes2)
println("Compiled $(length(wasm_bytes2)) bytes")

println("\n=== wasm-tools dump around offset 0xa3e (fix_broken_select) ===")
flush(stdout)
dump_output2 = read(`wasm-tools dump $tmpf2`, String)
dump_lines2 = split(dump_output2, '\n')

target2 = 0xa3e
for (i, line) in enumerate(dump_lines2)
    m = match(r"^0x([0-9a-fA-F]+)", strip(line))
    if m !== nothing
        offset = parse(UInt64, m[1]; base=16)
        if abs(Int(offset) - Int(target2)) < 30
            start_i = max(1, i - 5)
            end_i = min(length(dump_lines2), i + 5)
            for j in start_i:end_i
                marker = j == i ? ">>>" : "   "
                println("$marker $(dump_lines2[j])")
            end
            println()
            break
        end
    end
end

# And analyze_blocks (stack underflow, offset 0x1811)
println("=== Compiling analyze_blocks ===")
flush(stdout)
wasm_bytes3 = WasmTarget.compile_multi([(WasmTarget.analyze_blocks, (Vector{Any},))])
tmpf3 = tempname() * ".wasm"
write(tmpf3, wasm_bytes3)
println("Compiled $(length(wasm_bytes3)) bytes")

println("\n=== wasm-tools dump around offset 0x1811 (analyze_blocks) ===")
flush(stdout)
dump_output3 = read(`wasm-tools dump $tmpf3`, String)
dump_lines3 = split(dump_output3, '\n')

target3 = 0x1811
for (i, line) in enumerate(dump_lines3)
    m = match(r"^0x([0-9a-fA-F]+)", strip(line))
    if m !== nothing
        offset = parse(UInt64, m[1]; base=16)
        if abs(Int(offset) - Int(target3)) < 30
            start_i = max(1, i - 5)
            end_i = min(length(dump_lines3), i + 5)
            for j in start_i:end_i
                marker = j == i ? ">>>" : "   "
                println("$marker $(dump_lines3[j])")
            end
            println()
            break
        end
    end
end

rm(tmpf; force=true)
rm(tmpf2; force=true)
rm(tmpf3; force=true)
println("Done.")
