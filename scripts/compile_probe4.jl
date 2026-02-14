# Probe with correct _parse flow (rule=:statement)
using WasmTarget
using JuliaSyntax

# Match the actual _parse flow
function probe_bt_correct(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.bump_trivia(stream; skip_newlines=true)
    JuliaSyntax.parse!(stream; rule=:statement)
    source = SourceFile(stream)
    return JuliaSyntax.build_tree(Expr, stream, source)
end

# Just parsestmt for comparison
function probe_ps(s::String)
    return parsestmt(Expr, s)
end

println("Compiling...")
bytes = compile_multi([
    (probe_bt_correct, (String,)),
    (probe_ps, (String,)),
])
fname = "/Users/daleblack/Documents/dev/GroupTherapyOrg/WasmTarget.jl/browser/parsestmt_probe4.wasm"
write(fname, bytes)
println("Wrote $(length(bytes)) bytes")
run(`wasm-tools validate $fname`)
println("VALIDATES")
