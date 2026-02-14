using JuliaSyntax

RTC = let
    stream = JuliaSyntax.ParseStream("1")
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    typeof(cursor)
end

ci, rt = only(Base.code_typed(JuliaSyntax.node_to_expr, (RTC, SourceFile, Vector{UInt8}, UInt32); optimize=true))

# Find returns that don't involve throw_boundserror (non-unreachable returns)
for i in 1:length(ci.code)
    if ci.code[i] isa Core.ReturnNode && isdefined(ci.code[i], :val)
        ty = ci.ssavaluetypes[i]
        if ty !== Union{}
            println("=== Return at $i :: $ty ===")
            for j in max(1,i-15):i
                println("  $j: $(ci.code[j]) :: $(ci.ssavaluetypes[j])")
            end
            println()
        end
    end
end
