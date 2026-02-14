#!/usr/bin/env julia
# Trace what parse_expr_string("1+1") does at the cursor level
using JuliaSyntax
using JuliaSyntax: SyntaxHead, Kind, @K_str, EMPTY_FLAGS, is_trivia, is_leaf, is_error, has_flags, flags, kind, head, byte_range, span, TRIVIA_FLAG

stream = JuliaSyntax.ParseStream("1+1")
JuliaSyntax.parse!(stream)

cursor = JuliaSyntax.RedTreeCursor(stream)
println("=== Top-level cursor ===")
println("  kind: ", kind(cursor))
println("  is_leaf: ", is_leaf(cursor))
println("  is_trivia: ", is_trivia(cursor))
println("  byte_range: ", byte_range(cursor))
println("  flags raw: ", flags(cursor))

println("\n=== Children of toplevel ===")
for (i, child) in enumerate(reverse(cursor))
    leaf = is_leaf(child)
    println("  Child $i: kind=$(kind(child)), is_leaf=$leaf, is_trivia=$(is_trivia(child)), flags=$(flags(child)), byte_range=$(byte_range(child))")

    if !leaf
        println("  === Grandchildren of child $i ($(kind(child))) ===")
        for (j, grandchild) in enumerate(reverse(child))
            gc_leaf = is_leaf(grandchild)
            println("    Grandchild $j: kind=$(kind(grandchild)), is_leaf=$gc_leaf, is_trivia=$(is_trivia(grandchild)), flags=$(flags(grandchild)), byte_range=$(byte_range(grandchild)), head=$(head(grandchild))")

            should_include = !is_trivia(grandchild) || is_error(grandchild)
            println("    should_include_node = $should_include")

            if gc_leaf
                txtbuf = JuliaSyntax.unsafe_textbuf(stream)
                h = head(grandchild)
                br = byte_range(grandchild)
                k = kind(h)
                println("    parse_julia_literal input: kind=$k, flags=$(flags(h)), srcrange=$br")
                println("    is_identifier(kind) = $(JuliaSyntax.is_identifier(k))")
                println("    is_operator(kind) = $(JuliaSyntax.is_operator(k))")
                result = JuliaSyntax.parse_julia_literal(txtbuf, h, br)
                println("    parse_julia_literal result: $result ($(typeof(result)))")
            end
        end
    end
end

println("\n=== Toplevel handler path ===")
nodehead = head(cursor)
k = kind(cursor)
println("k = $k")
println("k == K\"toplevel\" = $(k == K"toplevel")")
println("has_flags(nodehead, JuliaSyntax.TOPLEVEL_SEMICOLONS_FLAG) = ", has_flags(nodehead, JuliaSyntax.TOPLEVEL_SEMICOLONS_FLAG))

# Also try the full parsestmt
println("\n=== Full parsestmt ===")
result = JuliaSyntax.parsestmt(Expr, "1+1")
println("result = $result")
println("type = $(typeof(result))")
