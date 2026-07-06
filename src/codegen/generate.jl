# ============================================================================
# Code Generation
# ============================================================================


"""
    _get_local_type(ctx, local_idx) -> Union{WasmValType, Nothing}

Get the Wasm type of a local variable by its index. Parameters come first,
then additional locals from ctx.locals.
"""
function _get_local_type(ctx::AbstractCompilationContext, local_idx::Int)::Union{WasmValType, Nothing}
    if local_idx < ctx.n_params
        # It's a parameter — get type from arg_types (skip WasmGlobal args)
        param_count = 0
        for (i, T) in enumerate(ctx.arg_types)
            if i in ctx.global_args
                continue
            end
            if param_count == local_idx
                return get_concrete_wasm_type(T, ctx.mod, ctx.type_registry)
            end
            param_count += 1
        end
        return nothing
    else
        # It's an additional local
        local_offset = local_idx - ctx.n_params
        if local_offset >= 0 && local_offset < length(ctx.locals)
            return ctx.locals[local_offset + 1]  # 1-indexed
        end
        return nothing
    end
end

"""
Generate Wasm bytecode from Julia CodeInfo.
Uses a block-based translation for control flow.
"""
function generate_body(ctx::AbstractCompilationContext)::Vector{UInt8}
    ENV["WT_CUR_FN"] = try first(string(ctx.func_ref), 80) catch; "?" end   # debug context for builder errors
    code = ctx.code_info.code
    n = length(code)

    # Analyze control flow to find basic block structure
    blocks = analyze_blocks(code)

    # Generate code using structured control flow
    bytes = generate_structured(ctx, blocks)

    # PURE-6025: Fix dead returns at the very end of a function body.
    # This happens when all paths inside the block return, leaving a dead return
    # with empty stack. Two patterns:
    # Pattern 1: [end] [return] [unreachable] [end] — dead return before unreachable
    # Pattern 2: [return] [end] [return] [end] — both if/else branches return
    # Forward-parse to find genuine instruction boundaries: raw backward byte checks
    # misfire when a LEB immediate collides with an opcode — e.g. `local.get 1418`
    # encodes as [0x20, 0x8a, 0x0b] and the trailing 0x0b reads as END, turning
    # [local.get N][return][unreachable][end] into a false Pattern-1 match that
    # rewrites a LIVE return to unreachable (gap 4c8236022172).
    if length(bytes) >= 4 && bytes[end] == Opcode.END
        _tail = _last_instr_starts(bytes, 4)
        if length(_tail) == 4
            _t1, _t2, _t3, _t4 = bytes[_tail[1]], bytes[_tail[2]], bytes[_tail[3]], bytes[_tail[4]]
            if _t1 == Opcode.END && _t2 == Opcode.RETURN && _t3 == Opcode.UNREACHABLE && _t4 == Opcode.END
                bytes[_tail[2]] = Opcode.UNREACHABLE  # Pattern 1: dead RETURN after END
            elseif _t1 == Opcode.RETURN && _t2 == Opcode.END && _t3 == Opcode.RETURN && _t4 == Opcode.END
                bytes[_tail[3]] = Opcode.UNREACHABLE  # Pattern 2: dead final RETURN
            end
        end
    end

    # PURE-6022: Strip excess bytes after the function body's closing `end`.
    # The flow generator may emit dead code (unreachable, br, etc.) after all blocks
    # are closed, creating bytes outside the function body expression. The WASM spec
    # requires: func = locals* expr, where expr = instr* end. Any bytes after the
    # expression's closing `end` cause "operators remaining after end of function body."
    bytes = strip_excess_after_function_end(bytes)

    return bytes
end






# Helper: number of LEB128 operands to skip for a given opcode
function _skip_leb_count(op::UInt8)::Int
    # local.get/set/tee, global.get/set
    (op == 0x20 || op == 0x21 || op == 0x22 || op == 0x23 || op == 0x24) && return 1
    # br, br_if
    (op == 0x0C || op == 0x0D) && return 1
    # throw (tag index)
    op == 0x08 && return 1
    # br_on_null / br_on_non_null (label)
    (op == 0xD5 || op == 0xD6) && return 1
    # call
    op == 0x10 && return 1
    # call_indirect (type_idx, table_idx)
    op == 0x11 && return 2
    # ref.null (heap type)
    op == 0xD0 && return 1
    # ref.func
    op == 0xD2 && return 1
    # block/loop/if (blocktype)
    (op == 0x02 || op == 0x03 || op == 0x04) && return 1
    # i32.const, i64.const (signed LEB128 value)
    (op == 0x41 || op == 0x42) && return 1
    # memory load/store instructions (align + offset)
    (op >= 0x28 && op <= 0x3E) && return 2
    # memory.size, memory.grow
    (op == 0x3F || op == 0x40) && return 1
    return 0
end

# Helper: number of LEB128 operands to skip for a GC prefix sub-opcode
function _skip_gc_leb_count(sub_op::UInt8)::Int
    sub_op == 0x00 && return 1  # struct.new
    sub_op == 0x01 && return 1  # struct.new_default
    (sub_op >= 0x02 && sub_op <= 0x05) && return 2  # struct.get/get_s/get_u/set
    (sub_op == 0x06 || sub_op == 0x07) && return 1  # array.new/new_default
    sub_op == 0x08 && return 2  # array.new_fixed (type, count)
    (sub_op == 0x09 || sub_op == 0x0a) && return 2  # array.new_data/new_elem (type, seg)
    (sub_op >= 0x0b && sub_op <= 0x0e) && return 1  # array.get/get_s/get_u/set
    sub_op == 0x0f && return 0  # array.len
    sub_op == 0x10 && return 1  # array.fill (type)
    (sub_op >= 0x11 && sub_op <= 0x13) && return 2  # array.copy/init_data/init_elem
    (sub_op >= 0x14 && sub_op <= 0x17) && return 1  # ref.test/cast
    (sub_op == 0x1a || sub_op == 0x1b) && return 0  # extern/any convert
    (sub_op >= 0x1c && sub_op <= 0x1e) && return 0  # i31 ops
    return 0
end

"""
Forward-parse an instruction byte buffer and return the start index of the LAST
instruction, or 0 if the buffer is empty / truncated mid-instruction. Backward
scans for "does this buffer end with local.get?" misfire when an immediate byte
collides with an opcode — e.g. `i32.const 32` encodes as [0x41, 0x20] and the
0x20 immediate reads as LOCAL_GET (the titlecase ±32 wrong-value family, where
ASCII case distance is exactly 32). A forward parse from a known instruction
boundary is unambiguous.
"""
function _last_instr_start(bytes::Vector{UInt8})::Int
    i = 1
    n = length(bytes)
    last_start = 0
    while i <= n
        last_start = i
        i = _instr_next(bytes, i)
        i == 0 && return 0
    end
    return last_start
end

"""
Advance past the single instruction starting at index `i`; return the index of
the next instruction, or 0 if the buffer ends mid-instruction.
"""
function _instr_next(bytes::Vector{UInt8}, i::Int)::Int
    n = length(bytes)
    op = bytes[i]
    if op == 0xFB  # GC prefix: sub-opcode + LEB operands
        i + 1 > n && return 0
        sub_op = bytes[i + 1]
        i += 2
        for _ in 1:_skip_gc_leb_count(sub_op)
            while true
                i > n && return 0
                b = bytes[i]; i += 1
                (b & 0x80) == 0 && break
            end
        end
    elseif op == 0x43  # f32.const: 4 raw payload bytes
        i + 4 > n && return 0
        i += 5
    elseif op == 0x44  # f64.const: 8 raw payload bytes
        i + 8 > n && return 0
        i += 9
    elseif op == 0xFC  # saturating-trunc / misc prefix: sub-opcode LEB
        i += 1
        while true
            i > n && return 0
            b = bytes[i]; i += 1
            (b & 0x80) == 0 && break
        end
    elseif op == 0x0E  # br_table: count N, then N+1 label LEBs
        i += 1
        cnt = 0; shift = 0
        while true
            i > n && return 0
            b = bytes[i]; i += 1
            cnt |= (Int(b & 0x7f) << shift); shift += 7
            (b & 0x80) == 0 && break
        end
        for _ in 1:(cnt + 1)
            while true
                i > n && return 0
                b = bytes[i]; i += 1
                (b & 0x80) == 0 && break
            end
        end
    elseif op == 0x1F  # try_table: blocktype, count N, then N catch clauses
        i += 1
        i > n && return 0
        # blocktype LEB (single byte for valtypes/void; signed LEB for type idx)
        while true
            i > n && return 0
            b = bytes[i]; i += 1
            (b & 0x80) == 0 && break
        end
        cnt = 0; shift = 0
        while true
            i > n && return 0
            b = bytes[i]; i += 1
            cnt |= (Int(b & 0x7f) << shift); shift += 7
            (b & 0x80) == 0 && break
        end
        for _ in 1:cnt
            i > n && return 0
            kind = bytes[i]; i += 1
            # catch (0x00) / catch_ref (0x01): tag LEB + label LEB;
            # catch_all (0x02) / catch_all_ref (0x03): label LEB only
            nlebs = kind <= 0x01 ? 2 : 1
            for _ in 1:nlebs
                while true
                    i > n && return 0
                    b = bytes[i]; i += 1
                    (b & 0x80) == 0 && break
                end
            end
        end
    else
        i += 1
        for _ in 1:_skip_leb_count(op)
            while true
                i > n && return 0
                b = bytes[i]; i += 1
                (b & 0x80) == 0 && break
            end
        end
    end
    return i
end

"""
Forward-parse an instruction buffer and return the start indices of the last
`k` instructions (oldest first). Returns fewer than `k` entries if the buffer
holds fewer instructions, and an empty vector if it is truncated mid-instruction.
"""
function _last_instr_starts(bytes::Vector{UInt8}, k::Int)::Vector{Int}
    i = 1
    n = length(bytes)
    starts = Int[]
    while i <= n
        push!(starts, i)
        length(starts) > k && popfirst!(starts)
        i = _instr_next(bytes, i)
        i == 0 && return Int[]
    end
    return starts
end


function strip_excess_after_function_end(bytes::Vector{UInt8})::Vector{UInt8}
    depth = 0
    i = 1
    while i <= length(bytes)
        op = bytes[i]

        # Track block depth
        if op == 0x02 || op == 0x03 || op == 0x04  # block, loop, if
            depth += 1
            i += 1
            # Skip blocktype (void=0x40, or signed LEB128 type index/value type)
            if i <= length(bytes)
                if bytes[i] == 0x40  # void
                    i += 1
                else
                    # LEB128 blocktype
                    while i <= length(bytes)
                        b = bytes[i]
                        i += 1
                        (b & 0x80) == 0 && break
                    end
                end
            end
            continue
        end

        if op == 0x05  # else — doesn't change depth
            i += 1
            continue
        end

        if op == 0x0B  # end
            if depth == 0
                # This is the function body's closing `end`.
                # Truncate everything after this byte.
                if i < length(bytes)
                    return bytes[1:i]
                end
                return bytes
            end
            depth -= 1
            i += 1
            continue
        end

        # Skip GC prefix instructions with LEB128 params
        if op == 0xFB && i + 1 <= length(bytes)
            i += 1  # GC prefix
            sub_op = bytes[i]
            i += 1
            n_leb = if sub_op == 0x00; 1                          # struct.new
                    elseif sub_op == 0x01; 1                          # struct.new_default
                    elseif sub_op in (0x02, 0x03, 0x04, 0x05); 2     # struct.get/get_s/get_u/set
                    elseif sub_op in (0x06, 0x07); 1                  # array.new/new_default
                    elseif sub_op == 0x08; 2                          # array.new_fixed
                    elseif sub_op in (0x09, 0x0a); 2                  # array.new_data/new_elem
                    elseif sub_op in (0x0b, 0x0c, 0x0d, 0x0e); 1     # array.get/get_s/get_u/set
                    elseif sub_op == 0x0f; 0                          # array.len
                    elseif sub_op == 0x10; 1                          # array.fill
                    elseif sub_op == 0x11; 2                          # array.copy
                    elseif sub_op in (0x12, 0x13); 2                  # array.init_data/init_elem
                    elseif sub_op in (0x14, 0x15, 0x16, 0x17); 1     # ref.test/cast variants
                    elseif sub_op in (0x1a, 0x1b); 0                  # any_convert_extern/extern_convert_any
                    elseif sub_op in (0x1c, 0x1d, 0x1e); 0           # ref.i31/i31.get_s/i31.get_u
                    else 0
                    end
            for _ in 1:n_leb
                while i <= length(bytes)
                    b = bytes[i]; i += 1
                    (b & 0x80) == 0 && break
                end
            end
            continue
        end

        # Skip f32.const (4 raw bytes) and f64.const (8 raw bytes)
        if op == 0x43 && i + 4 <= length(bytes)
            i += 5; continue
        end
        if op == 0x44 && i + 8 <= length(bytes)
            i += 9; continue
        end

        # P2-batch12: opcodes with non-trivial immediates the decoder previously
        # treated as single-byte. Mis-skipping makes the scanner read an OPERAND
        # byte as an opcode — an operand byte of 0x0B then looks like the
        # function's closing `end` at depth 0 and TRUNCATES the real tail.
        # select_t's type-index operand was the trigger: type indices shift per
        # module, so the same function validated in one module and lost its last
        # 9 instructions in another (Ryu kernel, gaps 19d59e9a61b3/b72318c9598c).
        _skip_leb() = (while i <= length(bytes); b = bytes[i]; i += 1; (b & 0x80) == 0 && break; end)
        if op == 0x08  # throw: tag index LEB
            i += 1; _skip_leb(); continue
        end
        if op == 0x0E  # br_table: vec(label) + default label
            i += 1
            cnt = 0; shift = 0
            while i <= length(bytes)
                b = bytes[i]; i += 1
                cnt |= Int(b & 0x7f) << shift
                (b & 0x80) == 0 && break
                shift += 7
            end
            for _ in 1:(cnt + 1); _skip_leb(); end
            continue
        end
        if op == 0x1C  # select_t: vec(valtype); each valtype is 1 byte, or 0x63/0x64 + heaptype LEB
            i += 1
            cnt = 0; shift = 0
            while i <= length(bytes)
                b = bytes[i]; i += 1
                cnt |= Int(b & 0x7f) << shift
                (b & 0x80) == 0 && break
                shift += 7
            end
            for _ in 1:cnt
                i > length(bytes) && break
                vt = bytes[i]; i += 1
                (vt == 0x63 || vt == 0x64) && _skip_leb()  # ref null ht / ref ht
            end
            continue
        end
        if op == 0x1F  # try_table: blocktype + vec(catch clause); OPENS A FRAME
            depth += 1
            i += 1
            if i <= length(bytes)
                if bytes[i] == 0x40
                    i += 1
                else
                    _skip_leb()
                end
            end
            cnt = 0; shift = 0
            while i <= length(bytes)
                b = bytes[i]; i += 1
                cnt |= Int(b & 0x7f) << shift
                (b & 0x80) == 0 && break
                shift += 7
            end
            for _ in 1:cnt
                i > length(bytes) && break
                kind = bytes[i]; i += 1
                # 0x00 catch tag+label, 0x01 catch_ref tag+label: 2 LEBs;
                # 0x02 catch_all label, 0x03 catch_all_ref label: 1 LEB
                (kind == 0x00 || kind == 0x01) && _skip_leb()
                _skip_leb()
            end
            continue
        end

        # Skip instructions with LEB128 operands
        n_skip = if op == 0x20 || op == 0x21 || op == 0x22; 1      # local.get/set/tee
                 elseif op == 0x23 || op == 0x24; 1                  # global.get/set
                 elseif op == 0x0C || op == 0x0D; 1                  # br, br_if
                 elseif op == 0x10; 1                                # call
                 elseif op == 0x11; 2                                # call_indirect
                 elseif op == 0xD0; 1                                # ref.null
                 elseif op == 0xD2; 1                                # ref.func
                 elseif op == 0x41 || op == 0x42; 1                  # i32.const, i64.const
                 elseif op >= 0x28 && op <= 0x3E; 2                  # memory load/store
                 elseif op == 0x3F || op == 0x40; 1                  # memory.size/grow
                 else 0
                 end
        if n_skip > 0
            i += 1  # Skip opcode
            for _ in 1:n_skip
                while i <= length(bytes)
                    b = bytes[i]; i += 1
                    (b & 0x80) == 0 && break
                end
            end
            continue
        end

        # All other instructions: single byte (no operands)
        i += 1
    end
    return bytes  # No excess found
end



"""
Represents a basic block in the IR.
"""
struct BasicBlock
    start_idx::Int
    end_idx::Int
    terminator::Any  # GotoIfNot, GotoNode, or ReturnNode
end

"""
Represents a try/catch region in the IR.
"""
struct TryRegion
    enter_idx::Int      # SSA index of Core.EnterNode
    catch_dest::Int     # SSA index where catch block starts
    leave_idx::Int      # SSA index of :leave expression (end of try body)
end

"""
Find try/catch regions by scanning for Core.EnterNode statements.
Returns a list of TryRegion structs.
"""
function find_try_regions(code)::Vector{TryRegion}
    regions = TryRegion[]

    for (i, stmt) in enumerate(code)
        if stmt isa Core.EnterNode
            catch_dest = stmt.catch_dest
            # Find the corresponding :leave that references this EnterNode
            leave_idx = 0
            for (j, s) in enumerate(code)
                if s isa Expr && s.head === :leave
                    # :leave args contain references to EnterNode SSA values
                    for arg in s.args
                        if arg isa Core.SSAValue && arg.id == i
                            leave_idx = j
                            break
                        end
                    end
                    if leave_idx > 0
                        break
                    end
                end
            end

            if leave_idx > 0
                push!(regions, TryRegion(i, catch_dest, leave_idx))
            elseif catch_dest > i
                # P2-batch4: an always-throwing try body has NO :leave (Julia elides
                # it when the body can't exit normally — e.g. `try div(0,0) catch`).
                # Dropping the region here meant no try_table was emitted at all, so
                # the throw escaped uncaught. Synthesize leave_idx = catch_dest: the
                # try body becomes enter+1 .. catch_dest-1 and every consumer's
                # normal-exit range (leave_idx+1 .. catch_dest-1) is empty, which is
                # exactly right — there is no normal exit.
                push!(regions, TryRegion(i, catch_dest, catch_dest))
            end
        end
    end

    return regions
end

"""
Check if code contains try/catch regions.
"""
function has_try_catch(code)::Bool
    for stmt in code
        if stmt isa Core.EnterNode
            return true
        end
    end
    return false
end

"""
    stmt_must_execute(code, idx) -> Bool

Strict-mode reachability gate. Returns `true` iff statement `idx`'s basic block
**dominates every normal-return block** — i.e. the statement is executed on every call
that returns normally. Used to make loud strict rejects SOUND: an un-lowerable construct
is rejected only when it is DEFINITELY hit. A working (compiles+runs) function can never
have a must-execute trap-stub (it would trap on every call, so it wouldn't work), so
gating rejects on this can never regress valid code; branch/dead-code-guarded stubs stay
sound *silent* traps.

Conservative by construction: any uncertainty → `false` (don't reject). Functions with
`try`/`catch` (exception edges this simple CFG doesn't model) return `false` outright.
"""
function stmt_must_execute(code, idx::Int)::Bool
    (code isa AbstractVector && 1 <= idx <= length(code)) || return false
    has_try_catch(code) && return false          # exception edges unmodeled → never reject
    blocks = analyze_blocks(code)
    nb = length(blocks)
    nb == 0 && return false
    bidx = findfirst(b -> b.start_idx <= idx <= b.end_idx, blocks)
    bidx === nothing && return false
    start2id = Dict{Int,Int}(blocks[i].start_idx => i for i in 1:nb)
    succs = [Int[] for _ in 1:nb]
    retids = Int[]
    for i in 1:nb
        t = blocks[i].terminator
        if t isa Core.ReturnNode
            isdefined(t, :val) && push!(retids, i)   # normal return (unreachable-return has no val)
        elseif t isa Core.GotoNode
            haskey(start2id, t.label) && push!(succs[i], start2id[t.label])
        elseif t isa Core.GotoIfNot
            haskey(start2id, t.dest) && push!(succs[i], start2id[t.dest])
            i < nb && push!(succs[i], i + 1)
        else
            i < nb && push!(succs[i], i + 1)         # fall-through (nothing terminator)
        end
    end
    # reachable-from-entry (block 1); only consider reachable normal returns
    reach = falses(nb); stack = [1]; reach[1] = true
    while !isempty(stack)
        b = pop!(stack)
        for s in succs[b]; reach[s] || (reach[s] = true; push!(stack, s)); end
    end
    retids = filter(r -> reach[r], retids)
    isempty(retids) && return false              # always-throws / no reachable normal return
    reach[bidx] || return false
    preds = [Int[] for _ in 1:nb]
    for i in 1:nb, s in succs[i]; push!(preds[s], i); end
    # iterative dominators: dom[b] = blocks dominating b
    full = Set(1:nb)
    dom = Vector{Set{Int}}(undef, nb)
    for i in 1:nb; dom[i] = (i == 1 ? Set([1]) : copy(full)); end
    changed = true
    while changed
        changed = false
        for b in 2:nb
            reach[b] || continue
            ps = [p for p in preds[b] if reach[p]]
            isempty(ps) && continue
            nd = copy(dom[ps[1]])                    # fresh copy — never mutate a shared dom set
            for k in 2:length(ps); intersect!(nd, dom[ps[k]]); end
            push!(nd, b)
            nd == dom[b] || (dom[b] = nd; changed = true)
        end
    end
    return all(r -> bidx in dom[r], retids)
end

"""
Analyze the IR to find basic block boundaries.
A new block starts after each terminator AND at each jump target.
"""
function analyze_blocks(code)
    # First, collect all jump targets
    jump_targets = Set{Int}()
    for stmt in code
        if stmt isa Core.GotoNode
            push!(jump_targets, stmt.label)
        elseif stmt isa Core.GotoIfNot
            push!(jump_targets, stmt.dest)
        end
    end

    blocks = BasicBlock[]
    block_start = 1

    for i in 1:length(code)
        stmt = code[i]

        # Check if NEXT statement is a jump target (start new block after this one)
        is_terminator = stmt isa Core.GotoIfNot || stmt isa Core.GotoNode || stmt isa Core.ReturnNode
        next_is_jump_target = (i + 1) in jump_targets

        if is_terminator
            push!(blocks, BasicBlock(block_start, i, stmt))
            block_start = i + 1
        elseif next_is_jump_target && i >= block_start
            # Current statement is NOT a terminator but next statement IS a jump target
            # Close current block with no terminator (fallthrough)
            push!(blocks, BasicBlock(block_start, i, nothing))
            block_start = i + 1
        end
    end

    # Handle trailing code without explicit terminator
    if block_start <= length(code)
        push!(blocks, BasicBlock(block_start, length(code), nothing))
    end

    return blocks
end

"""
Check if this code contains a loop (has backward jumps).
"""
function has_loop(ctx::AbstractCompilationContext)
    return any(ctx.loop_headers)
end

"""
Check if there's a conditional BEFORE the first loop that jumps PAST the first loop.
This pattern requires special handling (the stackifier instead of generate_loop_code).
Example: if/else where each branch has its own loop (like float_to_string).
"""
function has_branch_past_first_loop(ctx::AbstractCompilationContext, code)
    if !any(ctx.loop_headers)
        return false
    end

    # Find first loop header and its back-edge
    first_header = findfirst(ctx.loop_headers)
    back_edge_idx = nothing
    for (i, stmt) in enumerate(code)
        if stmt isa Core.GotoNode && stmt.label == first_header
            back_edge_idx = i
            break
        end
    end
    if back_edge_idx === nothing
        return false
    end

    # Check for conditionals BEFORE the first loop that jump PAST its back-edge
    for i in 1:(first_header - 1)
        stmt = code[i]
        if stmt isa Core.GotoIfNot
            target = stmt.dest
            if target > back_edge_idx
                # This conditional jumps past the first loop - complex pattern
                return true
            end
        end
    end

    return false
end

"""
Find merge points - targets of multiple forward jumps.
These are blocks that need WASM block/br structure for proper control flow.
Returns a Dict mapping target index to list of source indices.
"""
function find_merge_points(code)
    # Track all forward jump targets
    forward_targets = Dict{Int, Vector{Int}}()

    for (i, stmt) in enumerate(code)
        if stmt isa Core.GotoNode
            target = stmt.label
            if target > i  # Forward jump
                if !haskey(forward_targets, target)
                    forward_targets[target] = Int[]
                end
                push!(forward_targets[target], i)
            end
        elseif stmt isa Core.GotoIfNot
            target = stmt.dest
            if target > i  # Forward jump (the false branch)
                if !haskey(forward_targets, target)
                    forward_targets[target] = Int[]
                end
                push!(forward_targets[target], i)
            end
        end
    end

    # Merge points are targets with multiple sources
    merge_points = Dict{Int, Vector{Int}}()
    for (target, sources) in forward_targets
        if length(sources) >= 2
            merge_points[target] = sources
        end
    end

    return merge_points
end

"""
Check if the control flow has || or && patterns (merge points from short-circuit evaluation).
"""
function has_short_circuit_patterns(code)
    merge_points = find_merge_points(code)
    return !isempty(merge_points)
end

"""
Generate code for try/catch blocks using WASM exception handling (try_table).

Following dart2wasm's approach:
- Use a single exception tag for all Julia exceptions
- try_table with catch_all to handle any exception
- Catch handler gets exception value (if any)

WASM structure:
  (block \$after_try          ; exit point for try success
    (block \$catch_handler    ; catch handler block
      (try_table (catch_all 0) ; branch to \$catch_handler on exception
        ;; try body code
        (br 1)                 ; normal exit (skip catch)
      )
    )
    ;; catch handler code
  )
  ;; code after try/catch
"""
# PURE-1102: Ensure module has exception tag 0 for Julia exceptions (idempotent)
# PURE-9032: Also ensures the $current_exn global exists for exception value stashing.
function ensure_exception_tag!(mod::WasmModule)
    # march6 slice D: THE TYPED TAG — dart's createExceptionTag carries
    # (exception, stackTrace) as the tag payload (translator.dart:485-491);
    # the value travels WITH the unwind, not via a pre-set global (re-entrancy).
    # Payload: (anyref exn, externref stackTrace — null until traces wire).
    if isempty(mod.tags)
        tag_ft = FuncType(WasmValType[AnyRef, ExternRef], WasmValType[])
        add_tag!(mod, add_type!(mod, tag_ft))
    end
end

"""
PURE-9032: Ensure module has the \$current_exn global for exception value stashing.
This is a (mut anyref) global initialized to ref.null any.
Returns the global index. Idempotent — scans existing globals to avoid duplicates.
"""
function ensure_exception_global!(mod::WasmModule)::UInt32
    # Check if we already have an anyref mutable global (our exception stash)
    for (i, g) in enumerate(mod.globals)
        if g.valtype === AnyRef && g.mutable_
            return UInt32(i - 1)
        end
    end
    # Create (global (mut anyref) (ref.null any))
    init = UInt8[0xD0, 0x6E, Opcode.END]  # ref.null any + end
    push!(mod.globals, WasmGlobalDef(AnyRef, true, init))
    return UInt32(length(mod.globals) - 1)
end

# census F7 (march5): the dormant stack-trace cluster (ensure_stack_trace_support!/
# emit_capture_stack!) is DELETED — zero callers since introduction (PURE-9036).
# The dart-shaped rebuild carries (exception, stackTrace) as the TYPED TAG PAYLOAD
# (translator.dart:481-491 createExceptionTag) — census queue item D9.1; the dart
# source is the reference, not dead scaffolding.

"""
PURE-6024: Generate try/catch code using generate_stackified_flow for the try body.
Used when the try body has complex control flow (phi nodes, nested conditionals).
The simple linear approach in generate_try_catch can't handle phi locals or nested
GotoIfNot, causing null pointer dereferences from uninitialized phi locals.

Structure:
  block \$catch_landing (void)          ; catch_all jumps here
    try_table (catch_all 0) (void)     ; catch clause routes to label 0
      ; generate_stackified_flow for all blocks before catch handler
      ; (handles phi nodes, nested control flow, all returns)
    end
  end
  ; catch handler code (pop_exception skipped, returns -1 or similar)
"""
# P2-batch17: compile a catch-handler region [from..to] honouring GotoIfNot
# (conditional catch arms / exception isa dispatch). The linear per-statement
# loops no-op'd GotoIfNot, so `catch; if x; a; else; b; end` always produced the
# then arm (gap f80bce91645e). Mirrors the PURE-9032 handling from the simple
# no-merge generator.
"""bytes shell for the remaining byte-region callers (dies with them)."""

"""builder-native (THE implementation): compile a catch-region [from..to] into `b`."""

# P2-batch22 (gap bac7c93c2871): `if cond; try A catch X end else try B catch
# Y end end` — two INDEPENDENT try/catches, one per branch arm, every arm
# returning. Neither the chain nor the sequential generator fits (chain glues
# the else arm into the then arm's catch; sequential leaves the branch
# condition stranded on the stack). Layout:
#   <pre-branch code>
#   block $else
#     cond eqz br_if 0                ;; !cond → else arm
#     <then arm: try_table A / catch X>   ;; all paths return
#   end
#   <else arm: try_table B / catch Y>     ;; all paths return
"""builder-native front for the branch-split try generator."""

