using JuliaSyntax

RTC = let
    stream = JuliaSyntax.ParseStream("1")
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    typeof(cursor)
end

ci, rt = only(Base.code_typed(JuliaSyntax.node_to_expr, (RTC, SourceFile, Vector{UInt8}, UInt32); optimize=true))

# Show statements 28-50 (around TRIVIA check and the `return nothing` path)
println("Statements 28-60:")
for i in 28:min(60, length(ci.code))
    println("  $i: $(ci.code[i]) :: $(ci.ssavaluetypes[i])")
end
