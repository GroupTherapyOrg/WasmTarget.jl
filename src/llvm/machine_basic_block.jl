# llvm/lib/CodeGen/MachineBasicBlock.cpp at the llvm pin (dev/LEDGER.md D42): the members of
# MachineBasicBlock CFGSort calls, over the machine code of src/julia/machine.jl.

"""    move_after(mf, b, new_before) -> Nothing

Moves block `b` to just after `new_before` in the layout."""
@parity "llvm/lib/CodeGen/MachineBasicBlock.cpp:707 MachineBasicBlock::moveAfter" function move_after(mf::MachineFunction, b::Int, new_before::Int)::Nothing
    local i = findfirst(==(b), mf.layout)
    i === nothing || deleteat!(mf.layout, i)
    local j = findfirst(==(new_before), mf.layout)
    j === nothing && reject!(Internal("src/llvm/machine_basic_block.jl move_after: block $new_before is not in the layout"), "MachineBasicBlock.moveAfter")
    insert!(mf.layout, j + 1, b)
    return nothing
end

"""
    update_terminator(mf, b, previous_layout_successor) -> Nothing

Rewrites the block's branches for its place in the layout: a branch to its new layout successor
becomes a fallthrough (a conditional one reversed when its taken target is that successor), and a
fallthrough to `previous_layout_successor`, its layout successor before the move, becomes a branch
when that block no longer follows it.
"""
@parity "llvm/lib/CodeGen/MachineBasicBlock.cpp:720 MachineBasicBlock::updateTerminator" function update_terminator(mf::MachineFunction, b::Int, previous_layout_successor::Union{Nothing,Int})::Nothing
    # a block with no successors has no concerns with fall-through edges
    isempty(mf.blocks[b].succs) && return nothing
    local failed, tbb, fbb, cond = analyze_branch(mf, b)
    failed && reject!(Internal("src/llvm/machine_basic_block.jl update_terminator: block $b's branches are not analyzable"), "MachineBasicBlock.updateTerminator")
    if isempty(cond)
        if tbb !== nothing
            # an unconditional branch to the new layout successor is deleted
            is_layout_successor(mf, b, tbb) && remove_branch(mf, b)
        else
            # an unconditional fallthrough, or the block's end is unreachable
            (previous_layout_successor === nothing || !is_successor(mf, b, previous_layout_successor) ||
             mf.blocks[previous_layout_successor].ehpad) && return nothing
            is_layout_successor(mf, b, previous_layout_successor) ||
                insert_branch(mf, b, previous_layout_successor, nothing, cond)
        end
        return nothing
    end
    if fbb !== nothing
        # a non-fallthrough conditional branch: one of its successors the layout successor makes it
        # a fallthrough conditional branch
        if is_layout_successor(mf, b, something(tbb))
            reverse_branch_condition(cond) && return nothing
            remove_branch(mf, b)
            insert_branch(mf, b, fbb, nothing, cond)
        elseif is_layout_successor(mf, b, fbb)
            remove_branch(mf, b)
            insert_branch(mf, b, tbb, nothing, cond)
        end
        return nothing
    end
    # the block falls through to previous_layout_successor
    (previous_layout_successor !== nothing && !mf.blocks[previous_layout_successor].ehpad &&
     is_successor(mf, b, previous_layout_successor)) ||
        reject!(Internal("src/llvm/machine_basic_block.jl update_terminator: block $b's fallthrough is no successor"), "MachineBasicBlock.updateTerminator")
    if previous_layout_successor == tbb
        # the fallthrough and the conditional jump go to one block: the jump goes
        remove_branch(mf, b)
        if !is_layout_successor(mf, b, something(tbb))
            empty!(cond)
            insert_branch(mf, b, tbb, nothing, cond)
        end
        return nothing
    end
    # a fallthrough conditional branch
    if is_layout_successor(mf, b, something(tbb))
        if reverse_branch_condition(cond)
            empty!(cond)
            insert_branch(mf, b, previous_layout_successor, nothing, cond)
            return nothing
        end
        remove_branch(mf, b)
        insert_branch(mf, b, previous_layout_successor, nothing, cond)
    elseif !is_layout_successor(mf, b, previous_layout_successor)
        remove_branch(mf, b)
        insert_branch(mf, b, tbb, previous_layout_successor, cond)
    end
    return nothing
end

"""    add_successor(mf, b, succ) -> Nothing

Adds `succ` to the block's successors and the block to its predecessors (branch probabilities, which
Julia's IR does not carry, aside)."""
@parity "llvm/lib/CodeGen/MachineBasicBlock.cpp:825 MachineBasicBlock::addSuccessor" function add_successor(mf::MachineFunction, b::Int, succ::Int)::Nothing
    push!(mf.blocks[b].succs, succ)
    push!(mf.blocks[succ].preds, b)
    return nothing
end

"""
    replace_successor(mf, b, old, new) -> Nothing

`new` takes `old`'s place among the block's successors, or, already a successor, `old` is removed;
the predecessor lists follow.
"""
@parity "llvm/lib/CodeGen/MachineBasicBlock.cpp:886 MachineBasicBlock::replaceSuccessor" function replace_successor(mf::MachineFunction, b::Int, old::Int, new::Int)::Nothing
    old == new && return nothing
    local succs = mf.blocks[b].succs
    local old_i = findfirst(==(old), succs)
    old_i === nothing && reject!(Internal("src/llvm/machine_basic_block.jl replace_successor: block $old is no successor of $b"), "MachineBasicBlock.replaceSuccessor")
    local pi = findfirst(==(b), mf.blocks[old].preds)
    pi === nothing || deleteat!(mf.blocks[old].preds, pi)
    if !(new in succs)
        push!(mf.blocks[new].preds, b)
        succs[old_i] = new
        return nothing
    end
    deleteat!(succs, old_i)
    return nothing
end

"""    is_successor(mf, b, s) -> Bool"""
@parity "llvm/lib/CodeGen/MachineBasicBlock.cpp:990 MachineBasicBlock::isSuccessor" is_successor(mf::MachineFunction, b::Int, s::Int)::Bool = s in mf.blocks[b].succs

"""    is_layout_successor(mf, b, s) -> Bool

Whether `s` follows `b` in the layout."""
@parity "llvm/lib/CodeGen/MachineBasicBlock.cpp:994 MachineBasicBlock::isLayoutSuccessor" function is_layout_successor(mf::MachineFunction, b::Int, s::Int)::Bool
    local i = findfirst(==(b), mf.layout)
    return i !== nothing && i < length(mf.layout) && mf.layout[i + 1] == s
end
