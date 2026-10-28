# llvm/lib/Target/WebAssembly/WebAssemblyCFGSort.cpp at the llvm pin (dev/LEDGER.md D42), modeled by
# dev/formal/CFGStackify.tla: the blocks laid out in a topological order of the CFG without its back
# edges, no region interrupted by a block its header does not dominate, the original order kept
# where it can be.

"""
    maybe_update_terminator(mf, mbb) -> Nothing

Rewrites the block's branches for its new place (update_terminator), its layout successor before
the sort the block numbered next, as every branch the machine code holds is analyzable.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGSort.cpp:77 maybeUpdateTerminator" function maybe_update_terminator(mf::MachineFunction, mbb::Int)::Nothing
    local any_barrier = false
    local all_analyzable = true
    for term in terminators(mf, mbb)
        any_barrier |= term.opcode == BR
        all_analyzable &= term.opcode in (BR, BR_IF, BR_UNLESS)
    end
    any_barrier || all_analyzable ||
        reject!(Internal("src/llvm/cfg_sort.jl maybe_update_terminator: block $mbb falls through past an unanalyzable branch"), "maybeUpdateTerminator")
    # the layout successor from the original block order
    local original_successor = get_block_numbered(mf, mf.blocks[mbb].number + 1)
    all_analyzable && update_terminator(mf, mbb, original_successor)
    return nothing
end

"""
    compare_block_numbers(mf, a, b) -> Bool

Preferred's order: an EH pad first, then the smaller number, the top of the queue the block no
other outranks.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGSort.cpp:137 CompareBlockNumbers" function compare_block_numbers(mf::MachineFunction, a::Int, b::Int)::Bool
    mf.blocks[a].ehpad && !mf.blocks[b].ehpad && return false
    !mf.blocks[a].ehpad && mf.blocks[b].ehpad && return true
    return mf.blocks[a].number > mf.blocks[b].number
end

"""
    compare_block_numbers_backwards(mf, a, b) -> Bool

Ready's order: an EH pad first, then the larger number.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGSort.cpp:151 CompareBlockNumbersBackwards" function compare_block_numbers_backwards(mf::MachineFunction, a::Int, b::Int)::Bool
    mf.blocks[a].ehpad && !mf.blocks[b].ehpad && return false
    !mf.blocks[a].ehpad && mf.blocks[b].ehpad && return true
    return mf.blocks[a].number < mf.blocks[b].number
end

"""
    Entry(r)

An active region: the region, how many of its blocks remain to be placed, and the blocks its header
does not dominate, deferred until it is done.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGSort.cpp:166 Entry" mutable struct Entry
    the_region::ConcreteSortRegion
    num_blocks_left::Int
    deferred::Vector{Int}
    Entry(r::ConcreteSortRegion) = new(r, get_num_blocks(r), Int[])
end

"""
    sort_blocks(mf, mli) -> Nothing

Lays the blocks out: a topological sort ignoring loop back edges, from two ready lists (Preferred,
the successors just made ready, to keep the original order; Ready, the rest), where a block the
innermost active region's header does not dominate waits until the region's last block is placed.
Then checks what LLVM asserts of the result: a block's predecessors are above it but a loop
header's back edges, and every region's blocks lie within its header and bottom, regions nested.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGSort.cpp:183 sortBlocks" function sort_blocks(mf::MachineFunction, mli::LoopInfoBase)::Nothing
    local mdt = mf.domtree
    local num(b::Int) = mf.blocks[b].number
    # the original layout's numbers, so terminators can be updated to the original layout successor
    renumber_blocks!(mf)
    # each block's predecessors, a loop header's back edges uncounted
    local num_preds_left = zeros(Int, length(mf.layout))
    for mbb in mf.layout
        local n = length(mf.blocks[mbb].preds)
        local l = get_loop_for(mli, mbb)
        if l !== nothing && get_header(l) == mbb
            for pred in mf.blocks[mbb].preds
                contains(l, pred) && (n -= 1)
            end
        end
        num_preds_left[num(mbb)] = n
    end
    local preferred = PriorityQueue()
    local ready = PriorityQueue()
    local pref_less(a::Int, b::Int) = compare_block_numbers(mf, a, b)
    local ready_less(a::Int, b::Int) = compare_block_numbers_backwards(mf, a, b)
    local sri = SortRegionInfo(mli)
    local entries = Entry[]
    local mbb = mf.layout[1]
    while true
        local r = get_region_for(sri, mbb)
        if r !== nothing
            # a region header joins the active regions; the region's last block readies its deferred
            get_header(r) == mbb && push!(entries, Entry(r))
            for e in entries
                if contains(e.the_region, mbb)
                    e.num_blocks_left -= 1
                    e.num_blocks_left == 0 && foreach(d -> pq_push!(ready, d), e.deferred)
                end
            end
            while !isempty(entries) && entries[end].num_blocks_left == 0
                pop!(entries)
            end
        end
        # the topological sort: a successor is ready once its last forward predecessor is placed
        for succ in mf.blocks[mbb].succs
            local succ_l = get_loop_for(mli, succ)
            succ_l !== nothing && get_header(succ_l) == succ && contains(succ_l, mbb) && continue
            num_preds_left[num(succ)] -= 1
            num_preds_left[num(succ)] == 0 && pq_push!(preferred, succ)
        end
        # the block to follow mbb: a preferred one first, to keep the original order
        local next = nothing
        while !pq_empty(preferred)
            local cand = pq_pop!(preferred, pref_less)
            # one the top active region's header does not dominate waits for the region's end
            if !isempty(entries) && !Core.Compiler.dominates(mdt, get_header(entries[end].the_region), cand)
                push!(entries[end].deferred, cand)
                continue
            end
            # one numbered before mbb, unless loop-rotated above the header, is not preferred
            if num(cand) < num(mbb) && !mf.blocks[cand].ehpad &&
               (r === nothing || !contains(r, cand) || num(get_header(r)) < num(cand))
                pq_push!(ready, cand)
                continue
            end
            next = cand
            break
        end
        if next === nothing
            if pq_empty(ready)
                maybe_update_terminator(mf, mbb)
                break
            end
            while true
                local cand = pq_pop!(ready, ready_less)
                if !isempty(entries) && !Core.Compiler.dominates(mdt, get_header(entries[end].the_region), cand)
                    push!(entries[end].deferred, cand)
                    continue
                end
                next = cand
                break
            end
        end
        local nb = something(next)
        move_after(mf, nb, mbb)
        maybe_update_terminator(mf, mbb)
        mbb = nb
    end
    isempty(entries) || reject!(Internal("src/llvm/cfg_sort.jl sort_blocks: an active sort region not finished"), "sortBlocks")
    renumber_blocks!(mf)
    # LLVM's assertions on the result (NDEBUG builds skip them; here they reject, located)
    for mbb in mf.layout
        local region = get_region_for(sri, mbb)
        local header = region !== nothing && mbb == get_header(region)
        for pred in mf.blocks[mbb].preds
            num(pred) < num(mbb) || (header && contains(something(region), pred)) ||
                reject!(Internal("src/llvm/cfg_sort.jl sort_blocks: block $mbb's predecessor $pred is below it and no back edge"), "sortBlocks")
        end
    end
    local intervals = Tuple{Int,Int}[]
    for region in unique(values(sri.loop_map))
        get_header(region) == mf.layout[1] && reject!(Internal("src/llvm/cfg_sort.jl sort_blocks: the entry block heads a region"), "sortBlocks")
        local interval = (num(get_header(region)), num(get_bottom(sri, mf, region)))
        interval[1] <= interval[2] || reject!(Internal("src/llvm/cfg_sort.jl sort_blocks: a region's bottom above its header"), "sortBlocks")
        all(b -> interval[1] <= num(b) <= interval[2], blocks(region)) ||
            reject!(Internal("src/llvm/cfg_sort.jl sort_blocks: a region's block outside its interval"), "sortBlocks")
        push!(intervals, interval)
    end
    for a in intervals, b in intervals
        (a[1] <= b[1] && a[2] >= b[2]) || (b[1] <= a[1] && b[2] >= a[2]) || a[2] < b[1] || a[1] > b[2] ||
            reject!(Internal("src/llvm/cfg_sort.jl sort_blocks: regions overlap without nesting"), "sortBlocks")
    end
    return nothing
end
