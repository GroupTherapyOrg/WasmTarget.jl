using JuliaSyntax

RTC = let
    stream = JuliaSyntax.ParseStream("1")
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    typeof(cursor)
end

ci, rt = only(Base.code_typed(JuliaSyntax.node_to_expr, (RTC, SourceFile, Vector{UInt8}, UInt32); optimize=true))
println("node_to_expr return type: ", rt)
println("Number of statements: ", length(ci.code))
println()

# Show statements 1-30 (should_include_node check + early code)
println("Statements 1-30:")
for i in 1:min(30, length(ci.code))
    println("  $i: $(ci.code[i]) :: $(ci.ssavaluetypes[i])")
end

# Find key patterns
println("\nKey statements:")
for i in 1:length(ci.code)
    stmt = ci.code[i]
    t = ci.ssavaluetypes[i]
    s = string(stmt)
    if occursin("TRIVIA", s) || occursin("trivia", s) || (stmt isa Core.ReturnNode && i < 50)
        println("  $i: $stmt :: $t")
    end
end
