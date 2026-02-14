using JuliaSyntax

RTC = let
    stream = JuliaSyntax.ParseStream("1")
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    typeof(cursor)
end

ci, rt = only(Base.code_typed(JuliaSyntax.node_to_expr, (RTC, SourceFile, Vector{UInt8}, UInt32); optimize=true))

# Show statements 60-95 (around the is_error check and return nothing / continue)
println("Statements 60-95:")
for i in 60:min(95, length(ci.code))
    println("  $i: $(ci.code[i]) :: $(ci.ssavaluetypes[i])")
end

# Find all ReturnNode statements
println("\nAll ReturnNode statements:")
for i in 1:length(ci.code)
    if ci.code[i] isa Core.ReturnNode
        println("  $i: $(ci.code[i]) :: $(ci.ssavaluetypes[i])")
    end
end
