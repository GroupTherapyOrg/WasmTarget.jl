# LLVM's PHIElimination, ported (src/llvm/phi_elimination.jl; dev/LEDGER.md D42), over hand-written
# statement lists whose CFG holds the edge under test: each predecessor's COPY into the PHI's
# register, an edge from a block no path reaches dropped, and an edge from any other block that is no
# predecessor a located Internal, never a copy skipped in silence.
using Test
using WasmTarget

const W = WasmTarget
const L = WasmTarget.LLVM

# the COPY instructions of each block, as (block, phi statement, edge index)
copies(mf) = [(b, (mi.operands[1]::W.MOImm).imm, (mi.operands[2]::W.MOImm).imm)
              for b in mf.layout for mi in mf.blocks[b].instrs if mi.opcode == W.COPY]

@testset "PHIElimination.cpp: a COPY in each predecessor, never an edge skipped in silence" begin
    # %1 branches to %3 or falls to %2, which jumps to %3: the phi at %3 takes 10 from %1, 20 from %2
    local diamond = Any[Core.GotoIfNot(Core.Argument(2), 3), Core.GotoNode(3),
                        Core.PhiNode(Int32[1, 2], Any[10, 20]), Core.ReturnNode(Core.SSAValue(3))]
    local mf = W.machine_function(diamond, "diamond")
    @test L.eliminate_phi_nodes(mf, Core.Compiler.compute_basic_blocks(diamond))
    # Julia's block k is machine block k + 1: the copy of edge 1 in block 2, of edge 2 in block 3
    @test sort(copies(mf)) == [(2, 3, 1), (3, 3, 2)]
    # an edge from a block no path reaches (%2, behind %1's jump) is dropped, as
    # UnreachableMachineBlockElim removes it
    local dead = Any[Core.GotoNode(3), Core.ReturnNode(1),
                     Core.PhiNode(Int32[1, 2], Any[10, 20]), Core.ReturnNode(Core.SSAValue(3))]
    local mfd = W.machine_function(dead, "dead")
    L.eliminate_phi_nodes(mfd, Core.Compiler.compute_basic_blocks(dead))
    @test copies(mfd) == [(2, 3, 1)]
    # an edge from a reachable block that is no predecessor (%2 returns) is WasmTarget's own defect
    local stray = Any[Core.GotoIfNot(Core.Argument(2), 3), Core.ReturnNode(1),
                      Core.PhiNode(Int32[1, 2], Any[10, 20]), Core.ReturnNode(Core.SSAValue(3))]
    local mfs = W.machine_function(stray, "stray")
    local e = try; L.eliminate_phi_nodes(mfs, Core.Compiler.compute_basic_blocks(stray)); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Internal && occursin("no predecessor of block", e.rejection.site) &&
          occursin("PHIEliminationImpl::LowerPHINode", e.at)
end
