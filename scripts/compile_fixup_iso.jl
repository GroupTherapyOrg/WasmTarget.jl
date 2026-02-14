# Isolate fixup_Expr_child to determine if it's the bug source
using WasmTarget
using JuliaSyntax

# Test fixup_Expr_child with different inputs
# For simple inputs (Int64), fixup_Expr_child should pass through
# For compound inputs (Expr), fixup_Expr_child should also pass through

# Check fixup_Expr_child IR first
ci_fc, rt_fc = only(Base.code_typed(JuliaSyntax.fixup_Expr_child,
    (JuliaSyntax.SyntaxHead, Any, Bool); optimize=true))
println("fixup_Expr_child return type: ", rt_fc)
println("Total statements: ", length(ci_fc.code))

# Show first 20 statements
for i in 1:min(20, length(ci_fc.code))
    println("  $i: $(ci_fc.code[i]) :: $(ci_fc.ssavaluetypes[i])")
end

# Show return nodes
println("Return nodes:")
for i in 1:length(ci_fc.code)
    stmt = ci_fc.code[i]
    if stmt isa Core.ReturnNode && isdefined(stmt, :val)
        v = stmt.val
        t = v isa Core.SSAValue ? ci_fc.ssavaluetypes[v.id] : typeof(v)
        println("  $i: return $v :: $t")
    end
end
