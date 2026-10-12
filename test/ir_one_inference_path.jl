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

# Codegen asks no inference (L152): every return type it needs (a callee's, an unused :invoke's,
# a joined box read's) is the plan's, computed in collection. The one inference entry is stubbed
# to count its calls: collection asks it (the box analyses' return types), the compile of the
# plan never does, and an unused :invoke's type is its MethodInstance's rettype in the plan.
_wt_oip_box(n::Int64) = (s = 0; foreach(i -> (s += i), 1:n); s)
@noinline _wt_oip_side(x::Int64) = (Base.donotdelete(x); x + 1)
_wt_oip_unused(n::Int64) = (_wt_oip_side(n); n * 2)
@testset "codegen asks no inference; an unused :invoke reads the plan's rettype" begin
    local calls = Ref(0)
    # every inference a WasmInterpreter runs, through any entry (Base.infer_return_type, typeinf,
    # code_typed) and cached or not, asks its cache partition: its queries are counted too
    local queries = Ref(0)
    local original = which(WasmTarget.infer_return_type, Tuple{Any, Tuple})
    try
        @eval WasmTarget function infer_return_type(@nospecialize(f), argtypes::Tuple;
                                                    interp::WasmInterpreter=get_wasm_interpreter())::Type
            $(calls)[] += 1
            return Base.infer_return_type(f, Tuple{argtypes...}; interp=interp)
        end
        @eval WasmTarget CC.cache_owner(interp::WasmInterpreter) = ($(queries)[] += 1; interp.cache_token)
        local plan = Base.invokelatest(WasmTarget.trim_compile_plan,
                                       Any[(_wt_oip_box, (Int64,), "box"), (_wt_oip_unused, (Int64,), "unused")])
        @test calls[] > 0                                 # collection asks Julia's inference
        @test queries[] > 0
        calls[] = 0
        queries[] = 0
        @test Base.invokelatest(WasmTarget._compile_closed_world_plan, plan) isa WasmTarget.WasmModule
        @test calls[] == 0                                # the compile of the plan asks none
        @test queries[] == 0                              # and runs no inference of any entry
        # every planned body's joins are the plan's, keyed by MethodInstance
        @test Set(keys(plan.joins)) == Set(fn[4] for fn in plan.functions)
        # the unused `_wt_oip_side(n)` reads `::Any` in its caller's IR; the type codegen gives
        # it is the return type of the function it calls, registered with the plan's rettype
        local unused = [s.node.mi for fn in plan.functions
                        for s in WasmTarget.build_nir(WasmTarget.plan_ir(plan, fn[4])[1])
                        if s.node isa WasmTarget.NirInvoke && s.julia_type === Any]
        @test any(mi -> mi.def.name === :_wt_oip_side, unused)
        @test all(mi -> WasmTarget.plan_ir(plan, mi)[2] === Int64, unused)
    finally
        Base.delete_method(only(m for m in methods(WasmTarget.infer_return_type) if m !== original))
        @eval WasmTarget CC.cache_owner(interp::WasmInterpreter) = interp.cache_token   # interpreter.jl's
    end
    @test which(WasmTarget.infer_return_type, Tuple{Any, Tuple}) === original
end

# The caller's context types the unused `_wt_oip_side_s("ab")`, which reads `::Any` in its IR, by
# the return type of the function its MethodInstance compiles to (get_function_by_mi): for a planned
# body that is registered with its rettype in the plan. Its operand is a String, so no numeric
# join types it: the context's seeding does.
@noinline _wt_oip_side_s(s::String) = (Base.donotdelete(s); ncodeunits(s))
_wt_oip_unused_s(n::Int64) = (_wt_oip_side_s("ab"); n * 2)
@testset "an unused :invoke's type in its caller's context is its callee's registered return type" begin
    local plan = WasmTarget.trim_compile_plan(Any[(_wt_oip_unused_s, (Int64,), "unused")])
    local mod, treg, freg, _ = WasmTarget._compile_closed_world_plan(plan; return_registries=true)
    local fn = only(fn for fn in plan.functions if fn[3] == "unused")
    local src, rt = WasmTarget.plan_ir(plan, fn[4])
    local body = WasmTarget.nir_body(src)
    local idx = findfirst(s -> s.node isa WasmTarget.NirInvoke && s.julia_type === Any &&
                               s.node.mi.def.name === :_wt_oip_side_s, body.stmts)
    @test idx !== nothing
    local callee = body.stmts[idx].node.mi
    local ctx = WasmTarget.CompilationContext(body, fn[2], rt, mod, treg;
                                              translator=WasmTarget.Translator(plan, nothing),
                                              func_registry=freg, mi=fn[4])
    @test ctx.ssa_types[idx] === WasmTarget.get_function_by_mi(freg, callee).return_type
    @test ctx.ssa_types[idx] === WasmTarget.plan_ir(plan, callee)[2] === Int64
end

# One reader of what a node is (L174): value_type is Julia's argextype (Compiler optimize.jl:423 on 1.12.7, :502 on 1.13.1),
# widened. For every call/invoke/new operand of every planned body of a program holding SSA values,
# arguments, literals, a type literal, quoted symbols and constant globals, the reader's answer (the
# boundary's SSA types, no join) is Compiler's argextype of the raw operand, widened.
const _WT_OIP_TABLE = [10, 20, 30]
_wt_oip_mix(n::Int64) = (s = string(n, :k, 'c'); v = n > 0 ? _WT_OIP_TABLE : Int64[];
                         Float64(length(s) + sum(v)) + (n isa Integer ? 1.5 : 0.0))
@testset "value_type is Julia's argextype" begin
    local CC = Core.Compiler
    local plan = WasmTarget.trim_compile_plan(Any[(_wt_oip_mix, (Int64,), "mix")])
    local compared = 0
    local kinds = Set{Symbol}()
    for fn in plan.functions
        local src = WasmTarget.plan_ir(plan, fn[4])[1]
        local nir = WasmTarget.build_nir(src)
        local slots = WasmTarget.nir_slot_types(src)
        for stmt in src.code
            (stmt isa Expr && stmt.head in (:call, :invoke, :new)) || continue
            for x in stmt.args[(stmt.head === :invoke ? 3 : 2):end]
                (x isa Expr || x isa Core.SlotNumber) && continue
                local node = WasmTarget.resolve_operand(x, nir)
                local julia = CC.widenconst(CC.argextype(x, src, CC.VarState[]))
                @test WasmTarget.value_type(node, slots, nothing) == julia
                push!(kinds, nameof(typeof(node)))
                compared += 1
            end
        end
    end
    @test compared > 100
    @test kinds ⊇ Set([:NirSSA, :NirArgument, :NirLiteral, :NirGlobalRef])
end
