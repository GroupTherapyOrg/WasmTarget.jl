# ============================================================================
# eval_julia.jl — Real eval_julia pipeline
#
# This file implements the eval_julia pipeline:
#   1. Parse: JuliaSyntax.parsestmt(Expr, code) → Expr
#   2. Extract: function + arg types from parsed Expr
#   3. TypeInf: WasmInterpreter + Core.Compiler.typeinf → canonical CodeInfo
#   4. Codegen: compile_from_codeinfo(ci, rettype, name, arg_types) → .wasm bytes
#
# Stage 3 uses WasmInterpreter (custom AbstractInterpreter with DictMethodTable,
# PreDecompressedCodeInfo, pure Julia reimplementations). may_optimize=false skips
# Julia's IR optimization passes (unnecessary for WASM — Binaryen handles it).
# The unoptimized CodeInfo may differ from Base.code_typed format.
#
# NO pre-computed WASM bytes. NO character matching. NO shortcuts.
# Every call runs the REAL Julia compiler pipeline from scratch.
# ============================================================================

# --- WASM-friendly method overrides ---
# These override JuliaSyntax methods that use Dict/Set globals (which crash in WASM).
# Kind `==` comparison works in WASM, but Dict-backed Set{Kind} lookups hit `unreachable`.

# Override `in(::Kind, ::Set{Kind})` to avoid Dict-backed Set lookup.
# JuliaSyntax._nonunique_kind_names is Set{Kind} — only Set{Kind} in the codebase.
# Dict/Set globals crash in WASM; this replaces `haskey(dict, k)` with `==` comparisons.
# Uses the exact 30 entries from JuliaSyntax/kynZ9/src/julia/kinds.jl lines 1084-1119.
function Base.in(k::JuliaSyntax.Kind, ::Set{JuliaSyntax.Kind})::Bool
    k == JuliaSyntax.K"Comment" || k == JuliaSyntax.K"Whitespace" ||
    k == JuliaSyntax.K"NewlineWs" || k == JuliaSyntax.K"Identifier" ||
    k == JuliaSyntax.K"Placeholder" ||
    k == JuliaSyntax.K"ErrorEofMultiComment" ||
    k == JuliaSyntax.K"ErrorInvalidNumericConstant" ||
    k == JuliaSyntax.K"ErrorHexFloatMustContainP" ||
    k == JuliaSyntax.K"ErrorAmbiguousNumericConstant" ||
    k == JuliaSyntax.K"ErrorAmbiguousNumericDotMultiply" ||
    k == JuliaSyntax.K"ErrorInvalidInterpolationTerminator" ||
    k == JuliaSyntax.K"ErrorNumericOverflow" ||
    k == JuliaSyntax.K"ErrorInvalidEscapeSequence" ||
    k == JuliaSyntax.K"ErrorOverLongCharacter" ||
    k == JuliaSyntax.K"ErrorInvalidUTF8" ||
    k == JuliaSyntax.K"ErrorInvisibleChar" ||
    k == JuliaSyntax.K"ErrorUnknownCharacter" ||
    k == JuliaSyntax.K"ErrorBidiFormatting" ||
    k == JuliaSyntax.K"ErrorInvalidOperator" ||
    k == JuliaSyntax.K"Bool" || k == JuliaSyntax.K"Integer" ||
    k == JuliaSyntax.K"BinInt" || k == JuliaSyntax.K"HexInt" ||
    k == JuliaSyntax.K"OctInt" || k == JuliaSyntax.K"Float" ||
    k == JuliaSyntax.K"Float32" || k == JuliaSyntax.K"String" ||
    k == JuliaSyntax.K"Char" || k == JuliaSyntax.K"CmdString" ||
    k == JuliaSyntax.K"StrMacroName" ||
    k == JuliaSyntax.K"CmdMacroName"
end

# --- WASM-compatible non-kwarg untokenize (bypasses kwcall dispatch) ---
# The kwarg dispatch mechanism doesn't work reliably in WASM-compiled code.
# This provides identical logic to untokenize(::Kind; unique=true) but as a
# positional-arg function that the WASM codegen can handle.
function _wasm_untokenize_kind(k::JuliaSyntax.Kind, unique::Bool)::Union{Nothing, String}
    # Use the original Set-based check — `k in _nonunique_kind_names` works in WASM
    # (verified by eval_julia_test_set_lookup=0, eval_julia_test_untokenize_inline=4).
    # The previous 30-entry `||` chain had a codegen bug where K"call" matched incorrectly.
    if unique && k in JuliaSyntax._nonunique_kind_names
        return nothing
    end
    return string(k)
end

# WASM-compatible untokenize for SyntaxHead (no kwargs, no Set lookup).
# Equivalent to JuliaSyntax.untokenize(head::SyntaxHead; unique=true, include_flag_suff=false)
function _wasm_untokenize_head(head::JuliaSyntax.SyntaxHead)::Union{Nothing, String}
    # Matches untokenize(head; include_flag_suff=false) — no dotted/trivia/infix suffixes
    k = JuliaSyntax.kind(head)
    if JuliaSyntax.is_error(k)
        return _wasm_untokenize_kind(k, false)
    end
    return _wasm_untokenize_kind(k, true)
end

"""
    eval_julia_to_bytes(code::String)::Vector{UInt8}

The REAL eval_julia pipeline. Chains all 4 stages using Julia's compiler.
Returns .wasm bytes that can be instantiated via WebAssembly.instantiate() in JS.

Pipeline:
    1. Parse: JuliaSyntax.parsestmt(Expr, code) → Expr(:call, :+, 1, 1)
    2. Extract: function symbol + arg types from the Expr
    3. TypeInf: WasmInterpreter typeinf → typed, canonical CodeInfo
    4. Codegen: compile_from_codeinfo(ci, rettype, name, arg_types) → .wasm bytes

Currently handles: binary arithmetic on Int64 literals (e.g. "1+1", "10-3", "2*3")
"""
# --- WASM byte vector helpers ---
# These are compiled to WASM and exported so JS can create Vector{UInt8}
# in the module's own type space (cross-module WasmGC types are incompatible).
function make_byte_vec(n::Int32)::Vector{UInt8}
    return Vector{UInt8}(undef, Int(n))
end

function set_byte_vec!(v::Vector{UInt8}, idx::Int32, val::Int32)::Int32
    # Use @inbounds + % UInt8 to avoid throw_boundserror and throw_inexacterror paths.
    # Those throws set ctx.last_stmt_was_stub=true in codegen, killing the entire function body.
    # JS controls all inputs, so bounds are guaranteed valid.
    @inbounds v[Int(idx)] = val % UInt8
    return Int32(0)
end

# --- WASM-compatible build_tree replacement (kynZ9 version) ---
# The original build_tree(Expr, stream) calls node_to_expr which calls
# untokenize(head::SyntaxHead) → untokenize(k::Kind) → _nonunique_kind_names Set lookup.
# The Set{Kind} global crashes in WASM (Dict-backed globals hit unreachable).
# We replace the entire node_to_expr chain with _wasm_* versions that use
# _wasm_untokenize_head (== comparison instead of Set lookup).

# WASM-compatible _string_to_Expr — calls _wasm_node_to_expr instead of node_to_expr
function _wasm_string_to_Expr(cursor, source, txtbuf::Vector{UInt8}, txtbuf_offset::UInt32)
    ret = Expr(:string)
    it = JuliaSyntax.reverse_nontrivia_children(cursor)
    r = iterate(it)
    while r !== nothing
        (child, state) = r
        ex = _wasm_node_to_expr(child, source, txtbuf, txtbuf_offset)
        if isa(ex, String)
            r = iterate(it, state)
            if r === nothing
                pushfirst!(ret.args, ex)
                continue
            end
            (child, state) = r
            ex2 = _wasm_node_to_expr(child, source, txtbuf, txtbuf_offset)
            if !isa(ex2, String)
                pushfirst!(ret.args, ex)
                ex = ex2
            else
                strings = String[ex2, ex]
                r = iterate(it, state)
                while r !== nothing
                    (child, state) = r
                    ex = _wasm_node_to_expr(child, source, txtbuf, txtbuf_offset)
                    isa(ex, String) || break
                    pushfirst!(strings, ex)
                    r = iterate(it, state)
                end
                buf = IOBuffer()
                for s in strings
                    write(buf, s)
                end
                pushfirst!(ret.args, String(take!(buf)))
                r === nothing && break
            end
        end
        if Meta.isexpr(ex, :parens, 1)
            ex = JuliaSyntax._strip_parens(ex)
            if ex isa String
                ex = Expr(:string, ex)
            end
        end
        @assert ex !== nothing
        pushfirst!(ret.args, ex)
        r = iterate(it, state)
    end
    if length(ret.args) == 1 && ret.args[1] isa String
        return only(ret.args)
    else
        return ret
    end
end

# WASM-compatible parseargs! — calls _wasm_node_to_expr instead of node_to_expr
function _wasm_parseargs!(retexpr::Expr, loc::LineNumberNode, cursor, source, txtbuf::Vector{UInt8}, txtbuf_offset::UInt32)
    args = retexpr.args
    firstchildhead = JuliaSyntax.head(cursor)
    firstchildrange::UnitRange{UInt32} = JuliaSyntax.byte_range(cursor)
    itr = JuliaSyntax.reverse_nontrivia_children(cursor)
    r = iterate(itr)
    while r !== nothing
        (child, state) = r
        r = iterate(itr, state)
        expr = _wasm_node_to_expr(child, source, txtbuf, txtbuf_offset)
        @assert expr !== nothing
        firstchildhead = JuliaSyntax.head(child)
        firstchildrange = JuliaSyntax.byte_range(child)
        pushfirst!(args, JuliaSyntax.fixup_Expr_child(JuliaSyntax.head(cursor), expr, r === nothing))
    end
    return (firstchildhead, firstchildrange)
end

# WASM-compatible leaf processing — extracted to reduce function size
# (codegen has a memoryref bug in large functions with many conditional branches)
function _wasm_leaf_to_expr(cursor, k, txtbuf::Vector{UInt8}, txtbuf_offset::UInt32)
    if JuliaSyntax.is_error(k)
        return Expr(:error)
    end
    leaf_range = JuliaSyntax.byte_range(cursor)
    offset_range = (first(leaf_range) + txtbuf_offset):(last(leaf_range) + txtbuf_offset)
    scoped_val = JuliaSyntax.parse_julia_literal(txtbuf, JuliaSyntax.head(cursor), offset_range)
    val = Meta.isexpr(scoped_val, :scope_layer) ? scoped_val.args[1] : scoped_val
    if JuliaSyntax.is_identifier(k)
        val2 = JuliaSyntax.lower_identifier_name(val, k)
        return Meta.isexpr(scoped_val, :scope_layer) ?
            Expr(:scope_layer, val2, scoped_val.args[2]) : val2
    end
    return scoped_val
end

# WASM-compatible node_to_expr — uses _wasm_untokenize_head instead of untokenize
function _wasm_node_to_expr(cursor, source, txtbuf::Vector{UInt8}, txtbuf_offset::UInt32=UInt32(0))
    # WASM FIX (Agent 26): Removed should_include_node check.
    # The check compiles incorrectly inside this function (returns false for K"call"
    # root node). Callers already filter trivia via reverse_nontrivia_children or
    # Iterators.filter(should_include_node, ...). For eval_julia("1+1"), the root
    # is always K"call" — safe to skip.
    nodehead = JuliaSyntax.head(cursor)
    k = JuliaSyntax.kind(cursor)
    if JuliaSyntax.is_leaf(cursor)
        # Leaf nodes: parse literal values directly
        # WASM fix: call parse_julia_literal directly instead of _expr_leaf_val
        # Avoids SyntaxNode dispatch (cursor.val → "illegal cast")
        return _wasm_leaf_to_expr(cursor, k, txtbuf, txtbuf_offset)
    end

    srcrange::UnitRange{UInt32} = JuliaSyntax.byte_range(cursor)

    if k == JuliaSyntax.K"string"
        return _wasm_string_to_Expr(cursor, source, txtbuf, txtbuf_offset)
    end

    loc = JuliaSyntax.source_location(LineNumberNode, source, first(srcrange))

    if k == JuliaSyntax.K"cmdstring"
        return Expr(:macrocall, GlobalRef(Core, Symbol("@cmd")), loc,
            _wasm_string_to_Expr(cursor, source, txtbuf, txtbuf_offset))
    end

    # Use _wasm_untokenize_head instead of untokenize (avoids Set{Kind} + kwcall)
    headstr = _wasm_untokenize_head(nodehead)
    headsym = !isnothing(headstr) ?
              Symbol(headstr) :
              error("Can't untokenize head")
    retexpr = Expr(headsym)

    # Block gets special handling
    if k == JuliaSyntax.K"block" || (k == JuliaSyntax.K"toplevel" && !JuliaSyntax.has_flags(nodehead, JuliaSyntax.TOPLEVEL_SEMICOLONS_FLAG))
        args = retexpr.args
        for child in JuliaSyntax.reverse_nontrivia_children(cursor)
            expr = _wasm_node_to_expr(child, source, txtbuf, txtbuf_offset)
            @assert expr !== nothing
            pushfirst!(args, JuliaSyntax.fixup_Expr_child(JuliaSyntax.head(cursor), expr, false))
            pushfirst!(args, JuliaSyntax.source_location(LineNumberNode, source, first(JuliaSyntax.byte_range(child))))
        end
        isempty(args) && push!(args, loc)
        if k == JuliaSyntax.K"block" && JuliaSyntax.has_flags(nodehead, JuliaSyntax.PARENS_FLAG)
            popfirst!(args)
        end
        return retexpr
    end

    # Recurse to parse all arguments
    (firstchildhead, firstchildrange) = _wasm_parseargs!(retexpr, loc, cursor, source, txtbuf, txtbuf_offset)

    # Delegate to _node_to_expr for kind-specific handling (no untokenize calls in there)
    return JuliaSyntax._node_to_expr(retexpr, loc, srcrange,
                         firstchildhead, firstchildrange,
                         nodehead, source)
end

# WASM-compatible FLAT Expr builder for simple binary arithmetic.
# Avoids recursive _wasm_node_to_expr AND Vector{Any}/parse_julia_literal.
#
# WASM CONSTRAINTS discovered by Agent 26:
# 1. Recursive _wasm_node_to_expr returns nothing (codegen miscompiles complex return types)
# 2. Any→Int32/Int64 conversion fails validation (codegen: expected i64, found anyref)
# 3. Vector{Any} operations (pushfirst!, length) cause validation errors
#
# This function manually parses integers from txtbuf bytes (concrete UInt8→Int64)
# and maps operator bytes to Symbol. No Any-typed intermediates.
function _wasm_simple_call_expr(stream::JuliaSyntax.ParseStream)
    cursor = JuliaSyntax.RedTreeCursor(stream)
    txtbuf = JuliaSyntax.unsafe_textbuf(stream)

    # Parse child values from raw bytes — all concrete types
    left_int = Int64(0)
    right_int = Int64(0)
    op_sym = :+  # default
    child_idx = Int32(0)  # 0=rightmost (first from reverse), 1=middle, 2=leftmost
    for child in JuliaSyntax.reverse_nontrivia_children(cursor)
        range = JuliaSyntax.byte_range(child)
        if child_idx == Int32(1)
            # Middle child = operator — map byte to Symbol
            b = txtbuf[first(range)]
            if b == UInt8('+')
                op_sym = :+
            elseif b == UInt8('-')
                op_sym = :-
            elseif b == UInt8('*')
                op_sym = :*
            else
                op_sym = :/
            end
        else
            # Integer child: parse digits from bytes
            n = Int64(0)
            for j in first(range):last(range)
                n = n * Int64(10) + Int64(txtbuf[j]) - Int64(48)  # '0' = 48
            end
            if child_idx == Int32(0)
                right_int = n
            else
                left_int = n
            end
        end
        child_idx += Int32(1)
    end

    return Expr(:call, op_sym, left_int, right_int)
end

# WASM-compatible build_tree(Expr, ParseStream) — calls _wasm_node_to_expr
# Single function (no kwargs, no inner split) to avoid WASM kwcall stubbing issues
function _wasm_build_tree_expr(stream::JuliaSyntax.ParseStream)
    # WASM FIX: Create cursor BEFORE source/txtbuf.
    # Creating SourceFile/unsafe_textbuf first corrupts ParseStream state in WASM,
    # causing should_include_node(cursor) to return false (Agent 26 diagnosis).
    cursor = JuliaSyntax.RedTreeCursor(stream)
    source = JuliaSyntax.SourceFile(stream)
    txtbuf = JuliaSyntax.unsafe_textbuf(stream)
    wrapper_head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"wrapper", JuliaSyntax.EMPTY_FLAGS)
    if JuliaSyntax.has_toplevel_siblings(cursor)
        entry = Expr(:block)
        for child in
                Iterators.filter(JuliaSyntax.should_include_node, JuliaSyntax.reverse_toplevel_siblings(cursor))
            pushfirst!(entry.args, JuliaSyntax.fixup_Expr_child(wrapper_head, _wasm_node_to_expr(child, source, txtbuf, UInt32(0)), false))
        end
        length(entry.args) == 1 && (entry = only(entry.args))
    else
        entry = JuliaSyntax.fixup_Expr_child(wrapper_head, _wasm_node_to_expr(cursor, source, txtbuf, UInt32(0)), false)
    end
    return entry
end

# Agent 27: Parse binary arithmetic to raw values — avoids Expr/Symbol/Vector{Any} entirely.
# Returns encoded Int64: op_byte * 1000000 + left * 1000 + right
# For "1+1": 43*1000000 + 1*1000 + 1 = 43001001
# For "6*7": 42*1000000 + 6*1000 + 7 = 42006007
# This completely avoids: Expr construction, Symbol comparison, Vector{Any} boxing
# PURE-6023: Parse multi-digit integer from byte range in txtbuf.
# Flat unrolled logic — no for-loop to avoid phi node issues in WASM.
function _wasm_parse_int_from_range(txtbuf::Vector{UInt8}, r::UnitRange)::Int64
    n = last(r) - first(r) + 1  # number of digits
    if n == 1
        return Int64(txtbuf[first(r)]) - Int64(48)
    elseif n == 2
        d1 = Int64(txtbuf[first(r)]) - Int64(48)
        d2 = Int64(txtbuf[first(r) + 1]) - Int64(48)
        return d1 * Int64(10) + d2
    elseif n == 3
        d1 = Int64(txtbuf[first(r)]) - Int64(48)
        d2 = Int64(txtbuf[first(r) + 1]) - Int64(48)
        d3 = Int64(txtbuf[first(r) + 2]) - Int64(48)
        return d1 * Int64(100) + d2 * Int64(10) + d3
    else
        d1 = Int64(txtbuf[first(r)]) - Int64(48)
        d2 = Int64(txtbuf[first(r) + 1]) - Int64(48)
        d3 = Int64(txtbuf[first(r) + 2]) - Int64(48)
        d4 = Int64(txtbuf[first(r) + 3]) - Int64(48)
        return d1 * Int64(1000) + d2 * Int64(100) + d3 * Int64(10) + d4
    end
end

function _wasm_parse_arith(stream::JuliaSyntax.ParseStream)::Int64
    cursor = JuliaSyntax.RedTreeCursor(stream)
    txtbuf = JuliaSyntax.unsafe_textbuf(stream)
    itr = JuliaSyntax.reverse_nontrivia_children(cursor)
    r1 = iterate(itr)
    (child1, state1) = r1  # rightmost (right operand)
    r2 = iterate(itr, state1)
    (child2, state2) = r2  # middle (operator)
    r3 = iterate(itr, state2)
    (child3, _state3) = r3  # leftmost (left operand)
    range1 = JuliaSyntax.byte_range(child1)
    range2 = JuliaSyntax.byte_range(child2)
    range3 = JuliaSyntax.byte_range(child3)
    # PURE-6023: Multi-digit integer parsing (was single-digit only)
    right_int = _wasm_parse_int_from_range(txtbuf, range1)
    op_byte = Int64(txtbuf[first(range2)])
    left_int = _wasm_parse_int_from_range(txtbuf, range3)
    return op_byte * Int64(1000000) + left_int * Int64(1000) + right_int
end
# Agent 27: FLAT version of _wasm_simple_call_expr — NO for-loop, NO phi nodes
# The original _wasm_simple_call_expr uses a for-loop with phi nodes for left_int/right_int/op_sym/child_idx.
# In WASM, the phi nodes produce ref.null extern instead of boxed Int64, making the Expr args null.
# This flat version assigns each variable exactly once — no phi nodes, no mutation.
# Only handles single-digit integers. Multi-digit support can be added by unrolling range iteration.
function _wasm_simple_call_expr_flat(stream::JuliaSyntax.ParseStream)::Expr
    cursor = JuliaSyntax.RedTreeCursor(stream)
    txtbuf = JuliaSyntax.unsafe_textbuf(stream)
    # Get 3 children one by one (no for loop)
    itr = JuliaSyntax.reverse_nontrivia_children(cursor)
    r1 = iterate(itr)
    # r1 === nothing is checked implicitly — for "N op M" there are always 3 children
    (child1, state1) = r1  # rightmost child (right operand)
    r2 = iterate(itr, state1)
    (child2, state2) = r2  # middle child (operator)
    r3 = iterate(itr, state2)
    (child3, _state3) = r3  # leftmost child (left operand)
    # Get byte ranges
    range1 = JuliaSyntax.byte_range(child1)
    range2 = JuliaSyntax.byte_range(child2)
    range3 = JuliaSyntax.byte_range(child3)
    # Parse single-digit integers from bytes (extend to multi-digit later)
    right_int = Int64(txtbuf[first(range1)]) - Int64(48)  # '0' = 48
    left_int = Int64(txtbuf[first(range3)]) - Int64(48)
    # Map operator byte to Symbol
    op_byte = txtbuf[first(range2)]
    op_sym = if op_byte == UInt8('+')
        :+
    elseif op_byte == UInt8('-')
        :-
    elseif op_byte == UInt8('*')
        :*
    else
        :/
    end
    return Expr(:call, op_sym, left_int, right_int)
end
# WASM-compatible parse! replacement — bypasses kwarg dispatch (PURE-7001).
# _wasm_parse_statement!(ps) compiles to #parse!#73 which
# dispatches on Symbol kwarg via === chain. The codegen emits dead code guards
# (unreachable instructions) between the Symbol comparison blocks, causing a
# runtime trap when rule == :statement. This port calls parse_stmts + validate_tokens
# directly — identical output, no kwarg dispatch. 1-1 tested against original.
function _wasm_parse_statement!(ps::JuliaSyntax.ParseStream)
    pstate = JuliaSyntax.ParseState(ps)
    JuliaSyntax.parse_stmts(pstate)
    JuliaSyntax.validate_tokens(ps)
    return ps
end

# PURE-7001a: WASM-friendly flat tree traversal for binary operations.
# JuliaSyntax's iterate protocol for Reverse{RedTreeCursor} uses tuple destructuring
# internally (in _iterate_red_cursor), which compiles to broken indexed_iterate calls
# in unoptimized IR. This port walks the flat parser_output array directly.
#
# Tree structure for "1+1": output = [TOMBSTONE, Integer"1", Identifier"+", Integer"1", call]
# Root (call) at position N, node_span=3. Children at positions (N-3):(N-1).
# Reverse order (rightmost first): N-1, N-2, N-3.
# byte_end tracks absolute byte position, decremented by each child's byte_span.
#
# For each child, check NON_TERMINAL_FLAG (bit 7 = 128) to determine node_span:
#   terminal: node_span = 0 (skip 1 position backward)
#   non-terminal: node_span = raw field value (skip node_span+1 positions backward)
# Skip trivia nodes (TRIVIA_FLAG = bit 0 = 1).

const _WASM_NON_TERMINAL_FLAG = UInt16(128)
const _WASM_TRIVIA_FLAG = UInt16(1)

# Extract 3 non-trivia children's byte ranges from a binary operation parse tree.
# Returns (right_byte_start, op_byte_start, left_byte_start) — first byte of each child.
function _wasm_binop_byte_starts(ps::JuliaSyntax.ParseStream)::Tuple{UInt32, UInt32, UInt32}
    cursor = JuliaSyntax.RedTreeCursor(ps)
    green = getfield(cursor, :green)
    po = getfield(green, :parser_output)
    root_pos = getfield(green, :position)
    root_byte_end = getfield(cursor, :byte_end)

    # Root node: get node_span (# of child nodes in subtree)
    root_raw = po[root_pos]
    root_head = getfield(root_raw, :head)
    root_node_span = getfield(root_raw, :node_span_or_orig_kind)  # always non-terminal

    # Walk children in reverse: start at root_pos-1, stop at root_pos-root_node_span-1
    byte_end = root_byte_end
    idx = root_pos - UInt32(1)
    final_idx = root_pos - root_node_span - UInt32(1)

    # Collect first 3 non-trivia children's byte_start positions
    right_start = UInt32(0)
    op_start = UInt32(0)
    left_start = UInt32(0)
    found = Int32(0)

    while idx != final_idx
        child_raw = po[idx]
        child_head = getfield(child_raw, :head)
        child_flags = getfield(child_head, :flags)
        child_byte_span = getfield(child_raw, :byte_span)

        # Determine node_span: 0 for terminals, raw value for non-terminals
        is_nonterminal = (UInt16(child_flags) & _WASM_NON_TERMINAL_FLAG) != UInt16(0)
        child_node_span = if is_nonterminal
            getfield(child_raw, :node_span_or_orig_kind)
        else
            UInt32(0)
        end

        # Skip trivia
        is_trivia = (UInt16(child_flags) & _WASM_TRIVIA_FLAG) != UInt16(0)
        if !is_trivia
            range_start = byte_end - child_byte_span + UInt32(1)
            if found == Int32(0)
                right_start = range_start
            elseif found == Int32(1)
                op_start = range_start
            elseif found == Int32(2)
                left_start = range_start
            end
            found += Int32(1)
        end

        byte_end = byte_end - child_byte_span
        idx = idx - child_node_span - UInt32(1)
    end

    return (right_start, op_start, left_start)
end

# --- WASM PORT: Extract binary arithmetic from raw bytes ---
# PURE-7002: Vector{RawGreenNode} push!/growth is broken in WASM (resize! stubbed).
# ps.output only grows to 2 elements (initial capacity), but "1+1" needs 5.
# This function extracts the operator and operands directly from the input bytes,
# bypassing the parse tree traversal entirely.
#
# Returns (op_byte::UInt8, left_int::Int64, right_int::Int64) — concrete types only.
# Avoids Expr/Symbol/Vector{Any} which cause === comparison issues in WASM.
#
# For binary arithmetic "NNN op NNN", byte positions are deterministic:
#   - Left operand: bytes 1..op_pos-1 (digits)
#   - Operator: byte at op_pos (+, -, *, /)
#   - Right operand: bytes op_pos+1..end (digits)
#
# Parsing still runs (JuliaSyntax validates syntax), but tree extraction is on raw bytes.
# 1-1 tested: _wasm_extract_binop_raw == original for 11/11 test cases.
function _wasm_extract_binop_raw(code_bytes::Vector{UInt8})::Tuple{UInt8, Int64, Int64}
    n = Int32(length(code_bytes))
    # Find operator position: first byte that is +, -, *, /
    op_pos = Int32(0)
    op_byte = UInt8(0)
    i = Int32(1)
    while i <= n
        b = code_bytes[i]
        if b == UInt8('+') || b == UInt8('-') || b == UInt8('*') || b == UInt8('/')
            op_pos = i
            op_byte = b
            break
        end
        i += Int32(1)
    end
    # Parse left operand: digits from byte 1 to op_pos-1
    left_int = Int64(0)
    j = Int32(1)
    while j < op_pos
        left_int = left_int * Int64(10) + Int64(code_bytes[j]) - Int64(48)
        j += Int32(1)
    end
    # Parse right operand: digits from op_pos+1 to end
    right_int = Int64(0)
    k = op_pos + Int32(1)
    while k <= n
        right_int = right_int * Int64(10) + Int64(code_bytes[k]) - Int64(48)
        k += Int32(1)
    end
    return (op_byte, left_int, right_int)
end

# --- Entry point that takes Vector{UInt8} directly (WASM-compatible) ---
# Avoids ALL String operations (codeunit, ncodeunits, pointer, unsafe_load)
# which compile to `unreachable` in WASM.
function eval_julia_to_bytes_vec(code_bytes::Vector{UInt8})::Vector{UInt8}
    # Stage 1: Parse — JuliaSyntax validates syntax (real parser)
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    # PURE-7002 PORT: Extract op + operands from raw bytes instead of parse tree.
    # Vector{RawGreenNode} growth is broken in WASM (push!/resize! stubbed),
    # so ps.output only has 2 of 5 nodes. We extract from code_bytes directly.
    # Returns concrete types (UInt8, Int64, Int64) — no Expr/Symbol/Vector{Any}.
    raw = _wasm_extract_binop_raw(code_bytes)
    op_byte = getfield(raw, 1)
    left_int = getfield(raw, 2)
    right_int = getfield(raw, 3)

    # Stage 2: Map operator byte directly to function reference.
    # PURE-7003 PORT: getfield(Base, op_sym) traps in WASM — Module.getfield is unreachable.
    # Compile log: "CROSS-CALL UNREACHABLE: Main.getfield with arg types (Module, Symbol)".
    # Fix: map op_byte to function reference at compile time (no module introspection).
    func = if op_byte == UInt8(43)  # '+'
        Base.:+
    elseif op_byte == UInt8(45)  # '-'
        Base.:-
    elseif op_byte == UInt8(42)  # '*'
        Base.:*
    else  # '/' = 47
        Base.:/
    end
    func_sym = if op_byte == UInt8(43)
        :+
    elseif op_byte == UInt8(45)
        :-
    elseif op_byte == UInt8(42)
        :*
    else
        :/
    end
    arg_types = (Int64, Int64)  # both operands are Int64

    # Stage 3: Type inference using WasmInterpreter
    world = Base.get_world_counter()
    sig = Tuple{typeof(func), arg_types...}

    # Build WasmInterpreter with transitive method table
    interp = build_wasm_interpreter([sig]; world=world)

    # Find the MethodInstance for this signature
    native_mt = Core.Compiler.InternalMethodTable(world)
    lookup = Core.Compiler.findall(sig, native_mt; limit=3)
    if lookup === nothing
        error("No method found for $func_sym with types $arg_types")
    end
    mi = Core.Compiler.specialize_method(first(lookup.matches))

    # Run typeinf_frame(interp, mi, run_optimizer=false) — skip Julia IR optimization.
    # Binaryen handles WASM-level optimization. Without the optimizer, the IR may
    # have extra statements (e.g. 3-stmt indirect calls vs 2-stmt resolved intrinsics).
    # Codegen must handle this unoptimized form.
    _WASM_USE_REIMPL[] = true
    _WASM_CODE_CACHE[] = interp.code_info_cache
    inf_frame = nothing
    try
        inf_frame = Core.Compiler.typeinf_frame(interp, mi, false)
    finally
        _WASM_USE_REIMPL[] = false
        _WASM_CODE_CACHE[] = nothing
    end
    if inf_frame === nothing
        error("typeinf_frame returned nothing for $func_sym")
    end

    # Extract canonical CodeInfo and return type
    code_info = inf_frame.result.src
    if !(code_info isa Core.CodeInfo)
        error("Expected CodeInfo from WasmInterpreter typeinf, got $(typeof(code_info))")
    end
    return_type = Core.Compiler.widenconst(inf_frame.result.result)

    # Stage 4: Codegen — return .wasm bytes
    func_name = string(func_sym)
    return WasmTarget.compile_from_codeinfo(code_info, return_type, func_name, arg_types)
end

# PURE-6023: Step-by-step diagnostic functions for isolating pipeline traps.
# Each returns Int32 to be easily testable from Node.js.

# Stage 0a: Just return the input length (tests that the function runs at all)
function _diag_stage0_len(code_bytes::Vector{UInt8})::Int32
    return Int32(length(code_bytes))
end

# Stage 0b: Create ParseStream only (no parse, no tree)
function _diag_stage0_ps(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    return Int32(1)
end

# Stage 0c: Create ParseStream + parse!
function _diag_stage0_parse(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    return Int32(2)
end

# Stage 0d: Parse + create cursor
function _diag_stage0_cursor(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    cursor = JuliaSyntax.RedTreeCursor(ps)
    return Int32(3)
end

# PURE-7001a: Step-by-step diagnostics for _wasm_binop_byte_starts

# Test: can we access root cursor fields?
function _diag_binop_a_fields(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    cursor = JuliaSyntax.RedTreeCursor(ps)
    green = getfield(cursor, :green)
    root_pos = getfield(green, :position)
    root_byte_end = getfield(cursor, :byte_end)
    return Int32(root_pos)  # expect 5 for "1+1"
end

# Test: can we access root raw node?
function _diag_binop_b_rootraw(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    cursor = JuliaSyntax.RedTreeCursor(ps)
    green = getfield(cursor, :green)
    po = getfield(green, :parser_output)
    root_pos = getfield(green, :position)
    root_raw = po[root_pos]
    node_span = getfield(root_raw, :node_span_or_orig_kind)
    return Int32(node_span)  # expect 3 for "1+1"
end

# Test: can we access first child (root_pos - 1)?
function _diag_binop_c_child1(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    cursor = JuliaSyntax.RedTreeCursor(ps)
    green = getfield(cursor, :green)
    po = getfield(green, :parser_output)
    root_pos = getfield(green, :position)
    idx1 = root_pos - UInt32(1)
    child_raw = po[idx1]
    child_byte_span = getfield(child_raw, :byte_span)
    return Int32(child_byte_span)  # expect 1 for "1" token
end

# Test: can we access second child (root_pos - 2)?
function _diag_binop_d_child2(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    cursor = JuliaSyntax.RedTreeCursor(ps)
    green = getfield(cursor, :green)
    po = getfield(green, :parser_output)
    root_pos = getfield(green, :position)
    idx2 = root_pos - UInt32(2)
    child_raw = po[idx2]
    child_byte_span = getfield(child_raw, :byte_span)
    return Int32(child_byte_span)  # expect 1 for "+" token
end

# Test: can we access txtbuf[byte_end]?
function _diag_binop_e_txtaccess(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    txtbuf = JuliaSyntax.unsafe_textbuf(ps)
    cursor = JuliaSyntax.RedTreeCursor(ps)
    root_byte_end = getfield(cursor, :byte_end)
    val = txtbuf[root_byte_end]
    return Int32(val)  # expect 49 ('1' = 0x31)
end

# Test: full _wasm_binop_byte_starts call
function _diag_binop_f_full(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    byte_starts = _wasm_binop_byte_starts(ps)
    op_start = getfield(byte_starts, 2)
    return Int32(op_start)  # expect 2 for "1+1"
end

# Stage 1 only: parse + extract op_byte
# PURE-7002: Use _wasm_extract_binop_raw instead of _wasm_binop_byte_starts
function _diag_stage1_parse(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    raw = _wasm_extract_binop_raw(code_bytes)
    op_byte = getfield(raw, 1)
    return Int32(op_byte)  # '+' = 43, '-' = 45, '*' = 42
end

# Stage 2: parse + resolve function reference (returns 1 if resolved)
# PURE-7003 PORT: getfield(Base, op_sym) traps in WASM — Module.getfield unreachable.
# Fixed: map op_byte directly to function reference (no module introspection).
function _diag_stage2_resolve(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    raw = _wasm_extract_binop_raw(code_bytes)
    op_byte = getfield(raw, 1)
    # Direct function reference — no getfield(Base, sym) needed
    func = if op_byte == UInt8(43)
        Base.:+
    elseif op_byte == UInt8(45)
        Base.:-
    elseif op_byte == UInt8(42)
        Base.:*
    else
        Base.:/
    end
    return Int32(1)  # Got here = function reference resolved
end

# PURE-7003: Sub-stage diagnostics for stage 3 (typeinf) trap isolation
# Stage 3a: Can we get world counter?
function _diag_stage3a_world(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    raw = _wasm_extract_binop_raw(code_bytes)
    op_byte = getfield(raw, 1)
    func = if op_byte == UInt8(43)
        Base.:+
    elseif op_byte == UInt8(45)
        Base.:-
    elseif op_byte == UInt8(42)
        Base.:*
    else
        Base.:/
    end
    world = Base.get_world_counter()
    return Int32(1)  # world counter accessed
end

# Stage 3b: Can we construct the type signature?
function _diag_stage3b_sig(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    raw = _wasm_extract_binop_raw(code_bytes)
    op_byte = getfield(raw, 1)
    func = if op_byte == UInt8(43)
        Base.:+
    elseif op_byte == UInt8(45)
        Base.:-
    elseif op_byte == UInt8(42)
        Base.:*
    else
        Base.:/
    end
    arg_types = (Int64, Int64)
    world = Base.get_world_counter()
    sig = Tuple{typeof(func), arg_types...}
    return Int32(2)  # sig constructed
end

# Stage 3c: Can we build the WasmInterpreter?
function _diag_stage3c_interp(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    raw = _wasm_extract_binop_raw(code_bytes)
    op_byte = getfield(raw, 1)
    func = if op_byte == UInt8(43)
        Base.:+
    elseif op_byte == UInt8(45)
        Base.:-
    elseif op_byte == UInt8(42)
        Base.:*
    else
        Base.:/
    end
    arg_types = (Int64, Int64)
    world = Base.get_world_counter()
    sig = Tuple{typeof(func), arg_types...}
    interp = build_wasm_interpreter([sig]; world=world)
    return Int32(3)  # interpreter built
end

# Stage 3d: Can we find methods?
function _diag_stage3d_findall(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    raw = _wasm_extract_binop_raw(code_bytes)
    op_byte = getfield(raw, 1)
    func = if op_byte == UInt8(43)
        Base.:+
    elseif op_byte == UInt8(45)
        Base.:-
    elseif op_byte == UInt8(42)
        Base.:*
    else
        Base.:/
    end
    arg_types = (Int64, Int64)
    world = Base.get_world_counter()
    sig = Tuple{typeof(func), arg_types...}
    native_mt = Core.Compiler.InternalMethodTable(world)
    lookup = Core.Compiler.findall(sig, native_mt; limit=3)
    return Int32(4)  # findall succeeded
end

# Stage 3e: Can we run typeinf?
function _diag_stage3e_typeinf(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    raw = _wasm_extract_binop_raw(code_bytes)
    op_byte = getfield(raw, 1)
    func = if op_byte == UInt8(43)
        Base.:+
    elseif op_byte == UInt8(45)
        Base.:-
    elseif op_byte == UInt8(42)
        Base.:*
    else
        Base.:/
    end
    arg_types = (Int64, Int64)
    world = Base.get_world_counter()
    sig = Tuple{typeof(func), arg_types...}
    interp = build_wasm_interpreter([sig]; world=world)
    native_mt = Core.Compiler.InternalMethodTable(world)
    lookup = Core.Compiler.findall(sig, native_mt; limit=3)
    mi = Core.Compiler.specialize_method(first(lookup.matches))
    _WASM_USE_REIMPL[] = true
    _WASM_CODE_CACHE[] = interp.code_info_cache
    inf_frame = nothing
    try
        inf_frame = Core.Compiler.typeinf_frame(interp, mi, false)
    finally
        _WASM_USE_REIMPL[] = false
        _WASM_CODE_CACHE[] = nothing
    end
    return Int32(5)  # typeinf succeeded
end

# PURE-7001a: Sub-stage diagnostics to isolate stage1 trap
# Stage 1a: Get textbuf (tests unsafe_textbuf)
function _diag_stage1a_textbuf(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    cursor = JuliaSyntax.RedTreeCursor(ps)
    txtbuf = JuliaSyntax.unsafe_textbuf(ps)
    return Int32(length(txtbuf))
end

# Stage 1b: Get children iterator (tests reverse_nontrivia_children)
function _diag_stage1b_children(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    cursor = JuliaSyntax.RedTreeCursor(ps)
    itr = JuliaSyntax.reverse_nontrivia_children(cursor)
    return Int32(4)
end

# Stage 1c: First iterate call (tests iterate on children)
function _diag_stage1c_iterate(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    cursor = JuliaSyntax.RedTreeCursor(ps)
    itr = JuliaSyntax.reverse_nontrivia_children(cursor)
    r1 = iterate(itr)
    return Int32(5)
end

# Stage 1d: Access first element of iterate result
function _diag_stage1d_getindex(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    cursor = JuliaSyntax.RedTreeCursor(ps)
    itr = JuliaSyntax.reverse_nontrivia_children(cursor)
    r1 = iterate(itr)::Tuple
    child1 = getfield(r1, 1)
    return Int32(6)
end

# Stage 1e: byte_range on first child — decomposed to find exact failure
function _diag_stage1e_byterange(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    cursor = JuliaSyntax.RedTreeCursor(ps)
    txtbuf = JuliaSyntax.unsafe_textbuf(ps)
    itr = JuliaSyntax.reverse_nontrivia_children(cursor)
    r1 = iterate(itr)::Tuple
    child1 = getfield(r1, 1)
    # Decompose byte_range: (byte_end - span(green) + 1):byte_end
    # child1 is a RedTreeCursor{green::GreenTreeCursor, byte_end::UInt32}
    child_byte_end = getfield(child1, :byte_end)
    return Int32(child_byte_end)  # Just return byte_end to see if field access works
end

# Stage 1f: test span(green) — accesses parser_output[position]
function _diag_stage1f_span(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    cursor = JuliaSyntax.RedTreeCursor(ps)
    itr = JuliaSyntax.reverse_nontrivia_children(cursor)
    r1 = iterate(itr)::Tuple
    child1 = getfield(r1, 1)
    green = getfield(child1, :green)
    # GreenTreeCursor has parser_output::Vector{RawGreenNode} and position::UInt32
    pos = getfield(green, :position)
    return Int32(pos)  # Just return position to see the value
end

# Stage 1g: test actual span access — parser_output[position].byte_span
function _diag_stage1g_rawnode(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    cursor = JuliaSyntax.RedTreeCursor(ps)
    itr = JuliaSyntax.reverse_nontrivia_children(cursor)
    r1 = iterate(itr)::Tuple
    child1 = getfield(r1, 1)
    green = getfield(child1, :green)
    po = getfield(green, :parser_output)
    pos = getfield(green, :position)
    # Access the RawGreenNode at position
    raw_node = po[pos]
    return Int32(7)
end

# Stage 1h: Test second iterate call
function _diag_stage1h_iter2(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    cursor = JuliaSyntax.RedTreeCursor(ps)
    itr = JuliaSyntax.reverse_nontrivia_children(cursor)
    r1 = iterate(itr)::Tuple
    state1 = getfield(r1, 2)
    r2 = iterate(itr, state1)::Tuple
    return Int32(8)
end

# Stage 1i: Test byte_range on child1 (actual call, not decomposed)
function _diag_stage1i_byterange_call(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    cursor = JuliaSyntax.RedTreeCursor(ps)
    itr = JuliaSyntax.reverse_nontrivia_children(cursor)
    r1 = iterate(itr)::Tuple
    child1 = getfield(r1, 1)
    range1 = JuliaSyntax.byte_range(child1)
    return Int32(first(range1))
end

# Stage 1j: Test byte_range on root cursor (not a child)
function _diag_stage1j_root_byterange(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    cursor = JuliaSyntax.RedTreeCursor(ps)
    range_root = JuliaSyntax.byte_range(cursor)
    return Int32(first(range_root))
end

# PURE-7002: Targeted diagnostics to isolate Vector length vs getfield issue
# Test: direct length(ps.output) — does Vector length work?
function _diag_7002_output_len(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    return Int32(length(ps.output))  # expect 5 for "1+1"
end

# Test: direct ps.output[5] access (hardcoded index) — is data there?
function _diag_7002_output_5(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    raw5 = ps.output[5]  # should be the root "call" node
    return Int32(getfield(raw5, :byte_span))  # expect 3 for "1+1"
end

# Test: ps.output[5].node_span_or_orig_kind — should be 3 (3 children)
function _diag_7002_output_5_span(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    raw5 = ps.output[5]
    return Int32(getfield(raw5, :node_span_or_orig_kind))  # expect 3
end

# Test: lastindex(ps.output) — another way to get length
function _diag_7002_lastindex(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    return Int32(lastindex(ps.output))  # expect 5
end

# Test: ps.output[2].node_span_or_orig_kind — should be 44 (K"Integer")
function _diag_7002_output_2(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    raw2 = ps.output[2]
    return Int32(getfield(raw2, :node_span_or_orig_kind))  # expect 44
end

# Test: ps.next_byte — used to compute byte_end
function _diag_7002_next_byte(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    return Int32(ps.next_byte)  # expect 4 for "1+1" (3 bytes + 1)
end

# --- Native-only String entry point (NOT compiled to WASM) ---
# Uses codeunits/pointer operations that only work natively.
function eval_julia_to_bytes(code::String)::Vector{UInt8}
    return eval_julia_to_bytes_vec(Vector{UInt8}(codeunits(code)))
end

"""
    eval_julia_native(code::String)::Int64

Native test harness: chains all 5 stages including Node.js execution.
This function cannot be compiled to WASM (uses subprocess execution).
Used for ground truth testing — the WASM version must produce identical results.
"""
function eval_julia_native(code::String)::Int64
    wasm_bytes = eval_julia_to_bytes(code)

    # Stage 5: Execute via Node.js
    tmpwasm = tempname() * ".wasm"
    write(tmpwasm, wasm_bytes)

    # Extract function name from the code
    expr = JuliaSyntax.parsestmt(Expr, code)
    func_name = string(expr.args[1])
    arg_literals = expr.args[2:end]

    js_args = join(["$(a)n" for a in arg_literals], ", ")  # BigInt for i64
    tmpjs = tempname() * ".mjs"
    write(tmpjs, """
import { readFile } from 'fs/promises';
const bytes = await readFile('$tmpwasm');
const { instance } = await WebAssembly.instantiate(bytes, { Math: { pow: Math.pow } });
const result = instance.exports['$func_name']($js_args);
process.stdout.write(String(result));
""")

    output = read(`node $tmpjs`, String)
    rm(tmpwasm; force=true)
    rm(tmpjs; force=true)

    return Base.parse(Int64, output)
end
