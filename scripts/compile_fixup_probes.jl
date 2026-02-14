# Probe fixup_Expr_child step by step
using WasmTarget
using JuliaSyntax

# Test if isa(x, Expr) works correctly for different types
function probe_isa_expr(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    source = SourceFile(s)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    txtbuf = JuliaSyntax.unsafe_textbuf(stream)
    expr = JuliaSyntax.node_to_expr(cursor, source, txtbuf)

    # Test isa
    if expr isa Expr
        return Int32(1)  # IS Expr
    else
        return Int32(0)  # NOT Expr
    end
end

# Test: does returning a function argument of type Any work?
function probe_return_arg(x)
    return x  # Just return the argument
end

# Test: return Any via identity
function probe_identity(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    source = SourceFile(s)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    txtbuf = JuliaSyntax.unsafe_textbuf(stream)
    expr = JuliaSyntax.node_to_expr(cursor, source, txtbuf)

    # Simple identity - just return what we got
    return expr
end

println("Compiling probes...")
for (name, f, types) in [
    ("probe_isa_expr", probe_isa_expr, (String,)),
    ("probe_identity", probe_identity, (String,)),
]
    try
        bytes = compile(f, types)
        fname = "/Users/daleblack/Documents/dev/GroupTherapyOrg/WasmTarget.jl/browser/$name.wasm"
        write(fname, bytes)
        run(`wasm-tools validate $fname`)
        println("  $name: $(length(bytes)) bytes, VALIDATES")
    catch e
        println("  $name: ERROR: $(sprint(showerror, e)[1:min(end,200)])")
    end
end
