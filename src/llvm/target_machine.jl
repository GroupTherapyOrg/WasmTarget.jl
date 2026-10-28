# llvm/lib/Target/WebAssembly/WebAssemblyTargetMachine.cpp at the llvm pin (dev/LEDGER.md D42): the
# order LLVM's WebAssembly backend runs its control-flow passes in, run here on one Julia body.

"""
    add_pre_emit_pass(stmts, at, has_results) -> MachineFunction

The structured control flow of a body whose statements are `stmts` (an optimized CodeInfo's), by
the control-flow passes of LLVM's addPreEmitPass in its order: UnreachableMachineBlockElim (in
machine_function), WebAssemblyFixIrreducibleControlFlow, WebAssemblyCFGSort over the loop tree
(MachineLoopInfo, LoopInfoBase::analyze), WebAssemblyCFGStackify. `has_results` says the function
returns values, for the block types of scopes ending its body. An irreducible loop rejects at `at`
until FixIrreducibleControlFlow is ported.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyTargetMachine.cpp:603 WebAssemblyPassConfig::addPreEmitPass" function add_pre_emit_pass(stmts::Vector{Any}, at::String, has_results::Bool)::MachineFunction
    local mf = machine_function(stmts, at)
    local entries = irreducible_entries(mf)
    isempty(entries) || reject!(Unported("llvm/lib/Target/WebAssembly/WebAssemblyFixIrreducibleControlFlow.cpp:550 WebAssemblyFixIrreducibleControlFlow::runOnMachineFunction"),
                                "$at: a loop entered at Julia's blocks $(join(sort!([e - 1 for e in entries]), ", "))")
    local mli = LoopInfoBase()
    analyze(mli, mf)
    sort_blocks(mf, mli)
    run_on_machine_function(WebAssemblyCFGStackify(), mf, mli, has_results)
    return mf
end
