using Core.Compiler

# tmerge_3 is the ConditionalsLattice variant
ci = code_typed(Core.Compiler.tmerge, (Core.Compiler.ConditionalsLattice, Any, Any))
if !isempty(ci)
    code = ci[1][1].code
    println("ConditionalsLattice tmerge: $(length(code)) stmts")
    for (i, stmt) in enumerate(code)
        println("$i: $(typeof(stmt)) - $stmt")
    end
end
