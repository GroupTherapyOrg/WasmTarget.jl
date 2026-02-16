using WasmTarget, Core.Compiler

# Compile record_slot_assign! and save .wasm
println("=== Compiling record_slot_assign! ===")
bytes_rsa = compile(Core.Compiler.record_slot_assign!, (Core.Compiler.InferenceState,))
write("/tmp/record_slot_assign.wasm", bytes_rsa)
println("Written: $(length(bytes_rsa)) bytes")

# Compile abstract_eval_phi and save .wasm
println("\n=== Compiling abstract_eval_phi ===")
bytes_aep = compile(Core.Compiler.abstract_eval_phi, (Core.Compiler.NativeInterpreter, Core.PhiNode, Core.Compiler.StatementState, Core.Compiler.InferenceState))
write("/tmp/abstract_eval_phi.wasm", bytes_aep)
println("Written: $(length(bytes_aep)) bytes")
