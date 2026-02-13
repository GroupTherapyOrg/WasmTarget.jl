#!/usr/bin/env julia
# PURE-324 attempt 21: Ground truth for parse!("1")

using JuliaSyntax

println("=== Native Julia Ground Truth ===")
println("ParseStream fields: ", fieldnames(JuliaSyntax.ParseStream))
println("JuliaSyntax version: ", pkgversion(JuliaSyntax))
println("RawGreenNode fields: ", fieldnames(JuliaSyntax.RawGreenNode))
println("SyntaxHead fields: ", fieldnames(JuliaSyntax.SyntaxHead))

for input in ["1", "hello", "1+1"]
    stream = JuliaSyntax.ParseStream(input)
    JuliaSyntax.parse!(stream)
    println("\nparse!(\"$input\"):")
    println("  output_len = ", length(stream.output))
    println("  next_byte = ", stream.next_byte)

    # Show output nodes
    for i in 1:length(stream.output)
        node = stream.output[i]
        h = JuliaSyntax.head(node)
        println("  out[$i]: kind=$(h.kind), span=$(node.byte_span)")
    end

    # byte values
    println("  _next_byte = ", JuliaSyntax._next_byte(stream))
    println("  last_byte = ", JuliaSyntax.last_byte(stream))
    println("  first_byte = ", JuliaSyntax.first_byte(stream))
end
