using WasmTarget, JuliaSyntax

# Step 1: What does parse_stmts output look like in native Julia?
function native_debug()
    stream = JuliaSyntax.ParseStream("1")
    ps = JuliaSyntax.ParseState(stream)

    println("Before parse_stmts:")
    println("  whitespace_newline: ", ps.whitespace_newline)
    println("  output.length: ", length(stream.output))
    println("  next_byte: ", stream.next_byte)

    JuliaSyntax.parse_stmts(ps)

    println("\nAfter parse_stmts:")
    println("  output.length: ", length(stream.output))
    println("  next_byte: ", stream.next_byte)
    println("  diagnostics: ", length(stream.diagnostics))
    for (i, node) in enumerate(stream.output)
        println("  output[$i]: kind=", Int(reinterpret(UInt16, node.head.kind)), " span=", node.span)
    end
end

native_debug()
