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
    # outside a compilation both queries infer
    @test WasmTarget.get_typed_ir(_wt_oip_b, (Int,))[2] === Int
    @test length(WasmTarget.get_typed_ir(Tuple{typeof(_wt_oip_a), Int})) == 1
end
