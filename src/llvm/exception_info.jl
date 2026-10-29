# llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.{h,cpp} at the llvm pin (dev/LEDGER.md D42):
# the exception tree, each EH pad's exception the blocks it dominates up to its dominance frontier,
# which CFGSort keeps contiguous and CFGStackify's placeTryTableMarker bounds. Over the blocks of
# Julia's machine CFG by number (src/julia/machine.jl), each EH pad a try region's catch block. Only
# the members the passes read are ported.

"""
    WebAssemblyException(eh_pad)

An exception: its EH pad (its header), its parent exception (nothing for a top-level one), its
subexceptions, and its blocks as a vector (the EH pad first once reversed) and as a set.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.h:42 WebAssemblyException" mutable struct WebAssemblyException
    const eh_pad::Int
    parent_exception::Union{Nothing,WebAssemblyException}
    const sub_exceptions::Vector{WebAssemblyException}
    const blocks::Vector{Int}
    const block_set::Set{Int}
    WebAssemblyException(eh_pad::Int) = new(eh_pad, nothing, WebAssemblyException[], Int[], Set{Int}())
end

"""    get_eh_pad(we) -> Int"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.h:55 WebAssemblyException::getEHPad" get_eh_pad(we::WebAssemblyException)::Int = we.eh_pad

"""    get_parent_exception(we) -> Union{WebAssemblyException,Nothing}"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.h:57 WebAssemblyException::getParentException" get_parent_exception(we::WebAssemblyException)::Union{WebAssemblyException,Nothing} = we.parent_exception

"""    set_parent_exception(we, parent) -> Nothing"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.h:58 WebAssemblyException::setParentException" function set_parent_exception(we::WebAssemblyException, parent::WebAssemblyException)::Nothing
    we.parent_exception = parent
    return nothing
end

"""    contains(we, other) -> Bool

Whether `other` is `we` or nested in it."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.h:60 WebAssemblyException::contains" function contains(we::WebAssemblyException, other::Union{Nothing,WebAssemblyException})::Bool
    other === we && return true
    other === nothing && return false
    return contains(we, get_parent_exception(other))
end

"""    contains(we, mbb) -> Bool

Whether block `mbb` is in the exception, a subexception's blocks included."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.h:67 WebAssemblyException::contains" contains(we::WebAssemblyException, mbb::Int)::Bool = mbb in we.block_set

"""    add_to_blocks_set(we, mbb) -> Nothing"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.h:71 WebAssemblyException::addToBlocksSet" function add_to_blocks_set(we::WebAssemblyException, mbb::Int)::Nothing
    push!(we.block_set, mbb)
    return nothing
end

"""    add_to_blocks_vector(we, mbb) -> Nothing"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.h:73 WebAssemblyException::addToBlocksVector" function add_to_blocks_vector(we::WebAssemblyException, mbb::Int)::Nothing
    push!(we.blocks, mbb)
    return nothing
end

"""    get_blocks(we) -> Vector{Int}"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.h:78 WebAssemblyException::getBlocks" get_blocks(we::WebAssemblyException)::Vector{Int} = we.blocks

"""    get_sub_exceptions(we) -> Vector{WebAssemblyException}"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.h:93 WebAssemblyException::getSubExceptions" get_sub_exceptions(we::WebAssemblyException)::Vector{WebAssemblyException} = we.sub_exceptions

"""    reverse_block(we) -> Nothing

The block vector reversed, the postorder it was filled in turned to the dominator tree's order."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.h:104 WebAssemblyException::reverseBlock" function reverse_block(we::WebAssemblyException)::Nothing
    reverse!(we.blocks)
    return nothing
end

"""    get_exception_depth(we) -> Int

The nesting level, an outermost exception's 1."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.h:109 WebAssemblyException::getExceptionDepth" function get_exception_depth(we::WebAssemblyException)::Int
    local d = 1
    local cur = we.parent_exception
    while cur !== nothing
        d += 1
        cur = cur.parent_exception
    end
    return d
end

"""
    WebAssemblyExceptionInfo()

The exceptions of one function: `bb_map`, each block's innermost exception, and the top-level
exceptions. `recalculate` fills it.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.h:123 WebAssemblyExceptionInfo" struct WebAssemblyExceptionInfo
    bb_map::Dict{Int,WebAssemblyException}
    top_level_exceptions::Vector{WebAssemblyException}
    WebAssemblyExceptionInfo() = new(Dict{Int,WebAssemblyException}(), WebAssemblyException[])
end

"""    empty(wei) -> Bool"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.h:147 WebAssemblyExceptionInfo::empty" empty(wei::WebAssemblyExceptionInfo)::Bool = isempty(wei.top_level_exceptions)

"""    get_exception_for(wei, mbb) -> Union{WebAssemblyException,Nothing}

The innermost exception block `mbb` lives in, nothing for a block in none."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.h:151 WebAssemblyExceptionInfo::getExceptionFor" get_exception_for(wei::WebAssemblyExceptionInfo, mbb::Int)::Union{WebAssemblyException,Nothing} =
    get(wei.bb_map, mbb, nothing)

"""    change_exception_for(wei, mbb, we) -> Nothing"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.h:155 WebAssemblyExceptionInfo::changeExceptionFor" function change_exception_for(wei::WebAssemblyExceptionInfo, mbb::Int, we::Union{Nothing,WebAssemblyException})::Nothing
    if we === nothing
        delete!(wei.bb_map, mbb)
        return nothing
    end
    wei.bb_map[mbb] = we
    return nothing
end

"""    add_top_level_exception(wei, we) -> Nothing"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.h:164 WebAssemblyExceptionInfo::addTopLevelException" function add_top_level_exception(wei::WebAssemblyExceptionInfo, we::WebAssemblyException)::Nothing
    we.parent_exception === nothing || reject!(Internal("llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.h:164 WebAssemblyExceptionInfo::addTopLevelException: not a top level exception"), "addTopLevelException")
    push!(wei.top_level_exceptions, we)
    return nothing
end

"""
    run_on_machine_function(wei, mf) -> Bool

The exception tree of `mf`, recalculated over Julia's dominator tree and the dominance frontier of
it; a function with no EH pad has none (LLVM's check of the personality function).
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.cpp:37 WebAssemblyExceptionInfo::runOnMachineFunction" function run_on_machine_function(wei::WebAssemblyExceptionInfo, mf::MachineFunction)::Bool
    release_memory(wei)
    any(b -> mf.blocks[b].ehpad, mf.layout) || return false
    local mdf = DominanceFrontierBase()
    analyze(mdf, mf)
    recalculate(wei, mf, mdf)
    return false
end

# the postorder of Julia's dominator tree from block 1, LLVM's post_order(&MDT)
@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.cpp:53 WebAssemblyExceptionInfo::recalculate" function recalculate(wei::WebAssemblyExceptionInfo, mf::MachineFunction, mdf::DominanceFrontierBase)::Nothing
    local mdt = mf.domtree
    local postorder = Int[]
    local stack = Tuple{Int,Bool}[(1, false)]
    while !isempty(stack)
        local (b, done) = pop!(stack)
        if done
            push!(postorder, b)
        else
            push!(stack, (b, true))
            for c in reverse(mdt.nodes[b].children)
                push!(stack, (c, false))
            end
        end
    end
    # Postorder traversal of the dominator tree.
    local exceptions = WebAssemblyException[]
    for eh_pad in postorder
        mf.blocks[eh_pad].ehpad || continue
        local we = WebAssemblyException(eh_pad)
        discover_and_map_exception(wei, we, mf, mdf)
        push!(exceptions, we)
    end
    # Add BBs to exceptions' block set. This is a preparation to take out remaining incorect BBs from
    # exceptions, because we need to iterate over BBs for each exception.
    for mbb in postorder
        local we = get_exception_for(wei, mbb)
        while we !== nothing
            add_to_blocks_set(we, mbb)
            we = get_parent_exception(we)
        end
    end
    # Add BBs to exceptions' block vector
    for mbb in postorder
        local we = get_exception_for(wei, mbb)
        while we !== nothing
            add_to_blocks_vector(we, mbb)
            we = get_parent_exception(we)
        end
    end
    # Add subexceptions to exceptions
    for we in exceptions
        local parent = get_parent_exception(we)
        parent === nothing ? add_top_level_exception(wei, we) : push!(get_sub_exceptions(parent), we)
    end
    # For convenience, Blocks and SubExceptions are inserted in postorder. Reverse the lists.
    for we in exceptions
        reverse_block(we)
        reverse!(get_sub_exceptions(we))
    end
    return nothing
end

@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.cpp:105 WebAssemblyExceptionInfo::releaseMemory" function release_memory(wei::WebAssemblyExceptionInfo)::Nothing
    empty!(wei.bb_map)
    empty!(wei.top_level_exceptions)
    return nothing
end

# the blocks of an EH pad's exception: those it dominates, reached by successors from the pad, a
# discovered subexception skipped whole with its pad's dominance frontier followed instead
@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.cpp:117 WebAssemblyExceptionInfo::discoverAndMapException" function discover_and_map_exception(wei::WebAssemblyExceptionInfo, we::WebAssemblyException, mf::MachineFunction, mdf::DominanceFrontierBase)::Nothing
    local mdt = mf.domtree
    # Map blocks that belong to a catchpad / cleanuppad
    local eh_pad = get_eh_pad(we)
    local wl = Int[eh_pad]
    while !isempty(wl)
        local mbb = pop!(wl)
        # Find its outermost discovered exception. If this is a discovered block, check if it is
        # already discovered to be a subexception of this exception.
        local sub_e = get_outermost_exception(wei, mbb)
        if sub_e !== nothing
            if sub_e !== we
                # Discover a subexception of this exception.
                set_parent_exception(sub_e, we)
                # All blocks that belong to this subexception have been already discovered. Skip all
                # of them. Add the subexception's landing pad's dominance frontier to the worklist.
                for frontier in find(mdf, get_eh_pad(sub_e))
                    Core.Compiler.dominates(mdt, eh_pad, frontier) && push!(wl, frontier)
                end
            end
            continue
        end
        # This is an undiscovered block. Map it to the current exception.
        change_exception_for(wei, mbb, we)
        # Add successors dominated by the current BB to the worklist.
        for succ in mf.blocks[mbb].succs
            Core.Compiler.dominates(mdt, eh_pad, succ) && push!(wl, succ)
        end
    end
    return nothing
end

@parity "llvm/lib/Target/WebAssembly/WebAssemblyExceptionInfo.cpp:164 WebAssemblyExceptionInfo::getOutermostException" function get_outermost_exception(wei::WebAssemblyExceptionInfo, mbb::Int)::Union{WebAssemblyException,Nothing}
    local we = get_exception_for(wei, mbb)
    if we !== nothing
        local parent = get_parent_exception(we)
        while parent !== nothing
            we = parent
            parent = get_parent_exception(we)
        end
    end
    return we
end
