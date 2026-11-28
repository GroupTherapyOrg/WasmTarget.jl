# Julia's module-binding queries of a (module, name) pair only run time knows, answered from the module binding table
# (src/julia/runtime/bindings.jl, src/intrinsics.jl module_binding_table): isconst (jl_is_const), Base.isdeprecated
# (jl_is_binding_deprecated) and isdefinedglobal (jl_f_isdefinedglobal's jl_boundp), each compared with the same function
# run natively; a pair outside the table, a name made at run time, ends the program at the fatal arm, located, never
# "no binding".
module ModuleBindingTableTest
using Test, WasmTarget
const W = WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const WTChild = Main.WTChild

module BindingCases
_mbt_type(x::Int64) = x > 0 ? Int64 : Base.RefValue{Int64}
mbt_isconst(x::Int64) = (tn = _mbt_type(x).name; Int64(isconst(tn.module, tn.singletonname)) + 2 * Int64(isconst(tn.module, tn.name)))
mbt_isdeprecated(x::Int64) = (tn = _mbt_type(x).name; Int64(Base.isdeprecated(tn.module, tn.name)))
mbt_isdefinedglobal(x::Int64) = (tn = _mbt_type(x).name; Int64(isdefinedglobal(tn.module, tn.singletonname)) + 2 * Int64(isdefinedglobal(tn.module, tn.name)))
# a name made at run time, which no Symbol constant of the module is: outside the table
mbt_made_name(x::Int64) = Int64(isconst(Base, Symbol("mbt_made_", x)))
end
const BC = BindingCases

@testset "module binding queries answered from the module binding table, as native" begin
    local cases = WTChild.RunCase[]
    for f in (BC.mbt_isconst, BC.mbt_isdeprecated, BC.mbt_isdefinedglobal), x in (1, -1)
        push!(cases, WTChild.compiled_case("$(nameof(f))($x)", W.compile, f, (Int64(x),)))
    end
    for r in WTChild.run_cases(cases)
        @test (r.label => r.why) == (r.label => "")
    end
    # a pair outside the table: the fatal arm, located
    local r = only(WTChild.run_cases([WTChild.compiled_case("mbt_made_name(1)", W.compile, BC.mbt_made_name, (Int64(1),))]))
    @test (r.outcome === :unported && occursin("module_binding_answers: a (module, name) pair outside the module binding table", r.why)) ||
          (@info "mbt_made_name" r.outcome r.why; false)
end
end
