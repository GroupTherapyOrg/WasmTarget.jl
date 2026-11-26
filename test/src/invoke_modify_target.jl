# Expr(:invoke_modify, target, f, args...): `target` is the instance of the modify's operator Julia resolved, which
# codegen calls as the operator (julia/src/codegen.cpp:5422 emit_invoke_modify, `lival`), a callee as an invoke's
# target is, never a value the program holds. Read as a constant operand, its CodeInstance's object graph was walked
# for classes and brought Random's MersenneTwister and a Memory{UInt128} (closed_world_edge_rejects/
# atomic_modify_operator). The modify itself is codegen's (emit_invoke_modify, cgutils.cpp's modify loop), compared with
# the same functions run natively: an operator that writes the field itself makes the loop load and call again.
module InvokeModifyTargetTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const W = WasmTarget
mutable struct _ImAtom
    @atomic v::Int64
end
@noinline _im_op(x::Int64, y::Int64) = x * 10 + y
im_atom(n::Int64) = (a = _ImAtom(n); @atomic a.v _im_op n; @atomic a.v)
# the modify's value, Pair(old, new)
im_pair(n::Int64) = (a = _ImAtom(n); p = (@atomic a.v _im_op n); first(p) * 1000 + last(p))
# an operator that writes the field on its first call: the field is no longer the old value, so the modify calls again
const _IM_OBJ = _ImAtom[]
const _IM_CALLS = Int64[0]
@noinline function _im_op_writes(x::Int64, y::Int64)
    _IM_CALLS[1] += 1
    _IM_CALLS[1] == 1 && (@atomic _IM_OBJ[1].v = x + 1000)
    return x * 10 + y
end
function im_retry(n::Int64)
    empty!(_IM_OBJ); _IM_CALLS[1] = 0
    local a = _ImAtom(n)
    push!(_IM_OBJ, a)
    local p = (@atomic a.v _im_op_writes n)
    return first(p) * 100000 + last(p) * 10 + _IM_CALLS[1]
end
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
    # the modify itself, as native
    local cases = [Main.WTChild.compiled_case("$(nameof(f))($n)", W.compile, f, (Int64(n),)) for f in (im_atom, im_pair, im_retry) for n in (1, 3)]
    for r in Main.WTChild.run_cases(cases)
        @test (r.label => r.why) == (r.label => "")
    end
end
end
