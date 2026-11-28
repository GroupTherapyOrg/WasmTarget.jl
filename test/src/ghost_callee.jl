# A method's callee read as a value where it is a singleton (src/code_generator.jl translateExpression's NirArgument
# arm): it is no parameter (_initializeThis), and its value is its type's one instance, as Julia's codegen gives an
# argument that is not actually passed (julia/src/codegen.cpp:8688 get_specsig_arg's ghostValue, :2221). Reached where
# a default argument's method passes a value no method takes: `dflt(k)` is `dflt(k, Int64)`, the type Int64 no Function,
# so Julia leaves the call to throw a MethodError whose function is the callee itself. Each answer is native Julia's.
module GhostCalleeTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module GhostCases
dflt(k::Int64, g::Function = Int64) = k + Int64(g(k))
# the MethodError's function is dflt itself; a call with a Function answers
function ghost(k::Int64)::Int64
    local r = try
        dflt(k)
    catch e
        e isa MethodError ? (e.f === dflt ? 100 : 200) : -1
    end
    return r + dflt(k, abs)
end
end

const GC_ = GhostCases

@testset "a singleton callee read as a value is its type's instance" begin
    @test GC_.ghost(Int64(-4)) == 100
    local both(f, a) = Main.WTVerdict._modules(WasmTarget.compile, f, a)
    local (plain, opt) = both(GC_.ghost, (Int64(1),))
    local cases = [Main.WTChild.RunCase("ghost_callee/ghost$a", plain, a, Main.WTChild.native_answer(GC_.ghost, a); optimized = opt)
                   for a in ((Int64(-4),), (Int64(7),))]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
