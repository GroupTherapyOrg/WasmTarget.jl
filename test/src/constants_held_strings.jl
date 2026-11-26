# An immutable constant is keyed by its value with each String it holds by its object (src/julia/wasm_array.jl
# HeldStrings, src/constants.jl ensureConstant), as a String constant is (StringObject): two egal tuples holding equal
# Strings that are two objects are two constants, each with its own Strings. Keyed by `===` alone they were one, whose
# children were the first tuple's Strings, and a Box whose field of type Any holds the second boxed it into its record
# from its own Strings inside the Box's eager initializer: a String constant created while another constant was, the
# rejection at dart2wasm/lib/constants.dart:2196 (`held_in_box` below rejected so, in both modules, before the key).
# Each case's answer is native Julia's, compared in both modules.
module ConstantsHeldStringsTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module HeldStringCases
struct Box
    x::Any
end
struct P
    s::String
end
const S1 = "ab"
const S2 = string('a', 'b')     # equal contents, another object
const T1 = (S1, 1)
const T2 = (S2, 1)              # egal to T1, holding S2
const B = Box(T2)
const P1 = P(S1)
const P2 = P(S2)
bits(bs::Bool...) = sum(Int64(b) << (i - 1) for (i, b) in enumerate(bs))
# T1 used, then a Box holding T2 at its field of type Any: T2 boxed into its record inside B's initializer
function held_in_box(n::Int64)::Int64
    local y = n > 0 ? T1 : ("zz", 2)
    local x = n > 1 ? Box(nothing) : B
    return ncodeunits(y[1]) + (x.x isa Tuple{String,Int} ? 10 : 0)
end
# the two tuples' Strings are two objects (two data ids), the tuples and the Strings egal and equal
function tuples_two_objects(n::Int64)::Int64
    local a = n > 0 ? T1 : ("q", 3)
    local b = n > 0 ? T2 : ("r", 4)
    return bits(Base.mightalias(unsafe_wrap(Vector{UInt8}, a[1]), unsafe_wrap(Vector{UInt8}, b[1])), a === b, a[1] == b[1])
end
# the same of two immutable structs
function structs_two_objects(n::Int64)::Int64
    local a = n > 0 ? P1 : P("q")
    local b = n > 0 ? P2 : P("r")
    return bits(Base.mightalias(unsafe_wrap(Vector{UInt8}, a.s), unsafe_wrap(Vector{UInt8}, b.s)), a === b, a.s == b.s)
end
end

const HS = HeldStringCases

@testset "an immutable constant is keyed with the objects of the Strings it holds" begin
    @test HS.T1 === HS.T2 && pointer_from_objref(HS.S1) != pointer_from_objref(HS.S2)
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((HS.held_in_box, (1, 2)), (HS.tuples_two_objects, (1, 0)), (HS.structs_two_objects, (1, 0)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("constants_held_strings/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    # native's answers: the box read (12, 2); the Strings two objects, egal and equal (6), other contents none (0)
    @test [c.native for c in cases] == [12, 2, 6, 0, 6, 0]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
