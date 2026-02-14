using JuliaSyntax

# build_tree is: build_tree(::Type{Expr}, stream::ParseStream, source) at expr.jl:650
# Get the IR
RTC = let
    stream = JuliaSyntax.ParseStream("1")
    JuliaSyntax.parse!(stream)
    typeof(stream)
end

ci, rt = only(Base.code_typed(JuliaSyntax.build_tree, (Type{Expr}, RTC, SourceFile); optimize=true))
println("build_tree return type: ", rt)
println("Total statements: ", length(ci.code))
println()

# Show ALL return nodes
println("=== RETURN NODES ===")
for i in 1:length(ci.code)
    stmt = ci.code[i]
    if stmt isa Core.ReturnNode
        if isdefined(stmt, :val)
            v = stmt.val
            t = v isa Core.SSAValue ? ci.ssavaluetypes[v.id] : typeof(v)
            println("  $i: return $v :: $t")
        else
            println("  $i: unreachable")
        end
    end
end
println()

# Show key calls: node_to_expr, fixup_Expr_child, has_toplevel_siblings
println("=== KEY CALLS ===")
for i in 1:length(ci.code)
    stmt = ci.code[i]
    s = string(stmt)
    if occursin("node_to_expr", s) || occursin("fixup_Expr_child", s) ||
       occursin("has_toplevel_siblings", s) || occursin("build_tree", s) ||
       occursin("wrapper_head", s) || occursin("_expr", s)
        t = ci.ssavaluetypes[i]
        println("  $i: $stmt :: $t")
    end
end
println()

# Show all statements
println("=== ALL STATEMENTS ===")
for i in 1:length(ci.code)
    stmt = ci.code[i]
    t = ci.ssavaluetypes[i]
    println("  $i: $stmt :: $t")
end
