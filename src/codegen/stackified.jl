"""
Generate code for more complex control flow patterns.
Uses nested blocks with br instructions.
"""
function generate_complex_flow(ctx::CompilationContext, blocks::Vector{BasicBlock}, code)::Vector{UInt8}
    bytes = UInt8[]

    # For void return types WITHOUT loops (like event handlers), use a simpler approach:
    # just execute all statements in order and return at the end.
    # PURE-314: Void functions WITH loops must use generate_stackified_flow because
    # generate_void_flow doesn't handle pre-loop phi initialization (single-edge phis
    # after if-then-else merge points stay at default 0, causing array bounds errors).
    if ctx.return_type === Nothing && isempty(ctx.loop_headers)
        append!(bytes, generate_void_flow(ctx, blocks, code))
        return bytes
    end

    # Count how many conditional branches we have
    conditionals = [(i, b) for (i, b) in enumerate(blocks) if b.terminator isa Core.GotoIfNot]

    # For functions with loops or 3+ conditionals, use the stackifier algorithm.
    # The nested conditional generator handles simple if-else well (1 conditional),
    # but loops and multi-conditional patterns with phi nodes require the stackifier's
    # approach of emitting loop/br for backedges and storing to phi locals at each branch.
    has_phi_nodes = any(stmt isa Core.PhiNode for stmt in code)
    has_loops = !isempty(ctx.loop_headers)
    if has_loops || length(conditionals) > 2 || (length(conditionals) >= 2 && has_phi_nodes)
        return generate_stackified_flow(ctx, blocks, code)
    end

    # For simpler functions, use nested if-else (which works well for moderate complexity)
    if length(conditionals) >= 1
        append!(bytes, generate_nested_conditionals(ctx, blocks, code, conditionals))
    else
        # Fallback: generate blocks sequentially
        for block in blocks
            append!(bytes, generate_block_code(ctx, block))
        end
    end

    return bytes
end

"""
Stackifier algorithm for complex control flow.
Converts Julia IR CFG to WASM structured control flow by:
1. Building a CFG from basic blocks
2. Computing dominators and identifying merge points
3. Generating each block exactly once
4. Using block/br for forward jumps, loop/br for back jumps

Based on LLVM's WebAssembly backend stackifier and Cheerp's enhancements.
Reference: https://labs.leaningtech.com/blog/control-flow
"""

"""
PURE-325: Check if compiled bytecode contains a GC instruction that produces a ref value.
Scans `val_bytes` for GC_PREFIX (0xFB) followed by a ref-producing sub-opcode.
Properly skips LEB128 immediates of the first instruction to avoid false positives from
i32.const/i64.const values that coincidentally contain 0xFB bytes in their LEB128 encoding.

GC sub-opcodes recognized: 0x00 (struct.new), 0x06 (array.new), 0x07 (array.new_default),
0x08 (array.new_fixed), 0x1A (any.convert_extern), 0x1B (extern.convert_any).
"""
function has_ref_producing_gc_op(val_bytes::Vector{UInt8})::Bool
    isempty(val_bytes) && return false
    # Determine scan start: skip past the first instruction's LEB128 immediate to avoid
    # false positives from constants like i32.const 251 which encodes as 0x41 0xFB 0x01.
    scan_start = 1
    first_op = val_bytes[1]
    if first_op == 0x41 || first_op == 0x42 || first_op == 0x20 || first_op == 0x21 || first_op == 0x22 || first_op == 0x23 || first_op == 0x24  # i32.const, i64.const, local.get/set/tee, global.get/set
        # Skip LEB128 immediate
        for bi in 2:length(val_bytes)
            if (val_bytes[bi] & 0x80) == 0
                scan_start = bi + 1
                break
            end
        end
    elseif first_op == 0x43  # f32.const: 4-byte immediate
        scan_start = 6
    elseif first_op == 0x44  # f64.const: 8-byte immediate
        scan_start = 10
    end
    for scan_i in scan_start:(length(val_bytes)-1)
        if val_bytes[scan_i] == 0xFB
            gc_op = val_bytes[scan_i + 1]
            if gc_op == 0x00 || gc_op == 0x08 || gc_op == 0x1A || gc_op == 0x1B
                return true
            end
        end
    end
    return false
end

"""
PURE-325: Emit boxing bytecode for a numeric value that needs to be returned as ExternRef.
Handles the common pattern where a function returns ExternRef (Union type) but the actual
value is numeric (I32/I64/F32/F64). Boxes the value in a WasmGC struct + extern_convert_any.

If `val` is nothing (literal nothing), emits ref.null extern instead of boxing.
If `val` is a non-nothing numeric value, compiles + boxes it.

`target_bytes` is the byte vector to append to (may be `bytes` or `inner_bytes`).
"""
function emit_numeric_to_externref!(target_bytes::Vector{UInt8}, val, val_wasm::WasmValType, ctx::CompilationContext)
    if is_nothing_value(val, ctx)
        # return nothing → ref.null extern
        push!(target_bytes, Opcode.REF_NULL)
        push!(target_bytes, UInt8(ExternRef))
        return
    end
    # Box: compile value → struct_new(box_type) → extern_convert_any
    append!(target_bytes, compile_value(val, ctx))
    box_type = get_numeric_box_type!(ctx.mod, ctx.type_registry, val_wasm)
    push!(target_bytes, Opcode.GC_PREFIX)
    push!(target_bytes, Opcode.STRUCT_NEW)
    append!(target_bytes, encode_leb128_unsigned(box_type))
    push!(target_bytes, Opcode.GC_PREFIX)
    push!(target_bytes, Opcode.EXTERN_CONVERT_ANY)
    return
end

function generate_stackified_flow(ctx::CompilationContext, blocks::Vector{BasicBlock}, code)::Vector{UInt8}
    # ========================================================================
    # STEP 0: BOUNDSCHECK PATTERN DETECTION
    # ========================================================================
    # We emit i32.const 0 for boundscheck, so GotoIfNot following boundscheck
    # ALWAYS jumps (since NOT 0 = TRUE). Track these patterns to skip dead code.

    boundscheck_jumps = Set{Int}()  # Statement indices of GotoIfNot that always jump
    dead_regions = Set{Int}()       # Statement indices that are dead code
    dead_blocks = Set{Int}()        # Block indices that are entirely dead

    for i in 1:length(code)
        stmt = code[i]
        if stmt isa Expr && stmt.head === :boundscheck && length(stmt.args) >= 1
            if i + 1 <= length(code) && code[i + 1] isa Core.GotoIfNot
                goto_stmt = code[i + 1]::Core.GotoIfNot
                if goto_stmt.cond isa Core.SSAValue && goto_stmt.cond.id == i
                    push!(boundscheck_jumps, i + 1)
                    push!(dead_regions, i)
                    target = goto_stmt.dest
                    for j in (i + 2):(target - 1)
                        push!(dead_regions, j)
                    end
                end
            end
        end
    end

    # Mark blocks as dead if all their statements are in dead regions
    for (block_idx, block) in enumerate(blocks)
        all_dead = true
        for i in block.start_idx:block.end_idx
            if !(i in dead_regions) && !(i in boundscheck_jumps)
                all_dead = false
                break
            end
        end
        if all_dead
            push!(dead_blocks, block_idx)
        end
    end

    # ========================================================================
    # STEP 1: Build Control Flow Graph
    # ========================================================================

    # Map statement index -> block index
    stmt_to_block = Dict{Int, Int}()
    for (block_idx, block) in enumerate(blocks)
        for i in block.start_idx:block.end_idx
            stmt_to_block[i] = block_idx
        end
    end

    # Build successor/predecessor maps (block indices)
    successors = Dict{Int, Vector{Int}}()  # block_idx -> successor block indices
    predecessors = Dict{Int, Vector{Int}}()  # block_idx -> predecessor block indices

    for i in 1:length(blocks)
        successors[i] = Int[]
        predecessors[i] = Int[]
    end

    for (block_idx, block) in enumerate(blocks)
        # Skip dead blocks entirely - don't add edges to/from them
        if block_idx in dead_blocks
            continue
        end

        term = block.terminator
        if term isa Core.GotoIfNot
            # Check if this is a boundscheck-based always-jump
            term_idx = block.end_idx
            if term_idx in boundscheck_jumps
                # This GotoIfNot ALWAYS jumps (boundscheck is 0, NOT 0 = TRUE)
                # Only add the jump target as successor, NOT the fall-through
                dest_block = get(stmt_to_block, term.dest, nothing)
                if dest_block !== nothing && !(dest_block in dead_blocks)
                    push!(successors[block_idx], dest_block)
                    push!(predecessors[dest_block], block_idx)
                end
            else
                # Real conditional: two successors
                dest_block = get(stmt_to_block, term.dest, nothing)
                fall_through_block = block_idx < length(blocks) ? block_idx + 1 : nothing

                if fall_through_block !== nothing && fall_through_block <= length(blocks) && !(fall_through_block in dead_blocks)
                    push!(successors[block_idx], fall_through_block)
                    push!(predecessors[fall_through_block], block_idx)
                end
                if dest_block !== nothing && !(dest_block in dead_blocks)
                    push!(successors[block_idx], dest_block)
                    push!(predecessors[dest_block], block_idx)
                end
            end
        elseif term isa Core.GotoNode
            dest_block = get(stmt_to_block, term.label, nothing)
            if dest_block !== nothing
                push!(successors[block_idx], dest_block)
                push!(predecessors[dest_block], block_idx)
            end
        elseif term isa Core.ReturnNode
            # No successors for return
        else
            # Fall through to next block
            if block_idx < length(blocks)
                push!(successors[block_idx], block_idx + 1)
                push!(predecessors[block_idx + 1], block_idx)
            end
        end
    end

    # ========================================================================
    # STEP 2: Identify Back Edges (loops) vs Forward Edges
    # ========================================================================

    back_edges = Set{Tuple{Int, Int}}()  # (from_block, to_block)
    forward_edges = Set{Tuple{Int, Int}}()
    loop_headers = Set{Int}()

    for (block_idx, succs) in successors
        for succ in succs
            if succ <= block_idx  # Back edge (loop)
                push!(back_edges, (block_idx, succ))
                push!(loop_headers, succ)
            else  # Forward edge
                push!(forward_edges, (block_idx, succ))
            end
        end
    end

    # ========================================================================
    # STEP 3: Find Forward Edge Targets (merge points that need block/br)
    # ========================================================================

    # For each forward edge target, track the sources
    # These are targets where we need to emit a block and use br to jump
    forward_targets = Dict{Int, Vector{Int}}()  # target_block -> source_blocks

    for (src, dst) in forward_edges
        # A forward edge needs block/br if it's NOT a simple fall-through
        # (i.e., src + 1 != dst or there are multiple paths to dst)
        if !haskey(forward_targets, dst)
            forward_targets[dst] = Int[]
        end
        push!(forward_targets[dst], src)
    end

    # ========================================================================
    # STEP 4: Count SSA uses for drop logic
    # ========================================================================

    ssa_use_count = Dict{Int, Int}()
    ssa_non_phi_uses = Dict{Int, Int}()  # Uses from non-PhiNode statements only
    for stmt in code
        count_ssa_uses!(stmt, ssa_use_count)
        if !(stmt isa Core.PhiNode)
            count_ssa_uses!(stmt, ssa_non_phi_uses)
        end
    end

    # ========================================================================
    # STEP 5: Generate Code Using Stackifier Strategy
    # ========================================================================

    # Helper to compile statements in a basic block
    function compile_block_statements(block::BasicBlock, skip_terminator::Bool)::Vector{UInt8}
        block_bytes = UInt8[]
        # PURE-7001a: Reset dead code guard — this block is reachable
        ctx.last_stmt_was_stub = false

        for i in block.start_idx:block.end_idx
            stmt = code[i]

            # Skip terminator if requested (we handle control flow separately)
            if skip_terminator && i == block.end_idx && (stmt isa Core.GotoIfNot || stmt isa Core.GotoNode || stmt isa Core.ReturnNode)
                continue
            end

            if stmt isa Core.ReturnNode
                if isdefined(stmt, :val)
                    val_wasm_type = infer_value_wasm_type(stmt.val, ctx)
                    ret_wasm_type = julia_to_wasm_type_concrete(ctx.return_type, ctx)
                    func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                    # PURE-315: Check numeric-to-ref BEFORE return_type_compatible,
                    # because I32 (nothing) is not "compatible" with ConcreteRef but
                    # is correctly handled by emitting ref.null instead.
                    is_numeric_val = val_wasm_type === I32 || val_wasm_type === I64 || val_wasm_type === F32 || val_wasm_type === F64
                    is_ref_ret = func_ret_wasm isa ConcreteRef || func_ret_wasm === ExternRef || func_ret_wasm === StructRef || func_ret_wasm === ArrayRef || func_ret_wasm === AnyRef
                    if is_numeric_val && is_ref_ret
                        # PURE-325: Box numeric value for ref return type
                        if func_ret_wasm === ExternRef
                            emit_numeric_to_externref!(block_bytes, stmt.val, val_wasm_type, ctx)
                        elseif func_ret_wasm isa ConcreteRef
                            push!(block_bytes, Opcode.REF_NULL)
                            append!(block_bytes, encode_leb128_signed(Int64(func_ret_wasm.type_idx)))
                        else
                            push!(block_bytes, Opcode.REF_NULL)
                            push!(block_bytes, UInt8(func_ret_wasm))
                        end
                        push!(block_bytes, Opcode.RETURN)
                    elseif !return_type_compatible(val_wasm_type, func_ret_wasm)
                        push!(block_bytes, Opcode.UNREACHABLE)
                    else
                        append!(block_bytes, compile_value(stmt.val, ctx))
                        if func_ret_wasm === ExternRef && val_wasm_type !== ExternRef
                            push!(block_bytes, Opcode.GC_PREFIX)
                            push!(block_bytes, Opcode.EXTERN_CONVERT_ANY)
                        elseif val_wasm_type === I32 && func_ret_wasm === I64
                            push!(block_bytes, Opcode.I64_EXTEND_I32_S)
                        elseif val_wasm_type === I64 && func_ret_wasm === F64
                            push!(block_bytes, Opcode.F64_CONVERT_I64_S)
                        elseif val_wasm_type === I32 && func_ret_wasm === F64
                            push!(block_bytes, Opcode.F64_CONVERT_I32_S)
                        elseif val_wasm_type === F32 && func_ret_wasm === F64
                            push!(block_bytes, Opcode.F64_PROMOTE_F32)
                        elseif val_wasm_type === I64 && func_ret_wasm === F32
                            push!(block_bytes, Opcode.F32_CONVERT_I64_S)
                        elseif val_wasm_type === I32 && func_ret_wasm === F32
                            push!(block_bytes, Opcode.F32_CONVERT_I32_S)
                        end
                        push!(block_bytes, Opcode.RETURN)
                    end
                else
                    push!(block_bytes, Opcode.RETURN)
                end

            elseif stmt isa Core.GotoIfNot
                # GotoIfNot: handled by control flow structure
                # Nothing to emit here

            elseif stmt isa Core.GotoNode
                # Unconditional goto: handled by control flow structure
                # Nothing to emit here

            elseif stmt isa Core.PhiNode
                # Phi nodes: check if we're falling through from a previous statement
                # in the same block that is an edge for this phi
                if haskey(ctx.phi_locals, i)
                    # Look for an edge from a previous statement in this block
                    for (edge_idx, edge) in enumerate(stmt.edges)
                        # Check if this edge is from within the same block (internal fallthrough)
                        if edge >= block.start_idx && edge < i
                            # This is an internal fallthrough edge - set the phi local
                            if isassigned(stmt.values, edge_idx)
                                val = stmt.values[edge_idx]
                                # Check type compatibility before storing
                                local_idx = ctx.phi_locals[i]
                                phi_local_type = ctx.locals[local_idx - ctx.n_params + 1]
                                edge_val_type = get_phi_edge_wasm_type(val)
                                if edge_val_type !== nothing && !wasm_types_compatible(phi_local_type, edge_val_type) && !(phi_local_type === I64 && edge_val_type === I32)
                                    if phi_local_type === ExternRef && (edge_val_type === I32 || edge_val_type === I64 || edge_val_type === F32 || edge_val_type === F64)
                                        # PURE-325: Box numeric phi edge for ExternRef local
                                        _pvb = compile_phi_value(val, i)
                                        if !isempty(_pvb)
                                            _pvb_boxed = length(_pvb) >= 2 && _pvb[end-1] == Opcode.GC_PREFIX && _pvb[end] == Opcode.EXTERN_CONVERT_ANY
                                            # PURE-602: compile_phi_value may return ref.null extern for nothing values
                                            # (already externref — don't try to box it as numeric)
                                            _pvb_is_ref_null = length(_pvb) >= 1 && _pvb[1] == Opcode.REF_NULL
                                            append!(block_bytes, _pvb)
                                            if !_pvb_boxed && !_pvb_is_ref_null
                                                _box_t = get_numeric_box_type!(ctx.mod, ctx.type_registry, edge_val_type)
                                                push!(block_bytes, Opcode.GC_PREFIX)
                                                push!(block_bytes, Opcode.STRUCT_NEW)
                                                append!(block_bytes, encode_leb128_unsigned(_box_t))
                                                push!(block_bytes, Opcode.GC_PREFIX)
                                                push!(block_bytes, Opcode.EXTERN_CONVERT_ANY)
                                            end
                                            push!(block_bytes, Opcode.LOCAL_SET)
                                            append!(block_bytes, encode_leb128_unsigned(local_idx))
                                            break
                                        end
                                    end
                                    # Type mismatch: emit type-safe default for the local's declared type.
                                    append!(block_bytes, emit_phi_type_default(phi_local_type))
                                    push!(block_bytes, Opcode.LOCAL_SET)
                                    append!(block_bytes, encode_leb128_unsigned(local_idx))
                                    break
                                end
                                phi_value_bytes = compile_phi_value(val, i)
                                # Detect multi-value bytes (all local_gets, N>=2).
                                if length(phi_value_bytes) >= 4
                                    _pv_all3 = true; _pv_n3 = 0; _pv_p3 = 1
                                    while _pv_p3 <= length(phi_value_bytes)
                                        if phi_value_bytes[_pv_p3] != 0x20; _pv_all3 = false; break; end
                                        _pv_n3 += 1; _pv_p3 += 1
                                        while _pv_p3 <= length(phi_value_bytes) && (phi_value_bytes[_pv_p3] & 0x80) != 0; _pv_p3 += 1; end
                                        _pv_p3 += 1
                                    end
                                    if _pv_all3 && _pv_p3 > length(phi_value_bytes) && _pv_n3 >= 2
                                        phi_value_bytes = emit_phi_type_default(phi_local_type)
                                    end
                                end
                                # Only emit local_set if we actually have a value on the stack
                                if !isempty(phi_value_bytes)
                                    # PURE-325: If compile_phi_value already boxed (contains GC_PREFIX),
                                    # skip the safety check — it would undo the boxing
                                    _already_boxed = length(phi_value_bytes) >= 2 && phi_value_bytes[end-1] == Opcode.GC_PREFIX && phi_value_bytes[end] == Opcode.EXTERN_CONVERT_ANY
                                    # Safety check: verify actual local.get type matches phi local
                                    actual_val_type = edge_val_type
                                    if !_already_boxed && length(phi_value_bytes) >= 2 && phi_value_bytes[1] == Opcode.LOCAL_GET
                                        got_local_idx = 0
                                        shift = 0
                                        for bi in 2:length(phi_value_bytes)
                                            b = phi_value_bytes[bi]
                                            got_local_idx |= (Int(b & 0x7f) << shift)
                                            shift += 7
                                            if (b & 0x80) == 0
                                                break
                                            end
                                        end
                                        got_local_array_idx = got_local_idx - ctx.n_params + 1
                                        if got_local_array_idx >= 1 && got_local_array_idx <= length(ctx.locals)
                                            actual_val_type = ctx.locals[got_local_array_idx]
                                        elseif got_local_idx < ctx.n_params
                                            # It's a parameter - get Wasm type from arg_types
                                            param_julia_type = ctx.arg_types[got_local_idx + 1]  # Julia is 1-indexed
                                            actual_val_type = get_concrete_wasm_type(param_julia_type, ctx.mod, ctx.type_registry)
                                        end
                                    end

                                    if _already_boxed
                                        append!(block_bytes, phi_value_bytes)
                                    elseif actual_val_type !== nothing && !wasm_types_compatible(phi_local_type, actual_val_type) && !(phi_local_type === I64 && actual_val_type === I32) && !(phi_local_type === F64 && (actual_val_type === I64 || actual_val_type === I32 || actual_val_type === F32)) && !(phi_local_type === F32 && (actual_val_type === I64 || actual_val_type === I32))
                                        # PURE-325: ConcreteRef/StructRef/ArrayRef/AnyRef → ExternRef:
                                        # wrap with extern_convert_any instead of emitting null default
                                        if phi_local_type === ExternRef && (actual_val_type isa ConcreteRef || actual_val_type === StructRef || actual_val_type === ArrayRef || actual_val_type === AnyRef)
                                            append!(block_bytes, phi_value_bytes)
                                            # PURE-803: ref.null extern is already externref — don't wrap with extern_convert_any
                                            _is_ref_null = length(phi_value_bytes) >= 1 && phi_value_bytes[1] == Opcode.REF_NULL
                                            if !_is_ref_null
                                                push!(block_bytes, Opcode.GC_PREFIX)
                                                push!(block_bytes, Opcode.EXTERN_CONVERT_ANY)
                                            end
                                        else
                                            append!(block_bytes, emit_phi_type_default(phi_local_type))
                                        end
                                    elseif actual_val_type !== nothing && phi_local_type === I64 && actual_val_type === I32
                                        append!(block_bytes, phi_value_bytes)
                                        if isempty(phi_value_bytes) || phi_value_bytes[1] != Opcode.I64_CONST
                                            push!(block_bytes, Opcode.I64_EXTEND_I32_S)
                                        end
                                    elseif actual_val_type !== nothing && phi_local_type === F64 && actual_val_type === I64
                                        append!(block_bytes, phi_value_bytes)
                                        push!(block_bytes, Opcode.F64_CONVERT_I64_S)
                                    elseif actual_val_type !== nothing && phi_local_type === F64 && actual_val_type === I32
                                        append!(block_bytes, phi_value_bytes)
                                        push!(block_bytes, Opcode.F64_CONVERT_I32_S)
                                    elseif actual_val_type !== nothing && phi_local_type === F64 && actual_val_type === F32
                                        append!(block_bytes, phi_value_bytes)
                                        push!(block_bytes, Opcode.F64_PROMOTE_F32)
                                    elseif actual_val_type !== nothing && phi_local_type === F32 && (actual_val_type === I64 || actual_val_type === I32)
                                        append!(block_bytes, phi_value_bytes)
                                        push!(block_bytes, actual_val_type === I64 ? Opcode.F32_CONVERT_I64_S : Opcode.F32_CONVERT_I32_S)
                                    else
                                        append!(block_bytes, phi_value_bytes)
                                    end
                                    push!(block_bytes, Opcode.LOCAL_SET)
                                    append!(block_bytes, encode_leb128_unsigned(local_idx))
                                end
                            end
                            break
                        end
                    end
                end
                # No other code needed - phi result is read via LOCAL_GET

            elseif stmt === nothing
                # Nothing statement

            else
                # Regular statement - compile_statement handles local.set internally
                # for statements that produce values and have ssa_locals allocated
                stmt_bytes = compile_statement(stmt, i, ctx)
                append!(block_bytes, stmt_bytes)

                # PURE-6024: Skip remaining statements after unreachable.
                # Dead code after unreachable leaves values on the stack causing
                # "values remaining on stack at end of block" validation errors.
                stmt_type = get(ctx.ssa_types, i, Any)
                if stmt_type === Union{} || ctx.last_stmt_was_stub
                    break
                end

                # NOTE: compile_statement already adds LOCAL_SET for SSA values
                # that need storing. We don't add another one here to avoid
                # duplicate stores that would cause "not enough arguments on stack" errors.

                # Only drop unused values that don't have locals
                if !haskey(ctx.ssa_locals, i) && stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                    # PURE-220: Skip if compile_statement already emitted a DROP
                    # PURE-6006: Guard against call instruction false-positive (func_idx 0x1a == DROP)
                    already_dropped = !isempty(stmt_bytes) && stmt_bytes[end] == Opcode.DROP &&
                                      !(length(stmt_bytes) >= 2 && stmt_bytes[end-1] == Opcode.CALL)
                    # Use statement_produces_wasm_value to check if the call actually
                    # produces a value on the stack (handles Any type correctly)
                    if !already_dropped && statement_produces_wasm_value(stmt, i, ctx)
                        if !haskey(ctx.phi_locals, i)
                            use_count = get(ssa_use_count, i, 0)
                            if use_count == 0
                                push!(block_bytes, Opcode.DROP)
                            end
                        end
                    end
                end
            end
        end

        return block_bytes
    end

    # ========================================================================
    # STEP 6: Main Code Generation
    # ========================================================================
    #
    # Strategy: Process blocks in order. For each block:
    # - If it's a loop header: wrap with loop/end
    # - If it's a forward edge target: wrap with block/end (so br can jump past it)
    # - For GotoIfNot: emit if/else
    # - For GotoNode: emit br to the right scope
    #
    # The key insight: we need to set up block scopes BEFORE we need to br to them.
    # So we scan ahead to find all forward jump targets and wrap them.
    #
    # Simplified approach for Julia IR:
    # - Julia's IR tends to have simple diamond patterns (if/else merge)
    # - Most forward jumps go to the "next" merge point
    # - We use nested if/else for these patterns
    # - For more complex patterns, we use labeled blocks

    bytes = UInt8[]

    # For very complex functions, use a dispatcher-style approach
    # Create a big block structure with all targets as labeled positions

    # Collect all unique forward jump targets (excluding immediate fall-through)
    # Helper: resolve a dest_block through boundscheck chains to find the real non-dead target.
    # When a GotoIfNot targets a dead boundscheck block, that block's terminator always jumps
    # to another block. Follow the chain until we find a non-dead block.
    function resolve_through_dead_boundscheck(dest_block::Int)::Union{Int, Nothing}
        visited = Set{Int}()
        current = dest_block
        while current !== nothing && current in dead_blocks && !(current in visited)
            push!(visited, current)
            blk = blocks[current]
            t = blk.terminator
            if t isa Core.GotoIfNot && blk.end_idx in boundscheck_jumps
                # Boundscheck always-jump: follow to its destination
                current = get(stmt_to_block, t.dest, nothing)
            elseif t isa Core.GotoNode
                current = get(stmt_to_block, t.label, nothing)
            else
                return nothing
            end
        end
        if current !== nothing && !(current in dead_blocks)
            return current
        end
        return nothing
    end

    # Also exclude dead blocks and treat boundscheck-based jumps correctly
    non_trivial_targets = Set{Int}()
    for (block_idx, block) in enumerate(blocks)
        # Skip dead blocks
        if block_idx in dead_blocks
            continue
        end

        term = block.terminator
        term_idx = block.end_idx

        if term isa Core.GotoIfNot
            # Check if this is a boundscheck always-jump
            if term_idx in boundscheck_jumps
                # Boundscheck jumps ALWAYS go to dest, so it's like an unconditional jump
                # Only record it as non-trivial if it's not immediate fall-through
                dest_block = get(stmt_to_block, term.dest, nothing)
                if dest_block !== nothing && dest_block in dead_blocks
                    dest_block = resolve_through_dead_boundscheck(dest_block)
                end
                if dest_block !== nothing && dest_block != block_idx + 1 && !(dest_block in dead_blocks)
                    push!(non_trivial_targets, dest_block)
                end
            else
                # Real conditional - the false branch destination
                dest_block = get(stmt_to_block, term.dest, nothing)
                if dest_block !== nothing && dest_block in dead_blocks
                    dest_block = resolve_through_dead_boundscheck(dest_block)
                end
                if dest_block !== nothing && dest_block != block_idx + 1 && !(dest_block in dead_blocks)
                    push!(non_trivial_targets, dest_block)
                end
            end
        elseif term isa Core.GotoNode
            dest_block = get(stmt_to_block, term.label, nothing)
            if dest_block !== nothing && dest_block in dead_blocks
                dest_block = resolve_through_dead_boundscheck(dest_block)
            end
            if dest_block !== nothing && dest_block != block_idx + 1 && !(dest_block in dead_blocks)
                push!(non_trivial_targets, dest_block)
            end
        end
    end

    # ========================================================================
    # Determine which targets are inside loops vs outside
    # ========================================================================
    # A target is "inside a loop" if it's between the loop header and the
    # back-edge source (latch) block. Such targets need their BLOCKs opened
    # INSIDE the LOOP instruction, not outside it, to maintain valid nesting.

    # Map: loop_header -> latch_block (back-edge source)
    loop_latches = Dict{Int, Int}()
    for (src, dst) in back_edges
        # If multiple back edges to same header, take the latest latch
        if !haskey(loop_latches, dst) || src > loop_latches[dst]
            loop_latches[dst] = src
        end
    end

    # Determine which targets are inside which loop
    # target_loop[target] = loop_header if target is inside that loop
    target_loop = Dict{Int, Int}()
    for target in non_trivial_targets
        for (header, latch) in loop_latches
            if target > header && target <= latch
                # Target is inside this loop
                # If nested, pick the innermost loop (largest header)
                if !haskey(target_loop, target) || header > target_loop[target]
                    target_loop[target] = header
                end
            end
        end
    end

    # Split targets into outer (outside all loops) and inner (inside a loop)
    outer_targets = sort([t for t in non_trivial_targets if !haskey(target_loop, t)]; rev=true)
    # Group inner targets by their loop header
    loop_inner_targets = Dict{Int, Vector{Int}}()  # header -> sorted targets (desc)
    for (target, header) in target_loop
        if !haskey(loop_inner_targets, header)
            loop_inner_targets[header] = Int[]
        end
        push!(loop_inner_targets[header], target)
    end
    for header in keys(loop_inner_targets)
        sort!(loop_inner_targets[header]; rev=true)
    end

    # Track currently open blocks (as a stack of target block indices)
    # The stack is ordered with outermost at bottom, innermost at top
    open_blocks = copy(outer_targets)  # Only outer targets opened at start

    # Also track open loops
    open_loops = Int[]  # Stack of loop header block indices

    # Open blocks for OUTER forward jump targets only (outermost first = largest target)
    for target in outer_targets
        push!(bytes, Opcode.BLOCK)
        push!(bytes, 0x40)  # void
    end

    # Helper function to get current label depth for a forward jump target
    # Label 0 = innermost currently open block
    function get_forward_label_depth(target_block::Int)::Int
        # Find position of target in open_blocks (0-indexed from end = innermost)
        # open_blocks is [largest, ..., smallest] so target at end has depth 0
        for (i, t) in enumerate(reverse(open_blocks))
            if t == target_block
                if haskey(target_loop, target_block)
                    # Inner target: add count of open loops that are MORE INNER
                    # than this target's parent loop. These inner loops add labels
                    # between us and the target block.
                    # E.g., target is inner to outer loop (header=2), and inner loop
                    # (header=4) is also open — that inner loop's label sits between
                    # us and the target's block, so we must skip it.
                    parent_header = target_loop[target_block]
                    inner_loop_count = 0
                    for lh in open_loops
                        if lh > parent_header
                            inner_loop_count += 1
                        end
                    end
                    return i - 1 + inner_loop_count
                else
                    return i - 1 + length(open_loops)  # Outer target: add loop offset
                end
            end
        end
        # Target not in open blocks - shouldn't happen for non_trivial_targets
        return 0
    end

    # Helper to get label depth for back edge (loop)
    function get_loop_label_depth(loop_header::Int)::Int
        # Find the loop in open_loops stack
        for (i, h) in enumerate(reverse(open_loops))
            if h == loop_header
                return i - 1  # 0 = innermost loop
            end
        end
        return 0
    end

    # Helper to check if destination has phi nodes from this edge
    function dest_has_phi_from_edge(dest_block::Int, terminator_idx::Int)::Bool
        if dest_block < 1 || dest_block > length(blocks)
            return false
        end
        dest_start = blocks[dest_block].start_idx
        dest_end = blocks[dest_block].end_idx
        for i in dest_start:dest_end
            stmt = code[i]
            if stmt isa Core.PhiNode
                if haskey(ctx.phi_locals, i) && terminator_idx in stmt.edges
                    return true
                end
            else
                break  # Phi nodes are consecutive at the start
            end
        end
        return false
    end

    # Helper: emit a type-safe default value for a given WasmValType
    function emit_phi_type_default(wasm_type::WasmValType)::Vector{UInt8}
        result = UInt8[]
        if wasm_type isa ConcreteRef
            push!(result, Opcode.REF_NULL)
            append!(result, encode_leb128_signed(Int64(wasm_type.type_idx)))
        elseif wasm_type === StructRef
            push!(result, Opcode.REF_NULL)
            push!(result, UInt8(StructRef))
        elseif wasm_type === ArrayRef
            push!(result, Opcode.REF_NULL)
            push!(result, UInt8(ArrayRef))
        elseif wasm_type === ExternRef
            push!(result, Opcode.REF_NULL)
            push!(result, UInt8(ExternRef))
        elseif wasm_type === AnyRef
            push!(result, Opcode.REF_NULL)
            push!(result, UInt8(AnyRef))
        elseif wasm_type === I64
            push!(result, Opcode.I64_CONST)
            push!(result, 0x00)
        elseif wasm_type === I32
            push!(result, Opcode.I32_CONST)
            push!(result, 0x00)
        elseif wasm_type === F64
            push!(result, Opcode.F64_CONST)
            append!(result, UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        elseif wasm_type === F32
            push!(result, Opcode.F32_CONST)
            append!(result, UInt8[0x00, 0x00, 0x00, 0x00])
        else
            push!(result, Opcode.I32_CONST)
            push!(result, 0x00)
        end
        return result
    end

    # Helper to compile a value, ensuring it actually produces bytes
    # For SSAValues without locals, we need to recompute the value
    # phi_idx: the SSA index of the phi node we're setting (to get the phi's type)
    function compile_phi_value(val, phi_idx::Int)::Vector{UInt8}
        result = UInt8[]
        if val isa Core.SSAValue
            # Determine the phi local's wasm type for compatibility checking
            phi_local_wasm_type = nothing
            if haskey(ctx.phi_locals, phi_idx)
                phi_local_idx = ctx.phi_locals[phi_idx]
                phi_local_wasm_type = ctx.locals[phi_local_idx - ctx.n_params + 1]
            end

            # Check if this SSA has a local allocated
            if haskey(ctx.ssa_locals, val.id)
                local_idx = ctx.ssa_locals[val.id]
                # Check type compatibility: the SSA local's type must match the phi local's type
                local_array_idx = local_idx - ctx.n_params + 1
                ssa_local_type = local_array_idx >= 1 && local_array_idx <= length(ctx.locals) ? ctx.locals[local_array_idx] : nothing
                if phi_local_wasm_type !== nothing && ssa_local_type !== nothing && !wasm_types_compatible(phi_local_wasm_type, ssa_local_type)
                    if phi_local_wasm_type === I64 && ssa_local_type === I32
                        # PURE-313: Return i32 local.get — caller handles i64 widening
                        push!(result, Opcode.LOCAL_GET)
                        append!(result, encode_leb128_unsigned(local_idx))
                    elseif phi_local_wasm_type === ExternRef && (ssa_local_type === I32 || ssa_local_type === I64 || ssa_local_type === F32 || ssa_local_type === F64)
                        # PURE-325: Box numeric local for ExternRef phi
                        push!(result, Opcode.LOCAL_GET)
                        append!(result, encode_leb128_unsigned(local_idx))
                        _box_t = get_numeric_box_type!(ctx.mod, ctx.type_registry, ssa_local_type)
                        push!(result, Opcode.GC_PREFIX)
                        push!(result, Opcode.STRUCT_NEW)
                        append!(result, encode_leb128_unsigned(_box_t))
                        push!(result, Opcode.GC_PREFIX)
                        push!(result, Opcode.EXTERN_CONVERT_ANY)
                    elseif phi_local_wasm_type === ExternRef && (ssa_local_type isa ConcreteRef || ssa_local_type === StructRef || ssa_local_type === ArrayRef || ssa_local_type === AnyRef)
                        # PURE-325: ConcreteRef/StructRef/ArrayRef/AnyRef → ExternRef conversion
                        push!(result, Opcode.LOCAL_GET)
                        append!(result, encode_leb128_unsigned(local_idx))
                        push!(result, Opcode.GC_PREFIX)
                        push!(result, Opcode.EXTERN_CONVERT_ANY)
                    else
                        # Type mismatch: emit type-safe default for the phi local's type
                        append!(result, emit_phi_type_default(phi_local_wasm_type))
                    end
                else
                    push!(result, Opcode.LOCAL_GET)
                    append!(result, encode_leb128_unsigned(local_idx))
                end
            elseif haskey(ctx.phi_locals, val.id)
                local_idx = ctx.phi_locals[val.id]
                # Check type compatibility for phi-to-phi
                src_local_type = ctx.locals[local_idx - ctx.n_params + 1]
                if phi_local_wasm_type !== nothing && !wasm_types_compatible(phi_local_wasm_type, src_local_type)
                    if phi_local_wasm_type === ExternRef && (src_local_type === I32 || src_local_type === I64 || src_local_type === F32 || src_local_type === F64)
                        # PURE-325: Box numeric phi-to-phi for ExternRef
                        push!(result, Opcode.LOCAL_GET)
                        append!(result, encode_leb128_unsigned(local_idx))
                        _box_t = get_numeric_box_type!(ctx.mod, ctx.type_registry, src_local_type)
                        push!(result, Opcode.GC_PREFIX)
                        push!(result, Opcode.STRUCT_NEW)
                        append!(result, encode_leb128_unsigned(_box_t))
                        push!(result, Opcode.GC_PREFIX)
                        push!(result, Opcode.EXTERN_CONVERT_ANY)
                    elseif phi_local_wasm_type === ExternRef && (src_local_type isa ConcreteRef || src_local_type === StructRef || src_local_type === ArrayRef || src_local_type === AnyRef)
                        # PURE-325: ConcreteRef/StructRef/ArrayRef/AnyRef → ExternRef conversion (phi-to-phi)
                        push!(result, Opcode.LOCAL_GET)
                        append!(result, encode_leb128_unsigned(local_idx))
                        push!(result, Opcode.GC_PREFIX)
                        push!(result, Opcode.EXTERN_CONVERT_ANY)
                    else
                        append!(result, emit_phi_type_default(phi_local_wasm_type))
                    end
                else
                    push!(result, Opcode.LOCAL_GET)
                    append!(result, encode_leb128_unsigned(local_idx))
                end
            else
                # SSA without local - need to recompute the statement
                # This should ideally not happen for phi values, but handle it
                # PURE-6021: Guard against out-of-bounds SSAValue IDs (sentinel values)
                if val.id < 1 || val.id > length(code)
                    append!(result, emit_phi_type_default(phi_local_wasm_type))
                    return result
                end
                stmt = code[val.id]
                # PURE-036bg: Check type compatibility for recomputed SSA values
                # The compiled statement may produce a type incompatible with the phi local
                ssa_julia_type = get(ctx.ssa_types, val.id, Any)
                ssa_wasm_type = get_concrete_wasm_type(ssa_julia_type, ctx.mod, ctx.type_registry)
                if phi_local_wasm_type !== nothing && !wasm_types_compatible(phi_local_wasm_type, ssa_wasm_type) && !(phi_local_wasm_type === I64 && ssa_wasm_type === I32)
                    if phi_local_wasm_type === ExternRef && (ssa_wasm_type === I32 || ssa_wasm_type === I64 || ssa_wasm_type === F32 || ssa_wasm_type === F64)
                        # PURE-325: Box recomputed numeric SSA for ExternRef phi
                        if stmt !== nothing && !(stmt isa Core.PhiNode)
                            append!(result, compile_statement(stmt, val.id, ctx))
                        else
                            append!(result, compile_value(val, ctx))
                        end
                        _box_t = get_numeric_box_type!(ctx.mod, ctx.type_registry, ssa_wasm_type)
                        push!(result, Opcode.GC_PREFIX)
                        push!(result, Opcode.STRUCT_NEW)
                        append!(result, encode_leb128_unsigned(_box_t))
                        push!(result, Opcode.GC_PREFIX)
                        push!(result, Opcode.EXTERN_CONVERT_ANY)
                    elseif phi_local_wasm_type === ExternRef && (ssa_wasm_type isa ConcreteRef || ssa_wasm_type === StructRef || ssa_wasm_type === ArrayRef || ssa_wasm_type === AnyRef)
                        # PURE-325: ConcreteRef/StructRef/ArrayRef/AnyRef → ExternRef conversion.
                        # PiNode narrows Any→Expr (ExternRef→ConcreteRef). Compile the value
                        # and wrap with extern_convert_any to get back to ExternRef.
                        @warn "PURE-325 FIX HIT: phi=$phi_idx val=$(val.id) ssa_wasm=$ssa_wasm_type phi_wasm=$phi_local_wasm_type stmt=$(typeof(stmt))"
                        if stmt !== nothing && !(stmt isa Core.PhiNode)
                            append!(result, compile_statement(stmt, val.id, ctx))
                        else
                            append!(result, compile_value(val, ctx))
                        end
                        push!(result, Opcode.GC_PREFIX)
                        push!(result, Opcode.EXTERN_CONVERT_ANY)
                    else
                        # Type mismatch: emit type-safe default instead of recomputing
                        @warn "PURE-325 NULL DEFAULT: phi=$phi_idx val=$(val.id) ssa_wasm=$ssa_wasm_type phi_wasm=$phi_local_wasm_type"
                        append!(result, emit_phi_type_default(phi_local_wasm_type))
                    end
                elseif phi_local_wasm_type !== nothing && phi_local_wasm_type === I64 && ssa_wasm_type === I32
                    # PURE-313: i32 → i64 widening for recomputed SSA without local.
                    # Compile the value as i32 and let the caller (set_phi_locals_for_edge!)
                    # handle the i64.extend_i32_s widening.
                    append!(result, compile_value(val, ctx))
                elseif stmt !== nothing && !(stmt isa Core.PhiNode)
                    append!(result, compile_statement(stmt, val.id, ctx))
                else
                    # Can't recompute - try compile_value as fallback
                    append!(result, compile_value(val, ctx))
                end
            end
        elseif val === nothing || (val isa GlobalRef && val.name === :nothing)
            # Value is `nothing` (can be Core.nothing or Main.nothing in IR)
            # Emit the appropriate null/zero for the phi local's ACTUAL wasm type
            # (which may differ from the Julia type due to phi type resolution)
            if haskey(ctx.phi_locals, phi_idx)
                local_idx = ctx.phi_locals[phi_idx]
                local_wasm_type = ctx.locals[local_idx - ctx.n_params + 1]
                if local_wasm_type isa ConcreteRef
                    push!(result, Opcode.REF_NULL)
                    append!(result, encode_leb128_signed(Int64(local_wasm_type.type_idx)))
                elseif local_wasm_type === ExternRef
                    push!(result, Opcode.REF_NULL)
                    push!(result, UInt8(ExternRef))
                elseif local_wasm_type === StructRef
                    push!(result, Opcode.REF_NULL)
                    push!(result, UInt8(StructRef))
                elseif local_wasm_type === ArrayRef
                    push!(result, Opcode.REF_NULL)
                    push!(result, UInt8(ArrayRef))
                elseif local_wasm_type === AnyRef
                    push!(result, Opcode.REF_NULL)
                    push!(result, UInt8(AnyRef))
                elseif local_wasm_type === I64
                    push!(result, Opcode.I64_CONST)
                    push!(result, 0x00)
                elseif local_wasm_type === F32
                    push!(result, Opcode.F32_CONST)
                    append!(result, UInt8[0x00, 0x00, 0x00, 0x00])
                elseif local_wasm_type === F64
                    push!(result, Opcode.F64_CONST)
                    append!(result, UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
                else
                    # I32 default
                    push!(result, Opcode.I32_CONST)
                    push!(result, 0x00)
                end
            else
                # No phi local found — emit i32(0) as placeholder
                push!(result, Opcode.I32_CONST)
                push!(result, 0x00)
            end
        else
            # Not an SSA and not nothing - just compile directly
            # Check type compatibility for non-SSA values (QuoteNode, literals, etc.)
            if haskey(ctx.phi_locals, phi_idx)
                phi_local_idx = ctx.phi_locals[phi_idx]
                phi_local_type = ctx.locals[phi_local_idx - ctx.n_params + 1]
                edge_val_type = get_phi_edge_wasm_type(val)
                if edge_val_type !== nothing && !wasm_types_compatible(phi_local_type, edge_val_type) && !(phi_local_type === I64 && edge_val_type === I32)
                    if phi_local_type === ExternRef && (edge_val_type === I32 || edge_val_type === I64 || edge_val_type === F32 || edge_val_type === F64)
                        # PURE-325: Box numeric non-SSA value for ExternRef phi
                        append!(result, compile_value(val, ctx))
                        _box_t = get_numeric_box_type!(ctx.mod, ctx.type_registry, edge_val_type)
                        push!(result, Opcode.GC_PREFIX)
                        push!(result, Opcode.STRUCT_NEW)
                        append!(result, encode_leb128_unsigned(_box_t))
                        push!(result, Opcode.GC_PREFIX)
                        push!(result, Opcode.EXTERN_CONVERT_ANY)
                        return result
                    elseif phi_local_type === ExternRef && (edge_val_type isa ConcreteRef || edge_val_type === StructRef || edge_val_type === ArrayRef || edge_val_type === AnyRef)
                        # PURE-4151: ConcreteRef/StructRef/ArrayRef/AnyRef → ExternRef for non-SSA phi edges
                        # (e.g., Union{} literal in phi node produces global.get of DataType struct,
                        #  needs extern_convert_any to store in ExternRef phi local)
                        append!(result, compile_value(val, ctx))
                        push!(result, Opcode.GC_PREFIX)
                        push!(result, Opcode.EXTERN_CONVERT_ANY)
                        return result
                    end
                    # Type mismatch: emit type-safe default instead
                    append!(result, emit_phi_type_default(phi_local_type))
                    return result
                end
            end
            append!(result, compile_value(val, ctx))
        end
        return result
    end

    # Helper: determine the Wasm type that a phi edge value will produce on the stack
    function get_phi_edge_wasm_type(val)::Union{WasmValType, Nothing}
        # PURE-3111: Handle literal nothing — compile_value(nothing) emits i32_const 0
        if val === nothing
            return I32
        end
        # PURE-3111: Handle GlobalRef to nothing (e.g., Core.nothing)
        if val isa GlobalRef && val.name === :nothing
            return I32
        end
        if val isa Core.SSAValue
            # If the SSA has a local allocated, return the local's actual Wasm type.
            # This is what local.get will actually push on the stack, which may differ
            # from the Julia-inferred type when PiNodes narrow types.
            if haskey(ctx.ssa_locals, val.id)
                local_idx = ctx.ssa_locals[val.id]
                local_array_idx = local_idx - ctx.n_params + 1
                if local_array_idx >= 1 && local_array_idx <= length(ctx.locals)
                    return ctx.locals[local_array_idx]
                end
            elseif haskey(ctx.phi_locals, val.id)
                local_idx = ctx.phi_locals[val.id]
                local_array_idx = local_idx - ctx.n_params + 1
                if local_array_idx >= 1 && local_array_idx <= length(ctx.locals)
                    return ctx.locals[local_array_idx]
                end
            end
            edge_julia_type = get(ctx.ssa_types, val.id, nothing)
            if edge_julia_type !== nothing
                return julia_to_wasm_type_concrete(edge_julia_type, ctx)
            end
        elseif val isa Core.Argument
            # PURE-036ab: Use the ACTUAL Wasm parameter type from arg_types, not the Julia slottype.
            # Julia IR uses _1 for function type (not in arg_types), _2 for first arg (arg_types[1]), etc.
            # So arg_types index = val.n - 1 for non-closures.
            arg_types_idx = val.n - 1  # _2 → arg_types[1], _3 → arg_types[2], etc.
            if arg_types_idx >= 1 && arg_types_idx <= length(ctx.arg_types)
                return get_concrete_wasm_type(ctx.arg_types[arg_types_idx], ctx.mod, ctx.type_registry)
            end
        elseif val isa Int64 || val isa UInt64 || val isa Int
            return I64
        elseif val isa Int32 || val isa UInt32 || val isa Bool || val isa UInt8 || val isa Int8 || val isa UInt16 || val isa Int16
            return I32
        elseif val isa Float64
            return F64
        elseif val isa Float32
            return F32
        elseif val isa Symbol || val isa String
            # PURE-036ba: Symbol and String compile to array<i32> (string array type)
            str_type_idx = get_string_array_type!(ctx.mod, ctx.type_registry)
            return ConcreteRef(str_type_idx, false)  # non-nullable since array.new_fixed produces non-nullable ref
        elseif val isa QuoteNode
            # PURE-036bg: QuoteNode wraps a value - recursively determine its Wasm type
            return get_phi_edge_wasm_type(val.value)
        elseif val isa GlobalRef
            # PURE-317: Resolve GlobalRef to its actual value and determine its Wasm type.
            # Without this, GlobalRef falls to the else branch where typeof(val) is GlobalRef
            # and isstructtype(GlobalRef) is true, causing a false type mismatch that replaces
            # the actual value with i32.const 0 (e.g., EOF_CHAR = Char(0xFFFFFFFF) → i32(-1)
            # gets replaced with i32(0), breaking the JuliaSyntax Lexer).
            if val.name === :nothing
                return I32
            end
            try
                actual_val = getfield(val.mod, val.name)
                return get_phi_edge_wasm_type(actual_val)
            catch
                return nothing
            end
        elseif val isa Char
            # PURE-317: Char is a 4-byte primitive type, compiled as I32
            return I32
        elseif val isa Type
            # PURE-4155: Type{T} values are now represented as DataType struct refs (global.get).
            info = register_struct_type!(ctx.mod, ctx.type_registry, DataType)
            return ConcreteRef(info.wasm_type_idx, true)
        else
            # For any other value, try to get its Julia type and convert to Wasm type
            julia_type = typeof(val)
            if isstructtype(julia_type)
                # This will be compiled as struct_new, producing a non-nullable ref
                return get_concrete_wasm_type(julia_type, ctx.mod, ctx.type_registry)
            end
        end
        return nothing
    end

    # Helper: check if two Wasm types are compatible for local.set
    function wasm_types_compatible(local_type::WasmValType, value_type::WasmValType)::Bool
        if local_type == value_type
            return true
        end
        # Numeric types: i32 can be widened to i64 (via i64.extend_i32_s)
        # but they're NOT directly compatible for local.set
        local_is_numeric = local_type === I32 || local_type === I64 || local_type === F32 || local_type === F64
        value_is_numeric = value_type === I32 || value_type === I64 || value_type === F32 || value_type === F64
        local_is_ref = local_type isa ConcreteRef || local_type === StructRef || local_type === ArrayRef || local_type === ExternRef || local_type === AnyRef
        value_is_ref = value_type isa ConcreteRef || value_type === StructRef || value_type === ArrayRef || value_type === ExternRef || value_type === AnyRef
        # Numeric and ref are never compatible
        if local_is_numeric && value_is_ref
            return false
        end
        if local_is_ref && value_is_numeric
            return false
        end
        # Two different numeric types are NOT compatible (i32 != i64 for local.set)
        if local_is_numeric && value_is_numeric && local_type != value_type
            return false
        end
        # Different concrete refs are not directly compatible
        if local_type isa ConcreteRef && value_type isa ConcreteRef && local_type.type_idx != value_type.type_idx
            return false
        end
        # Abstract ref (StructRef/ArrayRef) is NOT directly compatible with ConcreteRef
        # (requires ref.cast to downcast from abstract to concrete)
        if local_type isa ConcreteRef && (value_type === StructRef || value_type === ArrayRef)
            return false
        end
        # ExternRef is NOT compatible with ConcreteRef/StructRef/ArrayRef/AnyRef
        if local_type === ExternRef && (value_type isa ConcreteRef || value_type === StructRef || value_type === ArrayRef || value_type === AnyRef)
            return false
        end
        if value_type === ExternRef && (local_type isa ConcreteRef || local_type === StructRef || local_type === ArrayRef || local_type === AnyRef)
            return false
        end
        return true
    end

    # Helper to set all phi locals at destination
    # dest_block: the block index being jumped to
    # terminator_idx: the statement index of the terminator (edge in phi)
    # target_stmt: optional - the actual statement being jumped to (may differ from block start)
    function set_phi_locals_for_edge!(bytes::Vector{UInt8}, dest_block::Int, terminator_idx::Int; target_stmt::Int=0)
        if dest_block < 1 || dest_block > length(blocks)
            return
        end
        # If target_stmt is specified, start from there; otherwise start from block start
        dest_start = target_stmt > 0 ? target_stmt : blocks[dest_block].start_idx
        dest_end = blocks[dest_block].end_idx

        # PURE-1001: Detect circular phi references (simultaneous assignment)
        # When phi A's value reads phi B's local and both are being set on the same edge,
        # we must save old values to temps first to avoid read-after-write corruption.
        # Example: a, b = b, a+b → %17=phi(edge→%19), %18=phi(edge→%17)
        # Without temps, setting %17 first corrupts the value %18 reads.
        phi_locals_being_set = Set{Int}()  # phi local indices being updated on this edge
        phi_values_reading = Dict{Int,Int}()  # phi_stmt_idx → phi_local it reads from (if any)
        for i in dest_start:dest_end
            stmt = code[i]
            if stmt isa Core.PhiNode && haskey(ctx.phi_locals, i)
                for (edge_idx, edge) in enumerate(stmt.edges)
                    if edge == terminator_idx && isassigned(stmt.values, edge_idx)
                        push!(phi_locals_being_set, ctx.phi_locals[i])
                        val = stmt.values[edge_idx]
                        # Check if val references another phi local
                        if val isa Core.SSAValue && haskey(ctx.phi_locals, val.id)
                            phi_values_reading[i] = ctx.phi_locals[val.id]
                        end
                        break
                    end
                end
            elseif !(stmt isa Core.PhiNode)
                break
            end
        end

        # If any phi reads from another phi local that is ALSO being set, use temps
        needs_temp = Dict{Int,Int}()  # original phi_local → temp local index
        for (phi_idx, read_local) in phi_values_reading
            if read_local in phi_locals_being_set && read_local != ctx.phi_locals[phi_idx]
                # read_local is being set on this edge AND read by another phi → need temp
                if !haskey(needs_temp, read_local)
                    phi_local_array_idx = read_local - ctx.n_params + 1
                    local_type = phi_local_array_idx >= 1 && phi_local_array_idx <= length(ctx.locals) ? ctx.locals[phi_local_array_idx] : I64
                    temp_local = allocate_local!(ctx, local_type)
                    needs_temp[read_local] = temp_local
                    # Save old value: local.get $orig → local.set $temp
                    push!(bytes, Opcode.LOCAL_GET)
                    append!(bytes, encode_leb128_unsigned(read_local))
                    push!(bytes, Opcode.LOCAL_SET)
                    append!(bytes, encode_leb128_unsigned(temp_local))
                end
            end
        end

        phi_count = 0
        for i in dest_start:dest_end
            stmt = code[i]
            if stmt isa Core.PhiNode
                if haskey(ctx.phi_locals, i)
                    found_edge = false
                    for (edge_idx, edge) in enumerate(stmt.edges)
                        if edge == terminator_idx
                            if isassigned(stmt.values, edge_idx)
                                val = stmt.values[edge_idx]
                                # Check type compatibility before emitting local.set
                                local_idx = ctx.phi_locals[i]
                                phi_local_type = ctx.locals[local_idx - ctx.n_params + 1]
                                edge_val_type = get_phi_edge_wasm_type(val)

                                if edge_val_type !== nothing && !wasm_types_compatible(phi_local_type, edge_val_type) && !(phi_local_type === I64 && edge_val_type === I32)
                                    if phi_local_type === ExternRef && (edge_val_type === I32 || edge_val_type === I64 || edge_val_type === F32 || edge_val_type === F64)
                                        # PURE-325: Box numeric phi edge for ExternRef local
                                        _pvb2 = compile_phi_value(val, i)
                                        if !isempty(_pvb2)
                                            _pvb2_boxed = length(_pvb2) >= 2 && _pvb2[end-1] == Opcode.GC_PREFIX && _pvb2[end] == Opcode.EXTERN_CONVERT_ANY
                                            # PURE-602: compile_phi_value may return ref.null extern for nothing values
                                            _pvb2_is_ref_null = length(_pvb2) >= 1 && _pvb2[1] == Opcode.REF_NULL
                                            append!(bytes, _pvb2)
                                            if !_pvb2_boxed && !_pvb2_is_ref_null
                                                _box_t2 = get_numeric_box_type!(ctx.mod, ctx.type_registry, edge_val_type)
                                                push!(bytes, Opcode.GC_PREFIX)
                                                push!(bytes, Opcode.STRUCT_NEW)
                                                append!(bytes, encode_leb128_unsigned(_box_t2))
                                                push!(bytes, Opcode.GC_PREFIX)
                                                push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                                            end
                                            push!(bytes, Opcode.LOCAL_SET)
                                            append!(bytes, encode_leb128_unsigned(local_idx))
                                            phi_count += 1
                                            found_edge = true
                                            break
                                        end
                                    end
                                    if phi_local_type === ExternRef && (edge_val_type isa ConcreteRef || edge_val_type === StructRef || edge_val_type === ArrayRef || edge_val_type === AnyRef)
                                        # PURE-325: ConcreteRef/StructRef/ArrayRef/AnyRef → ExternRef conversion
                                        _pvb3 = compile_phi_value(val, i)
                                        if !isempty(_pvb3)
                                            _pvb3_has_ecv = length(_pvb3) >= 2 && _pvb3[end-1] == Opcode.GC_PREFIX && _pvb3[end] == Opcode.EXTERN_CONVERT_ANY
                                            # PURE-803: compile_phi_value may return ref.null extern for type-mismatch fallback
                                            # ref.null extern is already externref — extern_convert_any expects anyref input
                                            _pvb3_is_ref_null = length(_pvb3) >= 1 && _pvb3[1] == Opcode.REF_NULL
                                            append!(bytes, _pvb3)
                                            if !_pvb3_has_ecv && !_pvb3_is_ref_null
                                                push!(bytes, Opcode.GC_PREFIX)
                                                push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                                            end
                                            push!(bytes, Opcode.LOCAL_SET)
                                            append!(bytes, encode_leb128_unsigned(local_idx))
                                            phi_count += 1
                                            found_edge = true
                                            break
                                        end
                                    end
                                    # Type mismatch: emit type-safe default
                                    append!(bytes, emit_phi_type_default(phi_local_type))
                                    push!(bytes, Opcode.LOCAL_SET)
                                    append!(bytes, encode_leb128_unsigned(local_idx))
                                    phi_count += 1
                                    found_edge = true
                                    break
                                end

                                phi_value_bytes = compile_phi_value(val, i)
                                # PURE-1001: If phi value reads from a remapped phi local, use temp
                                if !isempty(needs_temp) && length(phi_value_bytes) >= 2 && phi_value_bytes[1] == Opcode.LOCAL_GET
                                    _got_idx = 0; _shift = 0
                                    for bi in 2:length(phi_value_bytes)
                                        b = phi_value_bytes[bi]
                                        _got_idx |= (Int(b & 0x7f) << _shift)
                                        _shift += 7
                                        if (b & 0x80) == 0; break; end
                                    end
                                    if haskey(needs_temp, _got_idx)
                                        phi_value_bytes = UInt8[Opcode.LOCAL_GET]
                                        append!(phi_value_bytes, encode_leb128_unsigned(needs_temp[_got_idx]))
                                    end
                                end
                                # Detect multi-value bytes (all local_gets, N>=2).
                                # local_set only consumes 1, so N-1 would be orphaned.
                                if length(phi_value_bytes) >= 4
                                    _pv_all2 = true; _pv_n2 = 0; _pv_p2 = 1
                                    while _pv_p2 <= length(phi_value_bytes)
                                        if phi_value_bytes[_pv_p2] != 0x20; _pv_all2 = false; break; end
                                        _pv_n2 += 1; _pv_p2 += 1
                                        while _pv_p2 <= length(phi_value_bytes) && (phi_value_bytes[_pv_p2] & 0x80) != 0; _pv_p2 += 1; end
                                        _pv_p2 += 1
                                    end
                                    if _pv_all2 && _pv_p2 > length(phi_value_bytes) && _pv_n2 >= 2
                                        phi_value_bytes = emit_phi_type_default(phi_local_type)
                                    end
                                end
                                # Only emit local_set if we actually have a value on the stack
                                if !isempty(phi_value_bytes)
                                    # Safety check: if compile_phi_value produced a local.get,
                                    # verify the local's actual type matches the phi local type.
                                    # This catches cases where get_phi_edge_wasm_type reports compatible
                                    # (from Julia type inference) but the actual local has a different type
                                    # (e.g., externref from Any-typed struct field overrides).
                                    # PURE-325: If compile_phi_value already boxed, skip safety check
                                    _already_boxed2 = length(phi_value_bytes) >= 2 && phi_value_bytes[end-1] == Opcode.GC_PREFIX && phi_value_bytes[end] == Opcode.EXTERN_CONVERT_ANY
                                    actual_val_type = edge_val_type
                                    if !_already_boxed2 && length(phi_value_bytes) >= 2 && phi_value_bytes[1] == Opcode.LOCAL_GET
                                        # Decode the local index from unsigned LEB128
                                        got_local_idx = 0
                                        shift = 0
                                        for bi in 2:length(phi_value_bytes)
                                            b = phi_value_bytes[bi]
                                            got_local_idx |= (Int(b & 0x7f) << shift)
                                            shift += 7
                                            if (b & 0x80) == 0
                                                break
                                            end
                                        end
                                        got_local_array_idx = got_local_idx - ctx.n_params + 1
                                        if got_local_array_idx >= 1 && got_local_array_idx <= length(ctx.locals)
                                            actual_val_type = ctx.locals[got_local_array_idx]
                                        elseif got_local_idx < ctx.n_params
                                            # It's a parameter - get Wasm type from arg_types
                                            param_julia_type = ctx.arg_types[got_local_idx + 1]  # Julia is 1-indexed
                                            actual_val_type = get_concrete_wasm_type(param_julia_type, ctx.mod, ctx.type_registry)
                                        end
                                    end

                                    if _already_boxed2
                                        append!(bytes, phi_value_bytes)
                                    elseif actual_val_type !== nothing && !wasm_types_compatible(phi_local_type, actual_val_type) && !(phi_local_type === I64 && actual_val_type === I32) && !(phi_local_type === F64 && (actual_val_type === I64 || actual_val_type === I32 || actual_val_type === F32)) && !(phi_local_type === F32 && (actual_val_type === I64 || actual_val_type === I32))
                                        # PURE-325: ConcreteRef/StructRef/ArrayRef/AnyRef → ExternRef:
                                        # wrap with extern_convert_any instead of null default
                                        if phi_local_type === ExternRef && (actual_val_type isa ConcreteRef || actual_val_type === StructRef || actual_val_type === ArrayRef || actual_val_type === AnyRef)
                                            append!(bytes, phi_value_bytes)
                                            # PURE-803: ref.null extern is already externref — don't wrap with extern_convert_any
                                            _is_ref_null2 = length(phi_value_bytes) >= 1 && phi_value_bytes[1] == Opcode.REF_NULL
                                            if !_is_ref_null2
                                                push!(bytes, Opcode.GC_PREFIX)
                                                push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                                            end
                                        else
                                            # Type mismatch detected at emit point: replace with default
                                            append!(bytes, emit_phi_type_default(phi_local_type))
                                        end
                                    elseif actual_val_type !== nothing && phi_local_type === I64 && actual_val_type === I32
                                        # Numeric widening: i32 value into i64 local
                                        # PURE-324: Skip extend if compiled bytes are already i64
                                        # (happens when compile_phi_value emitted an i64 default)
                                        append!(bytes, phi_value_bytes)
                                        if isempty(phi_value_bytes) || phi_value_bytes[1] != Opcode.I64_CONST
                                            push!(bytes, Opcode.I64_EXTEND_I32_S)
                                        end
                                    elseif actual_val_type !== nothing && phi_local_type === F64 && actual_val_type === I64
                                        append!(bytes, phi_value_bytes)
                                        push!(bytes, Opcode.F64_CONVERT_I64_S)
                                    elseif actual_val_type !== nothing && phi_local_type === F64 && actual_val_type === I32
                                        append!(bytes, phi_value_bytes)
                                        push!(bytes, Opcode.F64_CONVERT_I32_S)
                                    elseif actual_val_type !== nothing && phi_local_type === F64 && actual_val_type === F32
                                        append!(bytes, phi_value_bytes)
                                        push!(bytes, Opcode.F64_PROMOTE_F32)
                                    elseif actual_val_type !== nothing && phi_local_type === F32 && (actual_val_type === I64 || actual_val_type === I32)
                                        append!(bytes, phi_value_bytes)
                                        push!(bytes, actual_val_type === I64 ? Opcode.F32_CONVERT_I64_S : Opcode.F32_CONVERT_I32_S)
                                    else
                                        # PURE-6025: Final safety net — detect numeric constants
                                        # being stored to ref-typed locals. This happens when
                                        # get_phi_edge_wasm_type returns ConcreteRef (from Julia
                                        # type inference of a Union type) but compile_phi_value
                                        # actually emits a numeric constant (e.g., UInt8 literal
                                        # like ExternRef=0x6f=111). The LOCAL_GET check above
                                        # doesn't catch this because the value is a recomputed
                                        # statement, not a local.get.
                                        phi_is_ref = phi_local_type isa ConcreteRef || phi_local_type === StructRef || phi_local_type === ArrayRef || phi_local_type === AnyRef || phi_local_type === ExternRef
                                        phi_val_is_numeric = !isempty(phi_value_bytes) && (phi_value_bytes[1] == Opcode.I32_CONST || phi_value_bytes[1] == Opcode.I64_CONST || phi_value_bytes[1] == Opcode.F32_CONST || phi_value_bytes[1] == Opcode.F64_CONST)
                                        if phi_is_ref && phi_val_is_numeric
                                            append!(bytes, emit_phi_type_default(phi_local_type))
                                        else
                                            append!(bytes, phi_value_bytes)
                                        end
                                    end
                                    push!(bytes, Opcode.LOCAL_SET)
                                    append!(bytes, encode_leb128_unsigned(local_idx))
                                    phi_count += 1
                                end
                            end
                            found_edge = true
                            break
                        end
                    end
                end
            else
                break  # Phi nodes are consecutive at the start
            end
        end
    end

    # PURE-6024 debug: trace function name for debugging
    _debug_fn_name = try string(ctx.func_name) catch; "" end
    _debug_stackified = contains(_debug_fn_name, "parse_int_literal")
    if _debug_stackified
        @warn "PURE-6024 STACKIFIED DEBUG: $(length(blocks)) blocks, non_trivial_targets=$non_trivial_targets, outer_targets=$outer_targets, return_type=$(ctx.return_type)"
    end

    # Now generate code for each block in order
    for (block_idx, block) in enumerate(blocks)
        # First, close any blocks whose target is this block
        # (We close BEFORE generating code for the target block)
        while !isempty(open_blocks) && last(open_blocks) == block_idx
            pop!(open_blocks)
            push!(bytes, Opcode.END)  # End the block for this target
            if _debug_stackified
                @warn "  CLOSE block for target $block_idx, open_blocks=$open_blocks, bytes_len=$(length(bytes))"
            end
        end

        # Skip dead blocks (from boundscheck patterns)
        if block_idx in dead_blocks
            if _debug_stackified
                @warn "  SKIP dead block $block_idx"
            end
            continue
        end

        # Check if we're entering a loop
        is_loop_header = block_idx in loop_headers

        if is_loop_header
            push!(bytes, Opcode.LOOP)
            push!(bytes, 0x40)  # void
            push!(open_loops, block_idx)

            # Open BLOCKs for forward-jump targets INSIDE this loop
            if haskey(loop_inner_targets, block_idx)
                inner_targets = loop_inner_targets[block_idx]
                for target in inner_targets  # already sorted desc (largest first = outermost)
                    push!(bytes, Opcode.BLOCK)
                    push!(bytes, 0x40)  # void
                end
                # Push inner targets onto open_blocks (smallest last = innermost at top)
                append!(open_blocks, inner_targets)
            end
        end

        # Compile the block's statements (not the terminator, we handle it separately)
        # Skip any dead statements within the block
        block_bytes = UInt8[]
        # PURE-7001a: Reset dead code guard at block boundaries. Each non-dead block
        # is reachable via a different control flow path, so a stub flag from a previous
        # block must not cascade. Without this, compile_statement emits unreachable on
        # valid fall-through paths after br_if (e.g., _next_token codepoint check).
        ctx.last_stmt_was_stub = false
        for i in block.start_idx:block.end_idx
            # Skip dead statements
            if i in dead_regions
                continue
            end
            if i in boundscheck_jumps
                continue  # This GotoIfNot always jumps - skip it (handled below)
            end

            stmt = code[i]

            # Skip terminator if we're going to handle it separately
            if i == block.end_idx && (stmt isa Core.GotoIfNot || stmt isa Core.GotoNode || stmt isa Core.ReturnNode)
                continue
            end

            if stmt isa Core.ReturnNode
                if isdefined(stmt, :val)
                    val_wasm_type = infer_value_wasm_type(stmt.val, ctx)
                    ret_wasm_type = julia_to_wasm_type_concrete(ctx.return_type, ctx)
                    func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                    # PURE-315: Check numeric-to-ref BEFORE return_type_compatible
                    is_numeric_val = val_wasm_type === I32 || val_wasm_type === I64 || val_wasm_type === F32 || val_wasm_type === F64
                    is_ref_ret = func_ret_wasm isa ConcreteRef || func_ret_wasm === ExternRef || func_ret_wasm === StructRef || func_ret_wasm === ArrayRef || func_ret_wasm === AnyRef
                    if is_numeric_val && is_ref_ret
                        # PURE-325: Box numeric value for ref return type
                        if func_ret_wasm === ExternRef
                            emit_numeric_to_externref!(block_bytes, stmt.val, val_wasm_type, ctx)
                        elseif func_ret_wasm isa ConcreteRef
                            push!(block_bytes, Opcode.REF_NULL)
                            append!(block_bytes, encode_leb128_signed(Int64(func_ret_wasm.type_idx)))
                        else
                            push!(block_bytes, Opcode.REF_NULL)
                            push!(block_bytes, UInt8(func_ret_wasm))
                        end
                        push!(block_bytes, Opcode.RETURN)
                    elseif !return_type_compatible(val_wasm_type, func_ret_wasm)
                        push!(block_bytes, Opcode.UNREACHABLE)
                    else
                        append!(block_bytes, compile_value(stmt.val, ctx))
                        if func_ret_wasm === ExternRef && val_wasm_type !== ExternRef
                            push!(block_bytes, Opcode.GC_PREFIX)
                            push!(block_bytes, Opcode.EXTERN_CONVERT_ANY)
                        elseif val_wasm_type === I32 && func_ret_wasm === I64
                            push!(block_bytes, Opcode.I64_EXTEND_I32_S)
                        elseif val_wasm_type === I64 && func_ret_wasm === F64
                            push!(block_bytes, Opcode.F64_CONVERT_I64_S)
                        elseif val_wasm_type === I32 && func_ret_wasm === F64
                            push!(block_bytes, Opcode.F64_CONVERT_I32_S)
                        elseif val_wasm_type === F32 && func_ret_wasm === F64
                            push!(block_bytes, Opcode.F64_PROMOTE_F32)
                        elseif val_wasm_type === I64 && func_ret_wasm === F32
                            push!(block_bytes, Opcode.F32_CONVERT_I64_S)
                        elseif val_wasm_type === I32 && func_ret_wasm === F32
                            push!(block_bytes, Opcode.F32_CONVERT_I32_S)
                        end
                        push!(block_bytes, Opcode.RETURN)
                    end
                else
                    push!(block_bytes, Opcode.RETURN)
                end

            elseif stmt isa Core.GotoIfNot
                # GotoIfNot: handled by control flow structure
                # Nothing to emit here

            elseif stmt isa Core.GotoNode
                # Unconditional goto: handled by control flow structure
                # Nothing to emit here

            elseif stmt isa Core.PhiNode
                # Phi nodes: check if we're falling through from a previous statement
                if haskey(ctx.phi_locals, i)
                    for (edge_idx, edge) in enumerate(stmt.edges)
                        if edge >= block.start_idx && edge < i
                            if isassigned(stmt.values, edge_idx)
                                val = stmt.values[edge_idx]
                                # Check type compatibility before storing
                                local_idx = ctx.phi_locals[i]
                                phi_local_type = ctx.locals[local_idx - ctx.n_params + 1]
                                edge_val_type = get_phi_edge_wasm_type(val)
                                if edge_val_type !== nothing && !wasm_types_compatible(phi_local_type, edge_val_type) && !(phi_local_type === I64 && edge_val_type === I32)
                                    if phi_local_type === ExternRef && (edge_val_type === I32 || edge_val_type === I64 || edge_val_type === F32 || edge_val_type === F64)
                                        # PURE-325: Box numeric phi edge for ExternRef local
                                        _pvb3 = compile_phi_value(val, i)
                                        if !isempty(_pvb3)
                                            _pvb3_boxed = length(_pvb3) >= 2 && _pvb3[end-1] == Opcode.GC_PREFIX && _pvb3[end] == Opcode.EXTERN_CONVERT_ANY
                                            # PURE-602: compile_phi_value may return ref.null extern for nothing values
                                            _pvb3_is_ref_null = length(_pvb3) >= 1 && _pvb3[1] == Opcode.REF_NULL
                                            append!(block_bytes, _pvb3)
                                            if !_pvb3_boxed && !_pvb3_is_ref_null
                                                _box_t3 = get_numeric_box_type!(ctx.mod, ctx.type_registry, edge_val_type)
                                                push!(block_bytes, Opcode.GC_PREFIX)
                                                push!(block_bytes, Opcode.STRUCT_NEW)
                                                append!(block_bytes, encode_leb128_unsigned(_box_t3))
                                                push!(block_bytes, Opcode.GC_PREFIX)
                                                push!(block_bytes, Opcode.EXTERN_CONVERT_ANY)
                                            end
                                            push!(block_bytes, Opcode.LOCAL_SET)
                                            append!(block_bytes, encode_leb128_unsigned(local_idx))
                                            break
                                        end
                                    end
                                    # Type mismatch: emit type-safe default
                                    append!(block_bytes, emit_phi_type_default(phi_local_type))
                                    push!(block_bytes, Opcode.LOCAL_SET)
                                    append!(block_bytes, encode_leb128_unsigned(local_idx))
                                    break
                                end
                                phi_value_bytes = compile_phi_value(val, i)
                                # Detect multi-value bytes (all local_gets, N>=2).
                                # local_set only consumes 1 value, so N-1 would be orphaned.
                                if length(phi_value_bytes) >= 4
                                    _pv_all = true; _pv_n = 0; _pv_p = 1
                                    while _pv_p <= length(phi_value_bytes)
                                        if phi_value_bytes[_pv_p] != 0x20; _pv_all = false; break; end
                                        _pv_n += 1; _pv_p += 1
                                        while _pv_p <= length(phi_value_bytes) && (phi_value_bytes[_pv_p] & 0x80) != 0; _pv_p += 1; end
                                        _pv_p += 1
                                    end
                                    if _pv_all && _pv_p > length(phi_value_bytes) && _pv_n >= 2
                                        # Multi-value: replace with type-safe default
                                        phi_value_bytes = emit_phi_type_default(phi_local_type)
                                    end
                                end
                                if !isempty(phi_value_bytes)
                                    # PURE-325: If compile_phi_value already boxed, skip safety check
                                    _already_boxed3 = length(phi_value_bytes) >= 2 && phi_value_bytes[end-1] == Opcode.GC_PREFIX && phi_value_bytes[end] == Opcode.EXTERN_CONVERT_ANY
                                    # Safety check: verify actual local.get type matches phi local
                                    actual_val_type = edge_val_type
                                    if !_already_boxed3 && length(phi_value_bytes) >= 2 && phi_value_bytes[1] == Opcode.LOCAL_GET
                                        got_local_idx = 0
                                        shift = 0
                                        for bi in 2:length(phi_value_bytes)
                                            b = phi_value_bytes[bi]
                                            got_local_idx |= (Int(b & 0x7f) << shift)
                                            shift += 7
                                            if (b & 0x80) == 0
                                                break
                                            end
                                        end
                                        got_local_array_idx = got_local_idx - ctx.n_params + 1
                                        if got_local_array_idx >= 1 && got_local_array_idx <= length(ctx.locals)
                                            actual_val_type = ctx.locals[got_local_array_idx]
                                        elseif got_local_idx < ctx.n_params
                                            # It's a parameter - get Wasm type from arg_types
                                            param_julia_type = ctx.arg_types[got_local_idx + 1]  # Julia is 1-indexed
                                            actual_val_type = get_concrete_wasm_type(param_julia_type, ctx.mod, ctx.type_registry)
                                        end
                                    end

                                    if _already_boxed3
                                        append!(block_bytes, phi_value_bytes)
                                    elseif actual_val_type !== nothing && !wasm_types_compatible(phi_local_type, actual_val_type) && !(phi_local_type === I64 && actual_val_type === I32) && !(phi_local_type === F64 && (actual_val_type === I64 || actual_val_type === I32 || actual_val_type === F32)) && !(phi_local_type === F32 && (actual_val_type === I64 || actual_val_type === I32))
                                        # PURE-325: ConcreteRef/StructRef/ArrayRef/AnyRef → ExternRef:
                                        # wrap with extern_convert_any instead of null default
                                        if phi_local_type === ExternRef && (actual_val_type isa ConcreteRef || actual_val_type === StructRef || actual_val_type === ArrayRef || actual_val_type === AnyRef)
                                            append!(block_bytes, phi_value_bytes)
                                            # PURE-803: ref.null extern is already externref — don't wrap with extern_convert_any
                                            _is_ref_null3 = length(phi_value_bytes) >= 1 && phi_value_bytes[1] == Opcode.REF_NULL
                                            if !_is_ref_null3
                                                push!(block_bytes, Opcode.GC_PREFIX)
                                                push!(block_bytes, Opcode.EXTERN_CONVERT_ANY)
                                            end
                                        else
                                            append!(block_bytes, emit_phi_type_default(phi_local_type))
                                        end
                                    elseif actual_val_type !== nothing && phi_local_type === I64 && actual_val_type === I32
                                        append!(block_bytes, phi_value_bytes)
                                        if isempty(phi_value_bytes) || phi_value_bytes[1] != Opcode.I64_CONST
                                            push!(block_bytes, Opcode.I64_EXTEND_I32_S)
                                        end
                                    elseif actual_val_type !== nothing && phi_local_type === F64 && actual_val_type === I64
                                        append!(block_bytes, phi_value_bytes)
                                        push!(block_bytes, Opcode.F64_CONVERT_I64_S)
                                    elseif actual_val_type !== nothing && phi_local_type === F64 && actual_val_type === I32
                                        append!(block_bytes, phi_value_bytes)
                                        push!(block_bytes, Opcode.F64_CONVERT_I32_S)
                                    elseif actual_val_type !== nothing && phi_local_type === F64 && actual_val_type === F32
                                        append!(block_bytes, phi_value_bytes)
                                        push!(block_bytes, Opcode.F64_PROMOTE_F32)
                                    elseif actual_val_type !== nothing && phi_local_type === F32 && (actual_val_type === I64 || actual_val_type === I32)
                                        append!(block_bytes, phi_value_bytes)
                                        push!(block_bytes, actual_val_type === I64 ? Opcode.F32_CONVERT_I64_S : Opcode.F32_CONVERT_I32_S)
                                    else
                                        append!(block_bytes, phi_value_bytes)
                                    end
                                    push!(block_bytes, Opcode.LOCAL_SET)
                                    append!(block_bytes, encode_leb128_unsigned(local_idx))
                                end
                            end
                            break
                        end
                    end
                end

            elseif stmt === nothing
                # Nothing statement

            else
                stmt_bytes = compile_statement(stmt, i, ctx)
                append!(block_bytes, stmt_bytes)

                # PURE-6024: Skip remaining statements after unreachable.
                stmt_type2 = get(ctx.ssa_types, i, Any)
                if stmt_type2 === Union{} || ctx.last_stmt_was_stub
                    break
                end

                if !haskey(ctx.ssa_locals, i)
                    # PURE-220: Skip if compile_statement already emitted a DROP
                    # PURE-6006: Guard against call instruction false-positive (func_idx 0x1a == DROP)
                    already_dropped = !isempty(stmt_bytes) && stmt_bytes[end] == Opcode.DROP &&
                                      !(length(stmt_bytes) >= 2 && stmt_bytes[end-1] == Opcode.CALL)
                    if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                        if !already_dropped && statement_produces_wasm_value(stmt, i, ctx)
                            if !haskey(ctx.phi_locals, i)
                                use_count = get(ssa_use_count, i, 0)
                                if use_count == 0
                                    push!(block_bytes, Opcode.DROP)
                                end
                            end
                        end
                    elseif stmt isa Core.PiNode && !isempty(stmt_bytes)
                        # PiNode without ssa_local pushed a value onto the stack.
                        # Drop it if it's only used by phi edges (phi stores re-compute
                        # the value via compile_phi_value, so this stack value is orphaned).
                        non_phi_uses = get(ssa_non_phi_uses, i, 0)
                        if non_phi_uses == 0
                            push!(block_bytes, Opcode.DROP)
                        end
                    end
                end
            end
        end
        append!(bytes, block_bytes)

        # Handle the terminator
        term = block.terminator
        terminator_idx = block.end_idx

        # Check if this terminator is a boundscheck always-jump
        if terminator_idx in boundscheck_jumps && term isa Core.GotoIfNot
            # This is an always-jump - emit unconditional br to the target
            dest_block = get(stmt_to_block, term.dest, nothing)
            if dest_block !== nothing && dest_block > block_idx && dest_block in non_trivial_targets
                label_depth = get_forward_label_depth(dest_block)
                push!(bytes, Opcode.BR)
                append!(bytes, encode_leb128_unsigned(label_depth))
            end
            # Otherwise, it's just a fall-through to a live block - nothing needed

        elseif term isa Core.ReturnNode
            if _debug_stackified
                @warn "  RETURN terminator at block $block_idx: term=$(term), val=$(isdefined(term,:val) ? term.val : :undef)"
            end
            if isdefined(term, :val)
                val_wasm_type = infer_value_wasm_type(term.val, ctx)
                ret_wasm_type = julia_to_wasm_type_concrete(ctx.return_type, ctx)
                func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                if _debug_stackified
                    @warn "  RETURN types: val_wasm=$val_wasm_type, ret_wasm=$ret_wasm_type, func_ret=$func_ret_wasm, compatible=$(return_type_compatible(val_wasm_type, func_ret_wasm))"
                end
                # PURE-315: Check numeric-to-ref BEFORE return_type_compatible
                is_numeric_val = val_wasm_type === I32 || val_wasm_type === I64 || val_wasm_type === F32 || val_wasm_type === F64
                is_ref_ret = func_ret_wasm isa ConcreteRef || func_ret_wasm === ExternRef || func_ret_wasm === StructRef || func_ret_wasm === ArrayRef || func_ret_wasm === AnyRef
                if is_numeric_val && is_ref_ret
                    if func_ret_wasm === ExternRef
                        emit_numeric_to_externref!(bytes, term.val, val_wasm_type, ctx)
                    elseif func_ret_wasm isa ConcreteRef
                        push!(bytes, Opcode.REF_NULL)
                        append!(bytes, encode_leb128_signed(Int64(func_ret_wasm.type_idx)))
                    else
                        push!(bytes, Opcode.REF_NULL)
                        push!(bytes, UInt8(func_ret_wasm))
                    end
                    push!(bytes, Opcode.RETURN)
                # PURE-6024: Use func_ret_wasm (actual WASM function signature type) for
                # return type compatibility, not ret_wasm_type (julia_to_wasm_type_concrete).
                # These disagree for Union types like Union{Int128, Int64, BigInt} where
                # func_ret_wasm=I64 but ret_wasm_type=ConcreteRef(tagged_union).
                # The phi local is correctly overridden to I64 (line 5196), so the value
                # on the stack IS I64, but checking against ConcreteRef incorrectly fails.
                elseif !return_type_compatible(val_wasm_type, func_ret_wasm)
                    push!(bytes, Opcode.UNREACHABLE)
                else
                    val_bytes = compile_value(term.val, ctx)
                    append!(bytes, val_bytes)
                    if func_ret_wasm === ExternRef && val_wasm_type !== ExternRef
                        is_externref_local = false
                        if length(val_bytes) >= 2 && val_bytes[1] == 0x20
                            src_idx = 0; shift = 0; leb_end = 0
                            for bi in 2:length(val_bytes)
                                b = val_bytes[bi]
                                src_idx |= (Int(b & 0x7f) << shift)
                                shift += 7
                                if (b & 0x80) == 0
                                    leb_end = bi
                                    break
                                end
                            end
                            if leb_end == length(val_bytes)
                                if src_idx < ctx.n_params
                                    if src_idx + 1 <= length(ctx.arg_types)
                                        src_type = ctx.arg_types[src_idx + 1]
                                        is_externref_local = src_type === ExternRef
                                    end
                                else
                                    arr_idx = src_idx - ctx.n_params + 1
                                    if arr_idx >= 1 && arr_idx <= length(ctx.locals)
                                        src_type = ctx.locals[arr_idx]
                                        is_externref_local = src_type === ExternRef
                                    end
                                end
                            end
                        end
                        if !is_externref_local
                            push!(bytes, Opcode.GC_PREFIX)
                            push!(bytes, Opcode.EXTERN_CONVERT_ANY)
                        end
                    elseif val_wasm_type === I32 && func_ret_wasm === I64
                        push!(bytes, Opcode.I64_EXTEND_I32_S)
                    elseif val_wasm_type === I64 && func_ret_wasm === F64
                        push!(bytes, Opcode.F64_CONVERT_I64_S)
                    elseif val_wasm_type === I32 && func_ret_wasm === F64
                        push!(bytes, Opcode.F64_CONVERT_I32_S)
                    elseif val_wasm_type === F32 && func_ret_wasm === F64
                        push!(bytes, Opcode.F64_PROMOTE_F32)
                    elseif val_wasm_type === I64 && func_ret_wasm === F32
                        push!(bytes, Opcode.F32_CONVERT_I64_S)
                    elseif val_wasm_type === I32 && func_ret_wasm === F32
                        push!(bytes, Opcode.F32_CONVERT_I32_S)
                    end
                    push!(bytes, Opcode.RETURN)
                end
            else
                push!(bytes, Opcode.RETURN)
            end

        elseif term isa Core.GotoIfNot
            dest_block = get(stmt_to_block, term.dest, nothing)

            # Resolve through dead boundscheck blocks to find real target
            if dest_block !== nothing && dest_block in dead_blocks
                dest_block = resolve_through_dead_boundscheck(dest_block)
            end

            # Check if destination has phi nodes that need values from this edge
            has_phi = dest_block !== nothing && dest_has_phi_from_edge(dest_block, terminator_idx)

            # Compile condition
            cond_bytes = compile_condition_to_i32(term.cond, ctx)
            append!(bytes, cond_bytes)

            # If condition is TRUE, fall through to next block
            # If condition is FALSE, jump to dest

            if dest_block !== nothing && dest_block > block_idx
                # Forward jump when condition is false
                if dest_block in non_trivial_targets
                    if has_phi
                        # Need to set phi values before jumping - use if/else
                        push!(bytes, Opcode.IF)
                        push!(bytes, 0x40)  # void
                        # Then branch: condition true, fall through (empty)
                        push!(bytes, Opcode.ELSE)
                        # Else branch: condition false, set all phi locals and jump
                        set_phi_locals_for_edge!(bytes, dest_block, terminator_idx; target_stmt=term.dest)
                        # Jump to destination (account for the if block we're inside)
                        label_depth = get_forward_label_depth(dest_block) + 1
                        push!(bytes, Opcode.BR)
                        append!(bytes, encode_leb128_unsigned(label_depth))
                        push!(bytes, Opcode.END)
                    else
                        # No phi - use br_if
                        label_depth = get_forward_label_depth(dest_block)
                        push!(bytes, Opcode.I32_EQZ)  # Invert the condition
                        push!(bytes, Opcode.BR_IF)
                        append!(bytes, encode_leb128_unsigned(label_depth))
                    end
                else
                    # Simple fall-through pattern - condition true continues, false skips
                    if has_phi
                        push!(bytes, Opcode.IF)
                        push!(bytes, 0x40)
                        push!(bytes, Opcode.ELSE)
                        set_phi_locals_for_edge!(bytes, dest_block, terminator_idx; target_stmt=term.dest)
                        push!(bytes, Opcode.END)
                    else
                        push!(bytes, Opcode.IF)
                        push!(bytes, 0x40)
                        push!(bytes, Opcode.END)
                    end
                end
            elseif dest_block !== nothing && dest_block <= block_idx
                # Back edge (loop continuation condition)
                if dest_block in loop_headers
                    if has_phi
                        push!(bytes, Opcode.IF)
                        push!(bytes, 0x40)
                        push!(bytes, Opcode.ELSE)
                        set_phi_locals_for_edge!(bytes, dest_block, terminator_idx; target_stmt=term.dest)
                        label_depth = get_loop_label_depth(dest_block) + 1
                        push!(bytes, Opcode.BR)
                        append!(bytes, encode_leb128_unsigned(label_depth))
                        push!(bytes, Opcode.END)
                    else
                        label_depth = get_loop_label_depth(dest_block)
                        push!(bytes, Opcode.I32_EQZ)
                        push!(bytes, Opcode.BR_IF)
                        append!(bytes, encode_leb128_unsigned(label_depth))
                    end
                end
            end

            # PURE-314: GotoIfNot fall-through phi locals
            # When condition is TRUE, execution falls through to the next block.
            # The false branch sets phi locals via set_phi_locals_for_edge! above,
            # but the true (fall-through) path never did. Set phi locals for the
            # next block on the fall-through path.
            next_fall_block = block_idx + 1
            if next_fall_block <= length(blocks)
                fall_has_phi = dest_has_phi_from_edge(next_fall_block, terminator_idx)
                if fall_has_phi
                    set_phi_locals_for_edge!(bytes, next_fall_block, terminator_idx)
                end
            end

        elseif term isa Core.GotoNode
            dest_block = get(stmt_to_block, term.label, nothing)
            terminator_idx = block.end_idx

            # Set all phi values before jumping
            # Pass the actual target statement to find phi nodes (might be inside the block)
            if dest_block !== nothing
                set_phi_locals_for_edge!(bytes, dest_block, terminator_idx; target_stmt=term.label)
            end

            if dest_block !== nothing && dest_block > block_idx
                # Forward jump
                if dest_block in non_trivial_targets
                    label_depth = get_forward_label_depth(dest_block)
                    push!(bytes, Opcode.BR)
                    append!(bytes, encode_leb128_unsigned(label_depth))
                end
                # Otherwise, simple fall through - implicit
            elseif dest_block !== nothing && dest_block <= block_idx
                # Back edge (loop)
                if dest_block in loop_headers
                    label_depth = get_loop_label_depth(dest_block)
                    push!(bytes, Opcode.BR)
                    append!(bytes, encode_leb128_unsigned(label_depth))
                end
            end
        else
            # No explicit terminator (GotoNode, GotoIfNot, ReturnNode)
            # This block falls through to the next block
            # Check if next block has phi nodes that need values from this edge
            next_block_idx = block_idx + 1
            if next_block_idx <= length(blocks)
                # The edge for fallthrough is the last statement of this block
                terminator_idx = block.end_idx
                set_phi_locals_for_edge!(bytes, next_block_idx, terminator_idx)
            end
        end

        # Close loop if this is the last block of the loop (back edge source)
        for (src, dst) in back_edges
            if src == block_idx
                # Close any inner target blocks that are still open for this loop
                if haskey(loop_inner_targets, dst)
                    for target in loop_inner_targets[dst]
                        if target in open_blocks
                            filter!(t -> t != target, open_blocks)
                            push!(bytes, Opcode.END)  # End inner target block
                        end
                    end
                end
                push!(bytes, Opcode.END)  # End of loop
                # Remove from open_loops
                filter!(h -> h != dst, open_loops)
            end
        end
    end

    # Close any remaining open blocks
    while !isempty(open_blocks)
        pop!(open_blocks)
        push!(bytes, Opcode.END)
    end

    # The code should always end with a return, but add unreachable as safety
    push!(bytes, Opcode.UNREACHABLE)

    return bytes
end

