using WasmTarget, Core.Compiler

println("=== type_annotate! compilation ===")
bytes = compile(Core.Compiler.type_annotate!, (Core.Compiler.AbstractInterpreter, Core.Compiler.InferenceState))
tmpf = "/tmp/type_annotate_3113_v2.wasm"
write(tmpf, bytes)
println("Compiled: $(length(bytes)) bytes to $tmpf")

# Validate with verbose output
println("\n--- Validation ---")
run(ignorestatus(pipeline(`sh -c "wasm-tools validate --features=gc $tmpf 2>&1"`)))
