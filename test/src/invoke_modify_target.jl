# Expr(:invoke_modify, target, f, args...): `target` is the instance of the modify's operator Julia resolved, which
# codegen calls as the operator (julia/src/codegen.cpp:5422 emit_invoke_modify, `lival`), a callee as an invoke's
# target is, never a value the program holds. Read as a constant operand, its CodeInstance's object graph was walked
# for classes and brought Random's MersenneTwister and a Memory{UInt128} (closed_world_edge_rejects/
# atomic_modify_operator). The modify itself stays a located rejection here.
module InvokeModifyTargetTest
using Test, WasmTarget
const W = WasmTarget
mutable struct _ImAtom
    @atomic v::Int64
end
@noinline _im_op(x::Int64, y::Int64) = x * 10 + y
im_atom(n::Int64) = (a = _ImAtom(n); @atomic a.v _im_op n; @atomic a.v)
@testset "invoke_modify's target is a callee, no operand" begin
    local world = W.build_nir(W.check_subset(im_atom, (Int64,), "invoke_modify_target", Base.get_world_counter()), "invoke_modify_target")
    local mods = [st for b in world for st in b.stmts if st isa W.NirInvokeModify]
    @test length(mods) == 1
    local st = only(mods)
    local mi = st.target isa Core.CodeInstance ? st.target.def : st.target
    @test mi isa Core.MethodInstance && mi.def.name === :_im_op
    # no operand holds a CodeInstance or a MethodInstance: the walk meets none of their object graphs
    @test !any(v -> v isa W.NirConst && v.c.val isa Union{Core.CodeInstance, Core.MethodInstance}, W.nir_operands(st))
    local classes = W.closed_world_classes(world, "invoke_modify_target")
    @test !any(c -> c <: GenericMemory && eltype(c) === UInt128, classes)
    @test !any(c -> c <: Base.RefValue && c.parameters[1] isa Type && nameof(c.parameters[1]) === :MersenneTwister, classes)
    # the modify itself: a located rejection of the code generator's, past the class walk
    local e = try; W.compile(im_atom, (Int64,)); nothing; catch x; x; end
    @test (e isa W.RejectionError && e.rejection isa W.Unquarantined && (occursin("invoke_modify", sprint(showerror, e)) || occursin("modifyfield!", sprint(showerror, e)))) ||
          (@info "im_atom" e === nothing ? "compiled" : sprint(showerror, e); false)
end
end
