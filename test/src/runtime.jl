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
    # a throw also demands StackTrace.current, the standalone patch's (dart's entry point)
    @test :StackTrace_current in names_of(gw) && !(:StackTrace_current in names_of(world_of(f, (Int,))))
end

isdefined(Main, :WTRunner) || Base.include(Main, joinpath(@__DIR__, "..", "runner.jl"))

# the standalone StackTrace.current called, its trace held and dropped
st(x::Int) = (W.Runtime.StackTrace_current(); x)

@testset "standalone/stack_trace_patch.dart: StackTrace.current, the embedder's trace in an _EmbedderStackTrace" begin
    # its one import, the standalone embedder's stackTraceGetCurrent, the embedder's own function
    local node = Main.WTRunner.node_binary()
    local imports_of(bytes) = mktempdir() do dir
        local path = joinpath(dir, "m.wasm")
        write(path, bytes)
        readchomp(`$node -e "const m = new WebAssembly.Module(require('fs').readFileSync(process.argv[1])); console.log(WebAssembly.Module.imports(m).map(i => i.module + '.' + i.name + ':' + i.kind).join(','))" $path`)
    end
    local bytes = W.compile(st, (Int,); optimize = false)
    @test imports_of(bytes) == "dart.stackTraceGetCurrent:function"
    # a throw throws with the current stack trace (_throwWithCurrentStackTrace), the same one import;
    # run by node, its raise is a wasm exception under the module's tag, as native Julia throws
    local gbytes = W.compile(g, (Int,); optimize = false)
    @test imports_of(gbytes) == "dart.stackTraceGetCurrent:function"
    for r in Main.WTRunner.run_cases([Main.WTRunner.RunCase("g$(a)", gbytes, a, Main.WTRunner.native_answer(g, a)) for a in [(2,), (-2,)]])
        @test r.ok || (@info r.label r.why; false)
    end
    # run by node, given dart's test runner's embedder, it answers its argument, the host's trace made
    # and dropped (native Julia has no standalone embedder to call: st's answer is its argument whatever
    # the trace)
    for r in Main.WTRunner.run_cases([Main.WTRunner.RunCase("st$(a)", bytes, a, a[1]) for a in [(3,), (-7,)]])
        @test r.ok || (@info r.label r.why; false)
    end
    # outside standalone mode a JS host supplies no `dart` module: the import rejects, located
    local ns = D.WasmCompilerOptions(; main_uri = "", output_file = "out/prog.wasm"); ns.translator_options.generate_source_maps = false
    local e = try; D.compile(ns, W.check_subset(st, (Int,), "runtime")); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Unquarantined && occursin("dart.stackTraceGetCurrent outside standalone mode", e.rejection.row)
end

end

module RuntimeAsCheck
using Test, WasmTarget
const W = WasmTarget
isdefined(Main, :WTRunner) || Base.include(Main, joinpath(@__DIR__, "..", "runner.jl"))
# a typeassert Julia keeps: the value's class only run time knows, an Int or a String
@noinline pick(x::Int)::Union{Int,String} = x > 0 ? x : "neg"
checked(x::Int) = typeassert(pick(x), Int) + 1
@testset "errors_patch.dart: _throwAsCheckError throws Julia's TypeError where a typeassert fails" begin
    local world = W.build_nir(W.check_subset(checked, (Int,), "runtime"), "runtime")
    @test :_TypeError__throw_as_check_error in Set(b.ci.def.def.name for b in world)
    @test (try; checked(-1); nothing; catch e; e; end) == TypeError(:typeassert, "", Int, "neg")
    local bytes = W.compile(checked, (Int,))
    for r in Main.WTRunner.run_cases([Main.WTRunner.RunCase("checked$(a)", bytes, a, Main.WTRunner.native_answer(checked, a)) for a in [(3,), (-1,)]])
        @test r.ok || (@info r.label r.why; false)
    end
end
end
