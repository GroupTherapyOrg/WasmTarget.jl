using JuliaSyntax

# Check what the 4-arg ParseStream method compiles to with code_ircode
println("=== code_ircode for ParseStream(Vec, Vec, Int64, VersionNumber) ===")
ir = Base.code_ircode(JuliaSyntax.ParseStream, (Vector{UInt8}, Vector{UInt8}, Int64, VersionNumber))
for (ci, ret) in ir
    for (i, stmt) in enumerate(ci.stmts)
        s = string(stmt)
        if contains(s, "typeintersect") || contains(s, "_tuple_error") || contains(s, "invoke")
            println("  [$i] $s")
        end
    end
end
println()

# Also check Lexer
println("=== Looking for typeintersect in Lexer(IOBuffer) ===")
try
    ir2 = Base.code_ircode(JuliaSyntax.Tokenize.Lexer, (IOBuffer,))
    for (ci, ret) in ir2
        for (i, stmt) in enumerate(ci.stmts)
            s = string(stmt)
            if contains(s, "typeintersect") || contains(s, "_tuple_error") || contains(s, "invoke")
                println("  [$i] $s")
            end
        end
    end
catch e
    println("  Error: $e")
end
println()

# Check VersionNumber fields
println("=== VersionNumber struct ===")
println("Fields: ", fieldnames(VersionNumber))
println("Types: ", [fieldtype(VersionNumber, f) for f in fieldnames(VersionNumber)])
v = JuliaSyntax.VERSION
println("Value: $v")
println("major=$(v.major) minor=$(v.minor) patch=$(v.patch)")
println("prerelease=$(v.prerelease) build=$(v.build)")
