# dart2wasm's translator.dart, ported (src/translator.jl, dev/MARCH.md 1.A9 and 1.C): each filled
# definition answers as dart's does on fixed inputs.
using Test
using WasmTarget

const D = WasmTarget.Dart2Wasm

@testset "translator.dart: TranslatorOptions" begin
    local O = D.TranslatorOptions
    local o = O()
    # dart's field initializers
    @test o.optimization_level == 1 && o.generate_source_maps && o.unique_constant_names && !o.enable_asserts
    @test o.enable_unique_types === nothing && o.shared_memory_max_pages === nothing && o.watch_points == Int[]
    # each construction its own list, as dart's `= []` initializer
    push!(o.watch_points, 3)
    @test O().watch_points == Int[]
    # the getters: the override where set, else the optimization level's threshold
    @test D.inlining(o) && !D.minify(o) && !D.unique_types(o) && !D.omit_error_details(o)
    @test !D.omit_implicit_type_checks(o) && !D.omit_bounds_checks(o)
    local o4 = O(optimization_level = 4, minify_override = false)
    @test !D.minify(o4) && D.omit_bounds_checks(o4) && D.omit_error_details(o4) && D.unique_types(o4)
    @test !D.inlining(O(inlining_override = false))
end
