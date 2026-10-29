# WasmTarget's runtime (src/runtime/, the ports of dart's patch libraries, and src/julia/runtime/,
# Julia's own runtime raises): a closed world holds each runtime entry point its program demands, and
# KernelNodes names each runtime method as dart2wasm's index.getProcedure names a patch member.

module RuntimeTest

using Test
using WasmTarget

const W = WasmTarget
const D = WasmTarget.Dart2Wasm

f(x::Int) = x + 1
g(x::Int) = x > 0 ? x : throw(DivideError())
h(x::Int, y::Int) = div(x, y)

names_of(world) = Set(b.ci.def.def.name for b in world)
world_of(p, at) = W.build_nir(W.check_subset(p, at, "runtime"), "runtime")

@testset "runtime: a closed world holds the runtime entry points its program demands" begin
    # no throw and no checked division: the closed world is the program's alone, and it compiles as before
    @test names_of(world_of(f, (Int,))) == Set([:f])
    @test W.compile(f, (Int,); optimize = false)[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
    # a throw demands the thrower _throwWithCurrentStackTrace, which calls _throw
    local gw = world_of(g, (Int,))
    @test issubset((:g, :Error__throw_with_current_stack_trace, :Error__throw), names_of(gw))
    @test !(:throw_divide_error in names_of(gw))
    # the program's bodies first: the roots are queued before the entry
    @test first(gw).ci.def.def.name === :g
    # a checked division demands DivideError's raise, whose own throw demands the thrower
    local hw = world_of(h, (Int, Int))
    @test issubset((:h, :throw_divide_error, :Error__throw_with_current_stack_trace, :Error__throw), names_of(hw))
    # KernelNodes resolves errorThrow and errorThrowWithCurrentStackTrace to their methods there
    local t = D.Translator(gw, D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    local twc = D.error_throw_with_current_stack_trace(t)
    @test twc.def.module === W.Runtime && twc.def.name === :Error__throw_with_current_stack_trace
    @test D.error_throw(t).def.name === :Error__throw
    # a closed world with no throw holds neither: naming one is WasmTarget's own defect, located
    local tf = D.Translator(world_of(f, (Int,)), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    local e = try; D.error_throw(tf); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Internal
end

end
