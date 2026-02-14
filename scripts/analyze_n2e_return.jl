using JuliaSyntax

RTC = let
    stream = JuliaSyntax.ParseStream("1")
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    typeof(cursor)
end

ci, rt = only(Base.code_typed(JuliaSyntax.node_to_expr, (RTC, SourceFile, Vector{UInt8}, UInt32); optimize=true))
println("node_to_expr return type: ", rt)
println("Total statements: ", length(ci.code))
println()

# Find ALL return nodes
println("=== RETURN NODES ===")
for i in 1:length(ci.code)
    stmt = ci.code[i]
    if stmt isa Core.ReturnNode
        if isdefined(stmt, :val)
            println("  $i: ReturnNode($(stmt.val))")
            v = stmt.val
            if v isa Core.SSAValue
                j = v.id
                println("    -> SSA $j: $(ci.code[j]) :: $(ci.ssavaluetypes[j])")
            end
        else
            println("  $i: ReturnNode() [unreachable]")
        end
    end
end
println()

# Show SSA 539 and surrounding context (530-550)
println("=== SSA 530-560 (around return value %539) ===")
for i in 530:min(560, length(ci.code))
    stmt = ci.code[i]
    t = ci.ssavaluetypes[i]
    println("  $i: $stmt :: $t")
end
println()

# Find PhiNodes near return (they often merge results from different code paths)
println("=== PHI NODES ===")
for i in 1:length(ci.code)
    stmt = ci.code[i]
    if stmt isa Core.PhiNode
        t = ci.ssavaluetypes[i]
        println("  $i: PhiNode(edges=$(stmt.edges), values=$(stmt.values)) :: $t")
    end
end
println()

# Show key function calls: parseargs!, _node_to_expr, Expr()
println("=== KEY CALLS (parseargs!, _node_to_expr, Expr constructor) ===")
for i in 1:length(ci.code)
    stmt = ci.code[i]
    s = string(stmt)
    if occursin("parseargs", s) || occursin("_node_to_expr", s) || occursin("Expr(", s) ||
       (stmt isa Expr && stmt.head == :new && length(stmt.args) > 0 && string(stmt.args[1]) == "Expr")
        t = ci.ssavaluetypes[i]
        println("  $i: $stmt :: $t")
    end
end
