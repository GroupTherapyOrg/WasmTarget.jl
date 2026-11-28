# rethrow(e), Base.rethrow(::Any), whose body is the foreign call jl_rethrow_other (julia/src/task.c:810): it
# overwrites the exception on the top of the task's exception stack with e (:819) and rethrows it, pushing no
# entry. Inside a catch region the top is the exception that catch stashed (src/code_generator.jl visit_rethrow),
# so a later rethrow() of the same catch, after a nested region caught the replacement, throws the replacement.
# Each case's answer is native Julia's, compared in both modules.
module RethrowOtherTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module RethrowCases
kind(e)::Int64 = e isa ArgumentError ? 1 : e isa DomainError ? 2 : e isa ErrorException ? 4 : 3
# the replacement reaches the caller's catch
@noinline replaced(x::Int64)::Int64 = (try; error("orig"); catch; x > 0 && rethrow(DomainError(x)); end; Int64(0))
replace_top(x::Int64)::Int64 = try; replaced(x); catch e; kind(e) + 10 * Int64(e isa DomainError && e.val === x); end
# the replacement overwrites the outer catch's exception: a nested catch takes it, and the outer rethrow() throws it
@noinline function overwrite_outer(x::Int64)::Int64
    try; throw(ArgumentError("outer")); catch
        try; x > 1 && rethrow(DomainError(x)); catch; end
        rethrow()
    end
    return 0
end
overwritten(x::Int64)::Int64 = try; overwrite_outer(x); catch e; kind(e); end
# the replacement inside the nested region's own catch overwrites that region's exception, never the outer one
@noinline function overwrite_inner(x::Int64)::Int64
    try; throw(ArgumentError("outer")); catch
        try; throw(ErrorException("inner")); catch; try; rethrow(DomainError(x)); catch; end; end
        rethrow()
    end
    return 0
end
inner_only(x::Int64)::Int64 = try; overwrite_inner(x); catch e; kind(e); end
# rethrow(e) with no catch region of its own function: the top is the task's, which only run time knows;
# called from no catch, the stack is empty and Julia raises ErrorException (task.c:816)
@noinline outside(x::Int64)::Int64 = (x > 0 && rethrow(ArgumentError("a")); Int64(0))
outside_of(x::Int64)::Int64 = try; outside(x); catch e; kind(e); end
end

const RC = RethrowCases

@testset "rethrow(e) overwrites the top of Julia's exception stack" begin
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((RC.replace_top, (1, 0)), (RC.overwritten, (1, 2)), (RC.inner_only, (1,)), (RC.outside_of, (1, 0)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("rethrow_other/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    # native's answers: the replacement caught with its value, none thrown, the outer exception kept or overwritten,
    # Julia's ErrorException where the task's stack is empty
    @test [c.native for c in cases] == [12, 0, 1, 2, 1, 4, 0]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
