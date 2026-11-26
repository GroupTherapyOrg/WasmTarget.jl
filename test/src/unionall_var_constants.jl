# Two UnionAll constants of one body whose variables are distinct TypeVars with distinct names: `Vector{T} where T`
# and `Vector{S} where S`, each bound by its own `const`. Julia's image keeps them two objects (natively `===` holds
# them apart), so a program reading `.var.name` of each answers each one's own name; WasmTarget keys its constants by
# `===`, so it keeps two constants and each keeps its own variable. Each case's answer is native Julia's (its native
# run), compared in both modules: one picked from a Vector{UnionAll} at run time, each hidden from inference by
# Base.inferencebarrier, and each read directly.
module UnionAllVarConstantsTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module Cases
const UA_T = Vector{T} where T
const UA_S = Vector{S} where S
code(s::Symbol)::Int64 = s === :T ? 1 : s === :S ? 2 : 3
picked(x::Int64)::Int64 = (us = UnionAll[UA_T, UA_S]; code(us[x].var.name))
both(x::Int64)::Int64 = (a = Base.inferencebarrier(UA_T)::UnionAll; b = Base.inferencebarrier(UA_S)::UnionAll;
    x * (code(a.var.name) + 10 * code(b.var.name)) + (a === b ? 100 : 0))
direct(x::Int64)::Int64 = x * (code(UA_T.var.name) + 10 * code(UA_S.var.name)) + (UA_T === UA_S ? 100 : 0)
end

const C = Cases

@testset "two UnionAll constants of one body keep their own variables" begin
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((C.picked, (1, 2)), (C.both, (1,)), (C.direct, (1,)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("unionall_var_constants/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
