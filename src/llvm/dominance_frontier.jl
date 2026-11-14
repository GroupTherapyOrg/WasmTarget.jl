# llvm/include/llvm/Analysis/DominanceFrontier.h at the llvm pin (dev/LEDGER.md D42): every block's
# dominance frontier, which WebAssemblyExceptionInfo reads to discover an exception's blocks. Julia's
# compiler computes iterated frontiers for SSA construction only (Core.Compiler's
# iterated_dominance_frontier), not each block's own, so LLVM's analysis is ported, over Julia's
# dominator tree of the machine CFG (src/julia/machine.jl). Only the members the passes read are
# ported.

"""
    DominanceFrontierBase()

The dominance frontier of each block, by number: `frontiers[b]` the blocks in `b`'s frontier, in the
order the analysis found them (LLVM's SetVector), forward dominance (`IsPostDom` false).
"""
@parity "llvm/include/llvm/Analysis/DominanceFrontier.h:43 DominanceFrontierBase" struct DominanceFrontierBase
    frontiers::Dict{Int,LinkedHashSet{Int}}
    DominanceFrontierBase() = new(Dict{Int,LinkedHashSet{Int}}())
end

"""    find(df, b) -> LinkedHashSet{Int}

Block `b`'s frontier; a block the analysis never reached has none (LLVM's find returning end)."""
@parity "llvm/include/llvm/Analysis/DominanceFrontier.h:79 DominanceFrontierBase::find" find(df::DominanceFrontierBase, b::Int)::LinkedHashSet{Int} =
    get(() -> reject!(Internal("llvm/include/llvm/Analysis/DominanceFrontier.h:79 DominanceFrontierBase::find: block $b has no frontier computed"), "DominanceFrontierBase::find"), df.frontiers, b)
