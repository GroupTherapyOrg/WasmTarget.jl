# LLVM's machine code over Julia's CFG (dev/LEDGER.md D42). The stackifier is LLVM's WebAssembly
# backend's (src/llvm/), whose passes read and rewrite a MachineFunction; Julia's CFG stands where
# LLVM reads one (D3: Julia's compiler computes the blocks and the dominator tree, never WasmTarget).
# Each LLVM type the ports name and its Julia counterpart, recorded once, here:
#
#   MachineFunction        MachineFunction: Core.Compiler's CFG of the body, codegen's top block
#                          before Julia's first, its blocks in the layout the passes reorder
#   MachineBasicBlock *    a block's number in that CFG, Core.Compiler's BBNumber (an Int); its state
#                          a MachineBasicBlock: layout number, Julia's predecessors and successors,
#                          the instructions the passes place
#   MachineInstr           MachineInstr: an Opcode, its operands and its block
#   MachineOperand         MachineOperand: a block (MOBlock) or an immediate (MOImm)
#   MachineDominatorTree   Core.Compiler.DomTree, Julia's construct_domtree over that CFG
#   MachineLoopInfo        LoopInfoBase, ported from GenericLoopInfo.h (src/llvm/generic_loop_info.jl)
#   MachineLoop            LoopBase, likewise
#
# precedent(llvm: a MachineFunction, the list of blocks its backend passes reorder and rewrite in
# place; cranelift: a function's Layout, its block order held apart from its data-flow graph).
# Julia's differs: compute_basic_blocks numbers the blocks once and nothing reorders them, so the
# layout and the instructions the passes place are held beside Julia's CFG, which stays as Julia
# made it.

"""
    Opcode

The WebAssembly instructions the stackifier reads and writes (WebAssemblyInstrControl.td: BLOCK,
LOOP, END_BLOCK, END_LOOP, BR, BR_IF, BR_UNLESS, BR_TABLE; WebAssemblyInstrInfo.td: CONST_I32, which
FixIrreducibleControlFlow writes a label register with; TargetOpcode's COPY, which PHIElimination
writes a PHI's incoming value with; WebAssemblyInstrControl.td's TRY_TABLE and END_TRY_TABLE, which
CFGStackify places for an EH pad, and UNREACHABLE, which it adds after an END_TRY_TABLE; CATCH, the
pseudo-instruction an EH pad begins with, which receives the caught exception; CATCH_ALL_REF and
THROW_REF, the pseudo-instruction a trampoline block takes the caught exnref with and the rethrow of
it, which CFGStackify adds to fix an unwind mismatch) and STMTS, the place of the block's Julia
statements, which LLVM holds as the block's other instructions.
"""
@quarantine "LLVM's WebAssembly control opcodes, TableGen's records, where Julia's statements are one pseudo-instruction" Core.UInt8 @enum Opcode::UInt8 BLOCK LOOP END_BLOCK END_LOOP BR BR_IF BR_UNLESS BR_TABLE CONST_I32 COPY STMTS TRY_TABLE END_TRY_TABLE CATCH UNREACHABLE CATCH_ALL_REF THROW_REF

"""    BLOCK_TYPE_VOID

A BLOCK's or LOOP's type with no params or results (WebAssembly::BlockType::Void)."""
@quarantine "LLVM's WebAssembly::BlockType::Void, the binary format's empty block type" Core.Int const BLOCK_TYPE_VOID::Int = 0x40
"""    BLOCK_TYPE_CATCH

A BLOCK's type that is its catch clause's payload, the exception tag's parameters (LLVM's pointer
type for CATCH), filled where the instructions are lowered."""
@quarantine "LLVM's catch destination BLOCK takes the caught value's type; WasmTarget's tag holds the exception" Core.Int const BLOCK_TYPE_CATCH::Int = -2

"""    BLOCK_TYPE_EXNREF

A BLOCK's type whose result is an exnref, a trampoline's, which a catch_all_ref branches to
(WebAssembly::BlockType::Exnref, wasm::ValType::EXNREF)."""
@quarantine "LLVM's WebAssembly::BlockType::Exnref, the binary format's exnref value type" Core.Int const BLOCK_TYPE_EXNREF::Int = 0x69

"""    WASM_OPCODE_CATCH

A TRY_TABLE's catch clause of a tag, its payload to the label (BinaryFormat/Wasm.h)."""
@quarantine "LLVM's wasm::WASM_OPCODE_CATCH, the binary format's catch clause kind" Core.Int const WASM_OPCODE_CATCH::Int = 0x00
"""    WASM_OPCODE_CATCH_ALL_REF

A TRY_TABLE's catch clause of every exception, its exnref to the label (BinaryFormat/Wasm.h)."""
@quarantine "LLVM's wasm::WASM_OPCODE_CATCH_ALL_REF, the binary format's catch clause kind" Core.Int const WASM_OPCODE_CATCH_ALL_REF::Int = 0x03

"""    BLOCK_TYPE_RESULTS

A BLOCK's or LOOP's type that is the function's results, filled where the instructions are lowered
(WebAssembly::BlockType::Multivalue, which MCInstLower fills from the function's signature)."""
@quarantine "LLVM's WebAssembly::BlockType::Multivalue, the function's results filled at lowering" Core.Int const BLOCK_TYPE_RESULTS::Int = 0xffff

"""A block operand: the block's number in the machine CFG (LLVM's MachineOperand::isMBB)."""
@quarantine "LLVM's MachineOperand of kind MO_MachineBasicBlock; a block is its number, Julia's BBNumber" Core.Int struct MOBlock
    mbb::Int
end
"""An immediate operand (LLVM's MachineOperand::isImm): a block type, a depth, a statement index."""
@quarantine "LLVM's MachineOperand of kind MO_Immediate" Core.Int struct MOImm
    imm::Int
end

"""
    MachineOperand

An operand, a block or an immediate (LLVM's MachineOperand, its two kinds the stackifier reads).
A closed sum by construction: a `@closed` `Union` of two concrete structs.

precedent(llvm: MachineOperand's MachineOperandType tag; rust: an enum). Julia's differs: a `Union`
of concrete types, its matches checked `@exhaustive` when the package loads.
"""
@quarantine "LLVM's MachineOperand is a tagged union; Julia's is a closed Union" Core.Union @closed const MachineOperand = Union{MOBlock, MOImm}

"""
    MachineInstr(opcode, operands, parent)

An instruction: its Opcode, its operands and `parent`, its block's number (LLVM's getParent).
BLOCK and LOOP take their block type (MOImm, 0x40 for none); BR a target block; BR_IF and BR_UNLESS
a target block and the statement index of Julia's GotoIfNot whose condition they test; STMTS the
first and last index of the block's Julia statements; BR_TABLE a label register then its target
blocks, the last the default; CONST_I32 a label register and the value it sets; COPY the statement
index of a PhiNode and the index of its edge whose value goes into the PHI's incoming register.
"""
@quarantine "LLVM's MachineInstr: an opcode with operands, its parent block a number in Julia's CFG" Base.Vector mutable struct MachineInstr
    opcode::Opcode
    operands::Vector{MachineOperand}
    parent::Int
end

"""
    MachineBasicBlock(number, preds, succs, instrs, ehpad)

A block's state: `number`, its place in the layout (LLVM's getNumber, renumbered by
RenumberBlocks), Julia's predecessors and successors by number, the instructions in order, and
whether it is an EH pad.
"""
@quarantine "LLVM's MachineBasicBlock, its edges Julia's CFG's and its instructions the passes'" Base.Vector mutable struct MachineBasicBlock
    number::Int
    preds::Vector{Int}
    succs::Vector{Int}
    instrs::Vector{MachineInstr}
    ehpad::Bool
end

"""
    MachineFunction

One body's machine code over Julia's CFG with codegen's top block as block 1 (Julia's block k is
block k + 1): `domtree`, Julia's dominator tree of it, `stmts`, the statements the CFG was computed
from, `blocks`, each block's state by its number in the CFG (a block a pass adds, after them), and
`layout`, the blocks in order. `label_registers` counts the i32 registers FixIrreducibleControlFlow
made (LLVM's virtual registers of its dispatch blocks), numbered from 1; `implicit_defs` says every
value needs a definition at entry (its addImplicitDefs); `handlers`, Julia's try handler of each
statement and whether it may throw, which WebAssembly::mayThrow reads.
"""
@quarantine "LLVM's MachineFunction, its CFG and dominator tree Julia's own" Core.Compiler.DomTree mutable struct MachineFunction
    domtree::Core.Compiler.DomTree
    stmts::Vector{NirStmt}
    blocks::Vector{MachineBasicBlock}
    layout::Vector{Int}
    label_registers::Int
    implicit_defs::Bool
    handlers::NirHandlers
end

"""
    machine_function(stmts, jcfg, handlers, at) -> MachineFunction

The machine code of a body whose statements are `stmts`, in NIR (nir_code), each jump naming the
statement it goes to: `jcfg`, Julia's CFG of them (compute_basic_blocks), with a top block before
Julia's first, as Julia's codegen emits its `top`
block before the first block of Julia's IR (src/codegen.cpp, emit_function), since Julia's first
block may have predecessors (`while true end`) and LLVM's entry block has none; and Julia's
dominator tree of it (construct_domtree). A block no path reaches leaves the layout and its edges
leave its successors' predecessors, as LLVM's UnreachableBlockElim runs before the backend. Each
block's instructions: STMTS, then its terminator read from Julia's last statement, BR for a
GotoNode and BR_UNLESS for a GotoIfNot (taken when the condition is false), and none for a block
that returns, falls through to the next, or enters a try region (an EnterNode, its CFG successors
the next block and the catch block).

A try region's catch block is an EH pad, begun by a CATCH of WasmTarget's one exception tag (the
role LLVM's instruction selection and LateEHPrepare play, a Julia catch catching every exception),
and its predecessors are exactly the blocks that unwind to it, as an LLVM EH pad's are: a block
holding a statement that may throw (`handlers`, Julia's answers) under a handler has that handler's
catch block as a successor, LLVM's unwind edge from an invoke to its landing pad, here read from
Julia's own facts, and Julia's CFG edge from the EnterNode's block to its catch block, which no
statement throws along, is dropped. Julia's CFG marks a catch block and the entry with a predecessor
0, which names no block and is dropped; the top block is the entry's one predecessor.

formal(dev/formal/CFGStackifyEH.tla): an EH pad's predecessors are exactly the blocks unwinding to it, as Julia's inference sends them
"""
@quarantine "Julia's IR is a CFG of its statements; codegen puts a top block before it" Core.Compiler.construct_domtree function machine_function(stmts::Vector{NirStmt}, jcfg::Core.Compiler.CFG, handlers::NirHandlers, at::String)::MachineFunction
    local jb = jcfg.blocks
    local n = length(jb) + 1
    # block 1 is codegen's top, its one successor Julia's first block; Julia's block k is k + 1
    local bbs = Core.Compiler.BasicBlock[Core.Compiler.BasicBlock(Core.Compiler.StmtRange(0, -1), Int[], Int[2])]
    for (k, b) in enumerate(jb)
        local preds = Int[p + 1 for p in b.preds if p != 0]
        k == 1 && pushfirst!(preds, 1)
        push!(bbs, Core.Compiler.BasicBlock(b.stmts, preds, Int[s + 1 for s in b.succs]))
    end
    # each try region's catch block, by its EnterNode's statement; a catch block is an EH pad
    local catch_block(enter::Int) = begin
        local e = stmts[enter]
        e isa NirEnter || reject!(Internal("src/julia/machine.jl machine_function: statement $enter, a handler, is no EnterNode"), at)
        e.catch_dest == 0 && reject!(Unquarantined("src/julia/machine.jl: an EnterNode with no catch, a scope region (ScopedValues)"), "$at: statement $enter")
        Core.Compiler.block_for_inst(jcfg, e.catch_dest) + 1
    end
    local eh_pads = Set{Int}(catch_block(i) for i in eachindex(stmts) if stmts[i] isa NirEnter)
    # the EnterNode's own edge to its catch block goes: an EH pad is reached only by unwinding
    for b in 2:n
        local r = bbs[b].stmts
        isempty(r) && continue
        local last_ = stmts[last(r)]
        last_ isa NirEnter || continue
        local pad = catch_block(last(r))
        filter!(!=(pad), bbs[b].succs)
        filter!(!=(b), bbs[pad].preds)
    end
    # the unwind edges: a block with a statement that may throw under a handler reaches its catch block
    for b in 2:n
        for i in bbs[b].stmts
            local h = handlers.handler_at[i]
            (h == 0 || handlers.nothrow[i]) && continue
            local pad = catch_block(h)
            pad in bbs[b].succs || push!(bbs[b].succs, pad)
            b in bbs[pad].preds || push!(bbs[pad].preds, b)
        end
    end
    local domtree = Core.Compiler.construct_domtree(bbs)
    local reachable(b::Int) = !Core.Compiler.bb_unreachable(domtree, b)
    local blocks = MachineBasicBlock[]
    for b in 1:n
        local bb = bbs[b]
        local instrs = MachineInstr[]
        if b > 1
            local r = bb.stmts
            local last_ = stmts[last(r)]
            local branch = last_ isa Union{NirGoto, NirGotoIfNot}
            # an EH pad begins with the CATCH that receives the exception
            b in eh_pads && push!(instrs, MachineInstr(CATCH, MachineOperand[], b))
            push!(instrs, MachineInstr(STMTS, MachineOperand[MOImm(first(r)), MOImm(branch ? last(r) - 1 : last(r))], b))
            # a jump of the CodeInfo names a statement, the first of its block (block_for_inst)
            if last_ isa NirGoto
                push!(instrs, MachineInstr(BR, MachineOperand[MOBlock(Core.Compiler.block_for_inst(jcfg, last_.label) + 1)], b))
            elseif last_ isa NirGotoIfNot
                local dest = Core.Compiler.block_for_inst(jcfg, last_.dest) + 1
                dest == b + 1 || push!(instrs, MachineInstr(BR_UNLESS, MachineOperand[MOBlock(dest), MOImm(last(r))], b))
            end
        end
        push!(blocks, MachineBasicBlock(b, unique(Int[p for p in bb.preds if reachable(p)]), unique(bb.succs), instrs, b in eh_pads))
    end
    return MachineFunction(domtree, stmts, blocks, Int[b for b in 1:n if reachable(b)], 0, false, handlers)
end

"""    renumber_blocks!(mf) -> Nothing

Numbers each block by its place in the layout (LLVM's MachineFunction::RenumberBlocks)."""
@quarantine "LLVM's MachineFunction::RenumberBlocks (MachineFunction.cpp), a block's number its place in the layout" Base.enumerate function renumber_blocks!(mf::MachineFunction)::Nothing
    for (i, b) in enumerate(mf.layout)
        mf.blocks[b].number = i
    end
    return nothing
end

"""    create_machine_basic_block!(mf) -> Int

A new block with no edges or instructions, outside the layout (LLVM's
MachineFunction::CreateMachineBasicBlock); a pass places it."""
@quarantine "LLVM's MachineFunction::CreateMachineBasicBlock: a block Julia's CFG lacks, numbered after its blocks" Base.push! function create_machine_basic_block!(mf::MachineFunction)::Int
    push!(mf.blocks, MachineBasicBlock(0, Int[], Int[], MachineInstr[], false))
    return length(mf.blocks)
end

"""    get_prev_node(mf, b) -> Union{Int,Nothing}

The block before `b` in the layout, nothing for the first (LLVM's ilist getPrevNode)."""
@quarantine "LLVM's ilist_node getPrevNode over the layout" Base.findfirst function get_prev_node(mf::MachineFunction, b::Int)::Union{Int,Nothing}
    local i = findfirst(==(b), mf.layout)
    i === nothing && reject!(Internal("src/julia/machine.jl get_prev_node: block $b is not in the layout"), "get_prev_node")
    return i == 1 ? nothing : mf.layout[i - 1]
end

"""    is_terminator(mi) -> Bool

Whether an instruction ends its block's straight-line code (LLVM's MachineInstr::isTerminator, the
isTerminator flag WebAssemblyInstrControl.td sets on BR, BR_IF, BR_UNLESS, BR_TABLE and UNREACHABLE)."""
@quarantine "LLVM's MCInstrDesc isTerminator flag, TableGen's, for the branches and unreachable" Base.in is_terminator(mi::MachineInstr)::Bool = mi.opcode in (BR, BR_IF, BR_UNLESS, BR_TABLE, UNREACHABLE, THROW_REF)

"""    is_barrier(mi) -> Bool

Whether control never falls through an instruction (LLVM's MachineInstr::isBarrier, the isBarrier
flag WebAssemblyInstrControl.td sets on BR and BR_TABLE)."""
@quarantine "LLVM's MCInstrDesc isBarrier flag, TableGen's" Base.in is_barrier(mi::MachineInstr)::Bool = mi.opcode in (BR, BR_TABLE, UNREACHABLE, THROW_REF)

"""    create_label_register!(mf) -> Int

A new i32 register (LLVM's MachineRegisterInfo::createVirtualRegister of I32RegClass)."""
@quarantine "LLVM's MachineRegisterInfo::createVirtualRegister, an i32 label register its code generator gives a local" Core.Int function create_label_register!(mf::MachineFunction)::Int
    mf.label_registers += 1
    return mf.label_registers
end

"""    recompute_domtree!(mf) -> Nothing

Julia's dominator tree of the CFG as the passes have changed it (construct_domtree)."""
@quarantine "Julia's construct_domtree over the machine CFG a pass changed" Core.Compiler.construct_domtree function recompute_domtree!(mf::MachineFunction)::Nothing
    mf.domtree = Core.Compiler.construct_domtree(Core.Compiler.BasicBlock[
        Core.Compiler.BasicBlock(Core.Compiler.StmtRange(0, -1), copy(b.preds), copy(b.succs)) for b in mf.blocks])
    return nothing
end

"""    terminators(mf, b) -> Vector{MachineInstr}

The block's instructions from its first terminator to its end (LLVM's
MachineBasicBlock::terminators)."""
@quarantine "LLVM's MachineBasicBlock::terminators, the instructions from the first terminator on" Base.findfirst function terminators(mf::MachineFunction, b::Int)::Vector{MachineInstr}
    local instrs = mf.blocks[b].instrs
    local i = findfirst(is_terminator, instrs)
    return i === nothing ? MachineInstr[] : instrs[i:end]
end

"""    post_order(mf, entry) -> Vector{Int}

The blocks reachable from `entry` in a depth-first postorder over successors (LLVM's po_iterator,
llvm/ADT/PostOrderIterator.h)."""
@quarantine "LLVM's po_iterator (ADT/PostOrderIterator.h); Julia's Base has no graph traversal" Base.push! function post_order(mf::MachineFunction, entry::Int)::Vector{Int}
    local out = Int[]
    local seen = Set{Int}([entry])
    local stack = Tuple{Int,Int}[(entry, 1)]
    while !isempty(stack)
        local b, i = stack[end]
        local succs = mf.blocks[b].succs
        if i <= length(succs)
            stack[end] = (b, i + 1)
            local s = succs[i]
            s in seen || (push!(seen, s); push!(stack, (s, 1)))
        else
            pop!(stack)
            push!(out, b)
        end
    end
    return out
end

"""
    PriorityQueue()

Blocks by priority (LLVM's PriorityQueue, llvm/ADT/PriorityQueue.h, a std::priority_queue): `pq_top`
is the block no other block outranks under the queue's comparator `less`, as a max-heap's top.
"""
@quarantine "LLVM's PriorityQueue over std::priority_queue; Julia's Base has no heap" Base.Vector struct PriorityQueue
    items::Vector{Int}
    PriorityQueue() = new(Int[])
end

"""    pq_push!(q, b) -> Nothing"""
@quarantine "std::priority_queue::push" Base.push! function pq_push!(q::PriorityQueue, b::Int)::Nothing
    push!(q.items, b)
    return nothing
end

"""    pq_pop!(q, less) -> Int

Removes and returns the top: the block `b` with `less(b, c)` for no other `c` (std::priority_queue's
top then pop, its comparator a strict weak order)."""
@quarantine "std::priority_queue::top and pop, the greatest under the comparator" Base.deleteat! function pq_pop!(q::PriorityQueue, less::Function)::Int
    isempty(q.items) && reject!(Internal("src/julia/machine.jl pq_pop!: top of an empty queue"), "PriorityQueue.top")
    local t = 1
    for i in 2:length(q.items)
        less(q.items[t], q.items[i]) && (t = i)
    end
    local b = q.items[t]
    deleteat!(q.items, t)
    return b
end

"""    pq_empty(q) -> Bool"""
@quarantine "std::priority_queue::empty" Base.isempty pq_empty(q::PriorityQueue)::Bool = isempty(q.items)

"""    get_block_numbered(mf, n) -> Union{Int,Nothing}

The block numbered `n`, nothing past the last (LLVM's MachineFunction::getBlockNumbered)."""
@quarantine "LLVM's MachineFunction::getBlockNumbered over the layout's numbers" Base.findfirst function get_block_numbered(mf::MachineFunction, n::Int)::Union{Int,Nothing}
    local i = findfirst(b -> mf.blocks[b].number == n, mf.layout)
    return i === nothing ? nothing : mf.layout[i]
end
