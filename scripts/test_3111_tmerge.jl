using Core.Compiler

for LT in [Core.Compiler.InferenceLattice, Core.Compiler.ConstsLattice, Core.Compiler.ConditionalsLattice, Core.Compiler.PartialsLattice]
    ci = code_typed(Core.Compiler.tmerge, (LT, Any, Any))
    if !isempty(ci)
        code = ci[1][1].code
        println("$(LT) tmerge: $(length(code)) stmts")
    end
end
