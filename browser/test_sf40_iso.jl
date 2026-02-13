using WasmTarget, JuliaSyntax

# What is SourceFile#40?
ms = methods(JuliaSyntax.var"#SourceFile#40")
for m in ms
    println("Method: ", m)
end

# Check code_typed for SourceFile#40
# It's a keyword sorter that calls #SourceFile#8
# The actual call in parsestmt is from build_tree which creates SourceFile
# from ParseStream data

# Let's check what the call chain looks like in _parse#75
# After parsing, it calls build_tree which creates SourceFile
# The SourceFile gets created with the original string/SubString
#
# But in the parsestmt wasm, the SubString might be constructed differently
# (from the ParseStream's text buffer)

# Test the actual call chain more precisely:
# In parsestmt, _parse#75 creates a ParseStream, calls parse!,
# then calls build_tree(Expr, stream, SourceFile(source_text, ...))

# Let's trace what _parse#75 does after parsing:
println()
println("=== _parse#75 IR (last 30 stmts) ===")
ci = first(code_typed(JuliaSyntax.var"#_parse#75",
    (typeof(JuliaSyntax.VERSION), Bool, Nothing, Int64, Bool, Bool,
     Base.Pairs{Symbol, Union{}, Nothing, @NamedTuple{}},
     typeof(JuliaSyntax._parse), Symbol, Bool, Type{Expr}, String, Int64)))
n = length(ci.first.code)
for i in max(1, n-40):n
    s = string(ci.first.code[i])
    if length(s) > 120; s = s[1:120] * "..."; end
    println("SSA $i: $s :: $(ci.first.ssavaluetypes[i])")
end
