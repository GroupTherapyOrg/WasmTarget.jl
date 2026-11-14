# llvm/lib/Target/WebAssembly/WebAssemblyInstrInfo.cpp at the llvm pin (dev/LEDGER.md D42): the
# branch analysis MachineBasicBlock::updateTerminator calls, over the instructions of
# src/julia/machine.jl. A condition is LLVM's two operands: an immediate, 1 for BR_IF (taken when
# true) and 0 for BR_UNLESS (taken when false), and the condition, here the statement index of
# Julia's GotoIfNot.

"""
    analyze_branch(mf, b) -> (failed, tbb, fbb, cond)

The block's branches: an unconditional BR's target in `tbb`; a BR_IF's or BR_UNLESS's target in
`tbb` with its condition in `cond`, and a BR after it in `fbb`. `failed` when an instruction is no
branch the analysis reads.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyInstrInfo.cpp:91 WebAssemblyInstrInfo::analyzeBranch" function analyze_branch(mf::MachineFunction, b::Int)::Tuple{Bool,Union{Nothing,Int},Union{Nothing,Int},Vector{MachineOperand}}
    local tbb = nothing
    local fbb = nothing
    local cond = MachineOperand[]
    local have_cond = false
    for mi in terminators(mf, b)
        if mi.opcode == BR_IF || mi.opcode == BR_UNLESS
            have_cond && return (true, tbb, fbb, cond)
            push!(cond, MOImm(mi.opcode == BR_IF ? 1 : 0))
            push!(cond, mi.operands[2])
            tbb = (mi.operands[1]::MOBlock).mbb
            have_cond = true
        elseif mi.opcode == BR
            if !have_cond
                tbb = (mi.operands[1]::MOBlock).mbb
            else
                fbb = (mi.operands[1]::MOBlock).mbb
            end
            break   # BR is a barrier
        else
            return (true, tbb, fbb, cond)
        end
    end
    return (false, tbb, fbb, cond)
end

"""    remove_branch(mf, b) -> Int

Removes the block's trailing terminators, returning how many."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyInstrInfo.cpp:139 WebAssemblyInstrInfo::removeBranch" function remove_branch(mf::MachineFunction, b::Int)::Int
    local instrs = mf.blocks[b].instrs
    local count = 0
    while !isempty(instrs) && is_terminator(instrs[end])
        pop!(instrs)
        count += 1
    end
    return count
end

"""
    insert_branch(mf, b, tbb, fbb, cond) -> Int

Appends the branches: with no condition a BR to `tbb` (none without one); with one, BR_IF or
BR_UNLESS to `tbb` by the condition's immediate, then a BR to `fbb` when there is one. Returns how
many it added.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyInstrInfo.cpp:161 WebAssemblyInstrInfo::insertBranch" function insert_branch(mf::MachineFunction, b::Int, tbb::Union{Nothing,Int}, fbb::Union{Nothing,Int}, cond::Vector{MachineOperand})::Int
    local instrs = mf.blocks[b].instrs
    if isempty(cond)
        tbb === nothing && return 0
        push!(instrs, MachineInstr(BR, MachineOperand[MOBlock(tbb)], b))
        return 1
    end
    length(cond) == 2 && tbb !== nothing ||
        reject!(Internal("src/llvm/instr_info.jl insert_branch: a condition of $(length(cond)) operands"), "WebAssemblyInstrInfo.insertBranch")
    push!(instrs, MachineInstr((cond[1]::MOImm).imm != 0 ? BR_IF : BR_UNLESS, MachineOperand[MOBlock(tbb), cond[2]], b))
    fbb === nothing && return 1
    push!(instrs, MachineInstr(BR, MachineOperand[MOBlock(fbb)], b))
    return 2
end

"""    reverse_branch_condition(cond) -> Bool

Flips the condition's sense, BR_IF to BR_UNLESS and back; false, since it always can."""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyInstrInfo.cpp:187 WebAssemblyInstrInfo::reverseBranchCondition" function reverse_branch_condition(cond::Vector{MachineOperand})::Bool
    length(cond) == 2 || reject!(Internal("src/llvm/instr_info.jl reverse_branch_condition: a condition of $(length(cond)) operands"), "WebAssemblyInstrInfo.reverseBranchCondition")
    cond[1] = MOImm((cond[1]::MOImm).imm != 0 ? 0 : 1)
    return false
end
