# A byte Memory a String takes (julia/src/genericmemory.c:189 jl_genericmemory_to_string, src/intrinsics.jl's lowering
# of it): Julia leaves the Memory of length 0 (:198), on every branch, so a later read or write through it fails its
# bounds check, and the String keeps the bytes it took. Each case's answer is native Julia's, compared in both modules.
module MemoryTakeTest
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module TakeCases
pack(v) = foldl((a, c) -> a * 256 + Int64(c), v; init = Int64(length(v)))
cs(s::String) = pack(codeunits(s))
# the Memory a Vector's String took: its length, then a write through it (BoundsError natively, the String unchanged)
function take_vector(x::Int64)::Int64
    local v = UInt8[0x61, 0x62, UInt8(0x60 + x)]
    local m = v.ref.mem
    local s = String(v)
    local r = length(m)
    try
        m[1] = 0x5a
    catch e
        return -(cs(s) * 10 + r)
    end
    return cs(s) * 10 + r
end
# unsafe_takestring of a StringMemory (its bytes a String's, the owner returned), then the Memory's length
function takestring_memory(x::Int64)::Int64
    local m = Base.StringMemory(3)
    m[1] = 0x61; m[2] = 0x62; m[3] = UInt8(0x60 + x)
    local s = Base.unsafe_takestring(m)
    return cs(s) * 10 + length(m)
end
# a read through the taken Memory: BoundsError natively, -1
function read_after_take(x::Int64)::Int64
    local m = Memory{UInt8}(undef, 2 + x)
    fill!(m, 0x61)
    local s = Base.unsafe_takestring(m)
    try
        return Int64(m[1])
    catch e
        return e isa BoundsError ? Int64(-1) - 10 * ncodeunits(s) : Int64(-2)
    end
end
# the Vector after its String: empty, then grown by resize! and push!, its new bytes its own, the String unchanged
function grow_after_take(x::Int64)::Int64
    local v = UInt8[0x61, 0x62, UInt8(0x60 + x)]
    local s = String(v)
    local n0 = length(v)
    resize!(v, 2)
    v[1] = 0x41; v[2] = 0x42
    push!(v, 0x43)
    return cs(s) * 1000 + n0 * 100 + pack(v) % 100
end
# a second String of the emptied Vector: the empty String
function take_twice(x::Int64)::Int64
    local v = UInt8[0x61, UInt8(0x60 + x)]
    local s1 = String(v)
    local s2 = String(v)
    return cs(s1) * 10 + ncodeunits(s2)
end
# take! of an IOBuffer twice, each taken as a String
function iobuffer_take_twice(x::Int64)::Int64
    local io = IOBuffer()
    write(io, UInt8(0x60 + x), 0x62)
    local a = String(take!(io))
    write(io, 0x63)
    local b = String(take!(io))
    return cs(a) * 100000 + cs(b)
end
end

const TC = TakeCases

@testset "a byte Memory a String takes is left of length 0" begin
    local cases = Main.WTChild.RunCase[]
    for (f, xs) in ((TC.take_vector, (1, 2)), (TC.takestring_memory, (1, 2)), (TC.read_after_take, (1,)),
                    (TC.grow_after_take, (1, 2)), (TC.take_twice, (1,)), (TC.iobuffer_take_twice, (1,)))
        local (p, o) = Main.WTVerdict._modules(WasmTarget.compile, f, (Int64(1),))
        for x in xs
            push!(cases, Main.WTChild.RunCase("memory_take/$(nameof(f))($x)", p, (Int64(x),), Main.WTChild.native_answer(f, (Int64(x),)); optimized = o))
        end
    end
    # native's answers: the Memory's length 0 after each take, a write and a read through it BoundsError
    @test [c.native for c in cases][1:5] == [-567138250, -567138260, 567138250, 567138260, -31]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
