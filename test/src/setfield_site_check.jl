# A field written by a constant name or position on a receiver Julia left abstract (src/code_generator.jl
# visitInstanceSet), some class of which takes no such write: Julia's codegen writes no field of a Union or an
# abstract type and calls jl_f_setfield, whose get_checked_fieldindex checks the receiver's own type before it
# writes (julia/src/builtins.c:994), in its order: a Module, then an immutable struct ("setfield!: immutable struct of
# type <name> cannot be changed", whatever the field), then the field (BoundsError of the value and the position past
# its fields, FieldError of the type and a name it lacks), then a const field ("setfield!: const field .<f> of type
# <name> cannot be changed"); then jl_f_setfield's atomic check (:1068). The port raises each class's error at the
# site, before the setter selector's call, which admits only the classes holding a field the site may write
# (formal(dev/formal/MCFieldSelectorTableSetCheck.tla) SetCheckTraps). Each case's answer is native Julia's,
# compared in both modules.
module SetfieldSiteCheckTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module SetCases
abstract type Slot end
# field names no other class of the world holds: a field selector is named by its field
mutable struct Open <: Slot; tval::Int64; tnext::Int64; end
mutable struct Bare <: Slot; tother::Int64; end
struct Frozen <: Slot; tval::Int64; end
mutable struct Pinned <: Slot; const tval::Int64; tnext::Int64; end
mutable struct Watched <: Slot; @atomic tval::Int64; end
# the error's kind and payload: ErrorException's message, FieldError's type and name, BoundsError's value and
# position, ConcurrencyViolationError's message
# (a message's type is AbstractString: asserted String, as Julia's runtime makes it)
function _why(e)::Int64
    if e isa ErrorException
        local m = e.msg::String
        return m == "setfield!: immutable struct of type Frozen cannot be changed" ? -1 :
            m == "setfield!: immutable struct of type Nothing cannot be changed" ? -2 :
            m == "setfield!: immutable struct of type Tuple cannot be changed" ? -3 :
            m == "setfield!: const field .tval of type Pinned cannot be changed" ? -4 : -8
    end
    e isa FieldError && return e.type === Bare && e.field === :tval ? -5 : -10
    e isa BoundsError && return e.a isa Bare && e.i === 2 ? -6 : -11
    e isa ConcurrencyViolationError && return (e.msg::String) == "setfield!: atomic field cannot be written non-atomically" ? -7 : -12
    return -9
end
# an abstract receiver: Open takes the write; Bare lacks the name (FieldError), Frozen is immutable, Pinned's
# field is const
@noinline _slot(x::Int64)::Slot = x == 1 ? Open(x, 0) : x == 2 ? Bare(x) : x == 3 ? Frozen(x) : Pinned(x, 0)
function set_by_name(x::Int64)::Int64
    local s = _slot(x)
    try
        local r = setfield!(s, :tval, 7x)
        return s isa Open ? s.tval + r : 100
    catch e
        return _why(e)
    end
end
# a position: Open's and Pinned's second field is the settable tnext, Bare holds one field (BoundsError), and
# Frozen, which holds one too, raises its immutability first
function set_by_position(x::Int64)::Int64
    local s = _slot(x)
    try
        setfield!(s, 2, 5x)
        return s isa Open ? s.tnext : s isa Pinned ? s.tnext : 100
    catch e
        return _why(e)
    end
end
# Nothing's value, the null, is an immutable struct's
@noinline _maybe(x::Int64) = x > 0 ? Open(x, 0) : nothing
function set_maybe(x::Int64)::Int64
    local m = _maybe(x)
    try
        setfield!(m, :tval, 3x)
        return m isa Open ? m.tval : 100
    catch e
        return _why(e)
    end
end
# a tuple held as its record is a Tuple, immutable
@noinline _open_or_pair(x::Int64) = x > 0 ? Open(x, 0) : (x, 2x)
function set_pair(x::Int64)::Int64
    local v = _open_or_pair(x)
    try
        setfield!(v, :tval, 4x)
        return v isa Open ? v.tval : 100
    catch e
        return _why(e)
    end
end
# Frozen lacks the name and is immutable: Julia's mutability check comes first
@noinline _bare_or_frozen(x::Int64) = x > 0 ? Bare(x) : Frozen(x)
function set_frozen_lacks(x::Int64)::Int64
    local s = _bare_or_frozen(x)
    try
        setfield!(s, :tother, 6x)
        return s isa Bare ? s.tother : 100
    catch e
        return _why(e)
    end
end
# an atomic field written with no order: jl_f_setfield's atomic check (ConcurrencyViolationError)
@noinline _open_or_watched(x::Int64) = x > 0 ? Open(x, 0) : Watched(x)
function set_atomic(x::Int64)::Int64
    local s = _open_or_watched(x)
    try
        setfield!(s, :tval, 8x)
        return s isa Open ? s.tval : 100
    catch e
        return _why(e)
    end
end
end

const SC = SetCases

@testset "a setfield! a class of the receiver does not take raises at the site as jl_f_setfield does" begin
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((SC.set_by_name, (1, 2, 3, 4)), (SC.set_by_position, (1, 2, 3, 4)), (SC.set_maybe, (2, 0)),
                    (SC.set_pair, (2, -1)), (SC.set_frozen_lacks, (2, -1)), (SC.set_atomic, (2, -1)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("setfield_site_check/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    # native's answers: the write, FieldError of Bare, the immutable Frozen, Nothing and Tuple, Pinned's const
    # field, BoundsError past Bare's field, the atomic field
    @test [c.native for c in cases] == [14, -5, -1, -4, 5, -6, -1, 20, 6, -2, 8, -3, 12, -1, 16, -7]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
