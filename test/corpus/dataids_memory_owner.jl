# A Memory's data id is its data owner's (julia/base/abstractarray.jl:1591 dataids, `UInt(A.ptr)`): Julia's owner is
# the Memory itself (julia/src/genericmemory.c:48, :167) or the String whose bytes a byte Memory wraps (:113), the
# set the data owner's arm admits (src/julia/runtime/hashing.jl jl_genericmemory_owner_arm). Two wraps of one String
# share one data id, a fresh byte Memory has its own, and two Memories of Int64 each their own; each answer a sum of
# comparisons, every one true natively
_g("memory", Any[
    ("dataids_string_wrap_owner", (n::Int64) -> (s = repeat("ab", n); m1 = unsafe_wrap(Memory{UInt8}, s); m2 = unsafe_wrap(Memory{UInt8}, s); m3 = Memory{UInt8}(undef, 2n); Int64(Base.dataids(m1) == Base.dataids(m2)) + 2 * Int64(Base.dataids(m1) != Base.dataids(m3)) + 4 * Int64(Base.dataids(m3) == Base.dataids(m3))), Int64(3)),
    ("dataids_memory_own_owner", (n::Int64) -> (a = Memory{Int64}(undef, n); b = Memory{Int64}(undef, n); Int64(Base.dataids(a) != Base.dataids(b)) + 2 * Int64(Base.dataids(a) == Base.dataids(a))), Int64(3)),
])
