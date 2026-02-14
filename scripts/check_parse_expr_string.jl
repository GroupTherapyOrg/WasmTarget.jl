using JuliaSyntax

# What does parse_expr_string actually do?
# Check if there's a function called parse_expr_string
println("Methods for parsestmt:")
for m in methods(JuliaSyntax.parsestmt)
    println("  ", m)
end

# What is parse_expr_string in parsestmt.wasm?
# It's the entry function compiled. Let's check what function was used.
# Based on ARCHITECTURE, it should be:
# parsestmt(Expr, s::String) which calls parsestmt(Expr, s; filename="none")

println()
println("parsestmt(Expr, \"1\"): ", parsestmt(Expr, "1"))
println("parsestmt(Expr, \"a\"): ", parsestmt(Expr, "a"))
println("parsestmt(Expr, \"1+1\"): ", parsestmt(Expr, "1+1"))
println()

# Check the IR for parsestmt
# First find the right method
ci, rt = only(Base.code_typed(JuliaSyntax.parsestmt, (Type{Expr}, String); optimize=true))
println("parsestmt(Expr, String) return type: ", rt)
println("Total statements: ", length(ci.code))

# Show key statements - look for _parse, build_tree, getfield
println()
println("=== KEY STATEMENTS ===")
for i in 1:length(ci.code)
    stmt = ci.code[i]
    t = ci.ssavaluetypes[i]
    s = string(stmt)
    if occursin("_parse", s) || occursin("build_tree", s) || occursin("getfield", s) ||
       occursin("return", s) || occursin("ReturnNode", s) || occursin("parse_expr", s) ||
       stmt isa Core.ReturnNode
        println("  $i: $stmt :: $t")
    end
end
