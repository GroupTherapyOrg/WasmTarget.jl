# A TypeName constant's type caches (`cache`, `linearcache`) hold every type the session made of that name. Julia's image
# writer queues them without recursing into them and prunes them to the types the image reaches otherwise
# (julia/src/staticdata.c:863-867, :3311-3316, jl_prune_type_cache_hash :2544, jl_prune_type_cache_linear :2572); so does
# WasmTarget's class walk and constant (src/julia/classes.jl _meet_constant!, typename_cache_pruned). A program that holds a
# TypeName constant compiles to the same classes and the same bytes whatever type the session made in between.
module TypenameCacheTest
using Test, WasmTarget
const W = WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module TNCases
# two types of two TypeNames through a phi: Julia folds each branch's `.name` to its TypeName constant
pick(x::Int64) = x > 0 ? Int64 : Base.RefValue{Int64}
named(x::Int64) = Int64(pick(x).name.name === :Int64)
end

# a type the test makes between the two compiles: Julia caches its RefValue in RefValue's TypeName
struct Unrelated; a::Int8; end

_classes() = W.closed_world_classes(W.build_nir(W.check_subset(TNCases.named, (Int64,), "typename_cache", Base.get_world_counter()), "typename_cache"), "typename_cache")

@testset "a TypeName constant's caches are pruned as Julia's image writer prunes them: the module is its program's" begin
    @test only(Base.code_typed(TNCases.named, (Int64,)))[2] === Int64
    local c1 = _classes()
    local m1 = W.compile(TNCases.named, (Int64,))
    local r = Ref(Unrelated(Int8(1)))
    @test any(e -> e === typeof(r), Base.unwrap_unionall(Base.RefValue).name.cache)
    local c2 = _classes()
    local m2 = W.compile(TNCases.named, (Int64,))
    # the same classes, none of them the type the session made in between, and the same bytes
    @test Set(c1) == Set(c2)
    # (their order is Julia's inference order, cold and warm apart: the order's own commit asserts it)
    @test !(typeof(r) in c2) && !(Unrelated in c2)
    @test m1 == m2
    @test all(r -> r.ok, Main.WTChild.run_cases([Main.WTChild.RunCase("named($x)", m1, (x,), TNCases.named(x)) for x in (Int64(1), Int64(-1))]))
end

@testset "typename_cache_pruned: an entry the program does not otherwise reach is nothing, and every one it reaches is kept" begin
    local tn = Base.unwrap_unionall(Base.RefValue).name
    local held = Base.IdSet{DataType}([Base.RefValue{Int64}, Int64])
    # the hash table: each unreached entry dropped, the kept ones rehashed to their count, at least HT_N_INLINE
    # (jl_prune_type_cache_hash, cache_rehash_set): a power of two, each kept type within max_probe of its home slot
    local c = W.typename_cache_pruned(held, tn, :cache)
    local kept_types = Set(e for e in tn.cache if e isa DataType && e in held)
    @test Set(e for e in c if e !== nothing) == kept_types && Base.RefValue{Int64} in kept_types
    @test ispow2(length(c)) && length(c) >= W.HT_N_INLINE
    @test all(eachindex(c)) do i
        local e = c[i]
        e === nothing && return true
        local home = W.typecache_h2index(UInt64(e.hash), length(c))
        mod(i - 1 - home, length(c)) <= W.typecache_max_probe(length(c))
    end
    # the list keeps its reached entries in order, then nothing (jl_prune_type_cache_linear)
    local l = W.typename_cache_pruned(held, tn, :linearcache)
    local kept = [e for e in getfield(tn, :linearcache) if e isa DataType && e in held]
    @test length(l) == length(getfield(tn, :linearcache)) && collect(l)[1:length(kept)] == kept && all(x -> x === nothing, collect(l)[length(kept)+1:end])
    # a field that is no type cache is refused
    @test try; W.typename_cache_pruned(held, tn, :names); false; catch e; e isa W.RejectionError; end
end

# A session that grows a TypeName's hash table between two compiles: 200 RefValue types take RefValue's cache past its
# capacity, so Julia rehashes it to a larger table (cache_insert_type_set's growth). The constant is the kept types
# rehashed to their own count (cache_rehash_set), so its length and slots, and the module, do not move (audit A126E2)
module TNGrow
named(x::Int64) = Int64((x > 0 ? Int64 : Base.RefValue{Int64}).name.name === :Int64)
end

@testset "a TypeName's hash cache, grown by the session between two compiles, is the same constant: the module is its program's" begin
    local tn = Base.unwrap_unionall(Base.RefValue).name
    local held = Base.IdSet{DataType}([Base.RefValue{Int64}, Int64])
    local c1 = W.typename_cache_pruned(held, tn, :cache)
    local m1 = W.compile(TNGrow.named, (Int64,))
    local before = length(tn.cache)
    for i in 1:200
        Base.RefValue{Val{(:a126e2, i)}}
    end
    @test length(tn.cache) > before
    local c2 = W.typename_cache_pruned(held, tn, :cache)
    @test length(c1) == length(c2) && all(i -> c1[i] === c2[i], eachindex(c1))
    local m2 = W.compile(TNGrow.named, (Int64,))
    @test m1 == m2
end

end # module
