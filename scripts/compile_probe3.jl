# Narrower probes to isolate the exact point where the return value becomes null
using WasmTarget
using JuliaSyntax

# Probe: call node_to_expr directly (already shown to work)
# Then call fixup_Expr_child and return the result
function probe_fixup_only(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    source = SourceFile(s)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    txtbuf = JuliaSyntax.unsafe_textbuf(stream)

    # This part works (returns non-null)
    expr = JuliaSyntax.node_to_expr(cursor, source, txtbuf)

    # Does this part work?
    wrapper_head = JuliaSyntax.SyntaxHead(JuliaSyntax.Kind(0x0010), UInt16(0))  # K"wrapper"
    result = JuliaSyntax.fixup_Expr_child(wrapper_head, expr, false)
    return result
end

# Probe: same as above but return 1 if fixup result is non-null
function probe_fixup_check(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    source = SourceFile(s)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    txtbuf = JuliaSyntax.unsafe_textbuf(stream)

    expr = JuliaSyntax.node_to_expr(cursor, source, txtbuf)
    wrapper_head = JuliaSyntax.SyntaxHead(JuliaSyntax.Kind(0x0010), UInt16(0))
    result = JuliaSyntax.fixup_Expr_child(wrapper_head, expr, false)
    if result === nothing
        return Int32(0)
    else
        return Int32(1)
    end
end

# Probe: skip fixup, just return node_to_expr result directly
function probe_n2e_direct(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    source = SourceFile(s)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    txtbuf = JuliaSyntax.unsafe_textbuf(stream)
    return JuliaSyntax.node_to_expr(cursor, source, txtbuf)
end

println("Compiling probes...")
bytes = compile_multi([
    (probe_fixup_only, (String,)),
    (probe_fixup_check, (String,)),
    (probe_n2e_direct, (String,)),
])
fname = "/Users/daleblack/Documents/dev/GroupTherapyOrg/WasmTarget.jl/browser/parsestmt_probe3.wasm"
write(fname, bytes)
println("Wrote $(length(bytes)) bytes")
run(`wasm-tools validate $fname`)
println("VALIDATES")
