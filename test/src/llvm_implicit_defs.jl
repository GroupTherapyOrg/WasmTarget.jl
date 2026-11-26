# LLVM's addImplicitDefs, ported (src/llvm/fix_irreducible_control_flow.jl; dev/LEDGER.md D42;
# dev/formal/ImplicitDefs.tla), and its consumer, visit_block (src/code_generator.jl): after
# FixIrreducibleControlFlow adds a dispatch block, every register with a use is defined at the entry
# by an IMPLICIT_DEF, which ExplicitLocals erases, the register's local holding wasm's default there; a
# value of a non-nullable reference type gets a defaultable local, read back at its type. A register's
# uses are MachineRegisterInfo's, the instructions' left in the function (reg_operands): none in a
# block no path reaches, none on a PHI's edge from one, none of a token (an EnterNode's, read by
# :leave; a gc_preserve_begin's, read by gc_preserve_end). Each function below is an @goto-made loop
# with two entries, a value of a reference type crossing its dispatch, run against native Julia.
module LLVMImplicitDefsTest

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "codegen_helpers.jl"))

const L = WasmTarget.LLVM

module IrreducibleCases
# a Vector made before the loop, grown in both of its entries
function grow(n::Int64)
    local list = Int64[]
    n > 0 && @goto b
    @label a
    push!(list, 1)
    @label b
    push!(list, 2)
    length(list) < 7 && @goto a
    return sum(list) + 100 * length(list)
end
# a String carried around the loop, a PHI of a reference type at each entry
function concat(n::Int64)
    local s = "x"
    n > 0 && @goto b
    @label a
    s = s * "a"
    @label b
    s = s * "b"
    ncodeunits(s) < 9 && @goto a
    return Int64(ncodeunits(s)) + 10 * Int64(count(==('a'), s))
end
# a Vector made inside the loop's first entry and read in a block it dominates
function inner(n::Int64)
    local list = Int64[]
    n > 0 && @goto b
    @label a
    local t = Int64[length(list), n]
    push!(list, t[1] + t[2])
    @label b
    push!(list, 3)
    length(list) < 6 && @goto a
    return sum(list)
end
# a try region and a preservation region after the loop: an EnterNode's token, which :leave reads, and
# a gc_preserve_begin's, which gc_preserve_end reads, each a value no instruction reads
function guarded(n::Int64)
    local list = Int64[]
    n > 0 && @goto b
    @label a
    push!(list, 1)
    @label b
    push!(list, 2)
    length(list) < 7 && @goto a
    local r = try
        list[n + 6]
    catch
        -1
    end
    local s = GC.@preserve list begin
        length(list) + 10 * r
    end
    return s
end
end

nir_of(f, types) = (ci = Base.code_typed(f, types; optimize = true)[1][1]; W.nir_code(ci.code, ci.ssaflags, W.NirBindings(Base.get_world_counter()), "llvm_implicit_defs"))
implicit_defs(mf) = [((i.operands[1]::W.MOImm).imm, (i.operands[2]::W.MOImm).imm) for i in mf.blocks[mf.layout[1]].instrs if i.opcode == W.IMPLICIT_DEF]
# the machine function as addImplicitDefs leaves it: add_pre_emit_pass's passes up to and with
# FixIrreducibleControlFlow
function fixed(stmts, jcfg, handlers, at)
    local mf = W.machine_function(stmts, jcfg, handlers, at)
    L.eliminate_phi_nodes(mf, jcfg)
    L.run_on_machine_function(L.WebAssemblyFixIrreducibleControlFlow(), mf)
    return mf
end
value_defs(mf) = sort([id for (kind, id) in implicit_defs(mf) if kind == W.REGISTER_VALUE])

@testset "addImplicitDefs: every register with a use defined at the entry" begin
    for f in (IrreducibleCases.grow, IrreducibleCases.concat, IrreducibleCases.inner)
        local stmts, jcfg, handlers = nir_of(f, (Int64,))
        local mf = fixed(stmts, jcfg, handlers, string(nameof(f)))
        local defs = implicit_defs(mf)
        # the function was irreducible: a dispatch, its label register defined at the entry
        @test mf.label_registers >= 1 && all(r -> (W.REGISTER_LABEL, r) in defs, 1:mf.label_registers)
        # every used statement's value but an Upsilon's, and every PHI's IncomingReg, exactly
        local used = [k for k in W.nir_used_statements(stmts) if !(stmts[k] isa W.NirUpsilon)]
        @test sort([id for (kind, id) in defs if kind == W.REGISTER_VALUE]) == sort(used)
        local phis = [k for b in mf.layout for mi in mf.blocks[b].instrs if mi.opcode == W.STMTS
                      for k in (mi.operands[1]::W.MOImm).imm:(mi.operands[2]::W.MOImm).imm if stmts[k] isa W.NirPhi]
        @test sort([id for (kind, id) in defs if kind == W.REGISTER_INCOMING]) == sort(phis)
    end
end

@testset "addImplicitDefs: the uses are the instructions' left in the function, a token none" begin
    # %1-%3: a gc_preserve_begin token and a value read only in a block no path reaches (%10-%11, behind
    # %9's return), then a loop entered at X (%4-%5) and at Y (%6-%7), each from the first block; Y's
    # PHI takes %4 from X and %10 from the dead block, its edge gone before PHIElimination
    local ir = Any[Expr(:gc_preserve_begin, Core.Argument(2)),
                   Expr(:call, Core.Intrinsics.add_int, Core.Argument(2), 1),
                   Core.GotoIfNot(Core.Argument(3), 6),
                   Expr(:call, Core.Intrinsics.add_int, Core.Argument(2), 2),
                   Core.GotoNode(6),
                   Core.PhiNode(Int32[3, 5, 11], Any[0, Core.SSAValue(4), Core.SSAValue(10)]),
                   Core.GotoIfNot(Core.Argument(3), 4),
                   Expr(:gc_preserve_end, Core.SSAValue(1)),
                   Core.ReturnNode(Core.SSAValue(6)),
                   Expr(:call, Core.Intrinsics.add_int, Core.SSAValue(2), 1),
                   Core.GotoNode(6)]
    local stmts, jcfg, handlers = W.nir_code(ir, zeros(UInt32, length(ir)), W.NirBindings(Base.get_world_counter()), "deadwalk")
    local mf = fixed(stmts, jcfg, handlers, "deadwalk")
    @test mf.label_registers == 1
    # Julia's use scan counts each of them; MachineRegisterInfo's use lists hold %4 (X's COPY) and %6
    # (the return) alone
    @test issubset([1, 2, 4, 6, 10], W.nir_used_statements(stmts))
    @test value_defs(mf) == [4, 6]
    # each token, of a function Julia compiled: no IMPLICIT_DEF of an EnterNode's or a gc_preserve_begin's
    local gstmts, gjcfg, ghandlers = nir_of(IrreducibleCases.guarded, (Int64,))
    local tokens = [k for k in eachindex(gstmts) if gstmts[k] isa Union{W.NirEnter, W.NirGCPreserveBegin}]
    @test any(k -> gstmts[k] isa W.NirEnter, tokens) && any(k -> gstmts[k] isa W.NirGCPreserveBegin, tokens)
    @test issubset(tokens, W.nir_used_statements(gstmts))
    local gmf = fixed(gstmts, gjcfg, ghandlers, "guarded")
    @test gmf.label_registers >= 1 && !isempty(value_defs(gmf)) && isdisjoint(tokens, value_defs(gmf))
end

@testset "visit_block: an IMPLICIT_DEF's value of a reference type crosses the dispatch, defaultable" begin
    for f in (IrreducibleCases.grow, IrreducibleCases.concat, IrreducibleCases.inner, IrreducibleCases.guarded)
        local bytes = W.compile(f, (Int64,); optimize = false)
        queue_native!(string(nameof(f)), bytes, f, [(Int64(n),) for n in (-1, 0, 1, 2)])
    end
end

@testset "the third oracle: every module queued above answers as native Julia" begin
    for r in WTChild.run_cases(NATIVE_RUNS)
        r.ok || println(r.label, ": ", r.why)
        @test r.ok
    end
end

end
