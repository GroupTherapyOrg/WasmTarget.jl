# llvm/include/llvm/Analysis/DominanceFrontierImpl.h at the llvm pin (dev/LEDGER.md D42): the
# dominance frontier's analysis, LLVM's iterative walk of the dominator tree, over Julia's dominator
# tree of the machine CFG (Core.Compiler.DomTree; a block's tree children `domtree.nodes[b].children`,
# its immediate dominator `domtree.idoms_bb[b]`).

"""
    DFCalculateWorkObject(current_bb, parent_bb)

One step of the analysis's walk: the block whose frontier is computed and its immediate dominator
(`nothing` for the root), each a dominator tree node, a block number in Julia's tree.
"""
@parity "llvm/include/llvm/Analysis/DominanceFrontierImpl.h:32 DFCalculateWorkObject" struct DFCalculateWorkObject
    current_bb::Int
    parent_bb::Union{Nothing,Int}
    # LLVM's constructor (line 36), the struct's one inner constructor
    DFCalculateWorkObject(current_bb::Int, parent_bb::Union{Nothing,Int}) = new(current_bb, parent_bb)
end

"""
    analyze(df, mf)

Fills `df` with each reachable block's dominance frontier: a CFG successor the block does not
immediately dominate (DF local), then the frontiers of the blocks it immediately dominates that it
does not properly dominate (DF up), children before their parent, the root block 1 (codegen's top).
"""
@parity "llvm/include/llvm/Analysis/DominanceFrontierImpl.h:77 DominanceFrontierBase::analyze" function analyze(df::DominanceFrontierBase, mf::MachineFunction)::Nothing
    local dt = mf.domtree
    local root = 1
    local work_list = DFCalculateWorkObject[DFCalculateWorkObject(root, nothing)]
    local visited = Set{Int}()
    local properly_dominates(a::Int, b::Int) = a != b && Core.Compiler.dominates(dt, a, b)
    while true
        local current_w = work_list[end]
        local current_bb = current_w.current_bb
        local parent_bb = current_w.parent_bb
        # Visit each block only once.
        if !(current_bb in visited)
            push!(visited, current_bb)
            # Loop over CFG successors to calculate DFlocal[currentNode].
            local s = get!(() -> LinkedHashSet{Int}(), df.frontiers, current_bb)
            for child in mf.blocks[current_bb].succs
                # Does Node immediately dominate this successor?
                dt.idoms_bb[child] != current_bb && push!(s, child)
            end
        end
        # At this point, S is DFlocal. Now we union in DFup's of our children... Loop through and visit
        # the nodes that Node immediately dominates (Node's children in the IDomTree)
        local visit_child = false
        for child_bb in dt.nodes[current_bb].children
            if !(child_bb in visited)
                push!(work_list, DFCalculateWorkObject(child_bb, current_bb))
                visit_child = true
            end
        end
        # If all children are visited or there is any child then pop this block from the workList.
        if !visit_child
            current_bb == root && break
            pop!(work_list)
            parent_bb === nothing && reject!(Internal("llvm/include/llvm/Analysis/DominanceFrontierImpl.h:77 DominanceFrontierBase::analyze: block $current_bb, no root, has no immediate dominator"), "DominanceFrontierBase::analyze")
            local s = df.frontiers[current_bb]
            local parent_set = get!(() -> LinkedHashSet{Int}(), df.frontiers, parent_bb)
            for cdfi in s
                properly_dominates(parent_bb, cdfi) || push!(parent_set, cdfi)
            end
        end
        isempty(work_list) && break
    end
    return nothing
end
