# llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp at the llvm pin (dev/LEDGER.md D42), modeled
# by dev/formal/CFGStackify.tla: BLOCK, LOOP and TRY_TABLE markers placed over the layout CFGSort
# made, and each branch's target block rewritten to its depth. An unwind mismatch a try_table's span
# makes is fixed with a nested try_table that catches to a trampoline, which rethrows the exception
# to the right destination.

"""
    WebAssemblyCFGStackify()

The pass's state over one function: `mdt`, the dominator tree; `scope_tops`, for each block (by
number) whose label ends a scope, the block holding the scope's beginning, the farthest-spanning
one; `begin_to_end` and `end_to_begin`, each marker's partner; `try_to_eh_pad` and `eh_pad_to_try`,
each TRY_TABLE's EH pad and back; `unwind_dest_to_trampoline`, each unwind destination's trampoline
block, which rethrows an exception a nested try_table caught to it; `appendix_bb`, the block added
after the last when a loop's bottom is the function's last block; `caller_trampoline_bb`, the
trampoline that rethrows to the caller, last in the layout; `fake_caller_bb`, the block outside the
layout that stands for the caller as an unwind destination.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:49 WebAssemblyCFGStackify" mutable struct WebAssemblyCFGStackify
    mdt::Union{Nothing,Core.Compiler.DomTree}
    scope_tops::Vector{Union{Nothing,Int}}
    begin_to_end::Dict{MachineInstr,MachineInstr}
    end_to_begin::Dict{MachineInstr,MachineInstr}
    try_to_eh_pad::Dict{MachineInstr,Int}
    eh_pad_to_try::Dict{Int,MachineInstr}
    unwind_dest_to_trampoline::Dict{Int,Int}
    appendix_bb::Union{Nothing,Int}
    caller_trampoline_bb::Union{Nothing,Int}
    fake_caller_bb::Union{Nothing,Int}
    WebAssemblyCFGStackify() = new(nothing, Union{Nothing,Int}[], Dict{MachineInstr,MachineInstr}(), Dict{MachineInstr,MachineInstr}(),
                                   Dict{MachineInstr,Int}(), Dict{Int,MachineInstr}(), Dict{Int,Int}(), nothing, nothing, nothing)
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
last block; a predecessor of itself, so it is never a scope's target. It goes before the caller
trampoline, which stays last.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:125 WebAssemblyCFGStackify::getAppendixBlock" function get_appendix_block(pass::WebAssemblyCFGStackify, mf::MachineFunction)::Int
    if pass.appendix_bb === nothing
        local a = create_machine_basic_block!(mf)
        add_successor(mf, a, a)
        # If the caller trampoline BB exists, insert the appendix BB before it. Otherwise insert it
        # at the end of the function.
        if pass.caller_trampoline_bb === nothing
            push!(mf.layout, a)
        else
            insert!(mf.layout, findfirst(==(pass.caller_trampoline_bb), mf.layout), a)
        end
        mf.blocks[a].number = length(mf.layout)
        pass.appendix_bb = a
    end
    return something(pass.appendix_bb)
end

"""
    get_caller_trampoline_block(pass, mf) -> Int

The trampoline block that rethrows to the caller, made once, last in the layout.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:143 WebAssemblyCFGStackify::getCallerTrampolineBlock" function get_caller_trampoline_block(pass::WebAssemblyCFGStackify, mf::MachineFunction)::Int
    if pass.caller_trampoline_bb === nothing
        pass.caller_trampoline_bb = create_machine_basic_block!(mf)
        push!(mf.layout, something(pass.caller_trampoline_bb))
    end
    return something(pass.caller_trampoline_bb)
end

"""
    get_fake_caller_block(pass, mf) -> Int

The block that stands for the caller as an unwind destination, made once and never in the layout: a
try_table catching to it rethrows to the caller.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:158 WebAssemblyCFGStackify::getFakeCallerBlock" function get_fake_caller_block(pass::WebAssemblyCFGStackify, mf::MachineFunction)::Int
    pass.fake_caller_bb === nothing && (pass.fake_caller_bb = create_machine_basic_block!(mf))
    return something(pass.fake_caller_bb)
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

formal(dev/formal/CFGStackify.tla): the markers stay well nested and the catch clause's depth names the BLOCK ending at the pad
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
    local try_table = MachineInstr(TRY_TABLE, MachineOperand[MOImm(BLOCK_TYPE_VOID), MOImm(1), MOImm(WASM_OPCODE_CATCH), MOBlock(mbb)], h)
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

"""
    get_trampoline_block(pass, mf, unwind_dest) -> Int

The trampoline block for an unwind destination, made once: the END_BLOCK of a BLOCK of type exnref
(the target of a nested try_table's catch_all_ref), then CATCH_ALL_REF, which takes the exnref, and
THROW_REF, which rethrows it. For the caller the BLOCK opens the function and the trampoline is the
caller trampoline, last; for an EH pad the BLOCK follows the pad's TRY_TABLE and the trampoline goes
before the block holding its END_TRY_TABLE, so the rethrow lands in that try_table's catch. An
UNREACHABLE ends the block before the trampoline, whose fallthrough has no exnref.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:1312 WebAssemblyCFGStackify::getTrampolineBlock" function get_trampoline_block(pass::WebAssemblyCFGStackify, mf::MachineFunction, unwind_dest::Int)::Int
    # We need one trampoline BB per unwind destination, even though there are multiple try_tables
    # target the same unwind destination.
    haskey(pass.unwind_dest_to_trampoline, unwind_dest) && return pass.unwind_dest_to_trampoline[unwind_dest]
    local block_, trampoline_bb
    if unwind_dest == get_fake_caller_block(pass, mf)
        # If the unwind destination is the caller, create a caller-dedicated trampoline BB at the end
        # of the function and wrap the whole function with a block (no ARGUMENT instructions precede
        # it: a parameter is a local).
        local first_bb = mf.layout[1]
        block_ = MachineInstr(BLOCK, MachineOperand[MOImm(BLOCK_TYPE_EXNREF)], first_bb)
        pushfirst!(mf.blocks[first_bb].instrs, block_)
        trampoline_bb = get_caller_trampoline_block(pass, mf)
    else
        # If the unwind destination is another EH pad, create a trampoline BB for the unwind dest and
        # insert a block instruction right after the target try_table.
        local target_begin_try = pass.eh_pad_to_try[unwind_dest]
        local target_end_try = pass.begin_to_end[target_begin_try]
        local target_begin_bb = target_begin_try.parent
        local target_end_bb = target_end_try.parent
        block_ = MachineInstr(BLOCK, MachineOperand[MOImm(BLOCK_TYPE_EXNREF)], target_begin_bb)
        local instrs = mf.blocks[target_begin_bb].instrs
        insert!(instrs, findfirst(mi -> mi === target_begin_try, instrs) + 1, block_)
        trampoline_bb = create_machine_basic_block!(mf)
        insert!(mf.layout, findfirst(==(target_end_bb), mf.layout), trampoline_bb)
        add_successor(mf, trampoline_bb, unwind_dest)
    end
    # Insert an end_block, catch_all_ref (pseudo instruction), and throw_ref instructions in the
    # trampoline BB.
    local end_block = MachineInstr(END_BLOCK, MachineOperand[], trampoline_bb)
    push!(mf.blocks[trampoline_bb].instrs, end_block)
    push!(mf.blocks[trampoline_bb].instrs, MachineInstr(CATCH_ALL_REF, MachineOperand[], trampoline_bb))
    push!(mf.blocks[trampoline_bb].instrs, MachineInstr(THROW_REF, MachineOperand[], trampoline_bb))
    # The trampoline BB's return type is exnref because it is a target of catch_all_ref. But the body
    # type of the block we just created is not. We add an 'unreachable' right before the 'end_block'
    # to make the code valid.
    local trampoline_layout_pred = something(get_prev_node(mf, trampoline_bb))
    push!(mf.blocks[trampoline_layout_pred].instrs, MachineInstr(UNREACHABLE, MachineOperand[], trampoline_layout_pred))
    register_scope(pass, block_, end_block)
    pass.unwind_dest_to_trampoline[unwind_dest] = trampoline_bb
    return trampoline_bb
end

"""
    add_nested_try_table(pass, mf, range_begin, range_end, unwind_dest) -> Nothing

Wraps the instructions from `range_begin` to `range_end`, one block's, in a TRY_TABLE whose one
catch_all_ref clause branches to `unwind_dest`'s trampoline. The END_TRY_TABLE goes in a block of
its own after the range: after the range's block where the range ends it, else between the two
halves the block is split into, the EH pad keeping the half that holds its CATCH.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:1383 WebAssemblyCFGStackify::addNestedTryTable" function add_nested_try_table(pass::WebAssemblyCFGStackify, mf::MachineFunction, range_begin::MachineInstr, range_end::MachineInstr, unwind_dest::Int)::Nothing
    local begin_bb = range_begin.parent
    local end_bb = range_end.parent
    # Get the trampoline BB that the new try_table will unwind to.
    local trampoline_bb = get_trampoline_block(pass, mf, unwind_dest)
    # Local expression tree before the first call of this range should go after the nested
    # TRY_TABLE: no instruction is another's child (WebAssembly::isChild, a stackified register's
    # definition), each value of Julia's statements being a local, so the set is the range's beginning.
    local after_set = Set{MachineInstr}([range_begin])
    # Create the nested try_table instruction.
    local try_table_pos = get_latest_insert_pos(mf, begin_bb, Set{MachineInstr}(), after_set)
    local try_table = MachineInstr(TRY_TABLE, MachineOperand[MOImm(BLOCK_TYPE_VOID), MOImm(1), MOImm(WASM_OPCODE_CATCH_ALL_REF), MOBlock(trampoline_bb)], begin_bb)
    insert!(mf.blocks[begin_bb].instrs, try_table_pos, try_table)
    # Create a BB to insert the 'end_try_table' instruction.
    local end_try_table_bb = create_machine_basic_block!(mf)
    add_successor(mf, end_try_table_bb, trampoline_bb)
    local instrs = mf.blocks[end_bb].instrs
    local split_pos = findfirst(mi -> mi === range_end, instrs) + 1
    if split_pos == length(instrs) + 1
        # If the range's end instruction is at the end of the BB, insert the new end_try_table BB
        # after the current BB.
        insert!(mf.layout, findfirst(==(end_bb), mf.layout) + 1, end_try_table_bb)
        add_successor(mf, end_bb, end_try_table_bb)
    else
        # When the split pos is in the middle of a BB, we split the BB into two and put the
        # 'end_try_table' BB in between; in case the BB is an EH pad and there is a 'catch' after
        # split pos, the later part keeps the BB, an EH pad, where the 'catch' is.
        local catch_after_split = mf.blocks[end_bb].ehpad && any(k -> instrs[k].opcode == CATCH, split_pos:length(instrs))
        local pre_bb, post_bb
        if !catch_after_split
            pre_bb = end_bb
            post_bb = create_machine_basic_block!(mf)
            local at = findfirst(==(pre_bb), mf.layout)
            insert!(mf.layout, at + 1, post_bb)
            insert!(mf.layout, at + 1, end_try_table_bb)
            local moved = instrs[split_pos:end]
            deleteat!(instrs, split_pos:length(instrs))
            for mi in moved
                mi.parent = post_bb
            end
            append!(mf.blocks[post_bb].instrs, moved)
            transfer_successors(mf, post_bb, pre_bb)
        else
            pre_bb = create_machine_basic_block!(mf)
            post_bb = end_bb
            local at = findfirst(==(post_bb), mf.layout)
            insert!(mf.layout, at, end_try_table_bb)
            insert!(mf.layout, at, pre_bb)
            local moved = instrs[1:split_pos-1]
            deleteat!(instrs, 1:split_pos-1)
            for mi in moved
                mi.parent = pre_bb
            end
            append!(mf.blocks[pre_bb].instrs, moved)
            # We don't need to transfer predecessors of the EH pad to 'PreBB', because an EH pad's
            # predecessors are all through unwind edges and they should still unwind to the EH pad.
        end
        # unstackifyVRegsUsedInSplitBB has nothing to do: no register is stackified, each value of
        # Julia's statements being a local
        add_successor(mf, pre_bb, end_try_table_bb)
        add_successor(mf, pre_bb, post_bb)
    end
    # Add a 'end_try_table' instruction in the EndTryTable BB created above.
    local end_try_table = MachineInstr(END_TRY_TABLE, MachineOperand[], end_try_table_bb)
    push!(mf.blocks[end_try_table_bb].instrs, end_try_table)
    register_try_scope(pass, try_table, end_try_table, trampoline_bb)
    return nothing
end

"""
    split_end_loop_bb(mf, end_try_table_bb) -> Nothing

An END_LOOP before the END_TRY_TABLE in its block moves to a block of its own before it, so a branch
to the try_table's end does not land inside the loop.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:1556 splitEndLoopBB" function split_end_loop_bb(mf::MachineFunction, end_try_table_bb::Int)::Nothing
    local instrs = mf.blocks[end_try_table_bb].instrs
    local end_try_table = nothing
    local end_loop = nothing
    for k in length(instrs):-1:1
        local mi = instrs[k]
        if mi.opcode == END_TRY_TABLE
            end_try_table = k
            continue
        end
        if end_try_table !== nothing && mi.opcode == END_LOOP
            end_loop = k
            break
        end
    end
    end_loop === nothing && return nothing
    local end_loop_bb = create_machine_basic_block!(mf)
    insert!(mf.layout, findfirst(==(end_try_table_bb), mf.layout), end_loop_bb)
    local moved = instrs[1:something(end_loop)]
    deleteat!(instrs, 1:something(end_loop))
    for mi in moved
        mi.parent = end_loop_bb
    end
    append!(mf.blocks[end_loop_bb].instrs, moved)
    add_successor(mf, end_loop_bb, end_try_table_bb)
    return nothing
end

"""
    fix_call_unwind_mismatches(pass, mf) -> Bool

Each call (a block's throwing statements) whose innermost try_table, after the layout, catches into
another EH pad than the one it unwinds to, or that should unwind to the caller but sits inside a
try_table: each such range gets a nested try_table to its right destination (addNestedTryTable).
Whether there were any.

formal(dev/formal/CFGStackify.tla): a throwing block is found exactly when the innermost open try_table catches it astray
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:1592 WebAssemblyCFGStackify::fixCallUnwindMismatches" function fix_call_unwind_mismatches(pass::WebAssemblyCFGStackify, mf::MachineFunction)::Bool
    # Linearizing the control flow by placing TRY_TABLE / END_TRY_TABLE markers can create mismatches
    # in unwind destinations: a call's try_table, by its place, catches into a pad it does not unwind
    # to. EHPadStack is the stack of the pads the open try_tables catch into, walked backward.
    local eh_pad_stack = Int[]
    # LLVM's MapVector: the destinations in the order first recorded, each with its ranges
    local unwind_dests = Int[]
    local unwind_dest_to_try_ranges = Dict{Int,Vector{Tuple{MachineInstr,MachineInstr}}}()
    local record(dest::Int, r::Tuple{MachineInstr,MachineInstr}) = begin
        haskey(unwind_dest_to_try_ranges, dest) || (push!(unwind_dests, dest); unwind_dest_to_try_ranges[dest] = Tuple{MachineInstr,MachineInstr}[])
        push!(unwind_dest_to_try_ranges[dest], r)
    end
    # Calls that unwind to an EH pad
    for mbb in Iterators.reverse(mf.layout)
        local seen_throwable_inst_in_bb = false
        for mi in Iterators.reverse(mf.blocks[mbb].instrs)
            if mi.opcode == TRY_TABLE
                pop!(eh_pad_stack)
            elseif mi.opcode == END_TRY_TABLE
                push!(eh_pad_stack, pass.try_to_eh_pad[pass.end_to_begin[mi]])
            end
            # Only the last throwing instruction of a block unwinds to the block's EH pad successor.
            (seen_throwable_inst_in_bb || !has_eh_pad_successor(mf, mbb) || !may_throw(mf, mi)) && continue
            seen_throwable_inst_in_bb = true
            # The block's EH pad successor is the call's unwind destination.
            local unwind_dest = first(s for s in mf.blocks[mbb].succs if mf.blocks[s].ehpad)
            # If the EH pad on the stack top is where this instruction should unwind next, fine.
            !isempty(eh_pad_stack) && eh_pad_stack[end] == unwind_dest && continue
            # Otherwise this call's range needs a nested try_table to its destination (no EH_LABELs
            # around it: Julia's IR has none).
            record(unwind_dest, (mi, mi))
        end
    end
    isempty(eh_pad_stack) || reject!(Internal("src/llvm/cfg_stackify.jl fix_call_unwind_mismatches: try_tables unbalanced"), "fixCallUnwindMismatches")
    # Calls that should unwind to the caller but sit inside a try_table: a range of such instructions,
    # cut at markers, wrapped in one nested try_table that rethrows to the caller.
    local range_begin = nothing
    local range_end = nothing
    local record_caller_mismatch_range() = begin
        record(get_fake_caller_block(pass, mf), (something(range_begin), something(range_end)))
        range_begin = range_end = nothing
    end
    local is_marker(mi::MachineInstr) = mi.opcode in (BLOCK, LOOP, TRY_TABLE, END_BLOCK, END_LOOP, END_TRY_TABLE)
    for mbb in Iterators.reverse(mf.layout)
        local seen_throwable_inst_in_bb = false
        for mi in Iterators.reverse(mf.blocks[mbb].instrs)
            local mt = may_throw(mf, mi)
            # A block's last throwing instruction unwinds to its EH pad successor, the first phase's.
            if has_eh_pad_successor(mf, mbb) && mt && !seen_throwable_inst_in_bb
                seen_throwable_inst_in_bb = true
            # A marker ends the current caller-mismatch range.
            elseif range_end !== nothing && is_marker(mi)
                record_caller_mismatch_range()
            # Outside every try_table, or not throwing: nothing to do.
            elseif isempty(eh_pad_stack) || eh_pad_stack[end] == pass.fake_caller_bb || !mt
            # A throwing instruction that should unwind to the caller, inside a try_table.
            else
                range_end === nothing ? (range_begin = range_end = mi) : (range_begin = mi)
            end
            if mi.opcode == TRY_TABLE
                pop!(eh_pad_stack)
            elseif mi.opcode == END_TRY_TABLE
                push!(eh_pad_stack, pass.try_to_eh_pad[pass.end_to_begin[mi]])
            end
        end
        range_end !== nothing && record_caller_mismatch_range()
    end
    isempty(eh_pad_stack) || reject!(Internal("src/llvm/cfg_stackify.jl fix_call_unwind_mismatches: try_tables unbalanced"), "fixCallUnwindMismatches")
    # We don't have any unwind destination mismatches to resolve.
    isempty(unwind_dests) && return false
    # A branch to an END_TRY_TABLE's block that also holds an END_LOOP before it would land in the loop.
    for unwind_dest in unwind_dests
        local try_table = get(pass.eh_pad_to_try, unwind_dest, nothing)
        try_table === nothing || split_end_loop_bb(mf, pass.begin_to_end[try_table].parent)
    end
    # Now fix the mismatches by wrapping each range in a nested try_table.
    for unwind_dest in unwind_dests
        for (range_begin_, range_end_) in unwind_dest_to_try_ranges[unwind_dest]
            # The block's EH pad successor edge goes; the nested try_table carries the unwind.
            local mbb = range_begin_.parent
            if unwind_dest != get_fake_caller_block(pass, mf)
                local eh_pad = findfirst(s -> mf.blocks[s].ehpad, mf.blocks[mbb].succs)
                eh_pad === nothing || remove_successor(mf, mbb, mf.blocks[mbb].succs[eh_pad])
            end
            add_nested_try_table(pass, mf, range_begin_, range_end_, unwind_dest)
        end
    end
    return true
end

"""
    fix_catch_unwind_mismatches(pass, mf) -> Bool

Each catch whose exceptions it does not catch, after the layout, would unwind into another EH pad
than its own unwind destination gets a nested try_table around its try_table. A Julia catch catches
every exception, a JS one too (dart's guardCanMatchJSException for a guard matching every object),
so each CATCH is LLVM's catch-all, which passes no exception on: the walk finds no mismatch, and the
arms for a catch that passes exceptions on have no Julia counterpart. Whether there were any.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:2076 WebAssemblyCFGStackify::fixCatchUnwindMismatches" function fix_catch_unwind_mismatches(pass::WebAssemblyCFGStackify, mf::MachineFunction)::Bool
    local eh_pad_stack = Int[]
    for mbb in Iterators.reverse(mf.layout)
        for mi in Iterators.reverse(mf.blocks[mbb].instrs)
            if mi.opcode == TRY_TABLE
                pop!(eh_pad_stack)
            elseif mi.opcode == CATCH
                # isCatchAll: if the catch catches every exception, it has no exception to pass on,
                # so it cannot have a mismatch
                push!(eh_pad_stack, mbb)
            end
        end
    end
    isempty(eh_pad_stack) || reject!(Internal("src/llvm/cfg_stackify.jl fix_catch_unwind_mismatches: try_tables unbalanced"), "fixCatchUnwindMismatches")
    return false
end

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

"""    cleanup_function_data(pass, mf) -> Nothing

Forgets the blocks made for this function. The fake caller block, outside the layout and without
edges, stays in the function's block list, where a block's number is its place."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyCFGStackify.cpp:2686 WebAssemblyCFGStackify::cleanupFunctionData" function cleanup_function_data(pass::WebAssemblyCFGStackify, mf::MachineFunction)::Nothing
    local fake = pass.fake_caller_bb
    fake === nothing || isempty(mf.blocks[fake].preds) && isempty(mf.blocks[fake].succs) && !(fake in mf.layout) ||
        reject!(Internal("src/llvm/cfg_stackify.jl cleanup_function_data: the fake caller block $fake has edges or a place"), "cleanupFunctionData")
    pass.appendix_bb = pass.fake_caller_bb = pass.caller_trampoline_bb = nothing
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
    cleanup_function_data(pass, mf)
    return nothing
end
