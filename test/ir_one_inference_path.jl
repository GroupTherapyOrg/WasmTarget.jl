using Test
using WasmTarget

# Inside a compilation the collected closed world's IR is the only IR: codegen reads it through
# the plan (plan_ir), and a MethodInstance outside the world is an error, never a second
# inference (which would run another interpreter, at another world, in another cache partition).
# L152 keeps codegen off every other IR source. Outside a compilation, get_typed_ir is a
# person's inspection and infers.
_wt_oip_a(x::Int) = x + 1
_wt_oip_b(x::Int) = x * 2

@testset "one inference path inside a collected world" begin
    plan = WasmTarget.trim_compile_plan(Any[(_wt_oip_a, (Int,), "a")])
    mi_a = only(fn[4] for fn in plan.functions if fn[3] == "a")
    ci, rt = WasmTarget.plan_ir(plan, mi_a)
    @test ci === plan.ir_cache[mi_a][1]                                   # served, not re-inferred
    mi_b = WasmTarget.entry_method_instance(_wt_oip_b, (Int,))
    @test_throws ErrorException WasmTarget.plan_ir(plan, mi_b)            # outside the world
    @test WasmTarget.plan_ir_or_nothing(plan, mi_b) === nothing           # a miss by design, no inference
    # every per-function fact the plan holds is keyed by MethodInstance, one key per function
    @test keytype(plan.ir_cache) === Core.MethodInstance
    @test Set(keys(plan.ir_cache)) == Set(fn[4] for fn in plan.functions)
    @test eltype(plan.candidate_mis) === Core.MethodInstance
    @test keytype(plan.bespoke) === Core.MethodInstance
    # outside a compilation both queries infer
    @test WasmTarget.get_typed_ir(_wt_oip_b, (Int,))[2] === Int
    @test length(WasmTarget.get_typed_ir(Tuple{typeof(_wt_oip_a), Int})) == 1
end

# A closure body called statically and through an `Any` slot is both the target of the :invoke
# naming its MethodInstance and a dispatch candidate: the plan keys candidates by MethodInstance,
# where a key of (callee, planned argument types) missed every closure body (its function's
# argument types start with the closure type).
@testset "a closure body invoked and a dispatch candidate" begin
    f = (n::Int64) -> (k = n; g = @noinline((x::Int64) -> x + k); a = g(1); fs = Any[g]; a * 100 + (fs[1](2)::Int64))
    plan = WasmTarget.trim_compile_plan(Any[(f, (Int64,), "f")])
    entry = only(fn[4] for fn in plan.functions if fn[3] == "f")
    invoked = Set(s.args[1] isa Core.CodeInstance ? s.args[1].def : s.args[1]
                  for s in WasmTarget.plan_ir(plan, entry)[1].code if s isa Expr && s.head === :invoke)
    bodies = [fn[4] for fn in plan.functions if fn[1] isa DataType && WasmTarget.is_closure_type(fn[1])]
    @test length(bodies) == 1
    @test only(bodies) in invoked
    @test only(bodies) in plan.candidate_mis
end

# An entry's MethodInstance is Julia's match, its static parameters' values included, also when
# the program is compiled before any native call made that specialization (the empty-sparams
# MethodInstance inferred `sizeof(T)` over an unknown T).
_wt_oip_pe(x::T) where {T<:Integer} = sizeof(T) + x
@testset "an entry's static parameters are Julia's" begin
    mi = WasmTarget.entry_method_instance(_wt_oip_pe, (Int64,))
    @test mi.sparam_vals == Core.svec(Int64)
    @test WasmTarget.compile_multi(Any[(_wt_oip_pe, (Int64,), "pe")]) isa Vector{UInt8}
    @test _wt_oip_pe(3) == 11
end
