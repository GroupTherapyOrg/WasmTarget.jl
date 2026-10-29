# LLVM's DominanceFrontier and WebAssemblyExceptionInfo, ported (src/llvm/dominance_frontier*.jl,
# src/llvm/exception_info.jl; dev/LEDGER.md D42), over hand-written statement lists whose CFG holds the
# shape under test: each block's dominance frontier, and an EH pad's exception the blocks it dominates.
using Test
using WasmTarget

const W = WasmTarget
const L = WasmTarget.LLVM

# the machine function of a statement list, through the NIR (nir_code)
machine_of(code, at) = W.machine_function(W.nir_code(code, at)..., at)

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
