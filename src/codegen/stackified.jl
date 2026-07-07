# parity(M1) ONE LOWERING: generate_complex_flow (the old strategy router) is GONE. The
# stackifier below is THE single lowering for every multi-block body, void included (dart
# parity: one CodeGenerator, one structured lowering, no routing heuristic). The old routes it
# absorbed: the 5-clause heuristic → generate_nested_conditionals (a documented multivar-phi
# miscompiler — dropped all-but-one phi at diamond merges, gap 1bcb0e7214c3 family,
# test/fuzz/repro_multivar_phi_merge.jl), is_simple_conditional → generate_if_then_else, and
# the void-without-loops fast-path → generate_void_flow (whose missing pre-loop phi init was
# PURE-314; the stackifier stores EVERY live phi local at each edge via set_phi_locals_for_edge!).

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
PURE-325: Emit boxing bytecode for a numeric value that needs to be returned as ExternRef.
Handles the common pattern where a function returns ExternRef (Union type) but the actual
value is numeric (I32/I64/F32/F64). Boxes the value in a WasmGC struct + extern_convert_any.

If `val` is nothing (literal nothing), emits ref.null extern instead of boxing.
If `val` is a non-nothing numeric value, compiles + boxes it.

`target_bytes` is the byte vector to append to (may be `bytes` or `inner_bytes`).
"""
# The value's static Julia type for boxing (SSA inferred / Bool literal / argument type),
# or `nothing` when unknown. Used to pick the box's real classId + the i31 fast-path
# decision. Extracted from the (formerly duplicated) emit_numeric_to_*ref! logic.
function _value_julia_type(val, ctx::AbstractCompilationContext)
    if val isa Core.SSAValue && val.id <= length(ctx.ssa_types)
        return ctx.ssa_types[val.id]
    elseif val isa Bool
        return Bool
    elseif val isa Core.Argument && val.n <= length(ctx.arg_types)
        return ctx.arg_types[val.n]
    end
    return nothing
end

"""builder-native (THE implementation): value → classId box → externref.
`nothing` values become ref.null extern (dart: null, not a boxed zero)."""
function emit_numeric_to_externref!(b::InstrBuilder, val, val_wasm::WasmValType, ctx::AbstractCompilationContext)
    if is_nothing_value(val, ctx)
        ref_null!(b, ExternRef)
        return b
    end
    # The value's static Julia type (for the box's real classId).
    local _jl_type = _value_julia_type(val, ctx)
    # B4: ALL numerics (incl. Bool/Int8/UInt8 — formerly a ref.i31 fast path) box through the
    # SINGLE-SOURCE producer with their REAL classId, so same-wasm-rep types stay distinguishable
    # (dart2wasm uses NO i31). Concrete → real classId; Union/abstract → wasm-rep fallback.
    emit_value!(b, val, ctx)
    emit_classid_box!(b, ctx, val_wasm, (_jl_type isa Type && isconcretetype(_jl_type)) ? _jl_type : nothing)
    extern_convert_any!(b)
    return b
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_numeric_to_externref!(target_bytes::Vector{UInt8}, val, val_wasm::WasmValType, ctx::AbstractCompilationContext)
    b = InstrBuilder(; func_name="emit_numeric_to_externref!", mod=ctx.mod)
    emit_numeric_to_externref!(b, val, val_wasm, ctx)
    append!(target_bytes, builder_code(b))
    return
end

"""
    emit_numeric_to_anyref!(b, val, val_wasm, ctx)

Like emit_numeric_to_externref! but produces anyref (no extern_convert_any) —
builder-native (THE implementation): value → real-classId box (already anyref).
`nothing` values become ref.null any (dart: null, not a boxed zero).
"""
function emit_numeric_to_anyref!(b::InstrBuilder, val, val_wasm::WasmValType, ctx::AbstractCompilationContext)
    if is_nothing_value(val, ctx)
        ref_null!(b, AnyRef)  # any heap type (0x6E)
        return b
    end
    # The value's static Julia type (for the box's real classId).
    local _jl_type = _value_julia_type(val, ctx)
    # B4: ALL numerics (incl. Bool/Int8/UInt8 — formerly a ref.i31 fast path) box through the
    # SINGLE-SOURCE producer with their REAL classId (dart2wasm uses NO i31). The box struct is
    # already an anyref subtype. Concrete → real classId; Union/abstract → wasm-rep fallback.
    emit_value!(b, val, ctx)
    emit_classid_box!(b, ctx, val_wasm, (_jl_type isa Type && isconcretetype(_jl_type)) ? _jl_type : nothing)
    return b  # No extern_convert_any — struct ref is already anyref
end

"""bytes shell for the remaining byte-region callers (dies with them)."""
function emit_numeric_to_anyref!(target_bytes::Vector{UInt8}, val, val_wasm::WasmValType, ctx::AbstractCompilationContext)
    b = InstrBuilder(; func_name="emit_numeric_to_anyref!", mod=ctx.mod)
    emit_numeric_to_anyref!(b, val, val_wasm, ctx)
    append!(target_bytes, builder_code(b))
    return
end

"""parity(M11): THE flow front — the ONE seam where a stackified region's bytes
enter a typed builder. All drivers route here."""
function generate_stackified_flow!(b::InstrBuilder, ctx::AbstractCompilationContext, args...; kwargs...)
    append_builder!(b, generate_stackified_flow(ctx, args...; kwargs...))   # typed merge
    return b
end

"""march6 slice B: split blocks so every region's enter_idx ENDS a block and every
catch_dest STARTS one — the try_table/landing labels then open and close exactly at
block boundaries and the stackifier's ordinary machinery does the rest."""
function _split_blocks_for_regions(blocks::Vector{BasicBlock}, regions)::Vector{BasicBlock}
    cuts_after = Set{Int}()          # statement idx that must END a block
    for r in regions
        push!(cuts_after, r.enter_idx)
        r.catch_dest > 1 && push!(cuts_after, r.catch_dest - 1)
    end
    out = BasicBlock[]
    for b in blocks
        lo = b.start_idx
        for i in b.start_idx:(b.end_idx - 1)
            if i in cuts_after
                push!(out, BasicBlock(lo, i, nothing))
                lo = i + 1
            end
        end
        push!(out, BasicBlock(lo, b.end_idx, b.terminator))
    end
    return out
end

function generate_stackified_flow(ctx::AbstractCompilationContext, blocks::Vector{BasicBlock}, code;
                                  trailing_unreachable::Bool = true,
                                  try_regions::Vector = Any[])::InstrBuilder
    # march6 slice B: try regions are FIRST-CLASS — pre-split at their boundaries,
    # then the two label events below (open at the enter block's end, close at the
    # handler block's start) are the ENTIRE try lowering. Handler blocks compile as
    # plain CFG blocks: the stackifier's phi machinery already owns handler-edge phis.
    if !isempty(try_regions)
        blocks = _split_blocks_for_regions(blocks, try_regions)
        ensure_exception_tag!(ctx.mod)
        ensure_exception_global!(ctx.mod)
    end
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
        # P2-batch6: boundscheck now compiles to its REAL value (true unless
        # @inbounds), so the always-jump/dead-region carving below — which
        # assumed we emit 0 — only applies to an explicit `false` (inside
        # @inbounds). For boundscheck=true the GotoIfNot falls through to the
        # check + catchable throw_boundserror, and that path must stay live.
        if stmt isa Expr && stmt.head === :boundscheck && length(stmt.args) >= 1 && stmt.args[1] === false
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

    # (successor edges for regions are added after the terminator walk below)
    # march6 slice B: region → block-event maps. A region OPENS at the end of the
    # block containing its EnterNode and CLOSES at the start of its handler block.
    try_open_at = Dict{Int, Vector{Any}}()   # block_idx (enter block) → regions, outermost first
    try_close_at = Dict{Int, Vector{Any}}()  # block_idx (handler block) → regions, innermost first
    for r in try_regions
        eb = get(stmt_to_block, r.enter_idx, nothing)
        hb = get(stmt_to_block, r.catch_dest, nothing)
        (eb === nothing || hb === nothing) && continue
        push!(get!(Vector{Any}, try_open_at, eb), r)
        pushfirst!(get!(Vector{Any}, try_close_at, hb), r)
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

    # march6 slice B: handler edges — the enter block flows to BOTH its fall-through
    # and the handler block (the catch edge), so predecessors/phi analysis see handlers.
    for r in try_regions
        eb = get(stmt_to_block, r.enter_idx, nothing)
        hb = get(stmt_to_block, r.catch_dest, nothing)
        (eb === nothing || hb === nothing) && continue
        if !(hb in successors[eb])
            push!(successors[eb], hb)
            push!(predecessors[hb], eb)
        end
        if eb < length(blocks) && !((eb + 1) in successors[eb])
            push!(successors[eb], eb + 1)
            push!(predecessors[eb + 1], eb)
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

    # MIGRATED to InstrBuilder: the main accumulator is the typed builder `b`. The
    # byte-INSPECTING helper closures (set_phi_locals_for_edge!, compile_phi_value,
    # emit_phi_type_default) keep building their own local
    # UInt8[] buffers — they LEB-decode + scan recursive results — and splice them into
    # `b` via emit_raw!. strict=false (collect mode): a full control-flow body's stack
    # effect can't be tracked precisely by the fragment model, so we never gate.
    # Byte-identical to the prior raw emission.
    # march17: the ONE documented opt-out — the whole-body flow's stack effect spans
    # fragments and control joins the per-builder model can't see (the merge validators
    # + the emitted module's wasm-tools pass gate it instead). R-strict counts this.
    b = InstrBuilder(; func_name="generate_stackified_flow", strict=false, mod=ctx.mod)
    _seed_builder_locals!(b, ctx)

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

    # march6 slice B: targets INSIDE a try region must open INSIDE its try_table —
    # a br from within the region to a label opened outside the try would exit the
    # try entirely (first-contact bug: the normal path br'd into the handler).
    # Deepest-construct-wins vs loops: a target inside both belongs to whichever
    # opened later; for the slice-B gate (non-nested, non-overlapping-with-loop
    # regions) region membership simply overrides.
    target_region = Dict{Int, Int}()   # target block → region enter block
    for target in non_trivial_targets
        for r in try_regions
            eb = get(stmt_to_block, r.enter_idx, nothing)
            hb = get(stmt_to_block, r.catch_dest, nothing)
            (eb === nothing || hb === nothing) && continue
            if target > eb && target < hb
                target_region[target] = eb
            end
        end
    end
    region_inner_targets = Dict{Int, Vector{Int}}()  # enter block → sorted targets (desc)
    for (target, eb) in collect(target_region)
        if haskey(target_loop, target)
            # deepest construct wins: if the target's loop header lies INSIDE the
            # region, the loop label is more inner — the loop keeps the target
            # (f_l2: try-around-loop; region-always stole the loop's exit target).
            local _lh = target_loop[target]
            if _lh > eb
                delete!(target_region, target)
                continue
            end
            delete!(target_loop, target)   # loop is outside the region — region wins
        end
        push!(get!(Vector{Int}, region_inner_targets, eb), target)
    end
    for eb in keys(region_inner_targets)
        sort!(region_inner_targets[eb]; rev=true)
    end

    # Split targets into outer (outside all loops) and inner (inside a loop)
    outer_targets = sort([t for t in non_trivial_targets if !haskey(target_loop, t) && !haskey(target_region, t)]; rev=true)
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

    # march6 slice A: ONE emission-ordered label stack (dart: one label stack) —
    # each entry mirrors one OPEN wasm label this function emitted, innermost last.
    # Kinds: (:block, target_block) | (:loop, header). Replaces the open_blocks +
    # open_loops parallel arrays and their positional-math depth corrections; a
    # third kind (:try) lands in slice B. Depth = distance from the top.
    label_stack = Tuple{Symbol,Int}[]
    _ls_blocks() = Int[e[2] for e in label_stack if e[1] === :block]   # transitional views
    _ls_loops()  = Int[e[2] for e in label_stack if e[1] === :loop]

    # Open blocks for OUTER forward jump targets only (outermost first = largest target)
    for target in outer_targets
        push!(label_stack, (:block, target))
        block!(b)  # void
    end

    # march6 slice A: depth = position from the top of THE label stack. The old
    # positional math (block-position + inner-loop-count corrections) is replaced by
    # the direct emission-order scan; where the two disagreed, the OLD math was the
    # suspect (the multi-back-edge bug class) — gates arbitrate.
    function get_forward_label_depth(target_block::Int)::Int
        i = findlast(==( (:block, target_block) ), label_stack)
        i === nothing && return 0   # not open — matches the old fallback
        return length(label_stack) - i
    end

    # Helper to get label depth for back edge (loop)
    function get_loop_label_depth(loop_header::Int)::Int
        i = findlast(==( (:loop, loop_header) ), label_stack)
        i === nothing && return 0
        return length(label_stack) - i
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
    # builder-native variant: emit the default directly into the target builder
    function emit_phi_type_default!(tb::InstrBuilder, wasm_type::WasmValType)
        if wasm_type isa ConcreteRef
            ref_null!(tb, Int64(wasm_type.type_idx), ConcreteRef(UInt32(wasm_type.type_idx), true))
        elseif wasm_type === StructRef
            ref_null!(tb, StructRef)
        elseif wasm_type === ArrayRef
            ref_null!(tb, ArrayRef)
        elseif wasm_type === ExternRef
            ref_null!(tb, ExternRef)
        elseif wasm_type === AnyRef
            ref_null!(tb, AnyRef)
        elseif wasm_type === EqRef
            ref_null!(tb, EqRef)
        elseif wasm_type === I64
            i64_const!(tb, 0)
        elseif wasm_type === F32
            f32_const!(tb, 0.0f0)
        elseif wasm_type === F64
            f64_const!(tb, 0.0)
        else
            i32_const!(tb, 0)
        end
        return tb
    end

    function emit_phi_type_default(wasm_type::WasmValType)::Vector{UInt8}
        # MIGRATED to InstrBuilder: pure straight-line value emission (no inspection).
        # strict=false; byte-identical to the prior raw emission.
        tb = InstrBuilder(; func_name="emit_phi_type_default", mod=ctx.mod)
        if wasm_type isa ConcreteRef
            ref_null!(tb, Int64(wasm_type.type_idx), ConcreteRef(UInt32(wasm_type.type_idx), true))
        elseif wasm_type === StructRef
            ref_null!(tb, StructRef)
        elseif wasm_type === ArrayRef
            ref_null!(tb, ArrayRef)
        elseif wasm_type === ExternRef
            ref_null!(tb, ExternRef)
        elseif wasm_type === AnyRef
            ref_null!(tb, AnyRef)
        elseif wasm_type === EqRef
            ref_null!(tb, EqRef)
        elseif wasm_type === I64
            i64_const!(tb, 0)
        elseif wasm_type === I32
            i32_const!(tb, 0)
        elseif wasm_type === F64
            f64_const!(tb, 0.0)
        elseif wasm_type === F32
            f32_const!(tb, 0.0f0)
        else
            i32_const!(tb, 0)
        end
        return builder_code(tb)
    end

    # Helper to compile a value, ensuring it actually produces bytes
    # For SSAValues without locals, we need to recompute the value
    # phi_idx: the SSA index of the phi node we're setting (to get the phi's type)
    function compile_phi_value(val, phi_idx::Int,
                               temp_map::Dict{Int,Int}=Dict{Int,Int}())::Tuple{InstrBuilder,Union{WasmValType,Nothing},Int}
        # parity(M2 -> march3) typed channel: emits into `pvb` and returns THE BUILDER
        # (pushed_type, npushed are its tracked byproducts) -- callers merge with
        # append_builder!, so the fragment's REAL stack effect transfers (no declared
        # pushes; the pv_ty===nothing guess that let an invalid module through WT's
        # own validation is structurally impossible now). `temp_map` substitutes
        # circular-phi temp locals at the plain local.get branches (PURE-1001).
        pvb = InstrBuilder(; func_name="compile_phi_value", mod=ctx.mod)
        _seed_builder_locals!(pvb, ctx)
        _cpv_ret() = begin
            if get(ENV, "WT_AUDIT_VALUE_STACK", "") == "1" && length(pvb.v.stack) != 1 && !isempty(pvb.instrs)
                println(stderr, "PHI-VALUE-LIAR n=$(length(pvb.v.stack)) stack=$(pvb.v.stack) val=$(first(repr(val), 80)) phi=$phi_idx instrs=$(join(builder_disasm(pvb), "; ")) philoc=$(haskey(ctx.phi_locals, phi_idx) ? ctx.locals[ctx.phi_locals[phi_idx] - ctx.n_params + 1] : :none) errs=$(pvb.v.errors)")
            end
            (pvb,
             isempty(pvb.v.stack) ? nothing : pvb.v.stack[end],
             length(pvb.v.stack))
        end
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
                        local_get!(pvb, get(temp_map, local_idx, local_idx))
                    else
                        # Loop C flow/phi dedup: box / cast / UNBOX via the single shared
                        # converter (source = local.get of the SSA local). The unbox arm is
                        # what fixes Any[i]→0 (numeric phi local ← classId-box SSA local).
                        local _srcb = InstrBuilder(; func_name="phi_edge_src", mod=ctx.mod)
                        _seed_builder_locals!(_srcb, ctx)
                        local_get!(_srcb, local_idx)
                        if !_emit_phi_edge_convert!(pvb, ctx, phi_local_wasm_type, ssa_local_type, _srcb)
                            emit_phi_type_default!(pvb, phi_local_wasm_type)
                        end
                    end
                else
                    local_get!(pvb, get(temp_map, local_idx, local_idx))
                    # parity(M10): the single-source-at-load contract — a join-refined
                    # numeric riding a ref local narrows HERE too, and the reported type
                    # becomes the numeric so the phi store boxes through the funnel.
                    local _cpv_refined = get(ctx.ssa_types, val.id, Any)
                    if _cpv_refined in (Int64, Int32, UInt64, UInt32, Float64, Float32, Bool) &&
                       ssa_local_type !== nothing && _wt_is_ref(ssa_local_type)
                        # funnel-unbox directly on the builder (no byte seam)
                        convert_type!(pvb, ssa_local_type, julia_to_wasm_type(_cpv_refined), ctx;
                                      from_julia=_cpv_refined)
                    end
                end
            elseif haskey(ctx.phi_locals, val.id)
                local_idx = ctx.phi_locals[val.id]
                # Check type compatibility for phi-to-phi
                src_local_type = ctx.locals[local_idx - ctx.n_params + 1]
                if phi_local_wasm_type !== nothing && !wasm_types_compatible(phi_local_wasm_type, src_local_type)
                    # Loop C flow/phi dedup: box / cast / UNBOX (phi-to-phi) via the single helper.
                    local _srcb = InstrBuilder(; func_name="phi_edge_src", mod=ctx.mod)
                    _seed_builder_locals!(_srcb, ctx)
                    local_get!(_srcb, local_idx)
                    if !_emit_phi_edge_convert!(pvb, ctx, phi_local_wasm_type, src_local_type, _srcb)
                        emit_phi_type_default!(pvb, phi_local_wasm_type)
                    end
                else
                    local_get!(pvb, get(temp_map, local_idx, local_idx))
                end
            else
                # SSA without local - need to recompute the statement
                # This should ideally not happen for phi values, but handle it
                # PURE-6021: Guard against out-of-bounds SSAValue IDs (sentinel values)
                if val.id < 1 || val.id > length(code)
                    emit_phi_type_default!(pvb, phi_local_wasm_type)
                    return _cpv_ret()
                end
                stmt = code[val.id]
                # Type compatibility for recomputed SSA values (the M10a fix lives in the
                # ssa_types join-write, not here). Source = emit_value! (typed recompute).
                ssa_julia_type = get(ctx.ssa_types, val.id, Any)
                ssa_wasm_type = get_concrete_wasm_type(ssa_julia_type, ctx.mod, ctx.type_registry)
                if phi_local_wasm_type !== nothing && !wasm_types_compatible(phi_local_wasm_type, ssa_wasm_type) && !(phi_local_wasm_type === I64 && ssa_wasm_type === I32)
                    local _sb = InstrBuilder(; func_name="phi_edge_src", mod=ctx.mod)
                    _seed_builder_locals!(_sb, ctx)
                    emit_value!(_sb, val, ctx)
                    if !_emit_phi_edge_convert!(pvb, ctx, phi_local_wasm_type, ssa_wasm_type, _sb)
                        emit_phi_type_default!(pvb, phi_local_wasm_type)
                    end
                elseif phi_local_wasm_type !== nothing && phi_local_wasm_type === I64 && ssa_wasm_type === I32
                    # PURE-313: i32 → i64 widening for recomputed SSA without local.
                    # Compile the value as i32 and let the caller (set_phi_locals_for_edge!)
                    # handle the i64.extend_i32_s widening.
                    emit_value!(pvb, val, ctx)
                elseif stmt !== nothing && !(stmt isa Core.PhiNode)
                    compile_statement!(pvb, stmt, val.id, ctx)   # THE visitor — tracked
                else
                    # Can't recompute - try compile_value as fallback
                    emit_value!(pvb, val, ctx)
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
                    ref_null!(pvb, Int64(local_wasm_type.type_idx), ConcreteRef(UInt32(local_wasm_type.type_idx), true))
                elseif local_wasm_type === ExternRef
                    ref_null!(pvb, ExternRef)
                elseif local_wasm_type === StructRef
                    ref_null!(pvb, StructRef)
                elseif local_wasm_type === ArrayRef
                    ref_null!(pvb, ArrayRef)
                elseif local_wasm_type === AnyRef
                    ref_null!(pvb, AnyRef)
                elseif local_wasm_type === I64
                    i64_const!(pvb, 0)
                elseif local_wasm_type === F32
                    f32_const!(pvb, 0.0f0)
                elseif local_wasm_type === F64
                    f64_const!(pvb, 0.0)
                else
                    # I32 default
                    i32_const!(pvb, 0)
                end
            else
                # No phi local found — emit i32(0) as placeholder
                i32_const!(pvb, 0)
            end
        else
            # Not an SSA and not nothing - just compile directly
            # Check type compatibility for non-SSA values (QuoteNode, literals, etc.)
            if haskey(ctx.phi_locals, phi_idx)
                phi_local_idx = ctx.phi_locals[phi_idx]
                phi_local_type = ctx.locals[phi_local_idx - ctx.n_params + 1]
                edge_val_type = get_phi_edge_wasm_type(val)
                if edge_val_type !== nothing && !wasm_types_compatible(phi_local_type, edge_val_type) && !(phi_local_type === I64 && edge_val_type === I32)
                    # Loop C flow/phi dedup: box / cast / UNBOX (non-SSA edge) via the single helper.
                    local _ne_b = _compile_value_b(val, ctx)
                    local _ne_vty = isempty(_ne_b.v.stack) ? nothing : _ne_b.v.stack[end]
                    if !_emit_phi_edge_convert!(pvb, ctx, phi_local_type,
                                                (_ne_vty === nothing ? edge_val_type : _ne_vty), _ne_b)
                        # Type mismatch with no conversion arm: emit a type-safe default —
                        # DIAGNOSED (M5 loud-visible; behavior unchanged pending the full audit).
                        record_unsupported!(ctx, :unsupported_type,
                            "phi-edge type mismatch with no conversion arm (type-safe default emitted)")
                        emit_phi_type_default!(pvb, phi_local_type)
                    end
                    return _cpv_ret()
                end
            end
            emit_value!(pvb, val, ctx)
        end
        return _cpv_ret()
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
            # parity(M9): String/Symbol constants are the CLASSED string struct
            str_type_idx = get_string_struct_type!(ctx.mod, ctx.type_registry)
            return ConcreteRef(str_type_idx, false)
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
            # PURE-9063: Use $JlDataType when hierarchy is available
            dt_idx = get_datatype_type_idx(ctx.type_registry)
            return ConcreteRef(dt_idx, true)
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
        local_is_ref = local_type isa ConcreteRef || local_type === StructRef || local_type === ArrayRef || local_type === ExternRef || local_type === AnyRef || local_type === EqRef
        value_is_ref = value_type isa ConcreteRef || value_type === StructRef || value_type === ArrayRef || value_type === ExternRef || value_type === AnyRef || value_type === EqRef
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
        # Abstract ref (StructRef/ArrayRef/AnyRef/EqRef) is NOT directly compatible with ConcreteRef
        # (requires ref.cast to downcast from abstract/super to concrete)
        if local_type isa ConcreteRef && (value_type === StructRef || value_type === ArrayRef || value_type === AnyRef || value_type === EqRef)
            return false
        end
        # ExternRef is NOT compatible with ConcreteRef/StructRef/ArrayRef/AnyRef/EqRef
        if local_type === ExternRef && (value_type isa ConcreteRef || value_type === StructRef || value_type === ArrayRef || value_type === AnyRef || value_type === EqRef)
            return false
        end
        if value_type === ExternRef && (local_type isa ConcreteRef || local_type === StructRef || local_type === ArrayRef || local_type === AnyRef || local_type === EqRef)
            return false
        end
        return true
    end

    # Helper to set all phi locals at destination
    # dest_block: the block index being jumped to
    # terminator_idx: the statement index of the terminator (edge in phi)
    # target_stmt: optional - the actual statement being jumped to (may differ from block start)
    # MIGRATED: emits phi-local stores directly into the outer typed builder `b`.
    # Byte-inspecting branches keep their local UInt8[] scan of the recursive
    # compile_phi_value result; only the EMISSION migrates to typed methods.
    function set_phi_locals_for_edge!(b::InstrBuilder, dest_block::Int, terminator_idx::Int; target_stmt::Int=0)
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
                    local_get!(b, read_local)
                    local_set!(b, temp_local)
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
                                # parity(M2) wrap+store: typed compile_phi_value → THE
                                # convert_type! funnel → local.set. Replaces the arm-chain +
                                # END-byte sniffing + LEB re-decode + temp byte-rewrite
                                # (cpv takes needs_temp) + the "safety check" re-derivation.
                                pv_b, pv_ty, pv_n = compile_phi_value(val, i, needs_temp)
                                # march3: typed merge — the audit proved the channel honest
                                # (pv_n is now trustworthy; the phantom declared-push is gone).
                                if pv_n >= 2
                                    # multi-value emission can't feed one local.set — type-safe default
                                    emit_phi_type_default!(b, phi_local_type)
                                    local_set!(b, local_idx)
                                    phi_count += 1
                                elseif !isempty(pv_b.instrs)
                                    append_builder!(b, pv_b)
                                    if pv_ty !== nothing && pv_ty !== phi_local_type
                                        convert_type!(b, pv_ty, phi_local_type, ctx)
                                    end
                                    # parity(M11.4): ALWAYS store — the `ty===nothing`
                                    # skip orphaned the emitted value on the stack (the
                                    # escaping-closure double-load bug, second site).
                                    local_set!(b, local_idx)
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

    # PURE-6024 debug: trace function name for debugging.
    # P2-batch21: ctx has no func_name field — use func_ref (the function object),
    # otherwise WT_DBG_FN can never match and the traces below are unreachable.
    _debug_fn_name = try string(ctx.func_ref) catch; "" end
    _debug_stackified = contains(_debug_fn_name, "parse_int_literal") ||
        (haskey(ENV, "WT_DBG_FN") && !isempty(ENV["WT_DBG_FN"]) && contains(_debug_fn_name, ENV["WT_DBG_FN"]))
    if _debug_stackified
        @warn "PURE-6024 STACKIFIED DEBUG: $(length(blocks)) blocks, non_trivial_targets=$non_trivial_targets, outer_targets=$outer_targets, return_type=$(ctx.return_type)"
    end

    # P2-batch23 (gaps 4be58371947f / 203da15d789c): when compiling a SUBSET of
    # the function's blocks (pre-try regions, chain prefixes), a terminator can
    # target a statement BEYOND the subset (e.g. `if cond; return X; end; try…`
    # — the GotoIfNot's dest is the try region). Previously the branch was
    # silently dropped while its compiled condition stayed on the stack
    # ("values remaining at end of block"). Wrap the subset in an EXIT block:
    # out-of-subset forward branches br to it, landing exactly where the
    # caller's continuation (e.g. the try_table) begins.
    _subset_end = isempty(blocks) ? 0 : maximum(byt.end_idx for byt in blocks)
    _term_dest(t) = t isa Core.GotoIfNot ? t.dest : t isa Core.GotoNode ? t.label : 0
    needs_exit_block = any(begin
                               d = _term_dest(byt.terminator)
                               d > _subset_end && get(stmt_to_block, d, nothing) === nothing
                           end for byt in blocks)
    _exit_depth() = length(label_stack)   # the exit block itself is never on the stack
    if needs_exit_block
        block!(b)
    end

    # Now generate code for each block in order
    for (block_idx, block) in enumerate(blocks)
        # First, close any blocks whose target is this block
        # (We close BEFORE generating code for the target block)
        # march6 slice B: a region's handler block starts here → the try_table and
        # its landing block END exactly at this boundary (the catch br lands at the
        # handler's first instruction). Innermost regions close first.
        if haskey(try_close_at, block_idx)
            for r in try_close_at[block_idx]
                # any region-inner target labels still open close first (nesting)
                while !isempty(label_stack) && label_stack[end][1] === :block
                    pop!(label_stack)
                    end_block!(b)
                end
                if !isempty(label_stack) && label_stack[end][1] === :try
                    pop!(label_stack)
                    end_block!(b)          # end try_table
                    unreachable!(b)  # structural trap (the landing end is catch-arrival ONLY; normal paths br out)
                end
                if !isempty(label_stack) && label_stack[end][1] === :landing
                    pop!(label_stack)
                    end_block!(b)          # end landing — the catch payload arrives here
                    # march15: bind the payload to the REGION's OWN local (dart binds each
                    # catch's exception to a named local — nested regions never clobber).
                    # $current_exn still receives a copy while non-local readers remain.
                    drop!(b)                                            # stackTrace
                    local _rex = get!(ctx.exn_region_locals, Int(r.enter_idx)) do
                        allocate_local!(ctx, AnyRef)
                    end
                    local_tee!(b, UInt32(_rex))
                    global_set!(b, ensure_exception_global!(ctx.mod))   # exn (legacy copy)
                end
                ctx.last_stmt_was_stub = false   # the handler is reachable
            end
        end

        # (slice-A exact-semantics note: the old code keyed on the LAST *block*
        # entry regardless of loops above it; replicated via findlast-:block)
        while true
            local _lb = findlast(e -> e[1] === :block, label_stack)
            (_lb !== nothing && label_stack[_lb][2] == block_idx) || break
            deleteat!(label_stack, _lb)
            end_block!(b)  # End the block for this target
            if _debug_stackified
                @warn "  CLOSE block for target $block_idx, stack=$label_stack, bytes_len=$(_byte_len(b))"
            end
        end

        # Skip dead blocks (from boundscheck patterns)
        if block_idx in dead_blocks
            if _debug_stackified
                @warn "  SKIP dead block $block_idx"
            end
            continue
        end

        if _debug_stackified
            @warn "  BLOCK $block_idx [$(block.start_idx):$(block.end_idx)] term=$(typeof(block.terminator)) bytes=$(_byte_len(b)) stack=$label_stack"
        end

        # Check if we're entering a loop
        is_loop_header = block_idx in loop_headers

        if is_loop_header
            loop!(b)  # void
            push!(label_stack, (:loop, block_idx))

            # Open BLOCKs for forward-jump targets INSIDE this loop (emission order:
            # the loop label sits below its inner-target labels)
            if haskey(loop_inner_targets, block_idx)
                for target in loop_inner_targets[block_idx]  # sorted desc = outermost first
                    push!(label_stack, (:block, target))
                    block!(b)  # void
                end
            end
        end

        # Compile the block's statements (not the terminator, we handle it separately)
        # Skip any dead statements within the block.
        # MIGRATED: block_bytes is now a sub-builder `bb`; straight-line emission uses
        # typed methods, recursive sub-results (stmt_bytes/phi_value_bytes) bridge via
        # emit_raw!, and the byte-INSPECTING DROP/box scans stay on those sub-results.
        bb = InstrBuilder(; func_name="generate_stackified_flow.block", mod=ctx.mod)
        _seed_builder_locals!(bb, ctx)
        # march17: values legitimately flow BETWEEN basic blocks on the wasm stack —
        # the block fragment declares the incoming stack (the merge settles exactly).
        isempty(b.v.stack) || seed_input!(bb, copy(b.v.stack))
        # PURE-7001a: Reset dead code guard at block boundaries. Each non-dead block
        # is reachable via a different control flow path, so a stub flag from a previous
        # block must not cascade. Without this, compile_statement emits unreachable on
        # valid fall-through paths after br_if (e.g., _next_token codepoint check).
        ctx.last_stmt_was_stub = false
        _block_is_dead = false  # PURE-9066: Track dead code within a block
        for i in block.start_idx:block.end_idx
            # Skip dead statements
            if i in dead_regions
                continue
            end
            if i in boundscheck_jumps
                continue  # This GotoIfNot always jumps - skip it (handled below)
            end
            # PURE-9066: Skip statements after unreachable/stub within same block.
            # After throw/error, remaining statements in the block are dead code.
            # Compiling them would place unreachable opcodes in the wrong block.
            if _block_is_dead
                continue
            end

            stmt = code[i]

            # Skip terminator if we're going to handle it separately
            if i == block.end_idx && (stmt isa Core.GotoIfNot || stmt isa Core.GotoNode || stmt isa Core.ReturnNode)
                continue
            end

            if stmt isa Core.ReturnNode
                if isdefined(stmt, :val)
                    # THE single return-coercion path (dead pre-emit type locals deleted).
                    bb = emit_return_coerced!(bb, stmt.val, ctx)
                else
                    # A valueless ReturnNode is Julia IR `unreachable` (the tail of a
                    # throw branch) — a structural trap, NEVER a bare `return` (which is
                    # invalid in a result-typed function and was silently wrong in a void
                    # one). dart: unimplemented/throw paths end in unreachable.
                    unreachable!(bb)   # structural trap (dart-legit dead path)
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
                                # parity(M2) wrap+store: typed compile_phi_value → THE convert_type! funnel.
                                pv_b2, pv_ty2, pv_n2 = compile_phi_value(val, i)
                                if pv_n2 >= 2
                                    emit_phi_type_default!(bb, phi_local_type)
                                    local_set!(bb, local_idx)
                                elseif !isempty(pv_b2.instrs)
                                    append_builder!(bb, pv_b2)   # typed merge (audit-proven channel)
                                    if pv_ty2 !== nothing && pv_ty2 !== phi_local_type
                                        convert_type!(bb, pv_ty2, phi_local_type, ctx)
                                    end
                                    # parity(M11.4): ALWAYS store — an unknown-typed value
                                    # left on the stack (the old `ty===nothing` skip)
                                    # orphaned it: the escaping-closure double-load bug.
                                    local_set!(bb, local_idx)
                                end
                            end
                            break
                        end
                    end
                end

            elseif stmt === nothing
                # Nothing statement

            else
                # march4 Phase C: THE statement visitor emits directly; the drop
                # logic reads the emission's node window (byte sniffs are gone).
                local _stmt_i0 = length(bb.instrs)
                compile_statement!(bb, stmt, i, ctx)
                local _stmt_emitted = length(bb.instrs) > _stmt_i0

                # DEBUG: trace DROP emissions (node count)
                _dbg_fn = try string(ctx.func_name) catch; "" end
                if contains(_dbg_fn, "test_if_call")
                    _drop_count = count(x -> x isa InstrIR.Drop, @view bb.instrs[_stmt_i0+1:end])
                    if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                        @warn "STACKIFIED-DROP stmt=$i head=$(stmt.head) drops=$(_drop_count) has_ssa=$(haskey(ctx.ssa_locals, i))" maxlog=20
                    end
                end

                # PURE-9066: After unreachable/stub, mark dead code within block.
                # Previous `break` exited the block loop, causing subsequent dead
                # statements to be placed in the wrong block. Now we mark dead code
                # and skip remaining statements with `continue` at the top of the loop.
                stmt_type2 = get(ctx.ssa_types, i, Any)
                if stmt_type2 === Union{} || ctx.last_stmt_was_stub
                    _block_is_dead = true
                    continue  # Skip drop/local checks but stay in block
                end

                if !haskey(ctx.ssa_locals, i)
                    # PURE-220 (march4, node): skip if the visitor already emitted a DROP.
                    # The PURE-6006 func_idx-0x1a false positive cannot exist at the ir/ layer.
                    already_dropped = _stmt_emitted && bb.instrs[end] isa InstrIR.Drop
                    if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke || stmt.head === :foreigncall)
                        if !already_dropped && _stmt_emitted && statement_produces_wasm_value(stmt, i, ctx)
                            if !haskey(ctx.phi_locals, i)
                                use_count = get(ssa_use_count, i, 0)
                                if use_count == 0
                                    drop!(bb)
                                    @debug "STACKIFIED-DROP ADDED extra drop for stmt=$i"
                                end
                            end
                        end
                    elseif stmt isa Core.PiNode && _stmt_emitted
                        # PiNode without ssa_local pushed a value onto the stack.
                        # Drop it if it's only used by phi edges (phi stores re-compute
                        # the value via compile_phi_value, so this stack value is orphaned).
                        non_phi_uses = get(ssa_non_phi_uses, i, 0)
                        if non_phi_uses == 0
                            drop!(bb)
                        end
                    end
                end
            end
        end
        append_builder!(b, bb)   # typed merge — the block's real tracked effect

        # Handle the terminator
        term = block.terminator
        terminator_idx = block.end_idx

        # Check if this terminator is a boundscheck always-jump
        if terminator_idx in boundscheck_jumps && term isa Core.GotoIfNot
            # This is an always-jump - emit unconditional br to the target
            dest_block = get(stmt_to_block, term.dest, nothing)
            if dest_block !== nothing && dest_block > block_idx && dest_block in non_trivial_targets
                label_depth = get_forward_label_depth(dest_block)
                br!(b, label_depth)
            end
            # Otherwise, it's just a fall-through to a live block - nothing needed

        elseif term isa Core.ReturnNode
            if _debug_stackified
                @warn "  RETURN terminator at block $block_idx: term=$(term), val=$(isdefined(term,:val) ? term.val : :undef)"
            end
            if isdefined(term, :val)
                # parity(M2): THE single return-coercion path (emit_return_coerced!, same as
                # the block-statement ReturnNode site) — deletes this duplicated ladder
                # (byte-scanned externref check + hand widening/casts + a numeric→ConcreteRef
                # ref.null VALUE DROP; the single source boxes/converts properly).
                b = emit_return_coerced!(b, term.val, ctx)
            else
                # A valueless ReturnNode terminator is Julia IR `unreachable` (throw tail):
                # a structural trap, never a bare `return` (invalid in result-typed fns).
                unreachable!(b)   # structural trap (dart-legit dead path)
            end

        elseif term isa Core.GotoIfNot
            dest_block = get(stmt_to_block, term.dest, nothing)

            # Resolve through dead boundscheck blocks to find real target
            if dest_block !== nothing && dest_block in dead_blocks
                dest_block = resolve_through_dead_boundscheck(dest_block)
            end

            # Check if destination has phi nodes that need values from this edge
            has_phi = dest_block !== nothing && dest_has_phi_from_edge(dest_block, terminator_idx)

            if _debug_stackified
                @warn "  GIN blk=$block_idx term_idx=$terminator_idx dest=$(term.dest) dest_block=$dest_block has_phi=$has_phi nontrivial=$(dest_block in non_trivial_targets) bytes=$(_byte_len(b))"
            end

            # Compile condition (THE condition front)
            compile_condition_to_i32!(b, term.cond, ctx)

            # If condition is TRUE, fall through to next block
            # If condition is FALSE, jump to dest

            if dest_block !== nothing && dest_block > block_idx
                # Forward jump when condition is false
                if dest_block in non_trivial_targets
                    if has_phi
                        # Need to set phi values before jumping - use if/else
                        if_!(b)  # void
                        # Then branch: condition true, fall through (empty)
                        else_!(b)
                        # Else branch: condition false, set all phi locals and jump
                        set_phi_locals_for_edge!(b, dest_block, terminator_idx; target_stmt=term.dest)
                        # Jump to destination (account for the if block we're inside)
                        label_depth = get_forward_label_depth(dest_block) + 1
                        br!(b, label_depth)
                        end_block!(b)
                    else
                        # No phi - use br_if
                        label_depth = get_forward_label_depth(dest_block)
                        num!(b, Opcode.I32_EQZ)  # Invert the condition
                        br_if!(b, label_depth)
                    end
                else
                    # Simple fall-through pattern - condition true continues, false skips
                    if has_phi
                        if_!(b)
                        else_!(b)
                        set_phi_locals_for_edge!(b, dest_block, terminator_idx; target_stmt=term.dest)
                        end_block!(b)
                    else
                        if_!(b)
                        end_block!(b)
                    end
                end
            elseif dest_block !== nothing && dest_block <= block_idx
                # Back edge (loop continuation condition)
                if dest_block in loop_headers
                    if has_phi
                        if_!(b)
                        else_!(b)
                        set_phi_locals_for_edge!(b, dest_block, terminator_idx; target_stmt=term.dest)
                        label_depth = get_loop_label_depth(dest_block) + 1
                        br!(b, label_depth)
                        end_block!(b)
                    else
                        label_depth = get_loop_label_depth(dest_block)
                        num!(b, Opcode.I32_EQZ)
                        br_if!(b, label_depth)
                    end
                end
            elseif dest_block === nothing && needs_exit_block && term.dest > _subset_end
                # P2-batch23: dest is beyond the compiled subset — branch to the
                # exit block (the caller's continuation begins right after it).
                num!(b, Opcode.I32_EQZ)
                br_if!(b, _exit_depth())
            elseif dest_block === nothing
                # Unresolvable dest: drop the compiled condition rather than
                # orphaning it on the operand stack.
                drop!(b)
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
                    set_phi_locals_for_edge!(b, next_fall_block, terminator_idx)
                end
            end

        elseif term isa Core.GotoNode
            dest_block = get(stmt_to_block, term.label, nothing)
            terminator_idx = block.end_idx

            # WBUILD-3001: Resolve through dead boundscheck blocks to find real target.
            # Same resolution as non_trivial_targets computation.
            if dest_block !== nothing && dest_block in dead_blocks
                dest_block = resolve_through_dead_boundscheck(dest_block)
            end

            # Set all phi values before jumping
            # Pass the actual target statement to find phi nodes (might be inside the block)
            if dest_block !== nothing
                set_phi_locals_for_edge!(b, dest_block, terminator_idx; target_stmt=term.label)
            end

            if dest_block !== nothing && dest_block > block_idx
                # Forward jump
                if dest_block in non_trivial_targets
                    label_depth = get_forward_label_depth(dest_block)
                    # WBUILD-3001: If the br exits ALL open blocks (outermost),
                    # emit return instead to avoid falling through to unreachable.
                    # The phi locals were just set by set_phi_locals_for_edge!.
                    # Find the destination block's ReturnNode and its phi local.
                    exits_outermost = (label_depth + 1 >= length(label_stack))
                    if exits_outermost && ctx.return_type !== Nothing
                        func_ret_wasm = get_concrete_wasm_type(ctx.return_type, ctx.mod, ctx.type_registry)
                        # Find the return phi local: look at the destination block
                        # for a ReturnNode whose value is a phi with a phi_local.
                        ret_local = nothing
                        dest_start = blocks[dest_block].start_idx
                        dest_end = blocks[dest_block].end_idx
                        for di in dest_start:dest_end
                            s = code[di]
                            if s isa Core.ReturnNode && isdefined(s, :val) && s.val isa Core.SSAValue
                                vid = s.val.id
                                if haskey(ctx.phi_locals, vid)
                                    ret_local = ctx.phi_locals[vid]
                                    break
                                elseif haskey(ctx.ssa_locals, vid)
                                    # WBUILD-7000: Only use ssa_local for return optimization
                                    # if the SSA value is defined OUTSIDE the destination block.
                                    # SSA values defined IN the destination block haven't been
                                    # computed yet (the local is still 0), so we must use br
                                    # to reach the block and let it compute the value.
                                    if vid < dest_start || vid > dest_end
                                        ret_local = ctx.ssa_locals[vid]
                                    end
                                    break
                                end
                            end
                        end
                        if ret_local !== nothing
                            local_get!(b, ret_local)
                            if func_ret_wasm isa ConcreteRef
                                ref_cast!(b, Int64(func_ret_wasm.type_idx), true)
                            else
                                # P2-batch24 (gap dc4aaea42654): the local can be
                                # narrower than the function result (Int32 return
                                # value in a function whose rettype widened to
                                # Union{Int32,Int64} → i64). Mirror the numeric
                                # conversions of the in-block ReturnNode handler.
                                _rl_arr = Int(ret_local) - ctx.n_params + 1
                                _rl_wasm = _rl_arr >= 1 && _rl_arr <= length(ctx.locals) ?
                                           ctx.locals[_rl_arr] : nothing
                                convert_type!(b, _rl_wasm, func_ret_wasm, ctx)
                            end
                            return_!(b)
                        else
                            br!(b, label_depth)
                        end
                    else
                        br!(b, label_depth)
                    end
                end
                # Otherwise, simple fall through - implicit
            elseif dest_block !== nothing && dest_block <= block_idx
                # Back edge (loop)
                if dest_block in loop_headers
                    label_depth = get_loop_label_depth(dest_block)
                    br!(b, label_depth)
                end
            elseif dest_block === nothing && needs_exit_block && term.label > _subset_end
                # P2-batch23: unconditional jump beyond the compiled subset —
                # branch to the exit block (the caller's continuation).
                br!(b, _exit_depth())
            end
        else
            # No explicit terminator (GotoNode, GotoIfNot, ReturnNode)
            # This block falls through to the next block
            # Check if next block has phi nodes that need values from this edge
            next_block_idx = block_idx + 1
            if next_block_idx <= length(blocks)
                # The edge for fallthrough is the last statement of this block
                terminator_idx = block.end_idx
                set_phi_locals_for_edge!(b, next_block_idx, terminator_idx)
            end
        end

        # march6 slice B: this block ends with an EnterNode (post-split guarantee) →
        # open the region: landing block (the catch's br target ends at the handler)
        # then the try_table with catch_all → label 0 (the landing). Outermost first.
        if haskey(try_open_at, block_idx)
            for r in try_open_at[block_idx]
                # march6 slice D: the TYPED catch — the landing block carries the tag
                # payload (exn, stackTrace) as its results; catch_clause(tag 0 → label 0)
                # delivers it there (dart: b.catch_(exceptionTag) + 2×local_set).
                local _lbt = add_type!(ctx.mod, FuncType(WasmValType[], WasmValType[AnyRef, ExternRef]))
                push!(label_stack, (:landing, get(stmt_to_block, r.catch_dest, 0)))
                block!(b, Int(_lbt); results=WasmValType[AnyRef, ExternRef])
                push!(label_stack, (:try, get(stmt_to_block, r.enter_idx, 0)))
                try_table!(b, InstrIR.TryCatch[catch_clause(0, 0)])
                # region-inner forward targets open INSIDE the try_table
                local _eb = get(stmt_to_block, r.enter_idx, 0)
                if haskey(region_inner_targets, _eb)
                    for target in region_inner_targets[_eb]
                        push!(label_stack, (:block, target))
                        block!(b)
                    end
                end
            end
        end

        # Close loop if this is the LAST back-edge source of the loop. A loop
        # with several `continue`-style branches has MULTIPLE back-edge sources
        # to the same header (1.13 Base IR does this in print); the loop label
        # closes only at the maximal one — earlier sources just `br` back
        # (their terminators already emitted it). Firing at every source emitted
        # one spurious End per extra edge, eating outer labels (the byte era
        # spliced this silently; the typed merge rejects it).
        for (src, dst) in back_edges
            if src == block_idx && block_idx == maximum(s for (s, d) in back_edges if d == dst)
                # Close any inner target blocks that are still open for this loop
                if haskey(loop_inner_targets, dst)
                    for target in loop_inner_targets[dst]
                        local _it = findlast(==( (:block, target) ), label_stack)
                        if _it !== nothing
                            deleteat!(label_stack, _it)
                            end_block!(b)  # End inner target block
                        end
                    end
                end
                _debug_stackified && @warn "  END-OF-LOOP fires at block=$block_idx src=$src dst=$dst stack=$label_stack labels=$(length(b.v.labels))"
                end_block!(b)  # End of loop
                local _lp = findlast(==( (:loop, dst) ), label_stack)
                _lp !== nothing && deleteat!(label_stack, _lp)
            end
        end
    end

    # Close any remaining open blocks (slice A: :block entries only, as before)
    while true
        local _rb = findlast(e -> e[1] === :block, label_stack)
        _rb === nothing && break
        _debug_stackified && @warn "  FINAL-SWEEP close $(label_stack[_rb]) labels=$(length(b.v.labels))"
        deleteat!(label_stack, _rb)
        end_block!(b)
    end

    # WBUILD-3001: After all blocks close, control may reach here when a `br`
    # exits the outermost block. For void functions: unreachable is fine.
    # For functions with a return type: emit unreachable (WASM validation uses
    # polymorphic stack after unreachable, so this validates). But we ALSO need
    # to ensure br to the outermost block uses `return` instead of `br`.
    # P2-batch19: callers compiling a FALL-THROUGH region (the pre-branch code
    # of an exit-branch try/catch) opt out — for them this guard is live code.
    trailing_unreachable && unreachable!(b)  # structural trap (dart-legit dead path)

    # P2-batch23: close the subset exit block — out-of-subset branches land
    # here, i.e. exactly at the caller's continuation.
    needs_exit_block && end_block!(b)

    return b
end

