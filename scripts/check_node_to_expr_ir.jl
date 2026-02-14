using JuliaSyntax

RTC = let
    stream = JuliaSyntax.ParseStream("1")
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    typeof(cursor)
end
println("RedTreeCursor type: ", RTC)

# Get IR for node_to_expr specialized on RedTreeCursor
ci, rt = only(Base.code_typed(JuliaSyntax.node_to_expr, (RTC, SourceFile, Vector{UInt8}, UInt32); optimize=true))
println("node_to_expr return type: ", rt)
println("Number of statements: ", length(ci.code))
println()

# Find the should_include_node check and return nothing
for i in 1:min(50, length(ci.code))
    stmt = ci.code[i]
    t = ci.ssavaluetypes[i]
    s = string(stmt)
    if occursin("should_include", s) || occursin("is_trivia", s) || occursin("has_flags", s) ||
       occursin("nothing", s) || occursin("return", s) || occursin("ReturnNode", s)
        println("  $i: $stmt :: $t")
    end
end
println()

# Show first 15 statements (the should_include_node check)
println("First 15 statements:")
for i in 1:min(15, length(ci.code))
    println("  $i: $(ci.code[i]) :: $(ci.ssavaluetypes[i])")
end
