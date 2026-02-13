#!/usr/bin/env julia
# PURE-324: Debug Stage D — identify which functions are func_1, func_2, func_8, func_16

using WasmTarget
using JuliaSyntax

function parse_expr_string(s::String)
    JuliaSyntax.parsestmt(Expr, s)
end

# Use compile_multi to see function order (or look at compilation output)
# The compile() function prints function names during compilation
println("=== Compiling Stage D with verbose output ===")
println("Look for 'Compiling function' messages to identify func indices")

# We need to capture the function name -> index mapping
# The compiler assigns indices in compilation order
# Let's redirect to capture all output
bytes = compile(parse_expr_string, (String,))

# Now let's also check what stubs exist
println("\n=== Stub check ===")
println("Total bytes: $(length(bytes))")
