using WasmTarget, Core.Compiler

println("=== type_annotate! compilation with debug ===")
bytes = compile(Core.Compiler.type_annotate!, (Core.Compiler.AbstractInterpreter, Core.Compiler.InferenceState))
tmpf = "/tmp/type_annotate_3113.wasm"
write(tmpf, bytes)
println("Compiled: $(length(bytes)) bytes to $tmpf")

# Validate
println("\n--- Validation ---")
run(ignorestatus(pipeline(`sh -c "wasm-tools validate --features=gc $tmpf 2>&1"`)))
