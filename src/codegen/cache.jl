# ============================================================================
# Compilation Cache — Incremental Compilation Support
# Caches compiled Wasm bytes by function identity + arg types hash.
# Avoids re-compilation when the same function is compiled multiple times.
# ============================================================================

struct CacheEntry
    wasm_bytes::Vector{UInt8}
    timestamp::Float64
end

"""
    CompileCache

Thread-safe LRU cache for compiled Wasm bytes.
Key: hash of (function code hash, arg types, WasmTarget version).
Invalidation: automatic when function method changes (world age) or
WasmTarget version changes.
"""
mutable struct CompileCache
    entries::Dict{UInt64, CacheEntry}
    access_order::Vector{UInt64}   # LRU: oldest first
    max_entries::Int
    lock::ReentrantLock
    hits::Int
    misses::Int
end

"""
    CompileCache(; max_entries=256)

Create a new compilation cache with LRU eviction.
"""
CompileCache(; max_entries::Int=256) = CompileCache(
    Dict{UInt64, CacheEntry}(),
    UInt64[],
    max_entries,
    ReentrantLock(),
    0, 0
)

# Global cache instance
const _GLOBAL_CACHE = Ref{Union{CompileCache, Nothing}}(nothing)

"""
    enable_cache!(; max_entries=256)

Enable the global compilation cache. Subsequent calls to `compile()` and
`compile_multi()` will use the cache.
"""
function enable_cache!(; max_entries::Int=256)
    _GLOBAL_CACHE[] = CompileCache(; max_entries)
    return _GLOBAL_CACHE[]
end

"""
    disable_cache!()

Disable the global compilation cache.
"""
function disable_cache!()
    _GLOBAL_CACHE[] = nothing
end

"""
    clear_cache!()

Clear all entries from the global compilation cache.
"""
function clear_cache!()
    cache = _GLOBAL_CACHE[]
    cache === nothing && return
    lock(cache.lock) do
        empty!(cache.entries)
        empty!(cache.access_order)
        cache.hits = 0
        cache.misses = 0
    end
end

"""
    cache_stats() -> NamedTuple

Return cache hit/miss statistics.
"""
function cache_stats()
    cache = _GLOBAL_CACHE[]
    cache === nothing && return (enabled=false, entries=0, hits=0, misses=0, hit_rate=0.0)
    lock(cache.lock) do
        total = cache.hits + cache.misses
        rate = total > 0 ? cache.hits / total : 0.0
        return (enabled=true, entries=length(cache.entries),
                hits=cache.hits, misses=cache.misses, hit_rate=rate)
    end
end

# ============================================================================
# Cache Key Generation
# ============================================================================

"""
    compute_cache_key(f, arg_types::Tuple) -> UInt64

Compute a cache key from a function and its argument types.
The key incorporates:
- Function identity (objectid for named functions, code hash for lambdas)
- Argument types
- Current world age (invalidates when methods change)
"""
function compute_cache_key(f, arg_types::Tuple)::UInt64
    h = UInt64(0)

    # Hash the function — use method world age for invalidation
    h = hash(typeof(f), h)
    h = hash(nameof(f), h)

    # Hash argument types
    for T in arg_types
        h = hash(T, h)
    end

    # Hash the world age of the most specific method
    # This ensures cache invalidation when the function is redefined
    try
        ms = methods(f, Tuple{arg_types...})
        if length(ms.ms) > 0
            m = ms.ms[1]
            # Include the method's primary_world to detect redefinitions
            if isdefined(m, :primary_world)
                h = hash(m.primary_world, h)
            end
        end
    catch
        # If method lookup fails, hash objectid as fallback
        h = hash(objectid(f), h)
    end

    return h
end

"""
    compute_multi_cache_key(functions::Vector) -> UInt64

Compute a cache key for a multi-function compilation.
"""
function compute_multi_cache_key(functions::Vector)::UInt64
    h = UInt64(0)
    for entry in functions
        f = entry[1]
        arg_types = entry[2]
        h = hash(compute_cache_key(f, arg_types), h)
    end
    return h
end

# ============================================================================
# Cache Lookup / Store
# ============================================================================

"""
    cache_lookup(cache::CompileCache, key::UInt64) -> Union{Vector{UInt8}, Nothing}

Look up a compiled Wasm binary in the cache.
Returns `nothing` on miss.
"""
function cache_lookup(cache::CompileCache, key::UInt64)
    lock(cache.lock) do
        if haskey(cache.entries, key)
            # Move to end (most recently used)
            filter!(!=(key), cache.access_order)
            push!(cache.access_order, key)
            cache.hits += 1
            return copy(cache.entries[key].wasm_bytes)  # return copy to prevent mutation
        end
        cache.misses += 1
        return nothing
    end
end

"""
    cache_store!(cache::CompileCache, key::UInt64, wasm_bytes::Vector{UInt8})

Store a compiled Wasm binary in the cache with LRU eviction.
"""
function cache_store!(cache::CompileCache, key::UInt64, wasm_bytes::Vector{UInt8})
    lock(cache.lock) do
        # Evict LRU entries if at capacity
        while length(cache.entries) >= cache.max_entries && !isempty(cache.access_order)
            evict_key = popfirst!(cache.access_order)
            delete!(cache.entries, evict_key)
        end

        cache.entries[key] = CacheEntry(
            copy(wasm_bytes),
            time()
        )
        push!(cache.access_order, key)
    end
end

# ============================================================================
# Cached Compilation Entry Points
# ============================================================================

"""
    compile_cached(f, arg_types::Tuple; optimize=false) -> Vector{UInt8}

Like `compile()` but uses the global cache. Enable with `enable_cache!()`.
"""
function compile_cached(f, arg_types::Tuple; optimize=false)::Vector{UInt8}
    cache = _GLOBAL_CACHE[]

    # If cache disabled, fall through to normal compile
    if cache === nothing
        return compile(f, arg_types; optimize=optimize)
    end

    key = compute_cache_key(f, arg_types)

    # Try cache lookup
    cached = cache_lookup(cache, key)
    if cached !== nothing
        return cached
    end

    # Cache miss — compile and store
    bytes = compile(f, arg_types; optimize=optimize)
    cache_store!(cache, key, bytes)
    return bytes
end

"""
    compile_multi_cached(functions::Vector; optimize=false, kwargs...) -> Vector{UInt8}

Like `compile_multi()` but uses the global cache.
"""
function compile_multi_cached(functions::Vector; optimize=false, kwargs...)
    cache = _GLOBAL_CACHE[]

    if cache === nothing
        return compile_multi(functions; optimize=optimize, kwargs...)
    end

    key = compute_multi_cache_key(functions)

    cached = cache_lookup(cache, key)
    if cached !== nothing
        return cached
    end

    bytes = compile_multi(functions; optimize=optimize, kwargs...)
    cache_store!(cache, key, bytes)
    return bytes
end
