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

@testset "WebAssemblyExceptionInfo.cpp: an EH pad's exception, the blocks it dominates" begin
    # %1 branches to %3 or returns at %2; %3 jumps to %4, which returns: the pad %3 (machine block 4)
    # dominates %4 (machine block 5)
    local chain = Any[Core.GotoIfNot(Core.Argument(2), 3), Core.ReturnNode(1), Core.GotoNode(4), Core.ReturnNode(2)]
    local mf = machine_of(chain, "chain")
    mf.blocks[4].ehpad = true
    local wei = L.WebAssemblyExceptionInfo()
    L.run_on_machine_function(wei, mf)
    local we = L.get_exception_for(wei, 4)
    @test we !== nothing && L.get_eh_pad(we) == 4 && L.get_blocks(we) == [4, 5] && L.get_exception_depth(we) == 1
    @test L.get_exception_for(wei, 5) === we && L.get_exception_for(wei, 2) === nothing && L.get_exception_for(wei, 3) === nothing
    @test wei.top_level_exceptions == [we] && L.contains(we, 5) && !L.contains(we, 3)
    # a pad nested in it: %4 a pad of its own, a subexception of %3's
    local mf2 = machine_of(chain, "nested")
    mf2.blocks[4].ehpad = true
    mf2.blocks[5].ehpad = true
    local wei2 = L.WebAssemblyExceptionInfo()
    L.run_on_machine_function(wei2, mf2)
    local outer = L.get_exception_for(wei2, 4)
    local inner = L.get_exception_for(wei2, 5)
    @test L.get_parent_exception(inner) === outer && L.get_sub_exceptions(outer) == [inner] && L.get_exception_depth(inner) == 2
    @test L.contains(outer, inner) && !L.contains(inner, outer) && L.get_blocks(outer) == [4, 5]
    # a function with no EH pad has no exception
    local wei3 = L.WebAssemblyExceptionInfo()
    L.run_on_machine_function(wei3, machine_of(chain, "none"))
    @test L.empty(wei3)
end

@testset "WebAssemblySortRegion.cpp: an exception is a sort region, its bottom its last block" begin
    local chain = Any[Core.GotoIfNot(Core.Argument(2), 3), Core.ReturnNode(1), Core.GotoNode(4), Core.ReturnNode(2)]
    local mf = machine_of(chain, "chain")
    mf.blocks[4].ehpad = true
    local wei = L.WebAssemblyExceptionInfo()
    L.run_on_machine_function(wei, mf)
    local li = L.LoopInfoBase()
    L.analyze(li, mf)
    # the pad's exception holds both its blocks; outside it, no region
    local sri = L.SortRegionInfo(li, wei)
    local r = L.get_region_for(sri, 5)
    @test r !== nothing && !L.is_loop(r) && L.get_header(r) == 4 && L.get_region_for(sri, 4) === r && L.get_region_for(sri, 2) === nothing
    @test L.get_bottom(sri, mf, r) == 5
    # the sort keeps the exception's blocks contiguous below its pad, every check of LLVM's passing
    L.sort_blocks(mf, li, wei)
    local pos(b) = findfirst(==(b), mf.layout)
    @test pos(5) == pos(4) + 1
end

module TryCases
struct E; v::Int64; end
@noinline thr(x::Int64) = x < 0 ? throw(E(x)) : x
tc(x::Int64) = try; thr(x) + 1; catch e; e isa E ? e.v * 2 : 0; end
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
    # its exception is the catch block alone, and the stackifier places its try_table, rejecting at
    # the unwind mismatch fixes
    local wei = L.WebAssemblyExceptionInfo()
    L.run_on_machine_function(wei, mf)
    @test L.get_blocks(L.get_exception_for(wei, pad)) == [pad]
    local e = try; L.add_pre_emit_pass(stmts, cfg, handlers, "tc", true); nothing; catch x; x; end
    @test e isa W.RejectionError && occursin("fixCatchUnwindMismatches", e.rejection.anchor)
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
