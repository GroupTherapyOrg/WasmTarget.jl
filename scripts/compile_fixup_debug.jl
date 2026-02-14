# Compile test functions to isolate fixup_Expr_child
using WasmTarget
using JuliaSyntax

# Test 1: Does build_tree itself return null for compound?
function debug_build_tree_null(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    source = SourceFile(s)
    result = JuliaSyntax.build_tree(Expr, stream, source)
    if result === nothing
        return Int32(0)
    else
        return Int32(1)
    end
end

# Test 2: Does fixup_Expr_child drop compound Expr results?
function debug_fixup_null(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    source = SourceFile(s)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    txtbuf = Vector{UInt8}(undef, 128)

    # Call node_to_expr
    expr = JuliaSyntax.node_to_expr(cursor, source, txtbuf, UInt32(0))
    if expr === nothing
        return Int32(-1)  # node_to_expr returned nothing
    end

    # Call fixup_Expr_child
    wrapper_head = JuliaSyntax.SyntaxHead(JuliaSyntax.Kind(UInt16(0x0010)), UInt16(0))  # K"wrapper"
    result = JuliaSyntax.fixup_Expr_child(wrapper_head, expr, false)
    if result === nothing
        return Int32(0)  # fixup returned nothing
    else
        return Int32(1)  # fixup returned non-null
    end
end

for (name, f) in [("debug_build_tree_null", debug_build_tree_null),
                    ("debug_fixup_null", debug_fixup_null)]
    println("Compiling $name...")
    try
        bytes = compile(f, (String,))
        fname = "/Users/daleblack/Documents/dev/GroupTherapyOrg/WasmTarget.jl/browser/$name.wasm"
        write(fname, bytes)
        println("  Wrote $(length(bytes)) bytes")
        run(`wasm-tools validate $fname`)
        println("  VALIDATES")
    catch e
        println("  ERROR: ", sprint(showerror, e)[1:min(end,200)])
    end
end
