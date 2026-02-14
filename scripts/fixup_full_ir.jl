using JuliaSyntax

ci_fc, rt_fc = only(Base.code_typed(JuliaSyntax.fixup_Expr_child,
    (JuliaSyntax.SyntaxHead, Any, Bool); optimize=true))

# Show statements 330-347 (near the return)
println("=== SSA 330-347 ===")
for i in 330:347
    if i <= length(ci_fc.code)
        println("  $i: $(ci_fc.code[i]) :: $(ci_fc.ssavaluetypes[i])")
    end
end

# Show phi nodes
println()
println("=== PHI NODES ===")
for i in 1:length(ci_fc.code)
    stmt = ci_fc.code[i]
    if stmt isa Core.PhiNode
        t = ci_fc.ssavaluetypes[i]
        println("  $i: φ(edges=$(stmt.edges), values=$(stmt.values)) :: $t")
    end
end

# Show key calls related to Expr manipulation
println()
println("=== EXPR MANIPULATION CALLS ===")
for i in 1:length(ci_fc.code)
    stmt = ci_fc.code[i]
    s = string(stmt)
    if occursin("_expr", s) || occursin("Expr", s) || occursin("setfield", s) ||
       occursin("getproperty", s) || occursin("head", s) || occursin("args", s) ||
       occursin("pushfirst", s) || occursin("popfirst", s) || occursin("push!", s)
        t = ci_fc.ssavaluetypes[i]
        println("  $i: $stmt :: $t")
    end
end
