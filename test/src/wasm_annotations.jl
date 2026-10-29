# dart2wasm's wasm_annotations.dart, ported (src/wasm_annotations.jl): a member's wasm:memory-type pragma
# and the limits it carries. Julia declares no memory type on any binding, so the read answers nothing,
# and the two readers of dart's MemoryType constant, which no Julia value is, reject Internal at their rows.

module WasmAnnotationsTest

using Test
using WasmTarget

const W = WasmTarget
const D = WasmTarget.Dart2Wasm

f(x::Int) = x + 1
@noinline g(x::Int) = x * 2

@testset "wasm_annotations.dart: MemoryLimits" begin
    local world = W.build_nir(W.check_subset(f, (Int,), "wasm_annotations"), "wasm_annotations")
    local t = D.Translator(world, D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    # a member declares no memory type: the read answers nothing, inlined or not
    for fn in (f, g)
        local mi = Base.method_instance(fn, (Int,))
        @test D.MemoryLimits_read_annotation(t, mi) === nothing
    end
    # dart's constructor keeps its limits
    local m = D.MemoryLimits(; min_size = 1, max_size = 4)
    @test m.min_size == 1 && m.max_size == 4 && D.MemoryLimits(; min_size = 2).max_size === nothing
    # the readers of a MemoryType or Limits constant, which no Julia value is, reject Internal at their rows
    local why(fn) = (e = try; fn(t, W.NirConst(Core.Const(1))); nothing; catch x; x; end; e isa W.RejectionError && e.rejection isa W.Internal ? e.rejection.site : e)
    @test occursin("wasm_annotations.dart:35 MemoryLimits._readMemoryType", why(D.MemoryLimits__read_memory_type))
    @test occursin("wasm_annotations.dart:43 MemoryLimits._readLimits", why(D.MemoryLimits__read_limits))
end

end
