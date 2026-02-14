using JuliaSyntax

# Get IR for the specific _parse method that parsestmt calls
arg_types = (VersionNumber, Bool, Nothing, Int64, Bool, Bool,
    Base.Pairs{Symbol, Union{}, Nothing, @NamedTuple{}},
    typeof(JuliaSyntax._parse), Symbol, Bool, Type{Expr}, String, Int64)

ci, rt = only(Base.code_typed(JuliaSyntax.var"#_parse#75", arg_types; optimize=true))
println("_parse return type: ", rt)
println("Total statements: ", length(ci.code))

# Show key calls
println("\n=== KEY CALLS ===")
for i in 1:length(ci.code)
    stmt = ci.code[i]
    s = string(stmt)
    if occursin("build_tree", s) || occursin("parse!", s) || occursin("ParseStream", s) ||
       occursin("SourceFile", s) || occursin("last_byte", s) || occursin("fixup", s) ||
       occursin("Tuple", s) || stmt isa Core.ReturnNode
        t = ci.ssavaluetypes[i]
        println("  $i: $stmt :: $t")
    end
end

# Show ALL return nodes
println("\n=== RETURN NODES ===")
for i in 1:length(ci.code)
    stmt = ci.code[i]
    if stmt isa Core.ReturnNode
        if isdefined(stmt, :val)
            v = stmt.val
            t = v isa Core.SSAValue ? ci.ssavaluetypes[v.id] : typeof(v)
            println("  $i: return $v :: $t")
            # Trace one level back
            if v isa Core.SSAValue
                inner = ci.code[v.id]
                println("    -> $inner :: $t")
            end
        else
            println("  $i: unreachable")
        end
    end
end
