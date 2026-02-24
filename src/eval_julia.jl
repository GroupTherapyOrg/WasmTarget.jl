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
    v[Int(idx)] = UInt8(val)
    return Int32(0)
end

# --- PURE-6024: Diagnostic functions to test individual pipeline stages ---
function eval_julia_test_ps_create(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    return Int32(1)
end

function eval_julia_test_parse_only(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps, rule=:statement)
    return Int32(1)
end

function eval_julia_test_build_tree(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps, rule=:statement)
    try
        expr = JuliaSyntax.build_tree(Expr, ps)
        return Int32(42)
    catch
        return Int32(-42)
    end
end

function eval_julia_test_parse(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps, rule=:statement)
    expr = JuliaSyntax.build_tree(Expr, ps)
    if expr isa Expr && expr.head === :call
        return Int32(length(expr.args))
    end
    return Int32(-1)
end

# --- PURE-6024 Agent 20: Fine-grained diagnostics ---
# Test String construction from bytes
function eval_julia_test_string_from_bytes(code_bytes::Vector{UInt8})::Int32
    try
        s = String(code_bytes)
        return Int32(length(s))
    catch
        return Int32(-1)
    end
end

# Test Base.parse(Int64, ...) on a simple string
function eval_julia_test_parse_int(code_bytes::Vector{UInt8})::Int32
    try
        s = String(code_bytes)
        n = Base.parse(Int64, s)
        return Int32(n)
    catch
        return Int32(-99)
    end
end

# Test SubString creation
function eval_julia_test_substring(code_bytes::Vector{UInt8})::Int32
    try
        s = String(code_bytes)
        ss = SubString(s, 1, 1)
        return Int32(length(ss))
    catch
        return Int32(-2)
    end
end

# Test build_tree with the parse tree — return output count (not ranges — field doesn't exist)
function eval_julia_test_tree_nranges(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        n = length(ps.output)
        return Int32(n)
    catch
        return Int32(-3)
    end
end

# --- PURE-6024 Agent 21: Step-by-step build_tree diagnostics ---
# Step A: SourceFile creation
function eval_julia_test_sourcefile(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        source = JuliaSyntax.SourceFile(ps)
        return Int32(1)
    catch
        return Int32(-1)
    end
end

# Step B: unsafe_textbuf
function eval_julia_test_textbuf(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        txtbuf = JuliaSyntax.unsafe_textbuf(ps)
        return Int32(length(txtbuf))
    catch
        return Int32(-1)
    end
end

# Step C: RedTreeCursor
function eval_julia_test_cursor(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        cursor = JuliaSyntax.RedTreeCursor(ps)
        return Int32(1)
    catch
        return Int32(-1)
    end
end

# Step D: has_toplevel_siblings
function eval_julia_test_toplevel(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        cursor = JuliaSyntax.RedTreeCursor(ps)
        ht = JuliaSyntax.has_toplevel_siblings(cursor)
        return ht ? Int32(1) : Int32(0)
    catch
        return Int32(-1)
    end
end

# Step E: node_to_expr — full call
function eval_julia_test_node_to_expr(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        source = JuliaSyntax.SourceFile(ps)
        txtbuf = JuliaSyntax.unsafe_textbuf(ps)
        cursor = JuliaSyntax.RedTreeCursor(ps)
        ht = JuliaSyntax.has_toplevel_siblings(cursor)
        if ht
            return Int32(-2)  # shouldn't happen for "1+1"
        end
        wrapper_head = JuliaSyntax.SyntaxHead(JuliaSyntax.K"wrapper", JuliaSyntax.EMPTY_FLAGS)
        e = JuliaSyntax.node_to_expr(cursor, source, txtbuf)
        return Int32(42)
    catch
        return Int32(-1)
    end
end

# Step E1: byte_range of cursor
function eval_julia_test_byte_range(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        cursor = JuliaSyntax.RedTreeCursor(ps)
        srcrange = JuliaSyntax.byte_range(cursor)
        return Int32(length(srcrange))
    catch
        return Int32(-1)
    end
end

# Step E2: source_location
function eval_julia_test_source_location(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        source = JuliaSyntax.SourceFile(ps)
        cursor = JuliaSyntax.RedTreeCursor(ps)
        srcrange = JuliaSyntax.byte_range(cursor)
        loc = JuliaSyntax.source_location(LineNumberNode, source, first(srcrange))
        return Int32(loc.line)
    catch
        return Int32(-1)
    end
end

# Step E3: untokenize (returns String from head)
function eval_julia_test_untokenize(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        cursor = JuliaSyntax.RedTreeCursor(ps)
        nodehead = JuliaSyntax.head(cursor)
        headstr = JuliaSyntax.untokenize(nodehead; include_flag_suff=false)
        if headstr === nothing
            return Int32(-2)
        end
        return Int32(length(headstr))
    catch
        return Int32(-1)
    end
end

# Step E3b: test untokenize(Kind; unique=true) directly
function eval_julia_test_untokenize_kind(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        cursor = JuliaSyntax.RedTreeCursor(ps)
        k = JuliaSyntax.kind(cursor)
        result = JuliaSyntax.untokenize(k; unique=true)
        if result === nothing
            return Int32(-2)
        end
        return Int32(length(result))
    catch
        return Int32(-1)
    end
end

# Step E3c: test untokenize(Kind; unique=false) — bypasses _nonunique check
function eval_julia_test_untokenize_kind_nouniq(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        cursor = JuliaSyntax.RedTreeCursor(ps)
        k = JuliaSyntax.kind(cursor)
        result = JuliaSyntax.untokenize(k; unique=false)
        return Int32(length(result))
    catch
        return Int32(-1)
    end
end

# Step E3d: test is_error(kind(head)) — should be false for K"call"
function eval_julia_test_is_error(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        cursor = JuliaSyntax.RedTreeCursor(ps)
        k = JuliaSyntax.kind(cursor)
        return JuliaSyntax.is_error(k) ? Int32(1) : Int32(0)
    catch
        return Int32(-1)
    end
end

# Step E4: _expr_leaf_val on a leaf child — just test it doesn't throw
function eval_julia_test_leaf_val(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        txtbuf = JuliaSyntax.unsafe_textbuf(ps)
        cursor = JuliaSyntax.RedTreeCursor(ps)
        count = Int32(0)
        for child in JuliaSyntax.reverse_nontrivia_children(cursor)
            if JuliaSyntax.is_leaf(child)
                val = JuliaSyntax._expr_leaf_val(child, txtbuf, UInt32(0))
                count += Int32(1)
            end
        end
        return count  # should be 3 for "1+1" (two ints + one symbol)
    catch
        return Int32(-1)
    end
end

# Step E5: parseargs! on the call node
function eval_julia_test_parseargs(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        source = JuliaSyntax.SourceFile(ps)
        txtbuf = JuliaSyntax.unsafe_textbuf(ps)
        cursor = JuliaSyntax.RedTreeCursor(ps)
        srcrange = JuliaSyntax.byte_range(cursor)
        loc = JuliaSyntax.source_location(LineNumberNode, source, first(srcrange))
        nodehead = JuliaSyntax.head(cursor)
        headstr = JuliaSyntax.untokenize(nodehead; include_flag_suff=false)
        headsym = Symbol(headstr)
        retexpr = Expr(headsym)
        (firstchildhead, firstchildrange) = JuliaSyntax.parseargs!(retexpr, loc, cursor, source, txtbuf, UInt32(0))
        return Int32(length(retexpr.args))
    catch
        return Int32(-1)
    end
end

# Step E6: just count children (test iteration without _expr_leaf_val)
function eval_julia_test_child_count(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        cursor = JuliaSyntax.RedTreeCursor(ps)
        count = Int32(0)
        for child in JuliaSyntax.reverse_nontrivia_children(cursor)
            count += Int32(1)
        end
        return count
    catch
        return Int32(-1)
    end
end

# Step E7: test string(Kind) directly — is Dict lookup working?
function eval_julia_test_kind_string(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        cursor = JuliaSyntax.RedTreeCursor(ps)
        k = JuliaSyntax.kind(cursor)
        s = string(k)
        return Int32(length(s))
    catch
        return Int32(-1)
    end
end

# Step E8: test is_leaf on first child
function eval_julia_test_child_is_leaf(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        cursor = JuliaSyntax.RedTreeCursor(ps)
        for child in JuliaSyntax.reverse_nontrivia_children(cursor)
            return JuliaSyntax.is_leaf(child) ? Int32(1) : Int32(0)
        end
        return Int32(-2)
    catch
        return Int32(-1)
    end
end

# Step E9: test byte_range of first child
function eval_julia_test_child_byte_range(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        cursor = JuliaSyntax.RedTreeCursor(ps)
        for child in JuliaSyntax.reverse_nontrivia_children(cursor)
            srcrange = JuliaSyntax.byte_range(child)
            return Int32(length(srcrange))
        end
        return Int32(-2)
    catch
        return Int32(-1)
    end
end

# Step E10z: test node_to_expr on a single leaf child
function eval_julia_test_leaf_node_to_expr(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        source = JuliaSyntax.SourceFile(ps)
        txtbuf = JuliaSyntax.unsafe_textbuf(ps)
        cursor = JuliaSyntax.RedTreeCursor(ps)
        for child in JuliaSyntax.reverse_nontrivia_children(cursor)
            if JuliaSyntax.is_leaf(child)
                e = JuliaSyntax.node_to_expr(child, source, txtbuf, UInt32(0))
                if e === nothing
                    return Int32(-3)
                end
                return Int32(1)
            end
        end
        return Int32(-2)
    catch
        return Int32(-1)
    end
end

# Step E10zz: replicate the EXACT leaf path of node_to_expr manually
function eval_julia_test_manual_leaf_path(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        source = JuliaSyntax.SourceFile(ps)
        txtbuf = JuliaSyntax.unsafe_textbuf(ps)
        cursor = JuliaSyntax.RedTreeCursor(ps)
        for child in JuliaSyntax.reverse_nontrivia_children(cursor)
            if JuliaSyntax.is_leaf(child)
                # Step 1: should_include_node
                if !JuliaSyntax.should_include_node(child)
                    return Int32(10)  # shouldn't happen
                end
                # Step 2: head + kind
                nodehead = JuliaSyntax.head(child)
                k = JuliaSyntax.kind(child)
                # Step 3: byte_range
                srcrange = JuliaSyntax.byte_range(child)::UnitRange{UInt32}
                # Step 4: is_leaf check
                if !JuliaSyntax.is_leaf(child)
                    return Int32(11)  # shouldn't happen
                end
                # Step 5: is_error check
                if JuliaSyntax.is_error(k)
                    return Int32(12)
                end
                # Step 6: _expr_leaf_val (inlined to parse_julia_literal)
                scoped_val = JuliaSyntax.parse_julia_literal(txtbuf, nodehead, srcrange)
                # Step 7: @isexpr check
                is_scope = scoped_val isa Expr && scoped_val.head === :scope_layer
                val = is_scope ? scoped_val.args[1] : scoped_val
                # Step 8: type checks
                if val isa Union{Int128, UInt128, BigInt}
                    return Int32(13)
                end
                if JuliaSyntax.is_identifier(k)
                    return Int32(14)
                end
                # Step 9: return scoped_val (for Integer "1", this is just 1)
                return Int32(42)  # success!
            end
        end
        return Int32(-2)
    catch
        return Int32(-1)
    end
end

# Step E10yz: test boolean negation of should_include_node
function eval_julia_test_not_should_include(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        cursor = JuliaSyntax.RedTreeCursor(ps)
        for child in JuliaSyntax.reverse_nontrivia_children(cursor)
            si = JuliaSyntax.should_include_node(child)
            nsi = !si
            # si should be true, nsi should be false
            # Return encoded: si*10 + nsi (expected: 10, i.e. true=1 false=0)
            return Int32(si ? 10 : 0) + Int32(nsi ? 1 : 0)
        end
        return Int32(-2)
    catch
        return Int32(-1)
    end
end

# Step E10yw: test if node_to_expr CALLED from a simple wrapper returns nothing
function eval_julia_test_node_to_expr_direct(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        source = JuliaSyntax.SourceFile(ps)
        txtbuf = JuliaSyntax.unsafe_textbuf(ps)
        cursor = JuliaSyntax.RedTreeCursor(ps)
        # Call node_to_expr with EXPLICIT 4th arg (bypass default arg dispatch)
        e = JuliaSyntax.node_to_expr(cursor, source, txtbuf, UInt32(0))
        if e === nothing
            return Int32(-3)
        end
        if e isa Expr
            return Int32(length(e.args))
        end
        return Int32(99)
    catch
        return Int32(-1)
    end
end

# Step E10y: test should_include_node on first leaf child AND ROOT
function eval_julia_test_should_include(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        cursor = JuliaSyntax.RedTreeCursor(ps)
        # Test ROOT should_include_node
        root_si = JuliaSyntax.should_include_node(cursor)
        root_trivia = JuliaSyntax.is_trivia(cursor)
        root_error = JuliaSyntax.is_error(cursor)
        # Encode: root_si*100 + root_trivia*10 + root_error
        # Expected: 100 (si=true, trivia=false, error=false)
        return Int32(root_si ? 100 : 0) + Int32(root_trivia ? 10 : 0) + Int32(root_error ? 1 : 0)
    catch
        return Int32(-1)
    end
end

# Step E10a: test head(child) on leaf
function eval_julia_test_child_head(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        cursor = JuliaSyntax.RedTreeCursor(ps)
        for child in JuliaSyntax.reverse_nontrivia_children(cursor)
            if JuliaSyntax.is_leaf(child)
                h = JuliaSyntax.head(child)
                return Int32(1)
            end
        end
        return Int32(-2)
    catch
        return Int32(-1)
    end
end

# Step E10b: test parse_julia_literal directly on first leaf
function eval_julia_test_parse_literal(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        txtbuf = JuliaSyntax.unsafe_textbuf(ps)
        cursor = JuliaSyntax.RedTreeCursor(ps)
        for child in JuliaSyntax.reverse_nontrivia_children(cursor)
            if JuliaSyntax.is_leaf(child)
                h = JuliaSyntax.head(child)
                br = JuliaSyntax.byte_range(child)
                val = JuliaSyntax.parse_julia_literal(txtbuf, h, br)
                return Int32(1)
            end
        end
        return Int32(-2)
    catch
        return Int32(-1)
    end
end

# Step E10c: test byte_range .+ UInt32(0) broadcast on child
function eval_julia_test_child_br_broadcast(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        cursor = JuliaSyntax.RedTreeCursor(ps)
        for child in JuliaSyntax.reverse_nontrivia_children(cursor)
            if JuliaSyntax.is_leaf(child)
                br = JuliaSyntax.byte_range(child)
                adjusted = br .+ UInt32(0)
                return Int32(length(adjusted))
            end
        end
        return Int32(-2)
    catch
        return Int32(-1)
    end
end

# Step E10: test getindex with UInt32 range (potential issue)
function eval_julia_test_uint32_getindex(code_bytes::Vector{UInt8})::Int32
    try
        r = UInt32(1):UInt32(1)
        slice = code_bytes[r]
        return Int32(length(slice))
    catch
        return Int32(-1)
    end
end

# --- Agent 22: Field-level diagnostics ---
# Test 1: Read textbuf BEFORE parse (is constructor storing it correctly?)
function eval_julia_test_textbuf_before_parse(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    # NO parse! call
    return Int32(length(JuliaSyntax.unsafe_textbuf(ps)))
end

# Test 2: Encode multiple ParseStream field values in one int
# Returns: textbuf_len * 10000 + output_len * 100 + next_byte
function eval_julia_test_ps_fields(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    try
        tb_len = length(JuliaSyntax.unsafe_textbuf(ps))
        out_len = length(ps.output)
        nb = ps.next_byte
        return Int32(tb_len * 10000 + out_len * 100 + nb)
    catch
        return Int32(-1)
    end
end

# Test 3: Store a Vector{UInt8} in a mutable struct and read it back
# This tests if Vector-in-struct field access works in general
mutable struct VecHolder
    data::Vector{UInt8}
    count::Int64
end

function eval_julia_test_vec_in_struct(code_bytes::Vector{UInt8})::Int32
    holder = VecHolder(code_bytes, Int64(42))
    # Read back the stored vector's length
    stored = holder.data
    return Int32(length(stored))
end

# Test 4: Input vector length directly (baseline)
function eval_julia_test_input_len(code_bytes::Vector{UInt8})::Int32
    return Int32(length(code_bytes))
end

# Test 5: Read textbuf right after constructor, get first byte
function eval_julia_test_textbuf_first_byte(code_bytes::Vector{UInt8})::Int32
    ps = JuliaSyntax.ParseStream(code_bytes)
    tb = JuliaSyntax.unsafe_textbuf(ps)
    if length(tb) == 0
        return Int32(-100)  # textbuf is empty!
    end
    return Int32(tb[1])  # should be 49 for '1'
end

# --- Agent 22 Round 2: Root cause diagnostics for length() bug ---
# length(v::Vector{UInt8}) returns 0 for ALL vectors!
# But String(v) works (data array has correct bytes).
# Hypothesis: size tuple is 0, or length() reads wrong location.

# Test 6: Create a Vector INSIDE WASM and return its length
# Bypasses JS boundary entirely — tests if Vector constructor sets size tuple
function eval_julia_test_fresh_vec_len(code_bytes::Vector{UInt8})::Int32
    v = Vector{UInt8}(undef, Int64(5))
    return Int32(length(v))
end

# Test 7: Use the data array length directly via arrayref/arraylen
# String(v) succeeds because it uses the raw array, not the size tuple
function eval_julia_test_array_nvals(code_bytes::Vector{UInt8})::Int32
    # Try to access elements directly — if data array exists with 3 elements,
    # indexing should work even if length() is wrong
    try
        b1 = code_bytes[1]  # should be 49 ('1')
        return Int32(b1)
    catch
        return Int32(-999)
    end
end

# Test 8: Check if code_bytes[1] works when we KNOW data exists
# Returns the sum of first N bytes where N is derived from the data array
function eval_julia_test_getindex_works(code_bytes::Vector{UInt8})::Int32
    try
        # These should be '1', '+', '1' = 49, 43, 49
        return Int32(code_bytes[1] + code_bytes[2] + code_bytes[3])
    catch
        return Int32(-999)
    end
end

# Test 9: Simple constant to verify the testing works
function eval_julia_test_constant(code_bytes::Vector{UInt8})::Int32
    return Int32(42)
end

# Test 10: Create, setindex!, getindex ALL within WASM — no JS boundary
function eval_julia_test_set_and_read(code_bytes::Vector{UInt8})::Int32
    v = Vector{UInt8}(undef, Int64(3))
    v[1] = UInt8(99)
    return Int32(v[1])
end

# Test 11: Create, setindex! via setindex!, getindex — longer chain
function eval_julia_test_set_read_chain(code_bytes::Vector{UInt8})::Int32
    v = Vector{UInt8}(undef, Int64(5))
    v[1] = UInt8(10)
    v[2] = UInt8(20)
    v[3] = UInt8(30)
    return Int32(v[1] + v[2] + v[3])  # should be 60
end

# Test 12: Copy from input to new vector and read back
function eval_julia_test_copy_byte(code_bytes::Vector{UInt8})::Int32
    # Read first byte from code_bytes, store in new vector, read back
    v = Vector{UInt8}(undef, Int64(1))
    # If code_bytes[1] works, store it; if not, store 77
    try
        b = code_bytes[1]
        v[1] = b
    catch
        v[1] = UInt8(77)
    end
    return Int32(v[1])
end

# Test 13: Call make_byte_vec + set_byte_vec! from WITHIN WASM
# This isolates JS boundary vs. function-to-function issues
function eval_julia_test_make_set_read(code_bytes::Vector{UInt8})::Int32
    v = make_byte_vec(Int32(3))
    set_byte_vec!(v, Int32(1), Int32(49))
    set_byte_vec!(v, Int32(2), Int32(43))
    set_byte_vec!(v, Int32(3), Int32(49))
    return Int32(v[1])  # should be 49
end

# Test 14: Same as 13 but check length
function eval_julia_test_make_len(code_bytes::Vector{UInt8})::Int32
    v = make_byte_vec(Int32(3))
    return Int32(length(v))  # should be 3
end

# Test 15: FULL PARSE PIPELINE — takes individual bytes, no JS boundary for Vector
function eval_julia_test_parse_3bytes(b1::Int32, b2::Int32, b3::Int32)::Int32
    code_bytes = Vector{UInt8}(undef, Int64(3))
    code_bytes[1] = UInt8(b1)
    code_bytes[2] = UInt8(b2)
    code_bytes[3] = UInt8(b3)
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps; rule=:statement)
    expr = JuliaSyntax.build_tree(Expr, ps)
    if !(expr isa Expr && expr.head === :call)
        return Int32(-1)
    end
    nargs = length(expr.args)
    return Int32(nargs)  # should be 3 for "1+1" → :call, :+, 1, 1
end

# --- Entry point that takes Vector{UInt8} directly (WASM-compatible) ---
# Avoids ALL String operations (codeunit, ncodeunits, pointer, unsafe_load)
# which compile to `unreachable` in WASM.
function eval_julia_to_bytes_vec(code_bytes::Vector{UInt8})::Vector{UInt8}
    # Stage 1: Parse — bytes go directly to ParseStream
    ps = JuliaSyntax.ParseStream(code_bytes)
    JuliaSyntax.parse!(ps, rule=:statement)
    expr = JuliaSyntax.build_tree(Expr, ps)

    # Stage 2: Extract function and arguments from the Expr
    if !(expr isa Expr && expr.head === :call)
        error("eval_julia only supports call expressions, got: $(repr(expr))")
    end

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
