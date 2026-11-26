# convertType's box and unbox by a value's Julia class (src/translator.jl convert_type's boxed_class), where the
# class is no type the statement carries: Julia boxes a value by its own type (julia/src/cgutils.cpp:3794 boxed,
# vinfo.typ), an invoke's value typed by its callee's return type (julia/src/codegen.cpp emit_call_specfun_other's
# mark_julia_type(..., jlretty)), and unboxes a PhiNode's incoming value by the phi's type (emit_phinode's
# emit_unbox(ctx, VN->getType(), val, phiType)). Each case's answer is native Julia's, compared in both modules; a
# box of the wrong class answers a wrong `isa` or `typeof`.
module ConvertBoxTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module BoxCases
@noinline maybe_i64(x::Int64) = x > 0 ? nothing : x
@noinline maybe_u64(x::Int64) = x > 0 ? nothing : UInt64(-x)
@noinline maybe_bool(x::Int64) = x > 0 ? nothing : iseven(x)
@noinline maybe_f64(x::Int64) = x > 0 ? nothing : x / 4
@noinline maybe_char(x::Int64) = x > 0 ? nothing : Char(64 - x)
# one function a class, each of one method (methods of one function over Union{Nothing,T} would all match nothing,
# an ambiguity): the inliner union-splits each call, `invoke pass_i64(%6::Int64)::Union{Nothing,Int64}`, its value
# boxed by Int64, the specialization's rettype, as the corpus's _un_pass (test/smoke_corpus.jl:997)
@noinline pass_i64(r::Union{Nothing,Int64}) = r
@noinline pass_u64(r::Union{Nothing,UInt64}) = r
@noinline pass_bool(r::Union{Nothing,Bool}) = r
@noinline pass_f64(r::Union{Nothing,Float64}) = r
@noinline pass_char(r::Union{Nothing,Char}) = r
code(r) = r === nothing ? Int64(-1) : r isa Int64 ? Int64(10) + r : r isa UInt64 ? Int64(20) + Int64(r) :
    r isa Bool ? Int64(30) + Int64(r) : r isa Float64 ? Int64(40) + Int64(floor(r * 4)) : r isa Char ? Int64(50) + Int64(r) : Int64(-2)
split_i64(x::Int64) = code(pass_i64(maybe_i64(x)))
split_u64(x::Int64) = code(pass_u64(maybe_u64(x)))
split_bool(x::Int64) = code(pass_bool(maybe_bool(x)))
split_f64(x::Int64) = code(pass_f64(maybe_f64(x)))
split_char(x::Int64) = code(pass_char(maybe_char(x)))
# a loop's phi of type T whose incoming value is a Union{Nothing,T} Julia proved holds a T: unboxed by the phi's type
phi_i64(n::Int64) = (r = nothing; for i in 1:n; i == 2 && (r = i - 2); end; r === nothing ? -1 : r)
phi_u64(n::Int64) = (r = nothing; for i in 1:n; i == 2 && (r = UInt64(i + 5)); end; r === nothing ? -1 : Int64(r))
phi_bool(n::Int64) = (r = nothing; for i in 1:n; i == 2 && (r = isodd(n)); end; r === nothing ? -1 : Int64(r))
phi_f64(n::Int64) = (r = nothing; for i in 1:n; i == 2 && (r = n / 4); end; r === nothing ? -1.0 : r)
phi_char(n::Int64) = (r = nothing; for i in 1:n; i == 2 && (r = Char(64 + n)); end; r === nothing ? -1 : Int64(r))
end

const BC = BoxCases

@testset "a box and an unbox by the value's Julia class" begin
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((BC.split_i64, (1, 0, -4)), (BC.split_u64, (1, -4)), (BC.split_bool, (1, -4, -3)), (BC.split_f64, (1, -6)),
                    (BC.split_char, (1, -2)), (BC.phi_i64, (1, 3)), (BC.phi_u64, (1, 3)), (BC.phi_bool, (1, 3, 4)),
                    (BC.phi_f64, (1, 2)), (BC.phi_char, (1, 3)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("convert_box/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    # native's answers: each class read back by isa, nothing as -1
    @test [c.native for c in cases][1:5] == [-1, 10, 6, -1, 24]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
