using Core.Compiler

ci = code_typed(Core.Compiler.tmerge, (Core.Compiler.InferenceLattice, Any, Any))
code = ci[1][1].code
for (i, stmt) in enumerate(code)
    println("$i: $(typeof(stmt)) - $stmt")
end
