# A load and a store through a managed pointer (src/julia/classes.jl managed_pointer; src/intrinsics.jl pointer_load,
# pointer_store): Julia's pointerref and pointerset, and atomic_pointerref and atomic_pointerset of :not_atomic, over the
# data array the pointer's base is, as dart's ByteData over a typed list's buffer reads it: the array's own element where
# its storage is the value's and the offset falls on an element, else the value's bytes, little-endian, from a byte
# array; a pointer stored in a memory of boxed elements its reference, C_NULL the null. Each function against native
# Julia; then the accesses WasmTarget does not hold, each the fatal arm at run time, named, or a rejection at compile
# time, located.
module ManagedPointerMemoryTest

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "codegen_helpers.jl"))

module PointerMemoryCases
# a byte array read as wider integers and floats, aligned and not, and written as them
bytes16() = UInt8[0x01, 0x82, 0x03, 0x84, 0x05, 0x86, 0x07, 0x88, 0x09, 0x8a, 0x0b, 0x8c, 0x0d, 0x8e, 0x0f, 0x90]
function bytes_u32(n::Int64)::Int64
    local v = bytes16()
    GC.@preserve v Int64(unsafe_load(Ptr{UInt32}(pointer(v)), n))
end
function bytes_u64_unaligned(n::Int64)::Int64
    local v = bytes16()
    GC.@preserve v reinterpret(Int64, unsafe_load(Ptr{UInt64}(pointer(v) + n)))
end
function bytes_i16(n::Int64)::Int64
    local v = bytes16()
    GC.@preserve v Int64(unsafe_load(Ptr{Int16}(pointer(v) + 1), n))
end
function bytes_store_u64(n::Int64)::Int64
    local v = zeros(UInt8, 16)
    GC.@preserve v unsafe_store!(Ptr{UInt64}(pointer(v) + n), 0x0102030405060708 * UInt64(n + 1))
    return sum(Int64(v[k]) * k for k in 1:16)
end
function bytes_store_u16(n::Int64)::Int64
    local v = zeros(UInt8, 8)
    GC.@preserve v unsafe_store!(Ptr{UInt16}(pointer(v) + 1), UInt16(0xa1b2 + n), n)
    return sum(Int64(v[k]) * k for k in 1:8)
end
function bytes_float64(n::Int64)::Float64
    local v = zeros(UInt8, 24)
    GC.@preserve v unsafe_store!(Ptr{Float64}(pointer(v) + n), Float64(n) / 3)
    GC.@preserve v unsafe_load(Ptr{Float64}(pointer(v) + n))
end
function bytes_float32(n::Int64)::Float64
    local v = zeros(UInt8, 12)
    GC.@preserve v unsafe_store!(Ptr{Float32}(pointer(v)), Float32(n) - 0.25f0, 2)
    GC.@preserve v Float64(unsafe_load(Ptr{Float32}(pointer(v)), 2)) + Float64(v[5])
end
function bytes_bool(n::Int64)::Int64
    local v = UInt8[0x00, 0x01, 0x01, 0x00]
    GC.@preserve v Int64(unsafe_load(Ptr{Bool}(pointer(v)), n))
end
# a memory's own elements, by index and by an offset on an element, read and written
function own_i64(n::Int64)::Int64
    local v = collect(Int64(10):Int64(10):Int64(50))
    GC.@preserve v begin
        unsafe_store!(pointer(v), -n, n)
        unsafe_load(pointer(v), n) * 100 + unsafe_load(pointer(v) + 8 * (n - 1), 1) + unsafe_load(pointer(v), 5)
    end
end
function own_i32(n::Int64)::Int64
    local v = Int32[-1, -2, 3, 4]
    GC.@preserve v Int64(unsafe_load(pointer(v), n)) + Int64(unsafe_load(Ptr{UInt32}(pointer(v)), n))
end
function own_f64(n::Int64)::Float64
    local v = [0.5, 1.5, 2.5]
    GC.@preserve v (unsafe_store!(pointer(v), 4.25 * n, n); unsafe_load(pointer(v), n) + unsafe_load(pointer(v), 1))
end
function own_u16(n::Int64)::Int64
    local v = UInt16[0x0102, 0xfffe, 0x0304]
    GC.@preserve v Int64(unsafe_load(Ptr{Int16}(pointer(v)), n))
end
function atomic_not_atomic(n::Int64)::Int64
    local v = collect(Int64(1):Int64(4))
    GC.@preserve v begin
        Core.Intrinsics.atomic_pointerset(pointer(v) + 8 * (n - 1), Int64(7 * n), :not_atomic)
        Core.Intrinsics.atomic_pointerref(pointer(v) + 8 * (n - 1), :not_atomic) + v[1]
    end
end
# a pointer in a memory of boxed elements: C_NULL stored is the element's #undef; an #undef read is C_NULL
function unset_string(n::Int64)::Int64
    local v = ["a", "b", "c"]
    GC.@preserve v unsafe_store!(Ptr{Ptr{Cvoid}}(pointer(v)), C_NULL, n)
    return (isassigned(v, n) ? 10 : 0) + (isassigned(v, 1) ? 1 : 0)
end
function undef_string(n::Int64)::Int64
    local v = Vector{String}(undef, 3)
    v[1] = "a"
    GC.@preserve v Int64(unsafe_load(Ptr{Ptr{Cvoid}}(pointer(v)), n) == C_NULL)
end
# a memory of pointers: its own elements, each an integer address here, made at run time (a constant one other
# than C_NULL is a host address, refused: src/constants.jl)
function own_pointers(n::Int64)::Int64
    local v = Ptr{Cvoid}[C_NULL, Ptr{Cvoid}(UInt64(8 * n + 16)), Ptr{Cvoid}(UInt64(8 * n + 24))]
    GC.@preserve v begin
        local q = unsafe_load(pointer(v), n)
        unsafe_store!(pointer(v), Ptr{Cvoid}(UInt64(8 * n)), 1)
        Int64(UInt(q)) * 100 + Int64(UInt(v[1]))
    end
end

# no element WasmTarget holds at that address: the fatal arm at run time
function misaligned(n::Int64)::Int64
    local v = collect(Int64(1):Int64(4))
    GC.@preserve v unsafe_load(Ptr{Int64}(pointer(v) + 4), n)
end
function past_end(n::Int64)::Int64
    local v = zeros(UInt8, 4)
    GC.@preserve v Int64(unsafe_load(Ptr{UInt32}(pointer(v) + n)))
end
integer_address(n::Int64) = unsafe_load(Ptr{Int64}(UInt64(8 * n)))
function other_storage(n::Int64)::Int64
    local v = Float64[1.0, 2.0]
    GC.@preserve v reinterpret(Int64, unsafe_load(Ptr{UInt64}(pointer(v)), n))
end
function unset_flagged(n::Int64)::Int64
    local v = Any[1, 2, 3]
    GC.@preserve v unsafe_store!(Ptr{Ptr{Cvoid}}(pointer(v)), C_NULL, n)
    return isassigned(v, n) ? 1 : 0
end

# rejected at compile time
atomic_order(n::Int64) = (v = collect(Int64(1):n); GC.@preserve v Core.Intrinsics.atomic_pointerref(pointer(v), :monotonic))
tuple_load(n::Int64) = (v = [(n, n)]; GC.@preserve v unsafe_load(pointer(v))[1])
end

const P = PointerMemoryCases

@testset "a load and a store through a managed pointer, against native" begin
    for (name, f, xs) in (("bytes_u32", P.bytes_u32, [1, 2, 4]), ("bytes_u64_unaligned", P.bytes_u64_unaligned, [0, 3, 8]),
                          ("bytes_i16", P.bytes_i16, [1, 2, 7]), ("bytes_store_u64", P.bytes_store_u64, [0, 5, 8]),
                          ("bytes_store_u16", P.bytes_store_u16, [1, 3]), ("bytes_float64", P.bytes_float64, [0, 3, 16]),
                          ("bytes_float32", P.bytes_float32, [1, 6]), ("bytes_bool", P.bytes_bool, [1, 2, 4]),
                          ("own_i64", P.own_i64, [1, 3, 5]), ("own_i32", P.own_i32, [1, 2, 4]), ("own_f64", P.own_f64, [1, 3]),
                          ("own_u16", P.own_u16, [1, 2]), ("atomic_not_atomic", P.atomic_not_atomic, [1, 4]),
                          ("unset_string", P.unset_string, [2, 3]), ("own_pointers", P.own_pointers, [1, 2, 3]), ("undef_string", P.undef_string, [2]))
        queue_native!(name, W.compile(f, (Int64,); optimize = false), f, [(x,) for x in xs])
    end
end

@testset "the third oracle: every module queued above answers as native Julia" begin
    for r in WTChild.run_cases(NATIVE_RUNS)
        r.ok || println(r.label, ": ", r.why)
        @test r.ok
    end
end

@testset "no element WasmTarget holds at the address: the fatal arm at run time, named" begin
    # the cases' answers are never read: each module reports its gap and traps before it answers
    local fatal = WTChild.RunCase[]
    for (name, f, x, why) in (("misaligned", P.misaligned, 1, "between two of the data array's elements"),
                              ("past_end", P.past_end, 2, "past the end of the byte array"),
                              ("integer_address", P.integer_address, 1, "with no base or into a data array of no storage it reads"),
                              ("other_storage", P.other_storage, 1, "with no base or into a data array of no storage it reads"),
                              ("unset_flagged", P.unset_flagged, 2, "keeps its #undef in set flags"))
        push!(fatal, WTChild.RunCase("$name($x) $why", W.compile(f, (Int64,); optimize = false), (x,), 0))
    end
    for r in WTChild.run_cases(fatal)
        r.outcome === :unported || println(r.label, ": ", r.outcome, " ", r.why)
        @test r.outcome === :unported && occursin(split(r.label, ") ")[2], r.why)
    end
end

@testset "an atomic order or an element of no primitive type: rejected at compile time, located" begin
    local e = rejection(() -> W.compile(P.atomic_order, (Int64,); optimize = false))
    @test e !== nothing && occursin("atomic order monotonic", sprint(showerror, e))
    e = rejection(() -> W.compile(P.tuple_load, (Int64,); optimize = false))
    @test e !== nothing && occursin("no primitive type of 1, 2, 4 or 8 bytes", sprint(showerror, e))
end

end
