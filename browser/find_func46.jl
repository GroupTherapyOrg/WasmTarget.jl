using WasmTarget, JuliaSyntax
parse_expr_string(s::String) = JuliaSyntax.parsestmt(Expr, s)
bytes = compile(parse_expr_string, (String,))
f = tempname() * ".wasm"
write(f, bytes)
println("Bytes: $(length(bytes))")

# Write to a WAT file for analysis
wat = read(`wasm-tools print $f`, String)
watf = replace(f, ".wasm" => ".wat")
write(watf, wat)
println("WAT written to: $watf")
println("WAT size: $(sizeof(wat)) bytes")

# Find func (;46;) in WAT
target = "(func (;46;)"
idx = findfirst(target, wat)
if !isnothing(idx)
    # Print 50 lines starting from there
    snippet = wat[first(idx):min(first(idx)+3000, length(wat))]
    lines = split(snippet, '\n')
    for (i, line) in enumerate(lines[1:min(50, end)])
        println("$i: $line")
    end
else
    println("func 46 not found!")
end
