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

# Show the first 120 statements — the should_include_node check and early returns
for i in 1:min(120, length(ci.code))
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

println("\n\n--- ReturnNode analysis ---")
for i in 1:length(ci.code)
    if ci.code[i] isa Core.ReturnNode
        # Show 3 stmts before
        for j in max(1,i-3):i
            stmt = ci.code[j]
            ty = ci.ssavaluetypes[j]
            println("  $j: $(ci.code[j]) :: $ty")
        end
        println()
    end
end
