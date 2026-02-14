using JuliaSyntax

# Show the parse tree structure for "1+1" - focus on the call node children
stream = JuliaSyntax.ParseStream("1+1")
JuliaSyntax.parse!(stream)

println("=== All output nodes ===")
output = stream.output
for (i, node) in enumerate(output)
    head = node.head
    flags = head.flags
    kind = head.kind
    is_trivia = (flags & JuliaSyntax.TRIVIA_FLAG) != 0
    is_nonterminal = (flags & JuliaSyntax.NON_TERMINAL_FLAG) != 0
    println("  [$i] kind=$kind, flags=$flags, is_trivia=$is_trivia, is_nonterminal=$is_nonterminal, byte_span=$(node.byte_span), node_span=$(node.node_span_or_orig_kind)")
end

# Get the call node cursor (position 5)
cursor = JuliaSyntax.RedTreeCursor(stream)
toplevel_children = collect(Iterators.reverse(cursor))
call_cursor = toplevel_children[1]
println("\nCall cursor: position=$(call_cursor.green.position), byte_end=$(call_cursor.byte_end)")
println("Call node: kind=$(output[call_cursor.green.position].head.kind), flags=$(output[call_cursor.green.position].head.flags)")
println("Call node_span_or_orig_kind=$(output[call_cursor.green.position].node_span_or_orig_kind)")
println("Call byte_span=$(output[call_cursor.green.position].byte_span)")

# Iterate children of the call cursor
println("\n=== All children of call cursor (reverse) ===")
for (i, child) in enumerate(Iterators.reverse(call_cursor))
    pos = child.green.position
    be = child.byte_end
    node = stream.output[pos]
    is_trivia = (node.head.flags & JuliaSyntax.TRIVIA_FLAG) != 0
    println("  child $i: position=$pos, byte_end=$be, kind=$(node.head.kind), flags=$(node.head.flags), is_trivia=$is_trivia, byte_span=$(node.byte_span)")
end

# Show filtered children
println("\n=== Non-trivia children of call cursor ===")
for (i, child) in enumerate(Iterators.filter(JuliaSyntax.should_include_node, Iterators.reverse(call_cursor)))
    pos = child.green.position
    be = child.byte_end
    node = stream.output[pos]
    is_trivia = (node.head.flags & JuliaSyntax.TRIVIA_FLAG) != 0
    println("  nontrivia child $i: position=$pos, byte_end=$be, kind=$(node.head.kind), flags=$(node.head.flags), is_trivia=$is_trivia")
    # Call node_to_expr on each
    srcfile = SourceFile("1+1")
    textbuf = Vector{UInt8}(codeunits("1+1"))
    result = JuliaSyntax.node_to_expr(child, srcfile, textbuf, UInt32(0))
    println("    node_to_expr => $result (type=$(typeof(result)))")
end

# Also show the GreenTreeCursor positions during iteration
println("\n=== GreenTreeCursor positions during reverse iteration of call node ===")
green = call_cursor.green
println("Starting green position: $(green.position)")
println("parser_output length: $(length(green.parser_output))")

# Manual iteration showing positions
pos = green.position
while true
    node = green.parser_output[pos]
    println("  pos=$pos: kind=$(node.head.kind), flags=$(node.head.flags), is_nonterminal=$((node.head.flags & JuliaSyntax.NON_TERMINAL_FLAG) != 0), byte_span=$(node.byte_span), node_span=$(node.node_span_or_orig_kind)")

    # Check if NON_TERMINAL to determine span
    if (node.head.flags & JuliaSyntax.NON_TERMINAL_FLAG) != 0
        child_span = node.node_span_or_orig_kind
    else
        child_span = UInt32(0)
    end

    next_pos = pos - child_span - 1
    println("    next_pos = $pos - $child_span - 1 = $next_pos")

    # Stop condition: went below start
    start_pos = green.position - (output[green.position].node_span_or_orig_kind)
    println("    start_pos = $(green.position) - $(output[green.position].node_span_or_orig_kind) = $start_pos")
    if next_pos < start_pos
        println("    DONE (next_pos < start_pos)")
        break
    end

    pos = next_pos
end
