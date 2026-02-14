using JuliaSyntax

# Show the parse tree structure for "1+1"
stream = JuliaSyntax.ParseStream("1+1")
JuliaSyntax.parse!(stream)

println("=== Output nodes ===")
output = stream.output
for (i, node) in enumerate(output)
    head = node.head
    flags = head.flags
    kind = head.kind
    is_trivia = (flags & JuliaSyntax.TRIVIA_FLAG) != 0
    is_nonterminal = (flags & JuliaSyntax.NON_TERMINAL_FLAG) != 0
    kind_val = Base.bitcast(UInt16, kind)
    println("  [$i] kind=$kind (UInt16=$kind_val), flags=$flags, is_trivia=$is_trivia, is_nonterminal=$is_nonterminal, span_or_orig=$(node.node_span_or_orig_kind)")
end

# Now inspect via cursor
println("\n=== RedTreeCursor iteration ===")
cursor = JuliaSyntax.RedTreeCursor(stream)
println("Root cursor: position=$(cursor.green.position), byte_end=$(cursor.byte_end)")

# Iterate children in reverse
println("\n=== Reverse iteration of root cursor ===")
for (i, child) in enumerate(Iterators.reverse(cursor))
    pos = child.green.position
    be = child.byte_end
    idx = child.green.position
    node = stream.output[idx]
    is_trivia = (node.head.flags & JuliaSyntax.TRIVIA_FLAG) != 0
    println("  child $i: position=$pos, byte_end=$be, kind=$(node.head.kind), flags=$(node.head.flags), is_trivia=$is_trivia")
end

# Also show the should_include_node filter
println("\n=== Filtered (non-trivia) children ===")
filter_fn = c -> begin
    idx = c.green.position
    node = stream.output[idx]
    head = node.head
    is_trivia = (head.flags & JuliaSyntax.TRIVIA_FLAG) != 0
    is_err = JuliaSyntax.is_error(head.kind)
    result = !is_trivia || is_err
    return result
end
for (i, child) in enumerate(Iterators.filter(JuliaSyntax.should_include_node, Iterators.reverse(cursor)))
    pos = child.green.position
    be = child.byte_end
    idx = child.green.position
    node = stream.output[idx]
    println("  nontrivia child $i: position=$pos, byte_end=$be, kind=$(node.head.kind), flags=$(node.head.flags)")
end

# Call node_to_expr on each child
println("\n=== node_to_expr on each filtered child ===")
srcfile = SourceFile("1+1")
textbuf = Vector{UInt8}(codeunits("1+1"))
for (i, child) in enumerate(Iterators.filter(JuliaSyntax.should_include_node, Iterators.reverse(cursor)))
    result = JuliaSyntax.node_to_expr(child, srcfile, textbuf, UInt32(0))
    println("  child $i: node_to_expr => $result (type=$(typeof(result)))")
end
