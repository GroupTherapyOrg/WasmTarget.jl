# llvm/include/llvm/Support/GenericLoopInfo.h at the llvm pin (dev/LEDGER.md D42): the loop tree
# LLVM's MachineLoopInfo is, LoopBase and LoopInfoBase over MachineBasicBlock, here over the blocks
# of Julia's CFG by number (src/julia/machine.jl). Only the members the stackifier reads are ported.

"""
    LoopBase(bb)

A natural loop: its parent loop (nothing for an outermost loop), its subloops, its blocks with the
header first, and the same blocks as a set. `LoopBase(bb)` is a loop of the one block `bb`, its
header (LLVM's `explicit LoopBase(BlockT *BB)`).
"""
@parity "llvm/include/llvm/Support/GenericLoopInfo.h:59 LoopBase" mutable struct LoopBase
    parent_loop::Union{Nothing,LoopBase}
    sub_loops::Vector{LoopBase}
    blocks::Vector{Int}
    dense_block_set::Set{Int}
    LoopBase(bb::Int) = new(nothing, LoopBase[], Int[bb], Set{Int}([bb]))
end

"""    get_header(l) -> Int

The loop's header, its first block."""
@parity "llvm/include/llvm/Support/GenericLoopInfo.h:90 LoopBase::getHeader" get_header(l::LoopBase)::Int = l.blocks[1]

"""    get_parent_loop(l) -> Union{LoopBase,Nothing}"""
@parity "llvm/include/llvm/Support/GenericLoopInfo.h:99 LoopBase::getParentLoop" get_parent_loop(l::LoopBase)::Union{LoopBase,Nothing} = l.parent_loop

"""    get_outermost_loop(l) -> LoopBase

The outermost loop holding `l`, `l` itself when it has no parent."""
@parity "llvm/include/llvm/Support/GenericLoopInfo.h:110 LoopBase::getOutermostLoop" function get_outermost_loop(l::LoopBase)::LoopBase
    local p = l.parent_loop
    while p !== nothing
        l = p
        p = l.parent_loop
    end
    return l
end

"""    set_parent_loop(l, p) -> Nothing"""
@parity "llvm/include/llvm/Support/GenericLoopInfo.h:118 LoopBase::setParentLoop" function set_parent_loop(l::LoopBase, p::LoopBase)::Nothing
    l.parent_loop = p
    return nothing
end

"""    contains(l, bb) -> Bool

Whether block `bb` is in the loop, a subloop's blocks included."""
@parity "llvm/include/llvm/Support/GenericLoopInfo.h:134 LoopBase::contains" contains(l::LoopBase, bb::Int)::Bool = bb in l.dense_block_set

"""    get_sub_loops_vector(l) -> Vector{LoopBase}"""
@parity "llvm/include/llvm/Support/GenericLoopInfo.h:149 LoopBase::getSubLoopsVector" get_sub_loops_vector(l::LoopBase)::Vector{LoopBase} = l.sub_loops

"""    is_outermost(l) -> Bool"""
@parity "llvm/include/llvm/Support/GenericLoopInfo.h:170 LoopBase::isOutermost" is_outermost(l::LoopBase)::Bool = l.parent_loop === nothing

"""    blocks(l) -> Vector{Int}

The loop's blocks, the header first."""
@parity "llvm/include/llvm/Support/GenericLoopInfo.h:180 LoopBase::blocks" blocks(l::LoopBase)::Vector{Int} = l.blocks

"""    get_num_blocks(l) -> Int"""
@parity "llvm/include/llvm/Support/GenericLoopInfo.h:187 LoopBase::getNumBlocks" get_num_blocks(l::LoopBase)::Int = length(l.blocks)

"""    add_block_entry(l, bb) -> Nothing

Adds `bb` to the loop's blocks."""
@parity "llvm/include/llvm/Support/GenericLoopInfo.h:419 LoopBase::addBlockEntry" function add_block_entry(l::LoopBase, bb::Int)::Nothing
    push!(l.blocks, bb)
    push!(l.dense_block_set, bb)
    return nothing
end

"""    reverse_block(l, from) -> Nothing

Reverses the loop's blocks from index `from` (0-based, as LLVM's) to the end."""
@parity "llvm/include/llvm/Support/GenericLoopInfo.h:426 LoopBase::reverseBlock" function reverse_block(l::LoopBase, from::Int)::Nothing
    reverse!(l.blocks, from + 1, length(l.blocks))
    return nothing
end

"""
    LoopInfoBase()

The loop tree of a function: `bb_map`, each block's innermost loop by its number in Julia's CFG
(nothing for a block in no loop), which LLVM indexes by GraphTraits' block number, and the
outermost loops.
"""
@parity "llvm/include/llvm/Support/GenericLoopInfo.h:526 LoopInfoBase" mutable struct LoopInfoBase
    bb_map::Vector{Union{Nothing,LoopBase}}
    top_level_loops::Vector{LoopBase}
    LoopInfoBase() = new(Union{Nothing,LoopBase}[], LoopBase[])
end

"""    allocate_loop(li, header) -> LoopBase

A new loop whose header is `header`."""
@parity "llvm/include/llvm/Support/GenericLoopInfo.h:584 LoopInfoBase::AllocateLoop" allocate_loop(li::LoopInfoBase, header::Int)::LoopBase = LoopBase(header)

"""    get_loop_for(li, bb) -> Union{LoopBase,Nothing}

The innermost loop holding `bb`, nothing for a block in no loop."""
@parity "llvm/include/llvm/Support/GenericLoopInfo.h:631 LoopInfoBase::getLoopFor" get_loop_for(li::LoopInfoBase, bb::Int)::Union{LoopBase,Nothing} =
    bb <= length(li.bb_map) ? li.bb_map[bb] : nothing

"""    change_loop_for(li, bb, l) -> Nothing

Makes `l` the innermost loop holding `bb`."""
@parity "llvm/include/llvm/Support/GenericLoopInfo.h:684 LoopInfoBase::changeLoopFor" function change_loop_for(li::LoopInfoBase, bb::Int, l::LoopBase)::Nothing
    bb <= length(li.bb_map) || reject!(Internal("src/llvm/generic_loop_info.jl change_loop_for: block $bb past the map's $(length(li.bb_map))"), "LoopInfoBase.changeLoopFor")
    li.bb_map[bb] = l
    return nothing
end

"""    add_top_level_loop(li, l) -> Nothing"""
@parity "llvm/include/llvm/Support/GenericLoopInfo.h:707 LoopInfoBase::addTopLevelLoop" function add_top_level_loop(li::LoopInfoBase, l::LoopBase)::Nothing
    is_outermost(l) || reject!(Internal("src/llvm/generic_loop_info.jl add_top_level_loop: the loop is already in a subloop"), "LoopInfoBase.addTopLevelLoop")
    push!(li.top_level_loops, l)
    return nothing
end
