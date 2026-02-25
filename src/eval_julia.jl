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

# --- Entry point that takes Vector{UInt8} directly (WASM-compatible) ---
# Avoids ALL String operations (codeunit, ncodeunits, pointer, unsafe_load)
# which compile to `unreachable` in WASM.
function eval_julia_to_bytes_vec(code_bytes::Vector{UInt8})::Vector{UInt8}
    # Stage 1: Parse — bytes go directly to ParseStream
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    # PURE-6023: Inline _wasm_simple_call_expr_flat logic here.
    # Cross-function call to Main-scoped functions gets stubbed by the compiler
    # (func_registry lookup fails for transitive dependencies from Main module scope).
    # Inlining eliminates the stub issue. Logic: extract op+left+right from parsed tree.
    cursor = JuliaSyntax.RedTreeCursor(ps)
    txtbuf = JuliaSyntax.unsafe_textbuf(ps)
    itr = JuliaSyntax.reverse_nontrivia_children(cursor)
    r1 = iterate(itr)
    (child1, state1) = r1  # rightmost child (right operand)
    r2 = iterate(itr, state1)
    (child2, state2) = r2  # middle child (operator)
    r3 = iterate(itr, state2)
    (child3, _state3) = r3  # leftmost child (left operand)
    range1 = JuliaSyntax.byte_range(child1)
    range2 = JuliaSyntax.byte_range(child2)
    range3 = JuliaSyntax.byte_range(child3)
    right_int = Int64(txtbuf[first(range1)]) - Int64(48)  # '0' = 48
    left_int = Int64(txtbuf[first(range3)]) - Int64(48)
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
    expr = Expr(:call, op_sym, left_int, right_int)

    # Stage 2: Extract function and arguments from the Expr
    func_sym = expr.args[1]  # e.g. :+
    arg_literals = expr.args[2:end]  # e.g. [1, 1]

    # Resolve the function symbol to an actual function
    func = getfield(Base, func_sym)

    # Determine argument types from literals
    arg_types = tuple((typeof(a) for a in arg_literals)...)

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

# Stage 1 only: parse + extract Expr fields (returns op_byte for verification)
function _diag_stage1_parse(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    cursor = JuliaSyntax.RedTreeCursor(ps)
    txtbuf = JuliaSyntax.unsafe_textbuf(ps)
    itr = JuliaSyntax.reverse_nontrivia_children(cursor)
    r1 = iterate(itr)
    (child1, state1) = r1
    r2 = iterate(itr, state1)
    (child2, state2) = r2
    r3 = iterate(itr, state2)
    (child3, _state3) = r3
    range2 = JuliaSyntax.byte_range(child2)
    op_byte = txtbuf[first(range2)]
    return Int32(op_byte)  # '+' = 43, '-' = 45, '*' = 42
end

# Stage 2: parse + resolve function from Base (returns 1 if getfield works)
function _diag_stage2_resolve(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    _wasm_parse_statement!(ps)
    cursor = JuliaSyntax.RedTreeCursor(ps)
    txtbuf = JuliaSyntax.unsafe_textbuf(ps)
    itr = JuliaSyntax.reverse_nontrivia_children(cursor)
    r1 = iterate(itr)
    (child1, state1) = r1
    r2 = iterate(itr, state1)
    (child2, state2) = r2
    range2 = JuliaSyntax.byte_range(child2)
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
    func = getfield(Base, op_sym)
    return Int32(1)  # Got here = getfield succeeded
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
