# llvm/include/llvm/Support/GenericLoopInfoImpl.h at the llvm pin (dev/LEDGER.md D42): LoopInfoBase's
# construction, natural loops discovered from the dominator tree's back edges. The dominator tree is
# Julia's (Core.Compiler.DomTree, construct_domtree; D3), read where LLVM reads its DomTreeBase.

"""
    discover_and_map_subloop(l, backedges, li, mf) -> Nothing

Maps every block of loop `l` to `l` or a subloop of it, walking backward from the sources of its
back edges: an undiscovered block joins `l` (its predecessors walked on, the header's not); a block
already in a loop makes that loop's outermost loop a subloop of `l`, walked on from its header.
"""
@parity "llvm/include/llvm/Support/GenericLoopInfoImpl.h:459 discoverAndMapSubloop" function discover_and_map_subloop(l::LoopBase, backedges::Vector{Int}, li::LoopInfoBase, mf::MachineFunction)::Nothing
    local worklist = copy(backedges)
    while !isempty(worklist)
        local pred_bb = pop!(worklist)
        local subloop = get_loop_for(li, pred_bb)
        if subloop === nothing
            Core.Compiler.bb_unreachable(mf.domtree, pred_bb) && continue
            # an undiscovered block: map it to the current loop
            change_loop_for(li, pred_bb, l)
            pred_bb == get_header(l) && continue
            append!(worklist, mf.blocks[pred_bb].preds)
        else
            # a discovered block: its outermost discovered loop
            subloop = get_outermost_loop(subloop)
            subloop === l && continue
            # discover a subloop of this loop
            set_parent_loop(subloop, l)
            pred_bb = get_header(subloop)
            # walk on along the predecessors that are not back edges from within the subloop tree
            for pred in mf.blocks[pred_bb].preds
                get_loop_for(li, pred) === subloop || push!(worklist, pred)
            end
        end
    end
    return nothing
end

"""
    PopulateLoopsDFS(li)

Fills every loop's block and subloop vectors in one forward depth-first walk.
"""
@parity "llvm/include/llvm/Support/GenericLoopInfoImpl.h:515 PopulateLoopsDFS" struct PopulateLoopsDFS
    li::LoopInfoBase
    PopulateLoopsDFS(li::LoopInfoBase) = new(li)
end

"""    traverse(dfs, mf, entry_block) -> Nothing

Inserts each block into its loops, in postorder from `entry_block`."""
@parity "llvm/include/llvm/Support/GenericLoopInfoImpl.h:532 PopulateLoopsDFS::traverse" function traverse(dfs::PopulateLoopsDFS, mf::MachineFunction, entry_block::Int)::Nothing
    for bb in post_order(mf, entry_block)
        insert_into_loop(dfs, bb)
    end
    return nothing
end

"""
    insert_into_loop(dfs, block) -> Nothing

Adds `block` to each loop holding it; a subloop's header, reached after the subloop's blocks, first
adds the subloop to its parent (or the top level) and puts its blocks and subloops in reverse
postorder, the header kept first.
"""
@parity "llvm/include/llvm/Support/GenericLoopInfoImpl.h:541 PopulateLoopsDFS::insertIntoLoop" function insert_into_loop(dfs::PopulateLoopsDFS, block::Int)::Nothing
    local subloop = get_loop_for(dfs.li, block)
    if subloop !== nothing && block == get_header(subloop)
        if !is_outermost(subloop)
            push!(get_sub_loops_vector(something(get_parent_loop(subloop))), subloop)
        else
            add_top_level_loop(dfs.li, subloop)
        end
        reverse_block(subloop, 1)
        reverse!(get_sub_loops_vector(subloop))
        subloop = get_parent_loop(subloop)
    end
    while subloop !== nothing
        add_block_entry(subloop, block)
        subloop = get_parent_loop(subloop)
    end
    return nothing
end

"""
    analyze(li, mf) -> Nothing

Builds the loop tree of `mf` from Julia's dominator tree: in reverse preorder of the tree (an inner
loop discovered before its outer loop), each block with predecessors it dominates heads a loop of
those back edges, discovered backward; then one forward walk fills the loops' vectors.
"""
@parity "llvm/include/llvm/Support/GenericLoopInfoImpl.h:578 LoopInfoBase::analyze" function analyze(li::LoopInfoBase, mf::MachineFunction)::Nothing
    local domtree = mf.domtree
    li.bb_map = Union{Nothing,LoopBase}[nothing for _ in mf.blocks]
    # the dominator tree's nodes in preorder from its root, block 1 (DomTreeBase's updateDFSNumbers)
    local preorder = Int[]
    local stack = Int[1]
    while !isempty(stack)
        local n = pop!(stack)
        push!(preorder, n)
        append!(stack, reverse(domtree.nodes[n].children))
    end
    for header in reverse(preorder)
        local backedges = Int[]
        # each predecessor of the potential header it dominates closes a loop
        for backedge in mf.blocks[header].preds
            !Core.Compiler.bb_unreachable(domtree, backedge) && Core.Compiler.dominates(domtree, header, backedge) &&
                push!(backedges, backedge)
        end
        isempty(backedges) || discover_and_map_subloop(allocate_loop(li, header), backedges, li, mf)
    end
    traverse(PopulateLoopsDFS(li), mf, 1)
    return nothing
end
