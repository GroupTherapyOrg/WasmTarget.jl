# The link-time check of the program's type values beside a run-time type test (src/julia/runtime/rtutils.jl
# check_run_time_type_values): an apply_type operand compile time knows, the UnionAll `RtvFoo` of `RtvFoo{T}`, is a
# key of the statement's cache (src/julia/classes.jl apply_type_cache), never a run-time value, so the program
# compiles and answers as native; the same UnionAll held as a value a run-time test may meet still rejects, located.
# The program is dart_is/is4's shape: Foo{T} made at run time, its methods testing values against T.
module RunTimeTypeValues
using Test, WasmTarget
const W = WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
struct RtvFoo{T} end
rtv_is_t(::RtvFoo{T}) where {T} = "a string" isa T
rtv_is_list_t(::RtvFoo{T}) where {T} = Int64[0, 1, 2] isa Vector{<:T}
rtv_all(o) = Int64(rtv_is_t(o)) + 2 * Int64(rtv_is_list_t(o))
# RtvFoo{T} made at run time (apply_type, its head the UnionAll RtvFoo a compile-time key), beside a run-time type test
# of a type value only run time knows
@noinline rtv_value_at(k::Int64)::Any = k == 1 ? Int64(1) : "a"
rtv_elt(j::Int64) = j == 1 ? Int64 : String
rtv_main(n::Int64) = rtv_all(RtvFoo{n == 1 ? String : Int64}()) * 10 + Int64(isa(rtv_value_at(n), rtv_elt(n + 1)))
# the UnionAll RtvFoo returned as a value, beside the same run-time test: a value the runtime's test could meet
@noinline rtv_wrapper_at(j::Int64)::Any = j == 1 ? RtvFoo : Int64
rtv_held(n::Int64) = rtv_main(n) + (rtv_wrapper_at(n) === Int64 ? 2 : 0)
@testset "check_run_time_type_values: an apply_type operand compile time knows is a key, never a run-time value" begin
    local (p, o) = Main.WTVerdict._modules(W.compile, rtv_main, (Int64(1),))
    local cases = [Main.WTChild.RunCase("rtv_main($n)", p, (n,), Main.WTChild.native_answer(rtv_main, (n,)); optimized = o) for n in (Int64(1), Int64(2))]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
    local e = try; W.compile(rtv_held, (Int64,)); nothing; catch x; x; end
    @test (e isa W.RejectionError && e.rejection isa W.Unquarantined &&
           startswith(e.rejection.row, "src/julia/runtime/rtutils.jl run_time_type_gap: the type $(RtvFoo), a UnionAll")) ||
          (@info "rtv_held" e === nothing ? "compiled" : sprint(showerror, e); false)
end
end
