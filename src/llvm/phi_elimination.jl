# llvm/lib/CodeGen/PHIElimination.cpp at the llvm pin (dev/LEDGER.md D42): Julia's PhiNodes out of SSA
# form, as LLVM's PHIElimination lowers the PHIs Julia's codegen hands it. Each PHI gets a register of
# its own, IncomingReg: every predecessor copies its incoming value into it before its terminators,
# and the PHI reads it, so a predecessor with two successors needs no split edge and two PHIs that
# swap values (`a, b = b, a + b`) read each other's old values.

"""
    eliminate_phi_nodes(mf, jcfg) -> Bool

Lowers the PhiNodes at the start of every block (the first statements of its STMTS), `jcfg` Julia's
CFG of the statements; whether there were any.
"""
@parity "llvm/lib/CodeGen/PHIElimination.cpp:317 PHIEliminationImpl::EliminatePHINodes" function eliminate_phi_nodes(mf::MachineFunction, jcfg::Core.Compiler.CFG)::Bool
    local changed = false
    for mbb in copy(mf.layout)
        local instrs = mf.blocks[mbb].instrs
        local i = findfirst(mi -> mi.opcode == STMTS, instrs)
        i === nothing && continue
        local first_ = (instrs[i].operands[1]::MOImm).imm
        local last_ = (instrs[i].operands[2]::MOImm).imm
        for k in first_:last_
            mf.stmts[k] isa NirPhi || break
            lower_phi_node(mf, jcfg, mbb, k)
            changed = true
        end
    end
    return changed
end

"""
    lower_phi_node(mf, jcfg, mbb, phi) -> Nothing

The PhiNode at statement `phi` of block `mbb`: in each predecessor whose edge carries a value, a COPY
of it into the PHI's IncomingReg before the predecessor's terminators (PHIEliminationUtils'
findPHICopyInsertPoint); the PHI itself reads IncomingReg where its statement stands. An edge with
no value (an undefined incoming value) copies nothing, as LLVM's IMPLICIT_DEF source does; an edge
from a block no path reaches is skipped, UnreachableMachineBlockElim's removal; an edge from any
other block that is no predecessor rejects as WasmTarget's own defect, located.
"""
@parity "llvm/lib/CodeGen/PHIElimination.cpp:365 PHIEliminationImpl::LowerPHINode" function lower_phi_node(mf::MachineFunction, jcfg::Core.Compiler.CFG, mbb::Int, phi::Int)::Nothing
    local p = mf.stmts[phi]::NirPhi
    for i in eachindex(p.edges)
        p.values[i] === nothing && continue
        # an edge names its predecessor's last statement; Julia's block k is machine block k + 1
        local pred = Core.Compiler.block_for_inst(jcfg, Int(p.edges[i])) + 1
        # an edge from a block no path reaches is gone, as LLVM's UnreachableMachineBlockElim removes a
        # dead predecessor's PHI operands before PHIElimination runs; any other edge names a predecessor
        if !(pred in mf.blocks[mbb].preds)
            Core.Compiler.bb_unreachable(mf.domtree, pred) && continue
            reject!(Internal("src/llvm/phi_elimination.jl lower_phi_node: statement $phi's edge from statement $(p.edges[i]) names block $pred, no predecessor of block $mbb"),
                    "llvm/lib/CodeGen/PHIElimination.cpp:365 PHIEliminationImpl::LowerPHINode")
        end
        local instrs = mf.blocks[pred].instrs
        local pos = something(findfirst(is_terminator, instrs), length(instrs) + 1)
        insert!(instrs, pos, MachineInstr(COPY, MachineOperand[MOImm(phi), MOImm(i)], pred))
    end
    return nothing
end
