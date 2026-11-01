# The String data operations (src/julia/wasm_array.jl), dart:_wasm's WasmArray operations on a String's
# code units: natively each answers as Julia does, which an overlay written with them relies on.
module WasmArrayStringTest

using Test
using WasmTarget

const W = WasmTarget

@testset "wasm_array.jl: a String's data, natively" begin
    for s in ("", "ab", "héllo", "日本語", repeat("é", 300))
        @test W.wasm_string_length(s) == ncodeunits(s) == sizeof(s)
        @test [W.wasm_string_codeunit(s, i) for i in 0:ncodeunits(s) - 1] == collect(codeunits(s))
    end
    # concatenation as Base's _string makes it: a fresh String, the bytes copied in
    local a, b = "héllo", " 世界"
    local t = W.wasm_string_alloc(ncodeunits(a) + ncodeunits(b))
    W.wasm_string_copy!(t, 0, a, 0, ncodeunits(a))
    W.wasm_string_copy!(t, ncodeunits(a), b, 0, ncodeunits(b))
    @test t == a * b && ncodeunits(t) == ncodeunits(a) + ncodeunits(b)
end

end

# a memory's element copy (wasm_memory_copy!), which Base's unsafe_copyto! of two MemoryRefs is by
# overlay (src/patch/genericmemory.jl): natively Base's copy, overlapping ranges included; compiled,
# push! growing a Vector of each kind of element (bits, a reference, one admitting nothing with its set
# flags) past its memory several times, and Julia's egal of two MemoryRefs (an offset and a memory)
module WasmArrayMemoryTest
using Test, WasmTarget
isdefined(Main, :WTRunner) || Base.include(Main, joinpath(@__DIR__, "..", "runner.jl"))
const WTRunner = Main.WTRunner
const W = WasmTarget
function memory(k::Int64, n::Int64)
    if k == 1
        local v = Int64[]
        for i in 1:n; push!(v, i); end
        return v[end] + 100 * length(v)
    elseif k == 2
        local s = String[]
        for i in 1:n; push!(s, isodd(i) ? "a" : "bcd"); end
        return Int64(ncodeunits(s[end])) + 100 * length(s)
    elseif k == 3
        local u = Union{Nothing,String}[]
        for i in 1:n; push!(u, isodd(i) ? nothing : "x"); end
        return Int64(u[end] === nothing) + 10 * Int64(u[1] === nothing) + 100 * length(u)
    end
    local m = Memory{Int64}(undef, 4)
    local r = Core.memoryrefnew(Core.memoryrefnew(m), n)
    return Int64(r === Core.memoryrefnew(Core.memoryrefnew(m), 2)) + 2 * Int64(r === Core.memoryrefnew(Core.memoryrefnew(Memory{Int64}(undef, 4)), n))
end
@testset "wasm_array.jl: a memory's elements copied, natively and as push! grows a Vector" begin
    local a = Memory{Union{Nothing,String}}(undef, 6)
    a[1] = "p"; a[2] = nothing; a[3] = "q"
    # overlapping, forwards: Base's copy keeps an unset element unset
    W.wasm_memory_copy!(Core.memoryrefnew(Core.memoryrefnew(a), 2), Core.memoryrefnew(a), 4)
    @test a[2] == "p" && a[3] === nothing && a[4] == "q" && !isassigned(a, 5)
    local plain = W.compile(memory, (Int64, Int64); optimize = false)
    local argsets = [(1, 1), (1, 40), (2, 1), (2, 40), (3, 1), (3, 40), (4, 2), (4, 3)]
    local cases = [WTRunner.RunCase("memory$a", plain, Int64.(a), WTRunner.native_answer(memory, Int64.(a))) for a in argsets]
    for r in WTRunner.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end
end
