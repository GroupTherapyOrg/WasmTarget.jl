# A field read by a constant name or position that is none of Julia's fields of the receiver's concrete type
# (src/code_generator.jl visitInstanceGet): Julia's codegen inlines no read (julia/src/codegen.cpp:4533, jl_field_index
# misses) and calls jl_f_getfield, which raises FieldError for a Symbol and BoundsError for an Int
# (julia/src/builtins.c:994 get_checked_fieldindex). Inference types such a read Union{}: Nothing's field on a union
# split's arm, a field only another subtype declares, a position past the last field. Each case's answer is native
# Julia's, compared in both modules.
module AbsentFieldTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module AbsentCases
mutable struct Node; next::Union{Nothing,Node}; v::Int64; end
abstract type Shape end
struct Wide <: Shape; a::Int64; b::Int64; end
struct Thin <: Shape; a::Int64; end
struct Pair2; x::Int64; y::Int64; end
_why(e) = e isa FieldError ? (e.field === :v ? -1 : e.field === :b ? -2 : -3) : e isa BoundsError ? -4 : -5
# the next node's value, a union split whose Nothing arm reads Nothing's `v`: FieldError natively at x == 1
function next_value(x::Int64)::Int64
    local n = Node(x > 1 ? Node(nothing, 10x) : nothing, x)
    try
        return n.next.v + n.v
    catch e
        return _why(e)
    end
end
# a field only one subtype declares, read on the other: FieldError natively at x == 1
@noinline _shape(x::Int64)::Union{Wide,Thin} = x > 1 ? Wide(x, 2x) : Thin(x)
function other_subtype_field(x::Int64)::Int64
    local s = _shape(x)
    try
        return s.b
    catch e
        return _why(e)
    end
end
# a position past the last field: BoundsError natively, at every x
@noinline _pair(x::Int64) = Pair2(x, x + 1)
function past_last_field(x::Int64)::Int64
    local p = _pair(x)
    try
        return getfield(p, 3)::Int64
    catch e
        return _why(e) * 100 + getfield(p, 2)
    end
end
end

const AC = AbsentCases

@testset "a field none of Julia's raises as jl_f_getfield does" begin
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((AC.next_value, (1, 2)), (AC.other_subtype_field, (1, 2)), (AC.past_last_field, (1, 2)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("absent_field/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    # native's answers: FieldError of Nothing's v and of Thin's b, BoundsError past Pair2's two fields
    @test [c.native for c in cases] == [-1, 22, -2, 4, -398, -397]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
