using JuliaSyntax

RTC = let
    stream = JuliaSyntax.ParseStream("1")
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    typeof(cursor)
end

ci, rt = only(Base.code_typed(JuliaSyntax.node_to_expr, (RTC, SourceFile, Vector{UInt8}, UInt32); optimize=true))
println("Total statements: ", length(ci.code))
println("Return type: ", rt)
println()

# Show statements 95-200 - the code AFTER the should_include_node check passes
# Line 96 is "return nothing" (the early exit for trivia)
# Line 97+ is the actual processing for included nodes
for i in 95:min(200, length(ci.code))
    stmt = ci.code[i]
    ty = ci.ssavaluetypes[i]
    is_special = stmt isa Core.PhiNode || stmt isa Core.GotoIfNot || stmt isa Core.ReturnNode ||
                 stmt isa Core.GotoNode || (stmt isa Expr && stmt.head == :invoke)
    if is_special
        println(">>> $i: $(ci.code[i]) :: $ty")
    else
        println("    $i: $(ci.code[i]) :: $ty")
    end
end

# Show all return statements and their context (5 lines before)
println("\n\n=== All return statements with context ===")
for i in 1:length(ci.code)
    if ci.code[i] isa Core.ReturnNode
        println("--- Return at stmt $i ---")
        for j in max(1,i-5):i
            println("  $j: $(ci.code[j]) :: $(ci.ssavaluetypes[j])")
        end
        println()
    end
end
