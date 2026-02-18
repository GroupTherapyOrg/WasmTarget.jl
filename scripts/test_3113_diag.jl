using WasmTarget, Core.Compiler

println("=== PURE-3113: Diagnosing type_annotate! ===")

bytes = compile(Core.Compiler.type_annotate!, (Core.Compiler.AbstractInterpreter, Core.Compiler.InferenceState))
f = "/tmp/type_annotate.wasm"
write(f, bytes)
println("Wrote $(length(bytes)) bytes to $f")

# Validate and capture error
r = run(`wasm-tools validate --features=gc $f`, wait=false)
wait(r)
println("Exit code: $(r.exitcode)")

# Count functions
println("\nFunction count:")
run(`bash -c "wasm-tools print $f | grep -c '(func'"`)

# Print the failing function area
println("\nDumping around offset 0xef5d...")
run(`bash -c "wasm-tools dump $f 2>&1 | grep -B5 -A5 'ef5d'"`)
