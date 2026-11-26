# setfield! through jl_f_setfield's checks (julia/src/builtins.c:1057, get_checked_fieldindex :994): an immutable
# struct's write raises ErrorException whatever the field; a name only run time knows is the switch over the field
# names getfield shares (FieldError, BoundsError past it); a const field raises ErrorException; a value outside the
# field's type raises TypeError(:setfield!), tested at run time where its type overlaps the field's. Each case's answer
# is native Julia's, compared in both modules.
module SetfieldCheckedTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module SetCases
struct Imm; x::Int64; y::Int64; end
mutable struct Mut; a::Int64; const b::Int64; c::String; d::Float64; end
mk() = Mut(1, 2, "s", 1.5)
@noinline pick(x::Int64) = x > 2 ? :a : x > 0 ? :b : x > -5 ? :c : :z
@noinline mixed(x::Int64)::Union{Int64,String} = x > 0 ? x : "q"
# the error's own fields, checked as native Julia gives them, inline where the exception is caught: the caught
# value is of type Any, so a function of it would be a call no method resolves, outside the subset Julia's
# verifier defines; Strings compared by ===, Julia's egal of their contents
macro code(e)
    esc(:($e isa FieldError ? ($e.type === Mut && $e.field === :z ? -7 : -70) :
          $e isa BoundsError ? ($e.a isa Mut ? -8 : -80) :
          $e isa TypeError ? ($e.func === :setfield! && $e.got === 7 && ($e.expected === String || $e.expected === Float64) ? -9 : -90) :
          $e isa ErrorException ? ($e.msg === "setfield!: const field .b of type Mut cannot be changed" ? -3 :
                                   $e.msg === "setfield!: immutable struct of type Imm cannot be changed" ? -4 :
                                   $e.msg === "setfield!: immutable struct of type Tuple cannot be changed" ? -5 : -30) : -100))
end
# a name only run time knows: the field written, or Julia's raise; setfield!'s value is the value written
function by_name(x::Int64)::Int64
    local m = mk()
    try
        local r = setfield!(m, pick(x), 7)
        return 1000 * r + m.a
    catch e
        return @code(e)
    end
end
# an index only run time knows: past the count BoundsError, the const field ErrorException, a String or a Float64
# field TypeError
function by_index(x::Int64)::Int64
    local m = mk()
    try
        setfield!(m, x, 7)
        return m.a
    catch e
        return @code(e)
    end
end
# an immutable struct and a tuple: ErrorException whatever the name, whether compile time or run time knows it
imm_name(x::Int64)::Int64 = try; setfield!(Imm(x, 2), pick(x), 5); 0; catch e; @code(e); end
imm_const(x::Int64)::Int64 = try; setfield!(Imm(x, 2), :x, 5); 0; catch e; @code(e); end
tuple_const(x::Int64)::Int64 = try; setfield!((x, 2), 1, 3); 0; catch e; @code(e); end
# a const field named at compile time
const_field(x::Int64)::Int64 = (m = mk(); try; setfield!(m, :b, x); 0; catch e; @code(e); end)
# a value whose type overlaps the field's: tested at run time, written where it is one; the field read back by a
# call, since Julia's optimizer would forward the stored Union value to the return (a narrowing WasmTarget's return
# does not unbox: cleanup/H.md)
@noinline geta(m::Mut)::Int64 = m.a
overlap(x::Int64)::Int64 = (m = mk(); try; setfield!(m, :a, mixed(x)); geta(m); catch e; e isa TypeError && e.expected === Int64 && e.got === "q" ? -11 : -12; end)
# a name compile time knows is codegen's arm (julia/src/codegen.cpp:3776-3827): the value's type is checked before
# the immutable struct and the const field; a name none of Julia's fields is jl_f_setfield's, the immutable struct first
macro typed(e)
    esc(:($e isa TypeError && $e.func === :setfield! && $e.expected === Int64 && $e.got === "s" ? -6 : -60))
end
imm_typed(x::Int64)::Int64 = try; setfield!(Imm(x, 2), :x, "s"); 0; catch e; @typed(e); end
const_typed(x::Int64)::Int64 = (m = mk(); try; setfield!(m, :b, "s"); 0; catch e; @typed(e); end)
absent_name(x::Int64)::Int64 = (m = mk(); try; setfield!(m, :z, x); 0; catch e; @code(e); end)
absent_index(x::Int64)::Int64 = (m = mk(); try; setfield!(m, 9, x); 0; catch e; @code(e); end)
imm_absent(x::Int64)::Int64 = try; setfield!(Imm(x, 2), :z, 5); 0; catch e; @code(e); end
# getfield of a varargs pack, a tuple of a type only run time knows, by a Symbol: FieldError of the value's own type
@noinline va(s::Symbol, xs...) = getfield(xs, s)
va_name(x::Int64)::Int64 = try; va(pick(x), x, 2); 0; catch e; e isa FieldError && e.type === Tuple{Int64,Int64} && e.field === pick(x) ? 21 : 22; end
end

const SC = SetCases

@testset "setfield! is jl_f_setfield's checks, a run-time name the switch getfield shares" begin
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((SC.by_name, (3, 1, -1, -6)), (SC.by_index, (1, 2, 3, 4, 5, 0)), (SC.imm_name, (3, -6)),
                    (SC.imm_const, (1,)), (SC.tuple_const, (1,)), (SC.const_field, (1,)), (SC.overlap, (4, -1)), (SC.va_name, (3,)),
                    (SC.imm_typed, (1,)), (SC.const_typed, (1,)), (SC.absent_name, (1,)), (SC.absent_index, (1,)), (SC.imm_absent, (1,)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("setfield_checked/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    # native's answers: each arm, each raise
    @test [c.native for c in cases] == [7007, -3, -9, -7, 7, -3, -9, -9, -8, -8, -4, -4, -4, -5, -3, 4, -11, 21, -6, -6, -7, -8, -4]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
