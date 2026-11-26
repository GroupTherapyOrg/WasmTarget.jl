# A field read by a constant name or position on a receiver Julia left abstract (src/code_generator.jl
# visitInstanceGet), some class of which holds no such field: Julia's codegen reads no field of a Union or an abstract
# type and calls jl_f_getfield, whose get_checked_fieldindex checks the field against the value's own type before it
# reads (julia/src/builtins.c:994), a name jl_field_index does not find raising FieldError of the type and the name
# (julia/src/rtutils.c:169 jl_has_no_field_error), a position past its fields BoundsError of the value and the
# position (:1006). The port checks at the site, before the field's selector call, which admits only the classes
# holding the field (formal(dev/formal/MCFieldSelectorTableSiteCheck.tla) SiteCheckTraps). Each case's answer is native
# Julia's, compared in both modules.
module FieldSiteCheckTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module SiteCases
abstract type Shape end
# field names no other class of the world holds: a field selector is named by its field
struct Wide <: Shape; sfirst::Int64; ssecond::Int64; end
struct Thin <: Shape; sfirst::Int64; end
# the error's kind and payload: FieldError's type and name, BoundsError's value and position
_why(e) = e isa FieldError ? (e.type === Thin ? -1 : e.type === Nothing ? -2 : e.type === Tuple{Int64,Int64} ? -3 : -4) * (e.field === :ssecond ? 1 : 10) :
          e isa BoundsError ? (e.i === 2 && e.a isa Thin ? -5 : -6) : -9
# a union receiver one member of which lacks the named field (FieldError of Thin at x < 1)
@noinline _wt(x::Int64) = x > 0 ? Wide(x, 2x) : Thin(x)
function second_by_name(x::Int64)::Int64
    try
        return getfield(_wt(x), :ssecond)::Int64
    catch e
        return _why(e)
    end
end
# a name every class of the receiver holds: no check, the selector's call alone
first_by_name(x::Int64)::Int64 = getfield(_wt(x), :sfirst)::Int64
# an abstract receiver, its subtype without the field (FieldError of Thin at x < 1)
@noinline _shape(x::Int64)::Shape = x > 0 ? Wide(x, 3x) : Thin(x)
function shape_second(x::Int64)::Int64
    try
        return getfield(_shape(x), :ssecond)::Int64
    catch e
        return _why(e)
    end
end
# Nothing's value, the null, has no field (FieldError of Nothing at x < 1)
@noinline _maybe(x::Int64) = x > 0 ? Wide(x, 4x) : nothing
function maybe_second(x::Int64)::Int64
    try
        return getfield(_maybe(x), :ssecond)::Int64
    catch e
        return _why(e)
    end
end
# a tuple held as its record has no named field: FieldError of its tuple type at x < 1
@noinline _wide_or_pair(x::Int64) = x > 0 ? Wide(x, 5x) : (x, 2x)
function pair_second(x::Int64)::Int64
    try
        return getfield(_wide_or_pair(x), :ssecond)::Int64
    catch e
        return _why(e)
    end
end
# a name and a position read on one receiver: the name every class holds, the position past Thin's one field
# (BoundsError of the Thin and 2 at x < 1)
function name_and_position(x::Int64)::Int64
    local s = _shape(x)
    try
        return getfield(s, :sfirst)::Int64 + getfield(s, 2)::Int64
    catch e
        return _why(e)
    end
end
end

const SC = SiteCases

@testset "a field none of the receiver's class holds raises at the site as jl_f_getfield does" begin
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((SC.second_by_name, (3, 0)), (SC.first_by_name, (3, -2)), (SC.shape_second, (2, -1)),
                    (SC.maybe_second, (2, 0)), (SC.pair_second, (2, -1)), (SC.name_and_position, (2, 0)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("field_site_check/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    # native's answers: FieldError of Thin, Nothing and Tuple{Int64,Int64} for `ssecond`, BoundsError past Thin's field
    @test [c.native for c in cases] == [6, -1, 3, -2, 6, -1, 8, -2, 10, -3, 8, -5]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
