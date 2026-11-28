# A return whose value Julia's inference types wider than the method's return type: Julia's codegen converts it by
# convert_julia_type to the return type (julia/src/codegen.cpp:9215), as a PiNode is converted. Julia's optimizer
# makes one where it forwards a field read as the value just stored: `setfield!(m, :a, v::Union{Int64,String});
# m.a` returns `v` from an `::Int64` method, setfield!'s TypeError having proved it an Int64 on that path. Each
# case's answer is native Julia's, compared in both modules.
module ReturnNarrowedTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module Cases
mutable struct Box; a::Int64; end
@noinline mixed(x::Int64)::Union{Int64,String} = x > 0 ? x : "q"
# the stored value forwarded to the return: an Int64 returned, or setfield!'s TypeError caught
forwarded(x::Int64)::Int64 = (m = Box(1); try; setfield!(m, :a, mixed(x)); m.a; catch e; e isa TypeError && e.got === "q" ? -11 : -12; end)
# the same with no handler: the TypeError leaves the method (caught by the caller)
@noinline forwarded_bare(x::Int64)::Int64 = (m = Box(1); setfield!(m, :a, mixed(x)); m.a)
caller(x::Int64)::Int64 = try; forwarded_bare(x) * 10; catch e; e isa TypeError ? -21 : -22; end
end

const C = Cases

@testset "a return narrower than its value's inferred type is convert_julia_type's, as a PiNode's" begin
    # Julia's own IR: the return's value is the stored Union, the method's return type Int64
    local ci = only(code_typed(C.forwarded, (Int64,)))
    local r = findfirst(st -> st isa Core.ReturnNode && st.val isa Core.SSAValue && ci[1].ssavaluetypes[st.val.id] == Union{Int64,String}, ci[1].code)
    @test r !== nothing && ci[2] === Int64
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((C.forwarded, (4, -1)), (C.caller, (4, -1)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("return_narrowed/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    @test [c.native for c in cases] == [4, -11, 40, -21]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
