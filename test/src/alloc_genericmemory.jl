# A foreign call of libjulia's jl_alloc_genericmemory (julia/src/genericmemory.c:75), lowered where it is called
# (src/intrinsics.jl generateStaticIntrinsic, Val(:alloc_genericmemory)) by memorynew's arm, the one allocation
# construction, after the C's own size limit (_new_genericmemory_, one element smaller than emit_memorynew's).
# Compiled and run, each case answers as native Julia's ccall: a memory of the type and length asked, its
# elements written and read, the type's one empty instance for no element, an #undef reference element, an
# isbits union's elements, a result declared Any, the InexactError of a negative count (Base's Csize_t
# conversion) and the C's ArgumentError at its limit, where codegen's memorynew would go on to allocate.
module AllocGenericMemoryTest
using Test, WasmTarget
const W = WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module Cases
alloc_int(n::Int64) = (m = ccall(:jl_alloc_genericmemory, Ref{Memory{Int64}}, (Any, Csize_t), Memory{Int64}, n);
    n > 0 && (m[1] = 4; m[n] = 7); (n > 0 ? m[1] + m[n] : Int64(0)) + 100 * length(m))
alloc_empty_same(n::Int64) = (m = ccall(:jl_alloc_genericmemory, Ref{Memory{Float64}}, (Any, Csize_t), Memory{Float64}, n);
    Int64(m === Memory{Float64}(undef, 0)) + 10 * length(m))
alloc_any(n::Int64) = (m = ccall(:jl_alloc_genericmemory, Any, (Any, Csize_t), Memory{Any}, n)::Memory{Any};
    a = isassigned(m, 1); m[1] = "x"; Int64(a) + 2 * Int64(isassigned(m, 1)) + 4 * length(m))
alloc_union(n::Int64) = (m = ccall(:jl_alloc_genericmemory, Ref{Memory{Union{Nothing,Int64}}}, (Any, Csize_t), Memory{Union{Nothing,Int64}}, n);
    m[1] = nothing; m[2] = n; Int64(m[1] === nothing) + 2 * something(m[2]) + 100 * length(m))
alloc_bytes(n::Int64) = (m = ccall(:jl_alloc_genericmemory, Ref{Memory{UInt8}}, (Any, Csize_t), Memory{UInt8}, n);
    for i in 1:n; m[i] = 0x05; end; s = Int64(0); for i in 1:n; s += m[i]; end; s + 1000 * length(m))
# the C's errors: a negative count's InexactError (Csize_t(n), before the call), and the ArgumentError at the C's
# limit, nel >= typemax(Int) - 1 for one-byte elements, where emit_memorynew's would let typemax(Int) - 1 through
function alloc_errors(n::Int64)
    local code = Int64(0)
    try
        ccall(:jl_alloc_genericmemory, Ref{Memory{UInt8}}, (Any, Csize_t), Memory{UInt8}, n)
    catch e
        code = e isa InexactError ? Int64(1) : e isa ArgumentError ? Int64(2) : e isa OutOfMemoryError ? Int64(3) : Int64(4)
    end
    return code
end
end

const RUNS = (("alloc_int", Cases.alloc_int, Int64[0, 1, 3, 100]), ("alloc_empty_same", Cases.alloc_empty_same, Int64[0, 2]),
              ("alloc_any", Cases.alloc_any, Int64[1, 5]), ("alloc_union", Cases.alloc_union, Int64[2, 9]),
              ("alloc_bytes", Cases.alloc_bytes, Int64[0, 1, 300]),
              ("alloc_errors", Cases.alloc_errors, Int64[-1, typemin(Int64), typemax(Int64), typemax(Int64) - 1]))

@testset "the native answers are the C's" begin
    @test Cases.alloc_errors(-1) == 1
    @test Cases.alloc_errors(typemax(Int64)) == 2
    @test Cases.alloc_errors(typemax(Int64) - 1) == 2          # _new_genericmemory_'s limit, the call's own
    @test Cases.alloc_empty_same(0) == 1
end

@testset "jl_alloc_genericmemory compiled answers as native Julia" begin
    local runs = Main.WTChild.RunCase[]
    for (name, f, xs) in RUNS
        local bytes = W.compile(f, (Int64,))
        append!(runs, [Main.WTChild.RunCase("$name($x)", bytes, (x,), Main.WTChild.native_answer(f, (x,))) for x in xs])
    end
    local results = Main.WTChild.run_cases(runs)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test length(results) == length(runs) && all(r -> r.ok, results)
end

end
