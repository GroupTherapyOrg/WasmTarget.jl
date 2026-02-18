using WasmTarget, Core.Compiler

println("=== PURE-3113: Testing 4 functions ===")

# 1. record_ssa_assign!
println("\n1. record_ssa_assign!...")
bytes1 = compile(Core.Compiler.record_ssa_assign!, (Core.Compiler.AbstractLattice, Int64, Any, Core.Compiler.InferenceState))
f1 = tempname() * ".wasm"
write(f1, bytes1)
println("  $(length(bytes1)) bytes")
try; run(`wasm-tools validate --features=gc $f1`); println("  VALIDATES"); catch; println("  FAILS"); end

# 2. stupdate!
println("\n2. stupdate!...")
bytes2 = compile(Core.Compiler.stupdate!, (Core.Compiler.AbstractLattice, Vector{Core.Compiler.VarState}, Vector{Core.Compiler.VarState}))
f2 = tempname() * ".wasm"
write(f2, bytes2)
println("  $(length(bytes2)) bytes")
try; run(`wasm-tools validate --features=gc $f2`); println("  VALIDATES"); catch; println("  FAILS"); end

# 3. tuple_tail_elem
println("\n3. tuple_tail_elem...")
bytes3 = compile(Core.Compiler.tuple_tail_elem, (Core.Compiler.AbstractLattice, Any, Vector{Any}))
f3 = tempname() * ".wasm"
write(f3, bytes3)
println("  $(length(bytes3)) bytes")
try; run(`wasm-tools validate --features=gc $f3`); println("  VALIDATES"); catch; println("  FAILS"); end

# 4. type_annotate!
println("\n4. type_annotate!...")
bytes4 = compile(Core.Compiler.type_annotate!, (Core.Compiler.AbstractInterpreter, Core.Compiler.InferenceState))
f4 = tempname() * ".wasm"
write(f4, bytes4)
println("  $(length(bytes4)) bytes")
try; run(`wasm-tools validate --features=gc $f4`); println("  VALIDATES"); catch; println("  FAILS"); end

println("\n=== Done ===")
