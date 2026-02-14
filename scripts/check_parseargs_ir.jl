using JuliaSyntax

RTC = let
    stream = JuliaSyntax.ParseStream("1")
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    typeof(cursor)
end

# parseargs! signature
ci, rt = only(Base.code_typed(JuliaSyntax.parseargs!,
    (Expr, LineNumberNode, RTC, SourceFile, Vector{UInt8}, UInt32); optimize=true))
println("parseargs! return type: ", rt)
println("Number of statements: ", length(ci.code))
println()

# First 60 statements — should show the iterator setup and first node_to_expr call
for i in 1:min(60, length(ci.code))
    println("  $i: $(ci.code[i]) :: $(ci.ssavaluetypes[i])")
end
