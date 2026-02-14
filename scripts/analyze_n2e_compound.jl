using JuliaSyntax

RTC = let
    stream = JuliaSyntax.ParseStream("1")
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    typeof(cursor)
end

# Get IR for node_to_expr
ci, rt = only(Base.code_typed(JuliaSyntax.node_to_expr, (RTC, SourceFile, Vector{UInt8}, UInt32); optimize=true))
println("node_to_expr return type: ", rt)
println("Total statements: ", length(ci.code))
println()

# Show ALL statements for compound path analysis
# Focus on: ReturnNode, getfield, parseargs!, _node_to_expr, Expr constructor
println("=== ALL STATEMENTS ===")
for i in 1:length(ci.code)
    stmt = ci.code[i]
    t = ci.ssavaluetypes[i]
    s = string(stmt)
    # Show everything relevant to understanding the control flow
    if occursin("Expr", s) || occursin("parseargs", s) || occursin("_node_to_expr", s) ||
       occursin("ReturnNode", s) || occursin("return", s) || occursin("GotoIfNot", s) ||
       occursin("GotoNode", s) || occursin("PhiNode", s) || occursin("getfield", s) ||
       occursin("nothing", s) || occursin("is_leaf", s) || occursin("K\"", s) ||
       occursin("push", s) || occursin("untokenize", s) || occursin("Symbol", s) ||
       t == Any || (t isa Type && t <: Union)
        println("  $i: $stmt :: $t")
    end
end
println()

# Also show ReturnNode details
println("=== RETURN NODES ===")
for i in 1:length(ci.code)
    stmt = ci.code[i]
    if stmt isa Core.ReturnNode
        println("  $i: ReturnNode($(stmt.val)) :: $(ci.ssavaluetypes[i])")
        # Show the value being returned
        if stmt.val isa Core.SSAValue
            j = stmt.val.id
            println("    -> SSA $j: $(ci.code[j]) :: $(ci.ssavaluetypes[j])")
        end
    end
end
