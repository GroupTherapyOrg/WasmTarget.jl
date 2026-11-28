# llvm/lib/Target/WebAssembly/WebAssemblyUtilities.cpp at the llvm pin (dev/LEDGER.md D42): the
# instruction predicates the stackifier's exception handling reads, over the machine code of
# src/julia/machine.jl. Only the members the passes read are ported.

"""
    may_throw(mf, mi) -> Bool

Whether the instruction may throw: LLVM's throws and calls that are not nounwind, here a block's
statements (STMTS) when one of them may throw, Julia's answer (no IR_FLAG_NOTHROW, the machine
function's handlers); no marker, branch or COPY throws.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyUtilities.cpp:41 WebAssembly::mayThrow" function may_throw(mf::MachineFunction, mi::MachineInstr)::Bool
    mi.opcode == STMTS || return false
    local first_ = (mi.operands[1]::MOImm).imm
    local last_ = (mi.operands[2]::MOImm).imm
    return any(i -> !mf.handlers.nothrow[i], first_:last_)
end

"""    find_catch(mf, eh_pad) -> Union{MachineInstr,Nothing}

The EH pad's catch, its first instruction past the end markers CFGStackify places there."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyUtilities.cpp:149 WebAssembly::findCatch" function find_catch(mf::MachineFunction, eh_pad::Int)::Union{MachineInstr,Nothing}
    mf.blocks[eh_pad].ehpad || reject!(Internal("src/llvm/utilities.jl find_catch: block $eh_pad is no EH pad"), "WebAssembly::findCatch")
    for mi in mf.blocks[eh_pad].instrs
        # Skip the 'end' marker instructions that may exist after marker placement in CFGStackify.
        mi.opcode in (BLOCK, LOOP, TRY_TABLE, END_BLOCK, END_LOOP, END_TRY_TABLE) && continue
        return mi.opcode == CATCH ? mi : nothing
    end
    return nothing
end
