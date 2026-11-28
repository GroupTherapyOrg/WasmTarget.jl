# dart2wasm makes a closure's dynamic call entry (_ClosureDynamicEntryGenerator, translator.dart:2864) only where the
# program calls Function.apply with named arguments (translator.dart:1550 usesFunctionApplyWithNamedArguments). Julia's
# counterpart, a call of a closure whose type only run time knows, keyword (Core.kwcall) or positional, is an unresolved
# call Julia's trim verifier refuses: outside the strict subset (D32), so no program WasmTarget compiles reaches the
# entry, whose port stays a located rejection naming that (src/translator.jl).
module ClosureDynamicCallTest
using Test, WasmTarget

module DynCases
const FS = Any[(x; k = 1) -> x + k, (x; k = 2) -> x * k]
@noinline pick(n::Int64) = FS[n]
kw_dyn(n::Int64)::Int64 = (pick(n)(3; k = 5))::Int64
pos_dyn(n::Int64)::Int64 = (pick(n)(3))::Int64
end

@testset "a closure called by a type only run time knows is outside the strict subset, keyword or positional" begin
    # native's answers, which no module gives
    @test DynCases.kw_dyn(1) == 8 && DynCases.kw_dyn(2) == 15 && DynCases.pos_dyn(2) == 6
    for (f, call) in ((DynCases.kw_dyn, "Core.kwcall("), (DynCases.pos_dyn, "(pick(n::Int64)::Any)(3)"))
        local e = try; WasmTarget.compile(f, (Int64,)); nothing; catch x; x; end
        @test (e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.OutsideSubset &&
               occursin("unresolved call", sprint(showerror, e)) && occursin(call, sprint(showerror, e))) ||
              (@info nameof(f) e === nothing ? "compiled" : sprint(showerror, e); false)
    end
end

end # module
