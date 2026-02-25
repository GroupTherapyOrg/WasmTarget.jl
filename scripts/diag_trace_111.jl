#!/usr/bin/env julia
# diag_trace_111.jl — Find exactly WHERE i32_const 111 → local_set to ref-typed local happens
using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

# Compile register_struct_type! (representative of all 7 failing functions)
println("=== Compiling register_struct_type! ===")
flush(stdout)
wasm_bytes = WasmTarget.compile_multi([(WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType))])
tmpf = "/tmp/regstruct_trace.wasm"
write(tmpf, wasm_bytes)
println("Written $(length(wasm_bytes)) bytes")

# Use wasm-tools dump to find ALL i32_const 111 → local_set patterns
println("\n=== Finding ALL i32_const 111 → local_set patterns ===")
flush(stdout)
dump_output = read(`wasm-tools dump $tmpf`, String)
dump_lines = split(dump_output, '\n')

matches = []
for (i, line) in enumerate(dump_lines)
    if contains(line, "i32_const value:111")
        # Check if next instruction is local_set
        if i + 1 <= length(dump_lines) && contains(dump_lines[i+1], "local_set")
            push!(matches, (i, line, dump_lines[i+1]))
        end
    end
end

println("Found $(length(matches)) instances of i32_const 111 → local_set:")
for (i, line, next_line) in matches
    println("  Line $i: $(strip(line))")
    println("          $(strip(next_line))")
    # Show surrounding context
    start_i = max(1, i - 5)
    end_i = min(length(dump_lines), i + 5)
    println("  Context:")
    for j in start_i:end_i
        marker = j == i ? ">>>" : "   "
        println("    $marker $(dump_lines[j])")
    end
    println("  ---")
end

# Also get the validate error to confirm the offset
errf = tempname() * ".err"
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errf, stdout=devnull))
    println("\nVALIDATES OK")
catch
    err = read(errf, String)
    println("\nValidation error: $(strip(err))")
end
rm(errf; force=true)

# Also check the WAT to see function boundaries around these offsets
println("\n=== WAT around error area ===")
flush(stdout)
wat = read(`wasm-tools print $tmpf`, String)
wat_lines = split(wat, '\n')

# For each match, find the byte offset and look in WAT
for (match_idx, (i, line, next_line)) in enumerate(matches)
    m = match(r"^\s*0x([0-9a-fA-F]+)", line)
    if m !== nothing
        offset = parse(Int, m[1]; base=16)
        println("\n--- Match $match_idx at offset 0x$(string(offset, base=16)) ---")
        # Search WAT for this offset
        for (wi, wline) in enumerate(wat_lines)
            om = match(r"\(@([0-9a-f]+)\)", wline)
            if om !== nothing
                wat_offset = parse(Int, om[1]; base=16)
                if abs(wat_offset - offset) < 30
                    ws = max(1, wi - 3)
                    we = min(length(wat_lines), wi + 3)
                    for wj in ws:we
                        wm = wj == wi ? ">>>" : "   "
                        println("  $wm L$wj: $(wat_lines[wj])")
                    end
                    break
                end
            end
        end
    end
end

rm(tmpf; force=true)
println("\nDone.")
