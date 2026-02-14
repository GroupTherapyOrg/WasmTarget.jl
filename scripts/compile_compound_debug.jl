# Compile parsestmt with debug output for compound expression path
using WasmTarget
using JuliaSyntax

# Test function that wraps parse_expr_string and returns
# different values to help diagnose WHERE the null comes from
function debug_compound(s::String)
    # This is what parse_expr_string does internally
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)

    # build_tree phase
    source = SourceFile(s)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    txtbuf = Vector{UInt8}(undef, 128)
    result = JuliaSyntax.node_to_expr(cursor, source, txtbuf, UInt32(0))

    return result
end

# Also compile a simpler test: just call node_to_expr with the cursor from "1+1"
# and return 1 if it returns something, 0 if nothing
function debug_n2e_null_check(s::String)
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    source = SourceFile(s)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    txtbuf = Vector{UInt8}(undef, 128)
    result = JuliaSyntax.node_to_expr(cursor, source, txtbuf, UInt32(0))

    if result === nothing
        return Int32(0)  # nothing
    else
        return Int32(1)  # something
    end
end

println("Compiling debug_n2e_null_check...")
try
    bytes = compile(debug_n2e_null_check, (String,))
    fname = "/Users/daleblack/Documents/dev/GroupTherapyOrg/WasmTarget.jl/browser/debug_n2e_check.wasm"
    write(fname, bytes)
    println("Wrote $(length(bytes)) bytes")

    # Validate
    result = run(`wasm-tools validate $fname`)
    if result.exitcode == 0
        println("VALIDATES")
    end
catch e
    println("ERROR: ", e)
    # Print compilation warnings
    for line in split(string(e), "\n")[1:min(end, 10)]
        println("  ", line)
    end
end
