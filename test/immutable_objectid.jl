# objectid of an immutable value is Julia's jl_object_id_ (builtins.c): the type's hash mixed
# with each field's id, or the bits' hash for a plain-bits layout (the objectid overlay,
# interpreter.jl). Base.hash of a struct without its own method is objectid-based, so a Dict or
# Set keyed by an immutable struct depends on it. The lowered jl_object_id once gave every
# immutable a per-object counter: two equal keys, two ids.
struct _OidP2; x::Int64; y::Int64; end            # plain bits, 16 bytes: memhash of the bytes
struct _OidPS; s::String; n::Int64; end           # a pointer field: bitmix over the fields
struct _OidPN; p::_OidP2; b::Bool; end            # an inline struct with padding
struct _OidE; end                                  # zero size: ~dt.hash
struct _OidPU; u::Union{Int64,Nothing}; end        # an inline Union field
struct _OidPI; a::Int32; b::Int32; end            # 8 bytes of bits: int64hash
struct _OidPB; a::Bool; end                        # 1 byte, read signed: int32hash
struct _OidPQ; q::Int128; end                      # a 16-byte leaf

@testset "objectid of an immutable value is Julia's jl_object_id_" begin
    for (f, n) in (((n::Int64) -> objectid(_OidP2(n, 2)) % Int64, 7),
                   ((n::Int64) -> objectid(_OidPS(string(n), 3)) % Int64, 7),
                   ((n::Int64) -> objectid(_OidPN(_OidP2(1, n), true)) % Int64, 7),
                   ((n::Int64) -> objectid(_OidE()) % Int64 + n, 7),
                   ((n::Int64) -> objectid(_OidPU(n)) % Int64, 7),
                   ((n::Int64) -> objectid(_OidPU(n > 100 ? n : nothing)) % Int64, 7),
                   ((n::Int64) -> objectid(_OidPI(Int32(n), Int32(-5))) % Int64, 7),
                   ((n::Int64) -> objectid(_OidPB(n > 0)) % Int64, 7),
                   ((n::Int64) -> objectid(_OidPQ(Int128(n) << 70)) % Int64, 7),
                   ((n::Int64) -> objectid(n) % Int64, 7),
                   ((n::Int64) -> objectid(Float64(n) / 3) % Int64, 7),
                   ((n::Int64) -> objectid(Char(96 + n)) % Int64, 7),
                   ((n::Int64) -> objectid(n > 0) % Int64, 7),
                   ((n::Int64) -> objectid((n, 2.5)) % Int64, 7))
        @test compare_julia_wasm(f, Int64(n)).pass
    end
    # the default hash of an immutable struct: equal keys meet in a Dict and a Set
    @test compare_julia_wasm((n::Int64) -> (d = Dict{_OidP2,Int64}(); d[_OidP2(n, 2)] = 5; get(d, _OidP2(n, 2), -1)), Int64(7)).pass
    @test compare_julia_wasm((n::Int64) -> length(Set([_OidP2(n, 1), _OidP2(n, 1), _OidP2(n, 2)])), Int64(7)).pass
    # a mutable object keeps its identity: two equal ones have two ids, one has one
    @test compare_julia_wasm((n::Int64) -> (r = Ref(n); objectid(r) == objectid(r) ? 1 : 0), Int64(7)).pass
end
