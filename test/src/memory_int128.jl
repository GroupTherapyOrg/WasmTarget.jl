# A Memory of 128-bit primitive elements (Int128, UInt128, a `primitive type P 128`), against native Julia. Julia
# stores such an element inline, 16 bytes (julia/src/genericmemory.c:95 `elsz`, its layout's size), LLVM's wasm target
# as its two i64 halves; WasmTarget's array holds the element's class's immutable struct of the two halves by
# reference (src/julia/classes.jl _memory_element_storage), a new memory filled with the struct of zero halves
# (src/intrinsics.jl memorynew). Each case reads, writes, copies and compares elements, a copy's write never reaching
# its source (an element is a value), and a constant vector's elements read back; every answer an Int64 folding the
# elements' halves, so a wrong half shows.
module MemoryInt128Test
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module MemoryInt128Cases
primitive type P128 128 end
# a 128-bit value's two halves folded into one Int64, the high one weighted so a swapped or lost half shows
fold(x::Int128)::Int64 = (x % Int64) * 31 + (x >> 64) % Int64
fold(x::UInt128)::Int64 = fold(x % Int128)
fold(x::P128)::Int64 = fold(Core.bitcast(Int128, x))
const K = Int128[Int128(-7), typemax(Int128), typemin(Int128) + 3, Int128(1) << 100]

# k selects the case; n is read at run time, so nothing folds
function m128(k::Int64, n::Int64)::Int64
    if k == 1
        # write, read, push!, sum over a Vector{Int128}
        local v = Int128[Int128(n) << 64 + i for i in 1:4]
        v[2] = -v[3]
        push!(v, Int128(n) * typemax(Int64))
        return fold(sum(v)) + fold(v[2]) + length(v)
    elseif k == 2
        # a copy's write never reaches its source, and == compares element by element
        local a = Int128[Int128(n), Int128(n) << 70, -Int128(n)]
        local b = copy(a)
        local same = a == b
        b[1] = b[1] + (Int128(1) << 64)
        return fold(a[1]) + 1000 * same + 2000 * (a == b) + fold(b[1])
    elseif k == 3
        # a Memory{UInt128} of undef length, every element written, then copied over itself shifted
        local m = Memory{UInt128}(undef, 5)
        for i in 1:5
            m[i] = (((n + i) % UInt128) << 96) | UInt128(i)
        end
        copyto!(m, 2, m, 1, 4)
        local s = Int64(0)
        for i in 1:5
            s = s * 7 + fold(m[i])
        end
        return s
    elseif k == 4
        # a vector of a primitive type of its own, compared by ===
        local p = P128[Core.bitcast(P128, Int128(n) << i) for i in 60:63]
        p[4] = p[1]
        return fold(p[4]) + 10 * (p[4] === p[1]) + 20 * (p[2] === p[3]) + length(p)
    elseif k == 5
        # a constant vector's elements, one sorted copy of it
        local s = sort(K)
        return fold(K[mod1(n, 4)]) + fold(s[1]) + fold(s[4])
    else
        # a new zero-length memory, then one grown by resize!
        local v = Int128[]
        for i in 1:n
            push!(v, Int128(i) << 80)
        end
        resize!(v, max(n - 1, 0))
        return isempty(v) ? Int64(-1) : fold(v[end]) + length(v)
    end
end
end

const MC = MemoryInt128Cases

@testset "a Memory of 128-bit primitive elements: read, write, copy and compare against native" begin
    local both(f, a) = Main.WTVerdict._modules(WasmTarget.compile, f, a)
    local (plain, opt) = both(MC.m128, (Int64(1), Int64(3)))
    local args = [(Int64(k), Int64(n)) for k in 1:6 for n in (0, 1, 3, -5)]
    local cases = [Main.WTChild.RunCase("memory_int128/m128$a", plain, a, Main.WTChild.native_answer(MC.m128, a); optimized = opt) for a in args]
    for r in Main.WTChild.run_cases(cases)
        @test r.ok || (@info r.label r.why; false)
    end
end

end # module
