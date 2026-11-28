# String(v) of a byte Vector copies its bytes in Julia unless a String owns them (julia/src/genericmemory.c:189
# jl_genericmemory_to_string): a pointer taken before, a store through it after, then the String read. Against native
# Julia (the landed module answered 122122 where native answers 97122: it shared the self-owned Memory's bytes).
module StringOfVectorAliasTest

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "codegen_helpers.jl"))

module AliasCases
function store_after(n::Int64)::Int64
    local v = UInt8[0x61, 0x62, 0x63, UInt8(96 + n)]
    GC.@preserve v begin
        local p = pointer(v)
        local t = String(v)
        unsafe_store!(p, UInt8(0x7a))
        return Int64(codeunit(t, 1)) * 1000 + Int64(unsafe_load(p))
    end
end
end

@testset "String of a byte Vector, a pointer kept across it: against native" begin
    local C = AliasCases
    queue_native!("store_after", W.compile(C.store_after, (Int64,); optimize = false), C.store_after, [(Int64(4),)])
end

@testset "the third oracle: every module queued above answers as native Julia" begin
    for r in WTChild.run_cases(NATIVE_RUNS)
        r.ok || println(r.label, ": ", r.why)
        @test r.ok
    end
end

end
