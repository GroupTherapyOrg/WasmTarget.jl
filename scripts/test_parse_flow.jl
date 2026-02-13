#!/usr/bin/env julia
# PURE-324: Trace the exact parse flow for parsestmt(Expr, "1")
# Check output at each stage

using JuliaSyntax

println("=== Tracing parsestmt(Expr, \"1\") parse flow ===")

# Stage 1: ParseStream creation
stream = JuliaSyntax.ParseStream("1")
println("After ParseStream creation:")
println("  output_len = ", length(stream.output))

# Stage 2: parse! with rule=:statement
# parse! calls parse_stmts
ps = JuliaSyntax.ParseState(stream)
JuliaSyntax.parse_stmts(ps)
println("After parse_stmts:")
println("  output_len = ", length(stream.output))
for i in 1:length(stream.output)
    node = stream.output[i]
    h = JuliaSyntax.head(node)
    println("  out[$i]: kind=$(h.kind), span=$(node.byte_span), flags=$(h.flags)")
end

# Stage 3: validate_tokens
JuliaSyntax.validate_tokens(stream)
println("After validate_tokens:")
println("  output_len = ", length(stream.output))

# Now check: the final result has 3 nodes. Where does the 3rd come from?
# Let me try from scratch with parse!
stream2 = JuliaSyntax.ParseStream("1")
JuliaSyntax.parse!(stream2, rule=:statement)
println("\nAfter parse!(stream, rule=:statement):")
println("  output_len = ", length(stream2.output))
for i in 1:length(stream2.output)
    node = stream2.output[i]
    h = JuliaSyntax.head(node)
    println("  out[$i]: kind=$(h.kind), span=$(node.byte_span), flags=$(h.flags)")
end

# And with parse!(:all)
stream3 = JuliaSyntax.ParseStream("1")
JuliaSyntax.parse!(stream3, rule=:all)
println("\nAfter parse!(stream, rule=:all):")
println("  output_len = ", length(stream3.output))
for i in 1:length(stream3.output)
    node = stream3.output[i]
    h = JuliaSyntax.head(node)
    println("  out[$i]: kind=$(h.kind), span=$(node.byte_span), flags=$(h.flags)")
end
