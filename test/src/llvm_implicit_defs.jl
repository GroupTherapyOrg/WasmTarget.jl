# LLVM's addImplicitDefs, ported (src/llvm/fix_irreducible_control_flow.jl; dev/LEDGER.md D42;
# dev/formal/ImplicitDefs.tla), and its consumer, visit_block (src/code_generator.jl): after
# FixIrreducibleControlFlow adds a dispatch block, every register with a use is defined at the entry
# by an IMPLICIT_DEF, which ExplicitLocals erases, the register's local holding wasm's default there; a
# value of a non-nullable reference type gets a defaultable local, read back at its type. Each function
# below is an @goto-made loop with two entries, a value of a reference type crossing its dispatch, run
# against native Julia.
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
end

nir_of(f, types) = (ci = Base.code_typed(f, types; optimize = true)[1][1]; W.nir_code(ci.code, ci.ssaflags, W.NirBindings(Base.get_world_counter()), "llvm_implicit_defs"))
implicit_defs(mf) = [((i.operands[1]::W.MOImm).imm, (i.operands[2]::W.MOImm).imm) for i in mf.blocks[mf.layout[1]].instrs if i.opcode == W.IMPLICIT_DEF]

@testset "addImplicitDefs: every register with a use defined at the entry" begin
    for f in (IrreducibleCases.grow, IrreducibleCases.concat, IrreducibleCases.inner)
        local stmts, jcfg, handlers = nir_of(f, (Int64,))
        local mf = L.add_pre_emit_pass(stmts, jcfg, handlers, string(nameof(f)), true)
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

@testset "visit_block: an IMPLICIT_DEF's value of a reference type crosses the dispatch, defaultable" begin
    for f in (IrreducibleCases.grow, IrreducibleCases.concat, IrreducibleCases.inner)
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
