# dart2wasm's constructor_info.dart, ported (src/constructor_info.jl): a Julia constructor's parameter
# usages, each expected answer Julia's own (the constructor's typed IR, its arguments).
module ConstructorInfoTest

using Test
using WasmTarget

const D = WasmTarget.Dart2Wasm

module Cases
struct Pt
    a::Int
    b::Int
    # reads its first two arguments and not its third
    @noinline Pt(a::Int, b::Int, unused::Int) = new(a, b + 1)
end
make(x::Int) = Pt(x, 2x, 0)
end

@testset "constructor_info.dart" begin
    local t = D.Translator(WasmTarget.check_subset(Cases.make, (Int,), "constructor_info"),
        D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    local body = only(b for b in t.component if b.ci.def.def isa Method && b.ci.def.def.name === :Pt)
    local mi = body.ci.def
    local closures = D.Closures(Val(:_), t, mi)
    # the body: the whole method, reading the arguments its NIR reads (2 and 3, a and b; not 4)
    local body_collector = D._UsageCollector(t, closures)
    D.collect_body_usages(body_collector, mi)
    @test WasmTarget.NirArgument(2) in body_collector.variables_read && WasmTarget.NirArgument(3) in body_collector.variables_read
    @test !(WasmTarget.NirArgument(4) in body_collector.variables_read) && isempty(body_collector.variables_written)
    # the initializer list: none, and no context, so nothing captured or stored in a field
    local init_collector = D._UsageCollector(t, closures)
    D.collect_initializer_usages(init_collector, mi)
    @test isempty(init_collector.variables_captured) && isempty(init_collector.variables_stored_in_fields)
    @test D.visit_type_parameter_type(init_collector, TypeVar(:T)) === nothing && length(init_collector.used_type_parameters) == 1
    # ConstructorInfo reads the member's closures, not yet ported: a located rejection
    local e = try; D.ConstructorInfo(mi, t); nothing; catch x; x; end
    @test e isa WasmTarget.RejectionError
end

end
