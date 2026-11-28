# A String constant is the object the program's IR holds (src/julia/wasm_array.jl StringObject, src/constants.jl
# ensureConstant): equal literals are one object in Julia's IR and natively (julia/src/ircode.c:175 roots each String
# literal by content), a const binding's String is its own object, so their data ids differ natively. Each case's
# answer is native Julia's, compared in both modules.
module StringConstantsTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module StringConstantCases
const KS = "hello"
const KB = Vector{UInt8}(KS)
bits(bs::Bool...) = sum(Int64(b) << (i - 1) for (i, b) in enumerate(bs))
# a literal of KS's contents against KS: two objects natively, so two data ids
function literal_vs_const(x::Int64)::Int64
    local a = unsafe_wrap(Vector{UInt8}, x > 0 ? "hello" : "x")
    return bits(Base.mightalias(a, unsafe_wrap(Vector{UInt8}, KS)), Base.dataids(a) == Base.dataids(unsafe_wrap(Vector{UInt8}, KS)))
end
# two equal literals of one method: one object; a literal and the const: two; the const and a String made at run time
function equal_literals(x::Int64)::Int64
    local a = unsafe_wrap(Vector{UInt8}, x > 0 ? "hello" : "x")
    local b = unsafe_wrap(Vector{UInt8}, x > 0 ? "hello" : "y")
    local c = unsafe_wrap(Vector{UInt8}, KS)
    local d = unsafe_wrap(Vector{UInt8}, string("hel", "lo"[1:x+1]))
    return bits(Base.mightalias(a, b), Base.mightalias(a, c), Base.mightalias(c, d))
end
# equal literals of two methods: one object
@noinline lit1(x::Int64) = unsafe_wrap(Vector{UInt8}, x > 0 ? "worlds" : "a")
@noinline lit2(x::Int64) = unsafe_wrap(Vector{UInt8}, x > 0 ? "worlds" : "b")
literals_two_methods(x::Int64)::Int64 = Int64(Base.mightalias(lit1(x), lit2(x)))
# a const Vector made from KS's bytes against KS's wrap and a Vector of it: each its own data
const_vector(x::Int64)::Int64 =
    bits(Base.mightalias(KB, unsafe_wrap(Vector{UInt8}, KS)), Base.mightalias(KB, Vector{UInt8}(KS)), x > 0)
end

const SC = StringConstantCases

@testset "a String constant is the object the IR holds" begin
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((SC.literal_vs_const, (1, 2)), (SC.equal_literals, (1,)), (SC.literals_two_methods, (1, 2)), (SC.const_vector, (1, 2)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("string_constants/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    # native's answers: the literal and the const two data ids; two equal literals one, in one method or two
    @test [c.native for c in cases] == [0, 0, 1, 1, 1, 4, 4]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
