# dart2wasm's compiler_options.dart, ported (src/compiler_options.jl): a phase parsed by its dart name,
# and the options' validation, each inconsistent set refused with dart's ArgumentError and message.

module CompilerOptionsTest

using Test
using WasmTarget

const D = WasmTarget.Dart2Wasm

# the ArgumentError's message `f()` throws, or nothing
refusal(f) = try; f(); nothing; catch e; e isa ArgumentError ? e.msg : rethrow(); end

@testset "compiler_options.dart: CompilerPhase.parse and validate" begin
    @test [D.CompilerPhase_parse(n) for n in ("cfe", "tfa", "codegen", "opt")] == collect(instances(D.CompilerPhase))
    @test refusal(() -> D.CompilerPhase_parse("link")) == "Invalid compiler phase name: link"

    local opts(main, out; phases = [D.CompilerPhase_cfe, D.CompilerPhase_tfa, D.CompilerPhase_codegen]) = begin
        local o = D.WasmCompilerOptions(; main_uri = main, output_file = out)
        o.phases = phases
        o
    end
    # dart's default phases, a .dart in and a .wasm out, validate
    @test D.validate(opts("a.dart", "a.wasm")) === nothing
    @test D.validate(opts("a.wasm", "b.wasm"; phases = [D.CompilerPhase_opt])) === nothing
    @test refusal(() -> D.validate(opts("a.dill", "a.wasm"))) == "Input to cfe phase must be a .dart file."
    @test refusal(() -> D.validate(opts("a.dart", "a.dill"))) == "Output from codegen phase must be a .wasm file."
    @test refusal(() -> D.validate(opts("a.dart", "a.wasm"; phases = D.CompilerPhase[]))) == "--phases must contain at least one phase."
    @test refusal(() -> D.validate(opts("a.dart", "a.wasm"; phases = [D.CompilerPhase_cfe, D.CompilerPhase_codegen]))) ==
          "--phases must contain consecutive phases."
    local zero = opts("a.wasm", "b.wasm"; phases = [D.CompilerPhase_opt])
    zero.translator_options.optimization_level = 0
    @test refusal(() -> D.validate(zero)) == "Cannot specify \"opt\" phase with optimization level 0"
    # the deferred-loading options require it
    local deferred = opts("a.dart", "a.wasm")
    deferred.use_load_ids = true
    @test refusal(() -> D.validate(deferred)) == "--use-load-ids can only be used with --enable-deferred-loading"
    deferred.translator_options.enable_deferred_loading = true
    @test refusal(() -> D.validate(deferred)) == "--use-load-ids requires --deferred-map"
    local shared = opts("a.dart", "a.wasm")
    shared.translator_options.import_shared_memory = true
    @test refusal(() -> D.validate(shared)) == "--shared-memory-max-pages must be specified if --import-shared-memory is used."
end

end
