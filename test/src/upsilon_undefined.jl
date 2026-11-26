# An Upsilon with no value, a variable undefined on an exception edge: Julia's codegen stores nothing (julia/src/codegen.cpp:6060
# emit_upsilonnode, "the value from this upsilon node is not dynamically observed"), its PhiC's read guarded by the
# variable's definedness. Each case's answer is native Julia's, compared in both modules.
module UpsilonUndefinedTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module UpsilonCases
# a variable assigned in try, read in catch and in finally: undefined on the edge before its assignment
function late_in_try(n::Int64)::Int64
    local x::Int64
    local r1 = false
    try
        x = 10n
        n > 0 && throw(ErrorException("foo"))
    catch
        r1 = x == 10n
    end
    local y::Int64
    local r2 = false
    try
        y = 10n
    finally
        r2 = y == 10n
    end
    return Int64(r1) + 2 * Int64(r2)
end
# a variable read in catch, assigned only after a call that may throw: undefined there, UndefVarError natively
function undef_in_catch(n::Int64)::Int64
    local x::Int64
    local r = Int64(0)
    try
        n > 1 && throw(ErrorException("early"))
        x = n
        n > 0 && throw(ErrorException("late"))
    catch
        r = try; x; catch e; e isa UndefVarError ? Int64(-1) : Int64(-2); end
    end
    return r
end
# a reference variable undefined on the edge: its register a null the read never observes
function late_ref_in_try(n::Int64)::Int64
    local s::String
    local r = Int64(0)
    try
        n > 1 && throw(ErrorException("early"))
        s = string(n)
        throw(ErrorException("late"))
    catch
        r = n > 1 ? Int64(-1) : Int64(ncodeunits(s))
    end
    return r
end
end

const UC = UpsilonCases

@testset "an Upsilon with no value stores nothing" begin
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((UC.late_in_try, (1, 0)), (UC.undef_in_catch, (1, 2)), (UC.late_ref_in_try, (1, 2)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("upsilon_undefined/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    @test [c.native for c in cases] == [3, 2, 1, -1, 1, -1]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
