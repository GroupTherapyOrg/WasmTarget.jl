#!/usr/bin/env julia
# Batch isolation testing for build_tree functions
# PURE-325 agent 32

using WasmTarget

results = []

function test_compile(name, f, argtypes)
    print("$name: ")
    try
        bytes = compile(f, argtypes)
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)
        validates = success(run(pipeline(`wasm-tools validate $tmpf`, stdout=devnull, stderr=devnull), wait=true))
        if validates
            println("VALIDATES ($(length(bytes)) bytes)")
            push!(results, (name=name, compiles=true, validates=true, bytes=length(bytes), error=""))
        else
            println("COMPILE OK but FAILS VALIDATION")
            # Get error message
            err = read(pipeline(`wasm-tools validate $tmpf`), String)
            push!(results, (name=name, compiles=true, validates=false, bytes=length(bytes), error=err))
        end
    catch e
        msg = sprint(showerror, e)
        # Truncate long messages
        if length(msg) > 200
            msg = msg[1:200] * "..."
        end
        println("ERROR: $msg")
        push!(results, (name=name, compiles=false, validates=false, bytes=0, error=msg))
    end
end

println("=== BATCH ISOLATION: build_tree functions ===\n")

# 1. Expr constructor
test_compile("Expr(::Symbol)", s -> Expr(s), (Symbol,))

# 2. fixup_Expr_child - the function that crashed before
using JuliaSyntax
test_compile("fixup_Expr_child",
    (h, arg, first) -> JuliaSyntax.fixup_Expr_child(h, arg, first),
    (JuliaSyntax.SyntaxHead, Any, Bool))

# 3. source_location(LineNumberNode, ...)
test_compile("source_location(LNN,SourceFile,Int)",
    (src, idx) -> JuliaSyntax.source_location(LineNumberNode, src, idx),
    (JuliaSyntax.SourceFile, Int))

# 4. parse_julia_literal
test_compile("parse_julia_literal",
    (buf, h, r) -> JuliaSyntax.parse_julia_literal(buf, h, r),
    (Vector{UInt8}, JuliaSyntax.SyntaxHead, UnitRange{UInt32}))

# 5. pushfirst! on Vector{Any}
test_compile("pushfirst!(Vector{Any}, Any)",
    (v, x) -> pushfirst!(v, x),
    (Vector{Any}, Any))

# 6. push!(Vector{Any}, Any)
test_compile("push!(Vector{Any}, Any)",
    (v, x) -> push!(v, x),
    (Vector{Any}, Any))

# 7. Expr(:call).args - accessing args field
test_compile("Expr.args_access",
    s -> Expr(s).args,
    (Symbol,))

# 8. reverse - used in reverse_nontrivia_children
# Actually reverse_nontrivia_children uses an iterator, let's skip this

# 9. isempty on Vector{Any}
test_compile("isempty(Vector{Any})",
    v -> isempty(v),
    (Vector{Any},))

# 10. length on Vector{Any}
test_compile("length(Vector{Any})",
    v -> length(v),
    (Vector{Any},))

# 11. iterate on some iterator type - tricky to isolate

# 12. Expr constructor with head and args
test_compile("Expr(head, args...)",
    (h, a, b) -> Expr(h, a, b),
    (Symbol, Any, Any))

println("\n=== RESULTS SUMMARY ===")
println("| Function | Compiles? | Validates? | Bytes | Error |")
println("|----------|-----------|------------|-------|-------|")
for r in results
    println("| $(r.name) | $(r.compiles) | $(r.validates) | $(r.bytes) | $(r.error[1:min(60,length(r.error))]) |")
end
