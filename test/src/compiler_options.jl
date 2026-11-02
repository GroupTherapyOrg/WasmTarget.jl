# dart2wasm's compiler_options.dart, ported (src/compiler_options.jl): a phase parsed by its dart name;
# the command line's validation, which WasmTarget has no caller of, rejects.

module CompilerOptionsTest

using Test
using WasmTarget

const D = WasmTarget.Dart2Wasm

# the ArgumentError's message `f()` throws, or nothing
refusal(f) = try; f(); nothing; catch e; e isa ArgumentError ? e.msg : rethrow(); end

@testset "compiler_options.dart: CompilerPhase.parse and validate" begin
    @test [D.CompilerPhase_parse(n) for n in ("cfe", "tfa", "codegen", "opt")] == collect(instances(D.CompilerPhase))
    @test refusal(() -> D.CompilerPhase_parse("link")) == "Invalid compiler phase name: link"

    # WasmTarget takes a Julia function, no command line or input file: validation has no caller and
    # rejects, Internal
    local o = D.WasmCompilerOptions(; main_uri = "a.dart", output_file = "a.wasm")
    for f in (D.validate, D._validate_phases)
        local e = try; f(o); nothing; catch x; x; end
        @test e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.Internal && occursin("Julia function", e.rejection.site)
    end
end

end
