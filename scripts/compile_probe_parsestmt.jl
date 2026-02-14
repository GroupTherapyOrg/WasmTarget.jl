# Compile parsestmt with additional probe functions
using WasmTarget
using JuliaSyntax

# The main entry point (same as parsestmt.wasm)
function parse_expr_string(s::String)
    return parsestmt(Expr, s)
end

# Probe 1: Check if _parse returns non-null tuple
function probe_parse_result(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    source = SourceFile(s)
    tree = JuliaSyntax.build_tree(Expr, stream, source)
    if tree === nothing
        return Int32(-1)  # build_tree returned nothing
    else
        return Int32(1)
    end
end

# Probe 2: Check _parse tuple directly
function probe_parse_tuple(s::String)
    # Call the underlying _parse kwarg desugared method
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)

    # Just check parse! output length
    return Int32(length(stream.output))
end

println("Compiling multi-function module with probes...")
bytes = compile_multi([
    (parse_expr_string, (String,)),
    (probe_parse_result, (String,)),
    (probe_parse_tuple, (String,)),
])
fname = "/Users/daleblack/Documents/dev/GroupTherapyOrg/WasmTarget.jl/browser/parsestmt_probe.wasm"
write(fname, bytes)
println("Wrote $(length(bytes)) bytes")
run(`wasm-tools validate $fname`)
println("VALIDATES")

# Count functions
f_count = read(`wasm-tools print $fname`, String) |> x -> count("(func ", x)
println("Functions: $f_count")
