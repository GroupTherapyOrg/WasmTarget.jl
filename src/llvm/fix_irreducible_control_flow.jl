# llvm/lib/Target/WebAssembly/WebAssemblyFixIrreducibleControlFlow.cpp at the llvm pin
# (dev/LEDGER.md D42), modeled by dev/formal/FixIrreducible.tla: every loop with two or more entries
# made single-entry by a dispatch block, a br_table over the entries indexed by a label register the
# routing blocks set, so CFGSort and CFGStackify see a reducible CFG.

"""    get_sorted_entries(mf, entries) -> Vector{Int}

The entries by block number."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyFixIrreducibleControlFlow.cpp:73 getSortedEntries" get_sorted_entries(mf::MachineFunction, entries::Set{Int})::Vector{Int} =
    sort!(collect(entries); by = b -> mf.blocks[b].number)

"""
    ReachabilityNode(mbb)

A block of a region's reachability graph: the block, its successors in the region (none the
region's entry), and its SCC's index (typemax until one is assigned).
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyFixIrreducibleControlFlow.cpp:84 ReachabilityNode" mutable struct ReachabilityNode
    mbb::Int
    succs::Vector{Int}
    scc_id::Int
    ReachabilityNode(mbb::Int) = new(mbb, Int[], typemax(Int))
end

"""
    ReachabilityGraph(mf, entry, blocks)

The SCC structure of a region, `blocks` with the one entry `entry`, branches out of the region and
to its entry ignored: its loop entries (loop blocks, other than the entry, with a predecessor outside
their SCC), each SCC's loop entries, and each block's node (`calculate`).
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyFixIrreducibleControlFlow.cpp:93 ReachabilityGraph" struct ReachabilityGraph
    entry::Int
    blocks::Set{Int}
    loop_entries::Set{Int}
    loop_entries_by_scc::Vector{Set{Int}}
    nodes::Dict{Int,ReachabilityNode}
    function ReachabilityGraph(mf::MachineFunction, entry::Int, blocks::Set{Int})
        # the region has a single entry
        for mbb in blocks
            mbb == entry && continue
            all(in(blocks), mf.blocks[mbb].preds) ||
                reject!(Internal("src/llvm/fix_irreducible_control_flow.jl ReachabilityGraph: block $mbb has a predecessor outside its region"), "ReachabilityGraph")
        end
        local g = new(entry, blocks, Set{Int}(), Set{Int}[], Dict{Int,ReachabilityNode}())
        calculate(g, mf)
        return g
    end
end

"""    get_loop_entries(g) -> Set{Int}"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyFixIrreducibleControlFlow.cpp:111 ReachabilityGraph::getLoopEntries" get_loop_entries(g::ReachabilityGraph)::Set{Int} = g.loop_entries

"""    get_loop_entries_for_scc(g, scc_id) -> Set{Int}"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyFixIrreducibleControlFlow.cpp:112 ReachabilityGraph::getLoopEntriesForSCC" get_loop_entries_for_scc(g::ReachabilityGraph, scc_id::Int)::Set{Int} =
    g.loop_entries_by_scc[scc_id]

"""    get_scc_id(g, mbb) -> Int"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyFixIrreducibleControlFlow.cpp:116 ReachabilityGraph::getSCCId" get_scc_id(g::ReachabilityGraph, mbb::Int)::Int = g.nodes[mbb].scc_id

"""    in_region(g, mbb) -> Bool"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyFixIrreducibleControlFlow.cpp:129 ReachabilityGraph::inRegion" in_region(g::ReachabilityGraph, mbb::Int)::Bool = mbb in g.blocks

"""
    calculate(g, mf) -> Nothing

The nodes and their region successors; then, SCC by SCC (Tarjan's, as LLVM's scc_iterator), each
node's SCC index, and for an SCC of two or more blocks or a self loop its entries.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyFixIrreducibleControlFlow.cpp:163 ReachabilityGraph::calculate" function calculate(g::ReachabilityGraph, mf::MachineFunction)::Nothing
    for mbb in g.blocks
        g.nodes[mbb] = ReachabilityNode(mbb)
    end
    # every relevant direct branch
    for mbb in g.blocks, succ in mf.blocks[mbb].succs
        succ != g.entry && in_region(g, succ) && push!(g.nodes[mbb].succs, succ)
    end
    local graph = LinkedHashMap{Int,LinkedHashSet{Int}}()
    for mbb in sort!(collect(g.blocks))
        local s = LinkedHashSet{Int}()
        foreach(x -> push!(s, x), g.nodes[mbb].succs)
        graph[mbb] = s
    end
    local curr_scc_idx = 0
    for scc in strongly_connected_components(graph)
        local members = collect(scc)
        push!(g.loop_entries_by_scc, Set{Int}())
        curr_scc_idx += 1
        for mbb in members
            g.nodes[mbb].scc_id == typemax(Int) ||
                reject!(Internal("src/llvm/fix_irreducible_control_flow.jl calculate: block $mbb in two SCCs"), "ReachabilityGraph.calculate")
            g.nodes[mbb].scc_id = curr_scc_idx
        end
        local self_loop = length(members) == 1 && members[1] in g.nodes[members[1]].succs
        # a block in a loop is in an SCC of two or more blocks or loops to itself; its entries are the
        # loop blocks with a predecessor outside the SCC
        if length(members) > 1 || self_loop
            for mbb in members
                mbb == g.entry && continue
                for pred in mf.blocks[mbb].preds
                    if g.nodes[pred].scc_id != curr_scc_idx
                        push!(g.loop_entries, mbb)
                        push!(g.loop_entries_by_scc[curr_scc_idx], mbb)
                    end
                end
            end
        end
    end
    all(n -> n.scc_id != typemax(Int), values(g.nodes)) ||
        reject!(Internal("src/llvm/fix_irreducible_control_flow.jl calculate: a node with no SCC"), "ReachabilityGraph.calculate")
    return nothing
end

"""    WebAssemblyFixIrreducibleControlFlow()

The pass, which keeps no state between functions."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyFixIrreducibleControlFlow.cpp:246 WebAssemblyFixIrreducibleControlFlow" struct WebAssemblyFixIrreducibleControlFlow
    WebAssemblyFixIrreducibleControlFlow() = new()
end

"""
    process_region(pass, mf, entry, blocks) -> Bool

Fixes the region `blocks` with the one entry `entry`: while an SCC has two or more entries, makes
it single-entry and analyzes again; then recurses into each loop, the region of its SCC entered at
its entry. Whether it changed the function.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyFixIrreducibleControlFlow.cpp:264 WebAssemblyFixIrreducibleControlFlow::processRegion" function process_region(pass::WebAssemblyFixIrreducibleControlFlow, mf::MachineFunction, entry::Int, blocks::Set{Int})::Bool
    local changed = false
    # irreducibility first, which may take several iterations, then the child loops
    while true
        local graph = ReachabilityGraph(mf, entry, blocks)
        local found_irreducibility = false
        for loop_entry in get_sorted_entries(mf, get_loop_entries(graph))
            # the mutual entries, all in one SCC: more than one is irreducible control flow
            local mutual_loop_entries = get_loop_entries_for_scc(graph, get_scc_id(graph, loop_entry))
            if length(mutual_loop_entries) > 1
                make_single_entry_loop(pass, mf, mutual_loop_entries, blocks, graph)
                found_irreducibility = true
                changed = true
                break
            end
        end
        found_irreducibility && continue
        for loop_entry in get_loop_entries(graph)
            local inner_blocks = Set{Int}()
            local entry_scc_id = get_scc_id(graph, loop_entry)
            for block in blocks
                entry_scc_id == get_scc_id(graph, block) && push!(inner_blocks, block)
            end
            process_region(pass, mf, loop_entry, inner_blocks) && (changed = true)
        end
        return changed
    end
end

"""
    make_single_entry_loop(pass, mf, entries, blocks, graph) -> Nothing

One entry for the loop entered at `entries`: a dispatch block (BR_TABLE over the entries in block
order, its index a fresh label register), and for each entry a routing block for the predecessors
inside the loop and one for those outside (CONST_I32 of the entry's index into the register, BR to
the dispatch), placed before the entry when its layout predecessor uses it, else at the end; each
predecessor's branches and successors to an entry go to its routing block. The new blocks join
`blocks`.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyFixIrreducibleControlFlow.cpp:352 WebAssemblyFixIrreducibleControlFlow::makeSingleEntryLoop" function make_single_entry_loop(pass::WebAssemblyFixIrreducibleControlFlow, mf::MachineFunction, entries::Set{Int}, blocks::Set{Int}, graph::ReachabilityGraph)::Nothing
    length(entries) >= 2 || reject!(Internal("src/llvm/fix_irreducible_control_flow.jl make_single_entry_loop: fewer than two entries"), "makeSingleEntryLoop")
    local sorted_entries = get_sorted_entries(mf, entries)
    # the dispatch block and its jump table, indexed by a new register
    local dispatch = create_machine_basic_block!(mf)
    push!(mf.layout, dispatch)
    push!(blocks, dispatch)
    local reg = create_label_register!(mf)
    local table = MachineInstr(BR_TABLE, MachineOperand[MOImm(reg)], dispatch)
    push!(mf.blocks[dispatch].instrs, table)
    local indices = Dict{Int,Int}()
    for entry in sorted_entries
        haskey(indices, entry) && reject!(Internal("src/llvm/fix_irreducible_control_flow.jl make_single_entry_loop: an entry twice"), "makeSingleEntryLoop")
        indices[entry] = length(table.operands) - 1
        push!(table.operands, MOBlock(entry))
        add_successor(mf, dispatch, entry)
    end
    # every predecessor of an entry but the dispatch
    local all_preds = Int[]
    for entry in sorted_entries, pred in mf.blocks[entry].preds
        pred != dispatch && push!(all_preds, pred)
    end
    # the predecessors inside this loop
    local in_loop = Set{Int}()
    for pred in all_preds
        local pred_scc_id = get_scc_id(graph, pred)
        for entry in mf.blocks[pred].succs
            entry in entries || continue
            if get_scc_id(graph, entry) == pred_scc_id
                push!(in_loop, pred)
                break
            end
        end
    end
    # each entry's layout predecessor, by side
    local entry_to_layout_pred = Dict{Tuple{Int,Bool},Int}()
    for pred in all_preds
        local pred_in_loop = pred in in_loop
        for entry in mf.blocks[pred].succs
            entry in entries && is_layout_successor(mf, pred, entry) && (entry_to_layout_pred[(entry, pred_in_loop)] = pred)
        end
    end
    # at most two routing blocks per entry, one for each side
    local map = Dict{Tuple{Int,Bool},Int}()
    for pred in all_preds
        local pred_in_loop = pred in in_loop
        for entry in copy(mf.blocks[pred].succs)
            (entry in entries && !haskey(map, (entry, pred_in_loop))) || continue
            # with a layout predecessor of this entry, the routing block goes after it
            local other_pred = get(entry_to_layout_pred, (entry, pred_in_loop), nothing)
            other_pred !== nothing && other_pred != pred && continue
            local routing = create_machine_basic_block!(mf)
            if is_layout_successor(mf, pred, entry)
                insert!(mf.layout, something(findfirst(==(entry), mf.layout)), routing)
            else
                push!(mf.layout, routing)
            end
            push!(blocks, routing)
            push!(mf.blocks[routing].instrs, MachineInstr(CONST_I32, MachineOperand[MOImm(reg), MOImm(indices[entry])], routing))
            push!(mf.blocks[routing].instrs, MachineInstr(BR, MachineOperand[MOBlock(dispatch)], routing))
            add_successor(mf, routing, dispatch)
            map[(entry, pred_in_loop)] = routing
        end
    end
    for pred in all_preds
        local pred_in_loop = pred in in_loop
        # the terminators' operands and the successor list remapped
        for term in terminators(mf, pred), (k, op) in enumerate(term.operands)
            op isa MOBlock && haskey(indices, op.mbb) && (term.operands[k] = MOBlock(map[(op.mbb, pred_in_loop)]))
        end
        for succ in copy(mf.blocks[pred].succs)
            succ in entries || continue
            replace_successor(mf, pred, succ, map[(succ, pred_in_loop)])
        end
    end
    # br_table's default label, which it requires: the last entry again
    push!(table.operands, table.operands[end])
    renumber_blocks!(mf)
    return nothing
end

"""
    run_on_machine_function(pass, mf) -> Bool

Fixes the whole function, a region entered at its first block; when it changed anything, renumbers
the blocks, recomputes Julia's dominator tree of the new CFG (the analyses LLVM's pass manager
recomputes after a pass that does not preserve them) and adds the implicit definitions.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyFixIrreducibleControlFlow.cpp:550 WebAssemblyFixIrreducibleControlFlow::runOnMachineFunction" function run_on_machine_function(pass::WebAssemblyFixIrreducibleControlFlow, mf::MachineFunction)::Bool
    local all_blocks = Set{Int}(mf.layout)
    process_region(pass, mf, mf.layout[1], all_blocks) || return false
    renumber_blocks!(mf)
    recompute_domtree!(mf)
    add_implicit_defs(mf)
    return true
end

"""
    add_implicit_defs(mf) -> Nothing

After a dispatch block is added, a use may be reached on a path without its definition (a value
defined in one block and used in another, a new dispatch between them): every value gets a
definition at entry (LLVM's IMPLICIT_DEF of every virtual register), here the function marked so
that its code generator defines each value's local before the first block.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyFixIrreducibleControlFlow.cpp:521 addImplicitDefs" function add_implicit_defs(mf::MachineFunction)::Nothing
    mf.implicit_defs = true
    return nothing
end
