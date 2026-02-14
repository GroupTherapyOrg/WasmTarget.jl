using JuliaSyntax

# Check if Tuple{SyntaxHead, UnitRange{UInt32}} is concrete
T = Tuple{JuliaSyntax.SyntaxHead, UnitRange{UInt32}}
println("Tuple{SyntaxHead, UnitRange{UInt32}} concrete: ", isconcretetype(T))

# Check _node_to_expr return type
ci_nte, rt_nte = only(Base.code_typed(JuliaSyntax._node_to_expr,
    (Expr, LineNumberNode, UnitRange{UInt32}, JuliaSyntax.SyntaxHead, UnitRange{UInt32}, JuliaSyntax.SyntaxHead, SourceFile);
    optimize=true))
println("_node_to_expr return type: ", rt_nte)
println("_node_to_expr statements: ", length(ci_nte.code))

# Check parseargs! return type
RTC = let
    stream = JuliaSyntax.ParseStream("1")
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    typeof(cursor)
end
ci_pa, rt_pa = only(Base.code_typed(JuliaSyntax.parseargs!,
    (Expr, LineNumberNode, RTC, SourceFile, Vector{UInt8}, UInt32);
    optimize=true))
println("parseargs! return type: ", rt_pa)
println("parseargs! statements: ", length(ci_pa.code))

# Check fixup_Expr_child return type
ci_fc, rt_fc = only(Base.code_typed(JuliaSyntax.fixup_Expr_child,
    (JuliaSyntax.SyntaxHead, Any, Bool);
    optimize=true))
println("fixup_Expr_child return type: ", rt_fc)
println("fixup_Expr_child statements: ", length(ci_fc.code))

# Check _node_to_expr - what does it return for :call?
println()
println("=== _node_to_expr IR (first 80 stmts) ===")
for i in 1:min(80, length(ci_nte.code))
    stmt = ci_nte.code[i]
    t = ci_nte.ssavaluetypes[i]
    s = string(stmt)
    if occursin("ReturnNode", s) || occursin("return", s) || occursin("GotoIfNot", s) ||
       occursin("Expr", s) || occursin("K\"", s) || occursin("call", s) || t == Any ||
       stmt isa Core.ReturnNode || stmt isa Core.PhiNode
        println("  $i: $stmt :: $t")
    end
end
println("...")
println()
println("=== _node_to_expr RETURN NODES ===")
for i in 1:length(ci_nte.code)
    stmt = ci_nte.code[i]
    if stmt isa Core.ReturnNode
        if isdefined(stmt, :val)
            v = stmt.val
            println("  $i: return $v :: $(v isa Core.SSAValue ? ci_nte.ssavaluetypes[v.id] : typeof(v))")
        else
            println("  $i: unreachable")
        end
    end
end
