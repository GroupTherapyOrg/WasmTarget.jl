using WasmTarget

function test_push3(x::Int32)::Int32
    v = Int[1]
    push!(v, Int(x) + 1)
    return Int32(length(v))
end

ci = first(code_typed(test_push3, (Int32,)))
n = length(ci.first.code)
println("Total stmts: $n")
for (i, s) in enumerate(ci.first.code)
    t = ci.first.ssavaluetypes[i]
    ss = string(s)
    if length(ss) > 120; ss = ss[1:120] * "..."; end
    println("SSA $i: $ss :: $t")
end

# Also compile
bytes = compile(test_push3, (Int32,))
println("\nCompiled: $(length(bytes)) bytes")
f = tempname() * ".wasm"
write(f, bytes)
run(`wasm-tools validate --features=gc $f`)
println("VALIDATES")

write("WasmTarget.jl/browser/test_push3.wasm", bytes)
