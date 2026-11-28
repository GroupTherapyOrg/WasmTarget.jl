# dart2wasm's constants.dart, ported (src/constants.jl): a Module constant, run against native Julia (split from
# test/src/constants_objects.jl, every testset verbatim; its other parts are test/src/constants_owners.jl and
# test/src/constants_large_arrays.jl, and test/src/constants_values.jl the other half of test/src/constants.jl).

# a Module constant: an instance constant of its class (src/julia/classes.jl _module_instance_fields),
# its one field the module's name, the Symbol Julia's `nameof` reads (jl_module_t's name); two modules
# through a phi, so Julia folds no `===`, each its own canonical constant, run against native
module ModuleConstants
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const WTChild = Main.WTChild
which_module(x::Int64) = (x > 0 ? Base : Core) === Base ? Int64(1) : Int64(2)
@testset "constants.dart: a Module constant is its class's struct, its name its one field" begin
    @test Base.code_typed(which_module, (Int64,))[1][2] === Int64
    # each module a constant, its name, the Symbol, a sub-constant of it
    local D = WasmTarget.Dart2Wasm
    local t = D.Translator(WasmTarget.build_nir(WasmTarget.check_subset(which_module, (Int64,), "constants", Base.get_world_counter()), "constants"),
        D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    D.translate(t, nothing)
    local made = t.constants[].constant_info
    @test all(m -> haskey(made, WasmTarget.NirConst(Core.Const(m))), (Base, Core, :Base, :Core))
    local cases = reduce(vcat, [first(WTChild.answer_cases("module constant $x", WasmTarget.compile, which_module, (x,))) for x in (Int64(1), Int64(-1))])
    local results = WTChild.run_cases(cases)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test !isempty(results) && all(r -> r.ok, results)
end
end
