using WasmTarget, JuliaSyntax

parse_expr_string(s::String) = JuliaSyntax.parsestmt(Expr, s)

# Diagnostic: parse, get the call node, count its children
function diag_count_children(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    po = stream.output
    pos = UInt32(length(po) - 1)
    cursor = JuliaSyntax.GreenTreeCursor(po, pos)
    count = Int32(0)
    for child in Iterators.reverse(cursor)
        count += Int32(1)
    end
    return count
end

# Diagnostic: parse, get kind of second-to-last node
function diag_node_kind(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    po = stream.output
    pos = UInt32(length(po) - 1)
    cursor = JuliaSyntax.GreenTreeCursor(po, pos)
    h = JuliaSyntax.head(cursor)
    return Int32(reinterpret(UInt16, JuliaSyntax.kind(h)))
end

# Diagnostic: parse, check if second-to-last is leaf
function diag_is_leaf(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    po = stream.output
    pos = UInt32(length(po) - 1)
    cursor = JuliaSyntax.GreenTreeCursor(po, pos)
    return JuliaSyntax.is_leaf(cursor) ? Int32(1) : Int32(0)
end

# Diagnostic: output length
function diag_output_len(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    return Int32(length(stream.output))
end

# Diagnostic: check should_include_node for children
function diag_should_include(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    po = stream.output
    pos = UInt32(length(po) - 1)
    cursor = JuliaSyntax.GreenTreeCursor(po, pos)
    count = Int32(0)
    for child in Iterators.reverse(cursor)
        if JuliaSyntax.should_include_node(child)
            count += Int32(1)
        end
    end
    return count
end

# Diagnostic: check is_trivia for children
function diag_trivia_count(s::String)::Int32
    stream = JuliaSyntax.ParseStream(s)
    JuliaSyntax.parse!(stream)
    po = stream.output
    pos = UInt32(length(po) - 1)
    cursor = JuliaSyntax.GreenTreeCursor(po, pos)
    count = Int32(0)
    for child in Iterators.reverse(cursor)
        if JuliaSyntax.is_trivia(child)
            count += Int32(1)
        end
    end
    return count
end

println("Compiling multi-function module...")
bytes = compile_multi([
    (parse_expr_string, (String,)),
    (diag_count_children, (String,)),
    (diag_node_kind, (String,)),
    (diag_is_leaf, (String,)),
    (diag_output_len, (String,)),
    (diag_should_include, (String,)),
    (diag_trivia_count, (String,)),
])
println("Compiled: $(length(bytes)) bytes")

tmpf = tempname() * ".wasm"
write(tmpf, bytes)
run(`wasm-tools validate --features=gc $tmpf`)
println("VALIDATES")

write("browser/parsestmt.wasm", bytes)
println("Written to browser/parsestmt.wasm")
