#!/usr/bin/env julia
# PURE-325 Agent 28: Compile parsestmt + simple diagnostics using compile_multi
using WasmTarget, JuliaSyntax

const BROWSER_DIR = @__DIR__

# The main parse function (same as always)
parse_expr_string(s::String) = JuliaSyntax.parsestmt(Expr, s)

# Diagnostic: return top-level kind value
function diag_top_kind(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    return Int32(reinterpret(UInt16, JuliaSyntax.kind(cursor)))
end

# Diagnostic: count total children (forward iterate, including trivia)
function diag_child_count(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    # Navigate to first child
    r = iterate(Iterators.reverse(cursor))
    r === nothing && return Int32(-1)
    child_cursor = r[1]
    count = Int32(0)
    r2 = iterate(Iterators.reverse(child_cursor))
    while r2 !== nothing
        count += Int32(1)
        r2 = iterate(Iterators.reverse(child_cursor), r2[2])
    end
    return count
end

# Diagnostic: check if should_include_node passes for all children
function diag_include_check(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    r = iterate(Iterators.reverse(cursor))
    r === nothing && return Int32(-1)
    child_cursor = r[1]
    count = Int32(0)
    r2 = iterate(Iterators.reverse(child_cursor))
    while r2 !== nothing
        c = r2[1]
        if JuliaSyntax.should_include_node(c)
            count += Int32(1)
        end
        r2 = iterate(Iterators.reverse(child_cursor), r2[2])
    end
    return count
end

println("Native: diag_top_kind(\"1+1\") = $(diag_top_kind("1+1"))")
println("Native: diag_child_count(\"1+1\") = $(diag_child_count("1+1"))")
println("Native: diag_include_check(\"1+1\") = $(diag_include_check("1+1"))")

println("\nCompiling multi-module...")
try
    bytes = compile_multi([
        (parse_expr_string, (String,)),
        (diag_top_kind, (String,)),
        (diag_child_count, (String,)),
        (diag_include_check, (String,)),
    ])
    outf = joinpath(BROWSER_DIR, "parsestmt_diag.wasm")
    write(outf, bytes)
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    run(`wasm-tools validate --features=gc $tmpf`)
    println("  VALIDATES, $(length(bytes)) bytes")
catch e
    println("  FAIL: $(sprint(showerror, e)[1:min(200,end)])")

    # Try WITHOUT the node_to_expr-related diagnostics
    println("\nTrying with just parse_expr_string + simpler diagnostics...")
    try
        bytes = compile_multi([
            (parse_expr_string, (String,)),
            (diag_top_kind, (String,)),
        ])
        outf = joinpath(BROWSER_DIR, "parsestmt_diag.wasm")
        write(outf, bytes)
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        run(`wasm-tools validate --features=gc $tmpf`)
        println("  VALIDATES, $(length(bytes)) bytes")
    catch e2
        println("  FAIL: $(sprint(showerror, e2)[1:min(200,end)])")
    end
end

println("\n=== Done ===")
