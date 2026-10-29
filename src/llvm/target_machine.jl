# llvm/lib/Target/WebAssembly/WebAssemblyTargetMachine.cpp at the llvm pin (dev/LEDGER.md D42): the
# order LLVM's WebAssembly backend runs its control-flow passes in, run here on one Julia body.

"""
    add_pre_emit_pass(stmts, jcfg, at, has_results) -> MachineFunction

The structured control flow of a body whose statements are `stmts` (in NIR) and whose CFG is `jcfg`
(Julia's, NirBody's), by
the control-flow passes of LLVM's addPreEmitPass in its order: UnreachableMachineBlockElim (in
machine_function), after PHIElimination (which runs before them, in register allocation's
pipeline), WebAssemblyFixIrreducibleControlFlow, WebAssemblyCFGSort over the loop tree
(MachineLoopInfo, LoopInfoBase::analyze), WebAssemblyCFGStackify. `has_results` says the function
returns values, for the block types of scopes ending its body.
"""
@parity "llvm/lib/Target/WebAssembly/WebAssemblyTargetMachine.cpp:603 WebAssemblyPassConfig::addPreEmitPass" function add_pre_emit_pass(stmts::Vector{NirStmt}, jcfg::Core.Compiler.CFG, at::String, has_results::Bool)::MachineFunction
    local mf = machine_function(stmts, jcfg, at)
    # PHIElimination runs before the pre-emit passes, in register allocation's pipeline
    eliminate_phi_nodes(mf, jcfg)
    run_on_machine_function(WebAssemblyFixIrreducibleControlFlow(), mf)
    local mli = LoopInfoBase()
    analyze(mli, mf)
    sort_blocks(mf, mli)
    run_on_machine_function(WebAssemblyCFGStackify(), mf, mli, has_results)
    return mf
end
