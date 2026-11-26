# A Ptr is a managed pointer (src/julia/classes.jl managed_pointer): its base, the data array it points into, and
# its byte offset. A MemoryRef's ptr_or_offset and a Memory's ptr read as Julia's element address
# (src/code_generator.jl memoryref_address, memory_address; src/intrinsics.jl element_address), a bitcast keeps the
# base, add_ptr and sub_ptr move the offset, === compares base and offset, and Base's ==, < and - of two pointers
# answer over the parts (src/patch/pointer.jl). Each function against native Julia: equality of one array's
# addresses and of two arrays', the stride of an element's address (bits, boxed, union and inline elements), the
# null pointer against an element's address, and an integer address's identity.
module ManagedPointerTest

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "codegen_helpers.jl"))

module PointerCases
function same_and_distinct(n::Int64)::Int64
    local a = collect(1:n); local b = collect(1:n)
    return Int64(pointer(a) == pointer(b)) + 2 * Int64(pointer(a) == pointer(a)) + 4 * Int64(pointer(a, 2) == pointer(a) + 8)
end
function stride(v, n::Int64)::Int64
    GC.@preserve v begin
        local p = Base.unsafe_convert(Ptr{Nothing}, memoryref(v.ref, n))
        local q = Base.unsafe_convert(Ptr{Nothing}, memoryref(v.ref, 1))
        return Int64(p - q) * 10 + Int64(q < p) + 2 * Int64(p == q + (n - 1) * Base.elsize(v))
    end
end
i64_stride(n::Int64) = stride(collect(1:5), n)
any_stride(n::Int64) = stride(Any[1, 2, 3, 4, 5], n)
union_stride(n::Int64) = stride(Union{Int64,Nothing}[1, nothing, 3, 4, 5], n)
tuple_stride(n::Int64) = stride(Tuple{Int64,String}[(1, "a"), (2, "b"), (3, "c"), (4, "d"), (5, "e")], n)
function null_against(n::Int64)::Int64
    local v = collect(1:n)
    return Int64(pointer(v) == C_NULL) + 2 * Int64(C_NULL < pointer(v)) + 4 * Int64(pointer(v) < C_NULL)
end
# an integer address built at run time (a constant one other than C_NULL is a host address, refused: src/constants.jl)
integer_address(n::Int64) = Int64(Ptr{Nothing}(UInt64(n)) === Ptr{Nothing}(UInt64(n + 0))) + 2 * Int64(UInt(Ptr{Int64}(UInt64(n)) + 8)) + 4 * Int64(Ptr{Nothing}(UInt64(n)) === C_NULL)
empty_memories(n::Int64) = Int64(pointer(Memory{Int64}(undef, n)) == pointer(Memory{Int64}(undef, n)))
end

@testset "a managed pointer: a MemoryRef's ptr_or_offset and a Memory's ptr, compared and strided, against native" begin
    local P = PointerCases
    for (name, f, xs) in (("same_and_distinct", P.same_and_distinct, [1, 3]), ("i64_stride", P.i64_stride, [1, 3, 5]),
                          ("any_stride", P.any_stride, [1, 4]), ("union_stride", P.union_stride, [1, 2, 5]),
                          ("tuple_stride", P.tuple_stride, [1, 3]), ("null_against", P.null_against, [2]),
                          ("integer_address", P.integer_address, [3, 4]), ("empty_memories", P.empty_memories, [0]))
        queue_native!(name, W.compile(f, (Int64,); optimize = false), f, [(x,) for x in xs])
    end
end

@testset "the third oracle: every module queued above answers as native Julia" begin
    for r in WTChild.run_cases(NATIVE_RUNS)
        r.ok || println(r.label, ": ", r.why)
        @test r.ok
    end
end

end
