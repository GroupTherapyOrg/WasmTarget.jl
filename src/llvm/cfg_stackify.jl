# llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp at the llvm pin (dev/LEDGER.md D42), modeled
# by dev/formal/CFGStackify.tla: BLOCK, LOOP and TRY_TABLE markers placed over the layout CFGSort
# made, and each branch's target block rewritten to its depth. The unwind mismatch fixes that make a
# try_table's span match each call's unwind destination are the next port; until then a function
# with an EH pad rejects there.

"""
    WebAssemblyCFGStackify()

The pass's state over one function: `mdt`, the dominator tree; `scope_tops`, for each block (by
number) whose label ends a scope, the block holding the scope's beginning, the farthest-spanning
one; `begin_to_end` and `end_to_begin`, each marker's partner; `try_to_eh_pad` and `eh_pad_to_try`,
each TRY_TABLE's EH pad and back; `appendix_bb`, the block added after the last when a loop's bottom
is the function's last block.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:49 WebAssemblyCFGStackify" mutable struct WebAssemblyCFGStackify
    mdt::Union{Nothing,Core.Compiler.DomTree}
    scope_tops::Vector{Union{Nothing,Int}}
    begin_to_end::Dict{MachineInstr,MachineInstr}
    end_to_begin::Dict{MachineInstr,MachineInstr}
    try_to_eh_pad::Dict{MachineInstr,Int}
    eh_pad_to_try::Dict{Int,MachineInstr}
    appendix_bb::Union{Nothing,Int}
    WebAssemblyCFGStackify() = new(nothing, Union{Nothing,Int}[], Dict{MachineInstr,MachineInstr}(), Dict{MachineInstr,MachineInstr}(),
                                   Dict{MachineInstr,Int}(), Dict{Int,MachineInstr}(), nothing)
end

"""    update_scope_tops(pass, mf, begin_, end_) -> Nothing

Records that a scope from block `begin_` ends at block `end_`, keeping the farthest-spanning."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:67 WebAssemblyCFGStackify::updateScopeTops" function update_scope_tops(pass::WebAssemblyCFGStackify, mf::MachineFunction, begin_::Int, end_::Int)::Nothing
    local begin_no = mf.blocks[begin_].number
    local end_no = mf.blocks[end_].number
    local top = pass.scope_tops[end_no]
    (top === nothing || mf.blocks[top].number > begin_no) && (pass.scope_tops[end_no] = begin_)
    return nothing
end

"""
    get_appendix_block(pass, mf) -> Int

The block after the function's last, made once, to hold the END_LOOP of a loop whose bottom is the
last block; a predecessor of itself, so it is never a scope's target.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:125 WebAssemblyCFGStackify::getAppendixBlock" function get_appendix_block(pass::WebAssemblyCFGStackify, mf::MachineFunction)::Int
    if pass.appendix_bb === nothing
        local a = create_machine_basic_block!(mf)
        push!(mf.blocks[a].succs, a)
        push!(mf.blocks[a].preds, a)
        push!(mf.layout, a)
        mf.blocks[a].number = length(mf.layout)
        pass.appendix_bb = a
    end
    return something(pass.appendix_bb)
end

"""    explicitly_branches_to(mf, pred, mbb) -> Bool

Whether a branch of `pred` names `mbb`, as opposed to falling through to it."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:194 explicitlyBranchesTo" function explicitly_branches_to(mf::MachineFunction, pred::Int, mbb::Int)::Bool
    for mi in terminators(mf, pred), mo in mi.operands
        mo isa MOBlock && mo.mbb == mbb && return true
    end
    return false
end

"""
    get_earliest_insert_pos(mf, mbb, before_set, after_set) -> Int

The earliest index in the block where a marker may go: just after the last instruction of
`before_set`, the start when none; an instruction of `after_set` before that point is an Internal
rejection (LLVM's assertion).
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:210 getEarliestInsertPos" function get_earliest_insert_pos(mf::MachineFunction, mbb::Int, before_set::Set{MachineInstr}, after_set::Set{MachineInstr})::Int
    local instrs = mf.blocks[mbb].instrs
    local pos = length(instrs) + 1
    while pos != 1
        if instrs[pos - 1] in before_set
            any(i -> instrs[i] in after_set, 1:pos-1) &&
                reject!(Internal("src/llvm/cfg_stackify.jl get_earliest_insert_pos: block $mbb orders a marker against its constraints"), "getEarliestInsertPos")
            break
        end
        pos -= 1
    end
    return pos
end

"""
    get_latest_insert_pos(mf, mbb, before_set, after_set) -> Int

The latest index in the block where a marker may go: just before the first instruction of
`after_set`, the end when none; an instruction of `before_set` after that point is an Internal
rejection (LLVM's assertion).
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:234 getLatestInsertPos" function get_latest_insert_pos(mf::MachineFunction, mbb::Int, before_set::Set{MachineInstr}, after_set::Set{MachineInstr})::Int
    local instrs = mf.blocks[mbb].instrs
    local pos = 1
    while pos != length(instrs) + 1
        if instrs[pos] in after_set
            any(i -> instrs[i] in before_set, pos:length(instrs)) &&
                reject!(Internal("src/llvm/cfg_stackify.jl get_latest_insert_pos: block $mbb orders a marker against its constraints"), "getLatestInsertPos")
            break
        end
        pos += 1
    end
    return pos
end

"""    register_scope(pass, begin_, end_) -> Nothing"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:251 WebAssemblyCFGStackify::registerScope" function register_scope(pass::WebAssemblyCFGStackify, begin_::MachineInstr, end_::MachineInstr)::Nothing
    pass.begin_to_end[begin_] = end_
    pass.end_to_begin[end_] = begin_
    return nothing
end

"""    register_try_scope(pass, begin_, end_, eh_pad) -> Nothing

A TRY_TABLE's scope, its END_TRY_TABLE and the EH pad it catches into."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:258 WebAssemblyCFGStackify::registerTryScope" function register_try_scope(pass::WebAssemblyCFGStackify, begin_::MachineInstr, end_::MachineInstr, eh_pad::Int)::Nothing
    register_scope(pass, begin_, end_)
    pass.try_to_eh_pad[begin_] = eh_pad
    pass.eh_pad_to_try[eh_pad] = begin_
    return nothing
end

"""    unregister_scope(pass, begin_) -> Nothing"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:266 WebAssemblyCFGStackify::unregisterScope" function unregister_scope(pass::WebAssemblyCFGStackify, begin_::MachineInstr)::Nothing
    haskey(pass.begin_to_end, begin_) || reject!(Internal("src/llvm/cfg_stackify.jl unregister_scope: a marker with no scope"), "unregisterScope")
    local end_ = pass.begin_to_end[begin_]
    haskey(pass.end_to_begin, end_) || reject!(Internal("src/llvm/cfg_stackify.jl unregister_scope: a scope's end unregistered"), "unregisterScope")
    delete!(pass.begin_to_end, begin_)
    delete!(pass.end_to_begin, end_)
    local eh_pad = get(pass.try_to_eh_pad, begin_, nothing)
    if eh_pad !== nothing
        haskey(pass.eh_pad_to_try, eh_pad) || reject!(Internal("src/llvm/cfg_stackify.jl unregister_scope: a try scope's EH pad unregistered"), "unregisterScope")
        delete!(pass.try_to_eh_pad, begin_)
        delete!(pass.eh_pad_to_try, eh_pad)
    end
    return nothing
end

"""
    place_block_marker(pass, mf, mbb) -> Nothing

A BLOCK for the branches to `mbb` from above, when one branches to it explicitly: at the nearest
common dominator of its forward predecessors, walked out to the nearest scope not more deeply
nested, before the markers of scopes it encloses and the terminators; its END_BLOCK at the start of
`mbb`, after the END_LOOPs of loops beginning inside it.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:283 WebAssemblyCFGStackify::placeBlockMarker" function place_block_marker(pass::WebAssemblyCFGStackify, mf::MachineFunction, mbb::Int)::Nothing
    mf.blocks[mbb].ehpad && reject!(Internal("src/llvm/cfg_stackify.jl place_block_marker: an EH pad"), "placeBlockMarker")
    local num(b::Int) = mf.blocks[b].number
    local mdt = something(pass.mdt)
    # the nearest common dominator of the forward predecessors, so the BLOCK is on the stack least
    local header = nothing
    local is_branched_to = false
    local mbb_number = num(mbb)
    for pred in mf.blocks[mbb].preds
        if num(pred) < mbb_number
            header = header === nothing ? pred : Core.Compiler.nearest_common_dominator(mdt, header, pred)
            explicitly_branches_to(mf, pred, mbb) && (is_branched_to = true)
        end
    end
    header === nothing && return nothing
    is_branched_to || return nothing
    mbb == mf.layout[1] && reject!(Internal("src/llvm/cfg_stackify.jl place_block_marker: the entry has predecessors"), "placeBlockMarker")
    local h = something(header)
    # a dominator inside a more deeply nested scope walks out to the nearest scope not more deeply nested
    local i = num(mbb) - 1
    while i != num(h)
        local scope_top = pass.scope_tops[i]
        if scope_top !== nothing
            if num(scope_top) > num(h)
                # skip over an intervening scope
                i = num(scope_top) + 1
            else
                # a scope level at an appropriate depth
                h = scope_top
                break
            end
        end
        i -= 1
    end
    # where in the header the BLOCK goes
    local before_set = Set{MachineInstr}()
    local after_set = Set{MachineInstr}()
    for mi in mf.blocks[h].instrs
        # a LOOP whose bottom is above mbb is nested in this BLOCK: after it
        if mi.opcode == LOOP
            local loop_bottom = something(get_prev_node(mf, pass.begin_to_end[mi].parent))
            mbb_number > num(loop_bottom) ? push!(after_set, mi) : push!(before_set, mi)
        end
        # a BLOCK whose END comes at or before this BLOCK's is nested in it: after it
        if mi.opcode == BLOCK
            num(pass.begin_to_end[mi].parent) <= mbb_number ? push!(after_set, mi) : push!(before_set, mi)
        end
        # every END marker before the BLOCK; the terminators after it
        mi.opcode in (END_BLOCK, END_LOOP) && push!(before_set, mi)
        is_terminator(mi) && push!(after_set, mi)
    end
    # (LLVM's local expression tree goes after the BLOCK too: STMTS, the only other instruction here,
    # is no stackified child)
    local insert_pos = get_latest_insert_pos(mf, h, before_set, after_set)
    local begin_ = MachineInstr(BLOCK, MachineOperand[MOImm(BLOCK_TYPE_VOID)], h)
    insert!(mf.blocks[h].instrs, insert_pos, begin_)
    # where in mbb the END_BLOCK goes
    empty!(before_set)
    empty!(after_set)
    for mi in mf.blocks[mbb].instrs
        # an END_BLOCK precedes the LOOP markers
        mi.opcode == LOOP && push!(after_set, mi)
        # an END_LOOP whose loop begins at or below the header ends inside this BLOCK: before the END_BLOCK
        if mi.opcode == END_LOOP
            num(pass.end_to_begin[mi].parent) >= num(h) ? push!(before_set, mi) : push!(after_set, mi)
        end
    end
    insert_pos = get_earliest_insert_pos(mf, mbb, before_set, after_set)
    local end_ = MachineInstr(END_BLOCK, MachineOperand[], mbb)
    insert!(mf.blocks[mbb].instrs, insert_pos, end_)
    register_scope(pass, begin_, end_)
    # the farthest-spanning scope that ends here
    update_scope_tops(pass, mf, h, mbb)
    return nothing
end

"""
    place_loop_marker(pass, mf, mli, wei, mbb) -> Nothing

A LOOP at `mbb` when it heads a loop: after the END_LOOPs of loops ending there; its END_LOOP at the
start of the block after the loop's bottom (the appendix block when the bottom is the last).
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:434 WebAssemblyCFGStackify::placeLoopMarker" function place_loop_marker(pass::WebAssemblyCFGStackify, mf::MachineFunction, mli::LoopInfoBase, wei::WebAssemblyExceptionInfo, mbb::Int)::Nothing
    local sri = SortRegionInfo(mli, wei)
    local loop = get_loop_for(mli, mbb)
    (loop === nothing || get_header(loop) != mbb) && return nothing
    # the LOOP's operand is the first block after the loop: past the function's end, the appendix
    local bottom = get_bottom(sri, mf, something(loop))
    local iter = mf.blocks[bottom].number + 1
    if iter > length(mf.layout)
        get_appendix_block(pass, mf)
        iter = mf.blocks[bottom].number + 1
    end
    local after_loop = mf.layout[iter]
    # where in the header the LOOP goes: after any END_LOOP ending there
    local before_set = Set{MachineInstr}()
    local after_set = Set{MachineInstr}()
    for mi in mf.blocks[mbb].instrs
        mi.opcode == END_LOOP ? push!(before_set, mi) : push!(after_set, mi)
    end
    local insert_pos = get_earliest_insert_pos(mf, mbb, before_set, after_set)
    local begin_ = MachineInstr(LOOP, MachineOperand[MOImm(BLOCK_TYPE_VOID)], mbb)
    insert!(mf.blocks[mbb].instrs, insert_pos, begin_)
    # where in after_loop the END_LOOP goes: before the END_LOOPs of the loops holding this one
    empty!(before_set)
    empty!(after_set)
    for mi in mf.blocks[after_loop].instrs
        mi.opcode == END_LOOP && push!(after_set, mi)
    end
    insert_pos = get_earliest_insert_pos(mf, after_loop, before_set, after_set)
    local end_ = MachineInstr(END_LOOP, MachineOperand[], after_loop)
    insert!(mf.blocks[after_loop].instrs, insert_pos, end_)
    register_scope(pass, begin_, end_)
    local top = pass.scope_tops[mf.blocks[after_loop].number]
    (top === nothing || mf.blocks[top].number < mf.blocks[mbb].number) ||
        reject!(Internal("src/llvm/cfg_stackify.jl place_loop_marker: the outermost loop for a block is not first"), "placeLoopMarker")
    update_scope_tops(pass, mf, mbb, after_loop)
    return nothing
end

"""
    place_try_table_marker(pass, mf, mli, wei, mbb) -> Nothing

A TRY_TABLE for the EH pad `mbb`, inside a BLOCK its catch clause branches to: at the nearest common
dominator of the pad's unwind predecessors above it, walked out to the nearest scope not more deeply
nested, before the markers of the scopes it encloses, the terminators and, when the header itself
unwinds to `mbb`, the header's statements (STMTS, where LLVM holds the throwing call); its
END_TRY_TABLE and the BLOCK's END_BLOCK at the start of `mbb`, after the END_LOOPs of loops beginning
inside it and before the CATCH. The scope tops are those of the try_table ending at `mbb` and of the
conceptual catch block ending after the exception's bottom.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:695 WebAssemblyCFGStackify::placeTryTableMarker" function place_try_table_marker(pass::WebAssemblyCFGStackify, mf::MachineFunction, mli::LoopInfoBase, wei::WebAssemblyExceptionInfo, mbb::Int)::Nothing
    mf.blocks[mbb].ehpad || reject!(Internal("src/llvm/cfg_stackify.jl place_try_table_marker: block $mbb is no EH pad"), "placeTryTableMarker")
    local num(b::Int) = mf.blocks[b].number
    local mdt = something(pass.mdt)
    local sri = SortRegionInfo(mli, wei)
    # Compute the nearest common dominator of all unwind predecessors
    local header = nothing
    local mbb_number = num(mbb)
    for pred in mf.blocks[mbb].preds
        if num(pred) < mbb_number
            header = header === nothing ? pred : Core.Compiler.nearest_common_dominator(mdt, header, pred)
            explicitly_branches_to(mf, pred, mbb) && reject!(Internal("src/llvm/cfg_stackify.jl place_try_table_marker: an explicit branch to the EH pad $mbb"), "placeTryTableMarker")
        end
    end
    header === nothing && return nothing
    local h = something(header)
    # Unlike the end_try marker, no end marker goes at the end of the exception's bottom, but the
    # try-catch part is still a scope when computing ScopeTops.
    local we = get_exception_for(wei, mbb)
    we === nothing && reject!(Internal("src/llvm/cfg_stackify.jl place_try_table_marker: the EH pad $mbb has no exception"), "placeTryTableMarker")
    local bottom = get_bottom(sri, mf, something(we))
    local cont = mf.layout[min(num(bottom) + 1, length(mf.layout))]
    # If the nearest common dominator is inside a more deeply nested context, walk out to the nearest
    # scope which isn't more deeply nested.
    local i = num(bottom)
    while i != num(h)
        local scope_top = pass.scope_tops[i]
        if scope_top !== nothing
            if num(scope_top) > num(h)
                # Skip over an intervening scope.
                i = num(scope_top) + 1
            else
                # We found a scope level at an appropriate depth.
                h = scope_top
                break
            end
        end
        i -= 1
    end
    # Decide where in Header to put the TRY_TABLE.
    local before_set = Set{MachineInstr}()
    local after_set = Set{MachineInstr}()
    for mi in mf.blocks[h].instrs
        # A LOOP whose bottom block is above MBB is nested in this TRY_TABLE: after it; otherwise before.
        if mi.opcode == LOOP
            local loop_bottom = something(get_prev_node(mf, pass.begin_to_end[mi].parent))
            mbb_number > num(loop_bottom) ? push!(after_set, mi) : push!(before_set, mi)
        end
        # All previously inserted BLOCK/TRY_TABLE markers are nested blocks/try_tables: after it.
        mi.opcode in (BLOCK, TRY_TABLE) && push!(after_set, mi)
        # All END_(BLOCK/LOOP/TRY_TABLE) markers before the TRY_TABLE.
        mi.opcode in (END_BLOCK, END_LOOP, END_TRY_TABLE) && push!(before_set, mi)
        # Terminators go after the TRY_TABLE.
        is_terminator(mi) && push!(after_set, mi)
    end
    # If Header unwinds to MBB (it holds a throwing statement), the try_table holds the throw: the
    # header's statements (STMTS, where LLVM holds the throwing call among the block's instructions)
    # go after the TRY_TABLE. A header ending in a rethrow throws there, not before; no Julia block
    # does.
    if h in mf.blocks[mbb].preds
        for mi in Iterators.reverse(mf.blocks[h].instrs)
            if mi.opcode == STMTS
                push!(after_set, mi)
                break
            end
        end
    end
    # (LLVM's local expression tree goes after the TRY_TABLE too: STMTS, the only other instruction
    # here, is no stackified child)
    # Add the TRY_TABLE and a BLOCK for the catch destination, one CATCH clause and one BLOCK:
    #   Header:
    #     block
    #       try_table (catch ... $MBB)
    #         ...
    #   MBB:
    #       end_try_table
    #     end_block                 ;; destination of (catch ...)
    #     ... catch handler body ...
    local insert_pos = get_latest_insert_pos(mf, h, before_set, after_set)
    # the CATCH clause: its destination BLOCK returns the caught value, WasmTarget's tag's payload
    local catch_ = mf.blocks[mbb].instrs[1]
    catch_.opcode == CATCH || reject!(Internal("src/llvm/cfg_stackify.jl place_try_table_marker: the EH pad $mbb does not begin with its CATCH"), "placeTryTableMarker")
    local block = MachineInstr(BLOCK, MachineOperand[MOImm(BLOCK_TYPE_CATCH)], h)
    # the TRY_TABLE's operands: its block type, its catch clause count, the clause (wasm's catch, 0x00,
    # of the one tag) and the clause's destination
    local try_table = MachineInstr(TRY_TABLE, MachineOperand[MOImm(BLOCK_TYPE_VOID), MOImm(1), MOImm(0x00), MOBlock(mbb)], h)
    insert!(mf.blocks[h].instrs, insert_pos, block)
    insert!(mf.blocks[h].instrs, insert_pos + 1, try_table)
    # Decide where in MBB to put the END_TRY_TABLE, and the END_BLOCK for the CATCH destination.
    empty!(before_set)
    empty!(after_set)
    for mi in mf.blocks[mbb].instrs
        # END_TRY_TABLE precedes existing LOOP markers.
        mi.opcode == LOOP && push!(after_set, mi)
        # An END_LOOP whose loop's header is at or below this try_table's header ends inside it: before
        # the END_TRY_TABLE; otherwise after.
        if mi.opcode == END_LOOP
            num(pass.end_to_begin[mi].parent) >= num(h) ? push!(before_set, mi) : push!(after_set, mi)
        end
        # CATCH simulates the block's return value: after the END_TRY_TABLE.
        mi.opcode == CATCH && push!(after_set, mi)
    end
    # Mark the end of the TRY_TABLE and the BLOCK.
    insert_pos = get_earliest_insert_pos(mf, mbb, before_set, after_set)
    local end_try_table = MachineInstr(END_TRY_TABLE, MachineOperand[], mbb)
    local end_block = MachineInstr(END_BLOCK, MachineOperand[], mbb)
    insert!(mf.blocks[mbb].instrs, insert_pos, end_try_table)
    insert!(mf.blocks[mbb].instrs, insert_pos + 1, end_block)
    register_try_scope(pass, try_table, end_try_table, mbb)
    register_scope(pass, block, end_block)
    # Track the farthest-spanning scope that ends at this point: the try_table ending at MBB and the
    # (conceptual) catch block ending at the block after the exception's bottom.
    for end_ in (mbb, cont)
        update_scope_tops(pass, mf, h, end_)
    end
    return nothing
end

"""
    add_unreachable_after_try_tables(mf) -> Nothing

An UNREACHABLE after each END_TRY_TABLE, in a block of its own split off before the END_TRY_TABLE's:
the catch destination BLOCK returns the caught value, which its body, ending with the try_table, does
not leave, so wasm checks the body against a value it never has unless the end is unreachable.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:2487 addUnreachableAfterTryTables" function add_unreachable_after_try_tables(mf::MachineFunction)::Nothing
    local end_try_tables = MachineInstr[mi for mbb in mf.layout for mi in mf.blocks[mbb].instrs if mi.opcode == END_TRY_TABLE]
    for end_try_table in end_try_tables
        local mbb = end_try_table.parent
        local new_end_try_table_bb = create_machine_basic_block!(mf)
        insert!(mf.layout, findfirst(==(mbb), mf.layout), new_end_try_table_bb)
        local instrs = mf.blocks[mbb].instrs
        local split_pos = findfirst(mi -> mi === end_try_table, instrs)
        local moved = instrs[1:split_pos]
        deleteat!(instrs, 1:split_pos)
        for mi in moved
            mi.parent = new_end_try_table_bb
        end
        append!(mf.blocks[new_end_try_table_bb].instrs, moved)
        push!(mf.blocks[new_end_try_table_bb].succs, mbb)
        push!(mf.blocks[mbb].preds, new_end_try_table_bb)
        push!(mf.blocks[new_end_try_table_bb].instrs, MachineInstr(UNREACHABLE, MachineOperand[], new_end_try_table_bb))
    end
    return nothing
end

@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:2076 WebAssemblyCFGStackify::fixCatchUnwindMismatches" @unported function fix_catch_unwind_mismatches(pass::WebAssemblyCFGStackify, mf::MachineFunction) end

@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:1592 WebAssemblyCFGStackify::fixCallUnwindMismatches" @unported function fix_call_unwind_mismatches(pass::WebAssemblyCFGStackify, mf::MachineFunction) end

"""
    recalculate_scope_tops(pass, mf) -> Nothing

The blocks renumbered and the scope tops computed again from every end marker, the passes after
the placement having made blocks.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:2367 WebAssemblyCFGStackify::recalculateScopeTops" function recalculate_scope_tops(pass::WebAssemblyCFGStackify, mf::MachineFunction)::Nothing
    # Renumber BBs and recalculate ScopeTop info because new BBs might have been created and inserted
    # during fixing unwind mismatches.
    renumber_blocks!(mf)
    pass.scope_tops = Union{Nothing,Int}[nothing for _ in 1:length(mf.layout)]
    for mbb in Iterators.reverse(mf.layout)
        for mi in Iterators.reverse(mf.blocks[mbb].instrs)
            pass.scope_tops[mf.blocks[mbb].number] === nothing || break
            mi.opcode in (END_BLOCK, END_LOOP, END_TRY_TABLE) && update_scope_tops(pass, mf, pass.end_to_begin[mi].parent, mbb)
        end
    end
    return nothing
end

"""
    place_markers(pass, mf, mli, wei) -> Nothing

Every LOOP first, then, in layout order, a TRY_TABLE for each EH pad and a BLOCK for each block
branched to from above; with EH pads, an UNREACHABLE after each END_TRY_TABLE, the unwind mismatches
fixed, and the scope tops recalculated over the blocks those made.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:2509 WebAssemblyCFGStackify::placeMarkers" function place_markers(pass::WebAssemblyCFGStackify, mf::MachineFunction, mli::LoopInfoBase, wei::WebAssemblyExceptionInfo)::Nothing
    # one more than the blocks, for the appendix block a loop may add
    pass.scope_tops = Union{Nothing,Int}[nothing for _ in 1:length(mf.layout)+1]
    for mbb in copy(mf.layout)
        place_loop_marker(pass, mf, mli, wei, mbb)
    end
    local has_eh_pads = false
    for mbb in copy(mf.layout)
        if mf.blocks[mbb].ehpad
            # Place the TRY_TABLE for MBB if MBB is the EH pad of an exception.
            has_eh_pads = true
            place_try_table_marker(pass, mf, mli, wei, mbb)
        else
            # Place the BLOCK for MBB if MBB is branched to from above.
            place_block_marker(pass, mf, mbb)
        end
    end
    if has_eh_pads
        # Add an 'unreachable' after 'end_try_table's.
        add_unreachable_after_try_tables(mf)
        # Fix mismatches in unwind destinations induced by linearizing the code, catches first so the
        # calls' fix sees the mismatches it introduces.
        fix_catch_unwind_mismatches(pass, mf)
        fix_call_unwind_mismatches(pass, mf)
        # addUnreachableAfterTryTables and the fixes create new blocks: ScopeTops again.
        recalculate_scope_tops(pass, mf)
    end
    return nothing
end

"""    get_branch_depth(stack, mbb) -> Int

The depth of `mbb`'s label: the scopes counted from the innermost until the one targeting `mbb`."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:2551 WebAssemblyCFGStackify::getBranchDepth" function get_branch_depth(stack::Vector{Tuple{Int,MachineInstr}}, mbb::Int)::Int
    local depth = 0
    for x in Iterators.reverse(stack)
        x[1] == mbb && break
        depth += 1
    end
    depth < length(stack) || reject!(Internal("src/llvm/cfg_stackify.jl get_branch_depth: block $mbb's label is not in scope"), "getBranchDepth")
    return depth
end

"""
    rewrite_depth_immediates(pass, mf) -> Nothing

Each branch's target block becomes its depth, walking the function backward with the stack of the
scopes open there: an END_BLOCK or END_TRY_TABLE pushes its block, an END_LOOP its loop's header, a
BLOCK, LOOP or TRY_TABLE pops, a TRY_TABLE's catch destination rewritten as it pops.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:2615 WebAssemblyCFGStackify::rewriteDepthImmediates" function rewrite_depth_immediates(pass::WebAssemblyCFGStackify, mf::MachineFunction)::Nothing
    local stack = Tuple{Int,MachineInstr}[]
    for mbb in Iterators.reverse(mf.layout), mi in Iterators.reverse(mf.blocks[mbb].instrs)
        if mi.opcode == BLOCK
            isempty(stack) && reject!(Internal("src/llvm/cfg_stackify.jl rewrite_depth_immediates: a BLOCK unbalanced"), "rewriteDepthImmediates")
            pop!(stack)
        elseif mi.opcode == TRY_TABLE
            # its catch clause's destination is a depth, counted from outside the try_table
            isempty(stack) && reject!(Internal("src/llvm/cfg_stackify.jl rewrite_depth_immediates: a TRY_TABLE unbalanced"), "rewriteDepthImmediates")
            pop!(stack)
            for (k, mo) in enumerate(mi.operands)
                mo isa MOBlock && (mi.operands[k] = MOImm(get_branch_depth(stack, mo.mbb)))
            end
        elseif mi.opcode == LOOP
            (!isempty(stack) && stack[end][1] == mbb) ||
                reject!(Internal("src/llvm/cfg_stackify.jl rewrite_depth_immediates: a LOOP unbalanced"), "rewriteDepthImmediates")
            pop!(stack)
        elseif mi.opcode in (END_BLOCK, END_TRY_TABLE)
            push!(stack, (mbb, mi))
        elseif mi.opcode == END_LOOP
            push!(stack, (pass.end_to_begin[mi].parent, mi))
        elseif is_terminator(mi)
            for (k, mo) in enumerate(mi.operands)
                mo isa MOBlock && (mi.operands[k] = MOImm(get_branch_depth(stack, mo.mbb)))
            end
        end
    end
    isempty(stack) || reject!(Internal("src/llvm/cfg_stackify.jl rewrite_depth_immediates: control flow unbalanced"), "rewriteDepthImmediates")
    return nothing
end

"""
    fix_ends_at_end_of_function(pass, mf, has_results) -> Nothing

A function with results: every BLOCK, LOOP and TRY_TABLE whose END ends the function body takes the
function's results as its block type (BLOCK_TYPE_RESULTS, filled where the instructions are
lowered, as LLVM's Multivalue), since wasm checks the type at an end the code never reaches.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:2401 WebAssemblyCFGStackify::fixEndsAtEndOfFunction" function fix_ends_at_end_of_function(pass::WebAssemblyCFGStackify, mf::MachineFunction, has_results::Bool)::Nothing
    has_results || return nothing
    local k = length(mf.layout)
    while k >= 1
        local instrs = mf.blocks[mf.layout[k]].instrs
        local i = length(instrs)
        while i >= 1
            local mi = instrs[i]
            mi.opcode in (END_BLOCK, END_LOOP, END_TRY_TABLE) || return nothing
            pass.end_to_begin[mi].operands[1] = MOImm(BLOCK_TYPE_RESULTS)
            i -= 1
        end
        # the start of a block: on into the previous block
        k -= 1
    end
    return nothing
end

"""
    run_on_machine_function(pass, mf, mli, wei, has_results) -> Nothing

Places the markers, rewrites the branches' targets to depths, and fixes the block types of the
scopes ending the function.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:2701 WebAssemblyCFGStackify::runOnMachineFunction" function run_on_machine_function(pass::WebAssemblyCFGStackify, mf::MachineFunction, mli::LoopInfoBase, wei::WebAssemblyExceptionInfo, has_results::Bool)::Nothing
    pass.mdt = mf.domtree
    place_markers(pass, mf, mli, wei)
    rewrite_depth_immediates(pass, mf)
    fix_ends_at_end_of_function(pass, mf, has_results)
    return nothing
end
