# More targeted probe - return build_tree result directly as externref
using WasmTarget
using JuliaSyntax

function probe_bt_direct(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    source = SourceFile(s)
    return JuliaSyntax.build_tree(Expr, stream, source)
end

# Also check: does SourceFile(stream) vs SourceFile(s) matter?
function probe_bt_stream_source(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    source = SourceFile(stream)  # Like _parse does
    return JuliaSyntax.build_tree(Expr, stream, source)
end

# Even simpler: just call parsestmt directly
function probe_parsestmt(s::String)
    return parsestmt(Expr, s)
end

println("Compiling probes...")
bytes = compile_multi([
    (probe_bt_direct, (String,)),
    (probe_bt_stream_source, (String,)),
    (probe_parsestmt, (String,)),
])
fname = "/Users/daleblack/Documents/dev/GroupTherapyOrg/WasmTarget.jl/browser/parsestmt_probe2.wasm"
write(fname, bytes)
println("Wrote $(length(bytes)) bytes")
run(`wasm-tools validate $fname`)
println("VALIDATES")
