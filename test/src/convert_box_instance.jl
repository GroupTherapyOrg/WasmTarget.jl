# An invoke's value boxed by its callee's own return type, one rule for every visitor of an invoke
# (src/code_generator.jl translate_expression): Julia's emit_call_specfun_other (julia/src/codegen.cpp) marks an
# invoke's result with the callee's jlretty, which update_julia_type keeps where it is concrete, so a call the
# inliner union-split is typed by its callee's return type while the statement's is the Union. A callable struct's
# call (Kernel's InstanceInvocation, visit_instance_invocation) is checked here, test/src/convert_box.jl holds the
# static call's; each program's IR is checked to hold the invoke of that shape, each answer native Julia's in both
# modules.
module ConvertBoxInstanceTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module InstanceCases
@noinline maybe_i64(x::Int64) = x > 0 ? nothing : x
@noinline maybe_bool(x::Int64) = x > 0 ? nothing : iseven(x)
@noinline maybe_f64(x::Int64) = x > 0 ? nothing : x / 4
# callable structs carrying a field: each call an instance invocation of the struct as receiver; one struct a class,
# each of one method (methods of one callable over Union{Nothing,T} would all match nothing, an ambiguity)
struct PassI64; k::Int64; end
struct PassBool; k::Int64; end
struct PassF64; k::Int64; end
@noinline (p::PassI64)(r::Union{Nothing,Int64}) = r
@noinline (p::PassBool)(r::Union{Nothing,Bool}) = r
@noinline (p::PassF64)(r::Union{Nothing,Float64}) = r
code(r) = r === nothing ? Int64(-1) : r isa Int64 ? Int64(10) + r : r isa Bool ? Int64(30) + Int64(r) :
    r isa Float64 ? Int64(40) + Int64(floor(r * 4)) : Int64(-2)
inst_i64(x::Int64) = code(PassI64(x)(maybe_i64(x)))
inst_bool(x::Int64) = code(PassBool(x)(maybe_bool(x)))
inst_f64(x::Int64) = code(PassF64(x)(maybe_f64(x)))
end

const IC = InstanceCases

# an invoke of the callable struct S typed by the Union while its callee returns the class T
function split_instance_invoke(f, S, T)
    local ir = first(only(Base.code_ircode(f, (Int64,))))
    return any(enumerate(ir.stmts.stmt)) do (i, st)
        Meta.isexpr(st, :invoke) || return false
        local mi = st.args[1] isa Core.CodeInstance ? st.args[1].def : st.args[1]
        mi.specTypes.parameters[1] === S && ir.stmts.type[i] == Union{Nothing,T} &&
            last(only(Base.code_typed_by_type(mi.specTypes))) === T
    end
end

@testset "an instance invocation's value boxed by its callee's return type" begin
    @test split_instance_invoke(IC.inst_i64, IC.PassI64, Int64)
    @test split_instance_invoke(IC.inst_bool, IC.PassBool, Bool)
    @test split_instance_invoke(IC.inst_f64, IC.PassF64, Float64)
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((IC.inst_i64, (1, 0, -4)), (IC.inst_bool, (1, -4, -3)), (IC.inst_f64, (1, -6)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("convert_box_instance/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    # native's answers: each class read back by isa, nothing as -1
    @test [c.native for c in cases] == [-1, 10, 6, -1, 31, 30, -1, 34]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
