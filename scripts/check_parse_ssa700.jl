using JuliaSyntax

arg_types = (VersionNumber, Bool, Nothing, Int64, Bool, Bool,
    Base.Pairs{Symbol, Union{}, Nothing, @NamedTuple{}},
    typeof(JuliaSyntax._parse), Symbol, Bool, Type{Expr}, String, Int64)

ci, rt = only(Base.code_typed(JuliaSyntax.var"#_parse#75", arg_types; optimize=true))

# Show SSA 695-711
println("=== SSA 695-711 ===")
for i in 695:min(711, length(ci.code))
    println("  $i: $(ci.code[i]) :: $(ci.ssavaluetypes[i])")
end
