#!/usr/bin/env julia
# Check the IR for peek-related functions

using JuliaSyntax

# Check what parse_toplevel looks like in IR form
println("=== IR for parse_toplevel ===")
# We can't directly see parse_toplevel's IR, but we can see key functions

# Check peek with skip_newlines=true
println("\n=== Base.peek(::ParseStream, ::Int; skip_newlines=true) ===")
ci = only(Base.code_typed(Base.peek, (JuliaSyntax.ParseStream,); optimize=true))
for (i, stmt) in enumerate(ci[1].code)
    println("  %$i = $stmt")
end

# Check _lookahead_index
println("\n=== _lookahead_index(::ParseStream, ::Int, ::Bool) ===")
try
    ci = only(Base.code_typed(JuliaSyntax._lookahead_index, (JuliaSyntax.ParseStream, Int, Bool); optimize=true))
    for (i, stmt) in enumerate(ci[1].code[1:min(30, length(ci[1].code))])
        println("  %$i = $stmt")
    end
    println("  ... ($(length(ci[1].code)) total stmts)")
catch e
    println("  ERROR: $e")
end

# Check is_closing_token
println("\n=== is_closing_token ===")
try
    ci = only(Base.code_typed(JuliaSyntax.is_closing_token, (JuliaSyntax.ParseState, JuliaSyntax.Kind); optimize=true))
    for (i, stmt) in enumerate(ci[1].code)
        println("  %$i = $stmt")
    end
catch e
    println("  ERROR: $e")
end
