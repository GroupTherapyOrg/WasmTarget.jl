using WasmTarget, Core.Compiler

# Compile record_slot_assign! and dump WAT around error
println("=== record_slot_assign! ===")
bytes = compile(Core.Compiler.record_slot_assign!, (Core.Compiler.InferenceState,))
f = tempname() * ".wasm"
write(f, bytes)
println("Written to: $f")
println("Size: $(length(bytes)) bytes")

# Dump WAT around offset 0xa26
run(pipeline(`wasm-tools validate --features=gc $f`, stderr=stdout))
