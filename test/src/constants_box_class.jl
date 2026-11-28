# A constant boxed where its class has no class info (src/constants.jl visitIntConstant, visitDoubleConstant,
# visitBoolConstant): a closed world numbers the class of every value its program holds, so a program's literal brings
# its class; a constant boxed in a world without it is WasmTarget's own defect, an Internal located at the visitor,
# never an unlocated KeyError (D9). A world of one Int32 add holds no Float64 and no Int16 class; boxing a constant of
# each there rejects at its visitor. Bool's class is in every world, so visitBoolConstant's arm has no such world.
module ConstantsBoxClassTest
using Test, WasmTarget
include(joinpath(@__DIR__, "..", "codegen_helpers.jl"))

@testset "a constant boxed where its class has no class info rejects, located" begin
    local g = ready_codegen_of(CodegenCases.f_add, (Int32,), [IR.NumType_i32], [IR.NumType_i32])
    local t = g.translator
    @test !haskey(t.class_info, Float64) && !haskey(t.class_info, Int16)
    for (v, anchor) in ((1.5, "ConstantInstantiator.visitDoubleConstant"), (Int16(7), "ConstantInstantiator.visitIntConstant"))
        local e = rejection(() -> D.translate_expression(g, W.NirConst(Core.Const(v)), t.top_type[]))
        @test e isa W.RejectionError && e.rejection isa W.Internal
        @test occursin(anchor, sprint(showerror, e)) && occursin("the class $(typeof(v)) of the boxed constant $v has no class info", sprint(showerror, e))
    end
end

end # module
