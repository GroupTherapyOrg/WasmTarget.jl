#!/usr/bin/env julia
using Pkg; Pkg.activate(joinpath(@__DIR__, ".."))
using WasmTarget

# Compile register_struct_type! and check the error offset
wasm_bytes = WasmTarget.compile_multi([(WasmTarget.register_struct_type!, (WasmTarget.WasmModule, WasmTarget.TypeRegistry, DataType))])
tmpf = "/tmp/regstruct_v2.wasm"
write(tmpf, wasm_bytes)

# Validate
errf = tempname() * ".err"
try
    Base.run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=errf, stdout=devnull))
    println("VALIDATES!")
catch
    err = read(errf, String)
    println("STILL FAILS: $(strip(err))")
end

# Check if i32_const 111 pattern is still there
dump_output = read(`wasm-tools dump $tmpf`, String)
# Search for "i32_const value:111"
for (i, line) in enumerate(split(dump_output, '\n'))
    if contains(line, "i32_const value:111")
        # Show surrounding lines
        dump_lines = split(dump_output, '\n')
        start_i = max(1, i - 2)
        end_i = min(length(dump_lines), i + 2)
        for j in start_i:end_i
            marker = j == i ? ">>>" : "   "
            println("$marker $(dump_lines[j])")
        end
        println("---")
    end
end

rm(errf; force=true)
println("\nDone.")
