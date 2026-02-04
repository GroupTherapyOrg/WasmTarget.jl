using WasmTarget

function count_funcs(wasm_file)
    out = read(pipeline(`wasm-tools print $wasm_file`, `grep -c "(func"`), String)
    return Base.parse(Int, strip(out))
end

# M1b: parsestmt
println("=== M1b: parsestmt ===")
using JuliaSyntax
parse_expr_string(s::String) = parsestmt(Expr, s)
bytes_m1b = compile(parse_expr_string, (String,))
write("/tmp/parsestmt_check.wasm", bytes_m1b)
run(`wasm-tools validate --features=gc /tmp/parsestmt_check.wasm`)
nfuncs_m1b = count_funcs("/tmp/parsestmt_check.wasm")
println("M1b VALIDATES: $(nfuncs_m1b) funcs, $(length(bytes_m1b)) bytes")

# M2: lowering
println("\n=== M2: lowering ===")
using JuliaLowering
bytes_m2 = compile(JuliaLowering._to_lowered_expr, (JuliaLowering.JuliaSyntax.SyntaxTree{JuliaLowering.JuliaSyntax.SyntaxGraph}, Int64))
write("/tmp/lowering_check.wasm", bytes_m2)
run(`wasm-tools validate --features=gc /tmp/lowering_check.wasm`)
nfuncs_m2 = count_funcs("/tmp/lowering_check.wasm")
println("M2 VALIDATES: $(nfuncs_m2) funcs, $(length(bytes_m2)) bytes")

# M3: typeinf
println("\n=== M3: typeinf ===")
using Core.Compiler
bytes_m3 = compile(Compiler.typeinf, (Compiler.NativeInterpreter, Compiler.InferenceState))
write("/tmp/typeinf_check.wasm", bytes_m3)
run(`wasm-tools validate --features=gc /tmp/typeinf_check.wasm`)
nfuncs_m3 = count_funcs("/tmp/typeinf_check.wasm")
println("M3 VALIDATES: $(nfuncs_m3) funcs, $(length(bytes_m3)) bytes")

# M4: self-hosting
println("\n=== M4: self-hosting ===")
bytes_m4 = compile(WasmTarget.compile, (Function, Type{Tuple{Int64}}))
write("/tmp/codegen_check.wasm", bytes_m4)
run(`wasm-tools validate --features=gc /tmp/codegen_check.wasm`)
nfuncs_m4 = count_funcs("/tmp/codegen_check.wasm")
println("M4 VALIDATES: $(nfuncs_m4) funcs, $(length(bytes_m4)) bytes")

println("\n=== ALL MILESTONES PASS ===")
