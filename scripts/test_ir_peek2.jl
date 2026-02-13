#!/usr/bin/env julia
# Check the IR for peek when called with skip_newlines=true vs false

using JuliaSyntax

# The actual function that parse_toplevel's peek compiles to:
# peek(ps::ParseState, n=1; skip_newlines=nothing)
#   skip_nl = isnothing(skip_newlines) ? ps.whitespace_newline : skip_newlines
#   peek(ps.stream, n; skip_newlines=skip_nl)
#
# When skip_newlines=true, skip_nl=true
# peek(stream, 1; skip_newlines=true) calls _lookahead_index(stream, 1, true)

# Let's look at the _lookahead_index fast path for skip_newlines=true
println("=== _lookahead_index IR (fast path, skip_newlines=true) ===")
# The fast path checks:
# if skip_newlines
#     k = kind(stream.lookahead[i])
#     if !(k == K"Whitespace" || k == K"Comment" || k == K"NewlineWs")
#         return i
# else
#     k = kind(stream.lookahead[i])
#     if !(k == K"Whitespace" || k == K"Comment")
#         return i

# Now, peek(stream, skip_newlines=true) goes through peek_token which goes through _lookahead_index
# The FULL function call:
#   peek_token(stream, 1, skip_newlines=true)
#   -> _lookahead_index(stream, 1, true)
#   -> fast path: if skip_newlines -> check Whitespace/Comment/NewlineWs
#   -> index into lookahead[i]
#   -> return kind

# Let's check: does the stream.lookahead have the right kind after parse!?
println("\nChecking lookahead contents after parse!")
stream = JuliaSyntax.ParseStream("1")
JuliaSyntax.parse!(stream)

println("lookahead_index = ", stream.lookahead_index)
println("lookahead length = ", length(stream.lookahead))
for i in 1:length(stream.lookahead)
    tok = stream.lookahead[i]
    k = JuliaSyntax.kind(tok)
    println("  lookahead[$i]: kind=$k ($(reinterpret(UInt16, k))), nb=$(tok.next_byte)")
end

# The key: at lookahead[lookahead_index], what kind is it?
li = stream.lookahead_index
println("\nCurrent lookahead token (index $li): kind=$(JuliaSyntax.kind(stream.lookahead[li]))")

# Now check: what does peek_token return?
println("\npeek result: ", Base.peek(stream, skip_newlines=true))
println("peek result (no skip): ", Base.peek(stream))

# What about the look-ahead index computation?
println("\n_lookahead_index(stream, 1, true) = ", JuliaSyntax._lookahead_index(stream, 1, true))
println("_lookahead_index(stream, 1, false) = ", JuliaSyntax._lookahead_index(stream, 1, false))
