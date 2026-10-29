# LLVM's DominanceFrontier and WebAssemblyExceptionInfo, ported (src/llvm/dominance_frontier*.jl,
# src/llvm/exception_info.jl; dev/LEDGER.md D42), over hand-written statement lists whose CFG holds the
# shape under test: each block's dominance frontier, and an EH pad's exception the blocks it dominates.
using Test
using WasmTarget

const W = WasmTarget
const L = WasmTarget.LLVM

# the machine function of a statement list, through the NIR (nir_code)
machine_of(code, at) = W.machine_function(W.nir_code(code, zeros(UInt32, length(code)), at)..., at)

@testset "DominanceFrontierImpl.h: each block's dominance frontier" begin
    # %1 branches to %3 or falls to %2, which jumps to %3: machine blocks 2 (%1), 3 (%2), 4 (%3, the join)
    local diamond = Any[Core.GotoIfNot(Core.Argument(2), 3), Core.GotoNode(3), Core.ReturnNode(1)]
    local mf = machine_of(diamond, "diamond")
    local df = L.DominanceFrontierBase()
    L.analyze(df, mf)
    # the arm %2 does not dominate the join, so the join is its frontier; the branch and the join
    # dominate all they reach, so theirs are empty
    @test collect(L.find(df, 3)) == [4] && isempty(L.find(df, 2)) && isempty(L.find(df, 4))
end

# a machine function of one of LLVM's MIR tests: `succs[n]` the successors of bb.(n-1), so bb.k is
# block k + 1, its landing pads `pads` (LLVM's numbers); laid out in order, its dominator tree Julia's
function mir_function(succs::Vector{Vector{Int}}, pads::Vector{Int})
    local blocks = [W.MachineBasicBlock(n, Int[], [s + 1 for s in ss], W.MachineInstr[], (n - 1) in pads) for (n, ss) in enumerate(succs)]
    for (n, b) in enumerate(blocks), s in b.succs
        push!(blocks[s].preds, n)
    end
    local mf = machine_of(Any[Core.ReturnNode(1)], "mir")
    mf.blocks = blocks
    mf.layout = collect(eachindex(blocks))
    W.recompute_domtree!(mf)
    return mf
end

module TryCases
struct E; v::Int64; end
@noinline thr(x::Int64) = x < 0 ? throw(E(x)) : x
tc(x::Int64) = try; thr(x) + 1; catch e; e isa E ? e.v * 2 : 0; end
end

module NestedTryCases
@noinline thr(x::Int64) = x < 0 ? error("negative") : x
tn(x::Int64) = try; thr(x); catch; try; thr(x + 2); catch; -1; end; end
end

@testset "WebAssemblyExceptionInfo.cpp: each EH pad's exception and the tree of them, LLVM's own tests" begin
    local bb(k) = k + 1
    # WebAssemblyExceptionInfoTest.cpp TEST0: bb2's exception holds bb3's, which holds bb8's, and bb9's,
    # which bb6 reaches past bb3's frontier
    local mf0 = mir_function([[1, 2], [7], [3, 9], [4, 6], [5, 8], [7], [10, 9], Int[], [9], Int[], Int[]], [2, 3, 8, 9])
    local wei0 = L.WebAssemblyExceptionInfo()
    L.run_on_machine_function(wei0, mf0)
    local we0 = L.get_exception_for(wei0, bb(2))
    @test we0 !== nothing && L.get_eh_pad(we0) == bb(2) && L.get_parent_exception(we0) === nothing && L.get_exception_depth(we0) == 1
    local we00 = L.get_exception_for(wei0, bb(3))
    @test we00 !== nothing && L.get_eh_pad(we00) == bb(3) && L.get_parent_exception(we00) === we0 && L.get_exception_depth(we00) == 2
    @test all(k -> L.get_eh_pad(L.get_exception_for(wei0, bb(k))) == bb(3), (4, 5, 6, 10))
    local we000 = L.get_exception_for(wei0, bb(8))
    @test L.get_eh_pad(we000) == bb(8) && L.get_parent_exception(we000) === we00 && L.get_exception_depth(we000) == 3
    local we01 = L.get_exception_for(wei0, bb(9))
    @test L.get_eh_pad(we01) == bb(9) && L.get_parent_exception(we01) === we0 && L.get_exception_depth(we01) == 2
    # TEST1: bb1's exception holds bb3's, which holds bb10's, and bb11's
    local mf1 = mir_function([[9, 1], [2, 8], [7, 3, 11], [4, 6], [5, 10], [7], [12, 11], [9], Int[], Int[], [11], Int[], Int[]], [1, 3, 10, 11])
    local wei1 = L.WebAssemblyExceptionInfo()
    L.run_on_machine_function(wei1, mf1)
    local we1 = L.get_exception_for(wei1, bb(1))
    @test L.get_eh_pad(we1) == bb(1) && L.get_parent_exception(we1) === nothing && L.get_exception_depth(we1) == 1
    @test all(k -> L.get_exception_for(wei1, bb(k)) === we1, (2, 7, 8))
    local we10 = L.get_exception_for(wei1, bb(3))
    @test L.get_eh_pad(we10) == bb(3) && L.get_parent_exception(we10) === we1 && L.get_exception_depth(we10) == 2
    @test all(k -> L.get_eh_pad(L.get_exception_for(wei1, bb(k))) == bb(3), (4, 5, 6, 12))
    local we100 = L.get_exception_for(wei1, bb(10))
    @test L.get_eh_pad(we100) == bb(10) && L.get_parent_exception(we100) === we10 && L.get_exception_depth(we100) == 3
    local we11 = L.get_exception_for(wei1, bb(11))
    @test L.get_eh_pad(we11) == bb(11) && L.get_parent_exception(we11) === we1 && L.get_exception_depth(we11) == 2
end

@testset "WebAssemblyExceptionInfo.cpp: a try in a catch, Julia's IR, its exception the catch's subexception" begin
    # tn's outer catch holds a try of its own: the inner catch block, which only the outer catch's
    # blocks reach, is in the outer catch's exception and has its own below it; the pads are the
    # catch destinations of Julia's two EnterNodes
    local ci = Base.code_typed(NestedTryCases.tn, (Int64,); optimize = true)[1][1]
    local stmts, cfg, handlers = W.nir_code(ci.code, ci.ssaflags, "tn")
    local enters = [st::W.NirEnter for st in stmts if st isa W.NirEnter]
    @test length(enters) == 2
    local outer_pad, inner_pad = (Core.Compiler.block_for_inst(cfg, e.catch_dest) + 1 for e in enters)
    local mf = W.machine_function(stmts, cfg, handlers, "tn")
    local wei = L.WebAssemblyExceptionInfo()
    L.run_on_machine_function(wei, mf)
    local outer = L.get_exception_for(wei, outer_pad)
    local inner = L.get_exception_for(wei, inner_pad)
    @test L.get_eh_pad(outer) == outer_pad && L.get_parent_exception(outer) === nothing && wei.top_level_exceptions == [outer]
    @test L.get_eh_pad(inner) == inner_pad && L.get_parent_exception(inner) === outer && L.get_exception_depth(inner) == 2
    @test L.contains(outer, inner) && all(b -> L.contains(outer, b), L.get_blocks(inner))
    # a function with no try has no exception
    local ci2 = Base.code_typed(NestedTryCases.thr, (Int64,); optimize = true)[1][1]
    local wei2 = L.WebAssemblyExceptionInfo()
    L.run_on_machine_function(wei2, W.machine_function(W.nir_code(ci2.code, ci2.ssaflags, "thr")..., "thr"))
    @test L.empty(wei2)
end

@testset "WebAssemblySortRegion.cpp: an exception is a sort region, its bottom its last block" begin
    # tn's outer catch: its exception a region headed by its pad, the sort keeping its blocks contiguous
    # below the pad, every check of LLVM's passing
    local ci = Base.code_typed(NestedTryCases.tn, (Int64,); optimize = true)[1][1]
    local stmts, cfg, handlers = W.nir_code(ci.code, ci.ssaflags, "tn")
    local mf = W.machine_function(stmts, cfg, handlers, "tn")
    local outer_pad = Core.Compiler.block_for_inst(cfg, (first(st for st in stmts if st isa W.NirEnter)::W.NirEnter).catch_dest) + 1
    local wei = L.WebAssemblyExceptionInfo()
    L.run_on_machine_function(wei, mf)
    local li = L.LoopInfoBase()
    L.analyze(li, mf)
    local sri = L.SortRegionInfo(li, wei)
    local r = L.get_region_for(sri, outer_pad)
    @test r !== nothing && !L.is_loop(r) && L.get_header(r) == outer_pad && L.get_region_for(sri, 2) === nothing
    L.sort_blocks(mf, li, wei)
    local pos(b) = findfirst(==(b), mf.layout)
    local exc = L.get_blocks(L.get_exception_for(wei, outer_pad))
    @test sort(pos.(exc)) == pos(outer_pad):pos(outer_pad) + length(exc) - 1
    @test L.get_bottom(sri, mf, r) == mf.layout[pos(outer_pad) + length(exc) - 1]
end

@testset "machine code: a try region's catch block is an EH pad, reached by unwind edges" begin
    # Julia's blocks: %1 enters the try (catch at %6), %2..%4 call thr and leave, %5 returns, %6..
    # catches; machine blocks are Julia's plus one
    local ci = Base.code_typed(TryCases.tc, (Int64,); optimize = true)[1][1]
    local stmts, cfg, handlers = W.nir_code(ci.code, ci.ssaflags, "tc")
    # Julia's answers: the call of thr may throw under the try's handler (its EnterNode, statement 1);
    # the add after it throws nothing
    local call = findfirst(st -> st isa W.NirInvoke, stmts)
    @test handlers.handler_at[call] == 1 && !handlers.nothrow[call] && handlers.nothrow[call + 1]
    local mf = W.machine_function(stmts, cfg, handlers, "tc")
    local pad = only(b for b in mf.layout if mf.blocks[b].ehpad)
    local caller = Core.Compiler.block_for_inst(cfg, call) + 1
    # the catch block is reached only by unwinding, from the call's block, as an LLVM EH pad is: the
    # EnterNode's own CFG edge to it goes; it begins with the CATCH that receives the exception
    @test pad == Core.Compiler.block_for_inst(cfg, (stmts[1]::W.NirEnter).catch_dest) + 1
    @test mf.blocks[pad].preds == [caller] && pad in mf.blocks[caller].succs && !(pad in mf.blocks[2].succs)
    @test mf.blocks[pad].instrs[1].opcode == W.CATCH && mf.blocks[pad].instrs[2].opcode == W.STMTS
    # its exception is the catch block alone; the stackifier places its try_table around the call,
    # catching to a BLOCK of the catch block type that the CATCH follows, and finds no unwind mismatch
    local wei = L.WebAssemblyExceptionInfo()
    L.run_on_machine_function(wei, mf)
    @test L.get_blocks(L.get_exception_for(wei, pad)) == [pad]
    local mfs = L.add_pre_emit_pass(stmts, cfg, handlers, "tc", true)
    local mis = [mi for b in mfs.layout for mi in mfs.blocks[b].instrs]
    local t = findfirst(mi -> mi.opcode == W.TRY_TABLE, mis)
    @test mis[t - 1].opcode == W.BLOCK && mis[t - 1].operands[1] == W.MOImm(W.BLOCK_TYPE_CATCH) && mis[t + 1].opcode == W.STMTS
    local et = findfirst(mi -> mi.opcode == W.END_TRY_TABLE, mis)
    @test [mi.opcode for mi in mis[et:et+3]] == [W.END_TRY_TABLE, W.UNREACHABLE, W.END_BLOCK, W.CATCH]
end

@testset "machine code: a :leave and a return send nothing to the handler, as inference decides" begin
    # %2 calls under %1's handler; %3 jumps to %4, a :leave alone in its block; %5 returns; %6 catches.
    # No statement carries a flag, yet inference never sends a :leave's or a return's exception to a
    # handler (typeinf_local): only the call's block unwinds to the catch block
    local code = Any[Core.EnterNode(6), Expr(:call, GlobalRef(Base, :identity), 1), Core.GotoNode(4),
                     Expr(:leave, Core.SSAValue(1)), Core.ReturnNode(Core.SSAValue(2)), Core.ReturnNode(2)]
    local stmts, cfg, handlers = W.nir_code(code, zeros(UInt32, length(code)), "leave")
    @test handlers.handler_at[4] == 1 && handlers.nothrow[4] && handlers.nothrow[5] && !handlers.nothrow[2]
    local mf = W.machine_function(stmts, cfg, handlers, "leave")
    # Julia's blocks %1, %2..%3, %4, %5, %6: machine blocks 2 to 6; the :leave's block 4 no predecessor
    # of the pad 6
    @test Core.Compiler.block_for_inst(cfg, 4) + 1 == 4 && length(cfg.blocks[3].stmts) == 1
    @test mf.blocks[6].ehpad && mf.blocks[6].preds == [3] && !(6 in mf.blocks[4].succs)
end

@testset "CFGStackify.cpp: fixCallUnwindMismatches and addNestedTryTable, a call the layout puts in a try_table it does not unwind to" begin
    # %2 under %1's handler unwinds to the catch block %6; %4, after the :leave, unwinds to the caller.
    # CFGSort lays the catch block (machine block 5) before %4's (4); laid after it, the try_table
    # spans %4, whose call would be caught by a catch it does not unwind to: a mismatch, which a nested
    # try_table fixes, catching every exception to the caller trampoline, which rethrows it
    local code = Any[Core.EnterNode(6), Expr(:call, GlobalRef(Base, :identity), 1), Expr(:leave, Core.SSAValue(1)),
                     Expr(:call, GlobalRef(Base, :identity), 2), Core.ReturnNode(Core.SSAValue(4)), Core.ReturnNode(2)]
    local mf = machine_of(code, "try")
    local li = L.LoopInfoBase()
    L.analyze(li, mf)
    local wei = L.WebAssemblyExceptionInfo()
    L.run_on_machine_function(wei, mf)
    L.sort_blocks(mf, li, wei)
    local pad = only(b for b in mf.layout if mf.blocks[b].ehpad)
    local k = findfirst(==(pad), mf.layout)
    @test pad == 5 && mf.layout[k + 1] == 4 && isempty(mf.blocks[4].succs)
    # as sorted, no mismatch
    @test L.add_pre_emit_pass(W.nir_code(code, zeros(UInt32, length(code)), "try")..., "try", true) isa W.MachineFunction
    mf.layout[k], mf.layout[k + 1] = mf.layout[k + 1], mf.layout[k]
    W.renumber_blocks!(mf)
    L.run_on_machine_function(L.WebAssemblyCFGStackify(), mf, li, wei, true)
    local mis = [mi for b in mf.layout for mi in mf.blocks[b].instrs]
    # the function opens with the trampoline's BLOCK of type exnref and ends with the trampoline: its
    # END_BLOCK, the exnref taken and rethrown
    @test mis[1].opcode == W.BLOCK && mis[1].operands[1] == W.MOImm(W.BLOCK_TYPE_EXNREF)
    @test [mi.opcode for mi in mf.blocks[mf.layout[end]].instrs] == [W.END_BLOCK, W.CATCH_ALL_REF, W.THROW_REF]
    # the nested try_table holds %4's statements, its catch_all_ref to the trampoline's label: two
    # labels out, past the try_table and the catch block's BLOCK; its END_TRY_TABLE in a block of its
    # own, before the outer try_table's
    local n = only(k for k in eachindex(mis) if mis[k].opcode == W.TRY_TABLE && mis[k].operands[3] == W.MOImm(W.WASM_OPCODE_CATCH_ALL_REF))
    @test mis[n].operands[4] == W.MOImm(2) && mis[n+1].opcode == W.STMTS && mis[n+1].operands[1] == W.MOImm(4)
    @test [mi.opcode for mi in mis[n+2:n+4]] == [W.END_TRY_TABLE, W.END_TRY_TABLE, W.UNREACHABLE]
end

@testset "CFGStackify.cpp: placeTryTableMarker, a try_table in a block its catch branches to" begin
    local ci = Base.code_typed(TryCases.tc, (Int64,); optimize = true)[1][1]
    local stmts, cfg, handlers = W.nir_code(ci.code, ci.ssaflags, "tc")
    local mf = W.machine_function(stmts, cfg, handlers, "tc")
    L.eliminate_phi_nodes(mf, cfg)
    L.run_on_machine_function(L.WebAssemblyFixIrreducibleControlFlow(), mf)
    local li = L.LoopInfoBase()
    L.analyze(li, mf)
    local wei = L.WebAssemblyExceptionInfo()
    L.run_on_machine_function(wei, mf)
    L.sort_blocks(mf, li, wei)
    local pass = L.WebAssemblyCFGStackify()
    pass.mdt = mf.domtree
    pass.scope_tops = Union{Nothing,Int}[nothing for _ in 1:length(mf.layout)+1]
    local pad = only(b for b in mf.layout if mf.blocks[b].ehpad)
    L.place_try_table_marker(pass, mf, li, wei, pad)
    local ops(b) = [mi.opcode for mi in mf.blocks[b].instrs]
    # the catch block begins with the END_TRY_TABLE, the catch destination's END_BLOCK, then its CATCH
    @test ops(pad)[1:3] == [W.END_TRY_TABLE, W.END_BLOCK, W.CATCH]
    local tt = pass.eh_pad_to_try[pad]
    @test tt.opcode == W.TRY_TABLE && pass.try_to_eh_pad[tt] == pad && (tt.operands[end]::W.MOBlock).mbb == pad
    # the header, the block whose call unwinds to the pad, holds the BLOCK then the TRY_TABLE, before
    # its statements, so the try_table holds the throwing call
    local hdr = tt.parent
    local k = findfirst(mi -> mi === tt, mf.blocks[hdr].instrs)
    @test hdr in mf.blocks[pad].preds && mf.blocks[hdr].instrs[k - 1].opcode == W.BLOCK &&
          any(mi -> mi.opcode == W.STMTS, mf.blocks[hdr].instrs[k+1:end])
    # an UNREACHABLE after the END_TRY_TABLE, in a block split off before the pad
    L.add_unreachable_after_try_tables(mf)
    local split = mf.layout[findfirst(==(pad), mf.layout) - 1]
    @test ops(split) == [W.END_TRY_TABLE, W.UNREACHABLE] && ops(pad)[1:2] == [W.END_BLOCK, W.CATCH] && pad in mf.blocks[split].succs
end
