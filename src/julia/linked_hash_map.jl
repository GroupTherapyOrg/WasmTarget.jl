# A map and a set iterated in insertion order: dart's default Map and Set, which the ported
# wasm_builder and dart2wasm iterate where the order reaches the module bytes (field and local
# names, custom sections, rec groups).
#
# precedent(dart: dart:collection LinkedHashMap and LinkedHashSet; python: dict since 3.7). Julia's
# differs: Base's Dict and Set iterate in hash order.

"""
    LinkedHashMap{K,V}()

A map from `K` to `V` iterated, as `key => value` pairs, in the order the keys were first inserted.
Assigning an existing key keeps its position; deleting a key removes it from the order.
"""
@quarantine "dart's default Map is insertion-ordered and its order reaches the bytes; Julia's Dict iterates in hash order" Base.AbstractDict struct LinkedHashMap{K,V} <: AbstractDict{K,V}
    _keys::Vector{K}
    _values::Vector{V}
    # each key's position, one Dict type for every K: Base's Dict{Any,Int} is compiled once (in Julia's
    # system image), where a Dict{K,Int} per key type compiles its hashing and probing again; keys
    # compare by isequal and hash as in any Dict, and are converted to K before they are stored
    _slots::Dict{Any,Int}
    LinkedHashMap{K,V}() where {K,V} = new{K,V}(K[], V[], Dict{Any,Int}())
end

@quarantine "the map's size, Julia's length" Base.length Base.length(m::LinkedHashMap)::Int = length(m._keys)

@quarantine "the map's containsKey, Julia's haskey" Base.haskey Base.haskey(m::LinkedHashMap{K}, k) where {K} = haskey(m._slots, k)

@quarantine "the map's operator [], Julia's getindex" Base.getindex function Base.getindex(m::LinkedHashMap{K,V}, k)::V where {K,V}
    m._values[m._slots[k]]
end

@quarantine "the map's lookup with a default, Julia's get" Base.get function Base.get(m::LinkedHashMap{K,V}, k, default) where {K,V}
    slot = get(m._slots, k, 0)
    slot == 0 ? default : m._values[slot]
end

@quarantine "the map's operator []=, an existing key keeping its place" Base.setindex! function Base.setindex!(m::LinkedHashMap{K,V}, v, k)::LinkedHashMap{K,V} where {K,V}
    k = convert(K, k)
    slot = get(m._slots, k, 0)
    if slot == 0
        push!(m._keys, k)
        push!(m._values, v)
        m._slots[k] = length(m._keys)
    else
        m._values[slot] = v
    end
    m
end

@quarantine "the map's remove, the order of the rest kept" Base.delete! function Base.delete!(m::LinkedHashMap{K,V}, k)::LinkedHashMap{K,V} where {K,V}
    slot = get(m._slots, k, 0)
    slot == 0 && return m
    deleteat!(m._keys, slot)
    deleteat!(m._values, slot)
    delete!(m._slots, k)
    for i in slot:length(m._keys)
        m._slots[m._keys[i]] = i
    end
    m
end

@quarantine "the map's entries in insertion order, Julia's iteration protocol" Base.iterate function Base.iterate(m::LinkedHashMap{K,V}, i::Int=1) where {K,V}
    i > length(m._keys) && return nothing
    (m._keys[i] => m._values[i], i + 1)
end

"""
    LinkedHashSet{T}()

A set iterated in the order its elements were first added: dart's default Set (`{}` of elements,
`<T>{}`), a LinkedHashSet, whose order the ported code reaches through `toList` and iteration.
"""
@quarantine "dart's default Set is insertion-ordered and its order reaches the bytes; Julia's Set iterates in hash order" Base.AbstractSet struct LinkedHashSet{T} <: AbstractSet{T}
    _map::LinkedHashMap{T,Nothing}
    LinkedHashSet{T}() where {T} = new{T}(LinkedHashMap{T,Nothing}())
end

@quarantine "the set's size, Julia's length" Base.length Base.length(s::LinkedHashSet)::Int = length(s._map)

@quarantine "the set's contains, Julia's in" Base.in Base.in(x, s::LinkedHashSet)::Bool = haskey(s._map, x)

@quarantine "the set's add, Julia's push!" Base.push! function Base.push!(s::LinkedHashSet{T}, x)::LinkedHashSet{T} where {T}
    s._map[x] = nothing
    s
end

@quarantine "the set's remove, the order of the rest kept" Base.delete! function Base.delete!(s::LinkedHashSet{T}, x)::LinkedHashSet{T} where {T}
    delete!(s._map, x)
    s
end

@quarantine "the set's elements in insertion order, Julia's iteration protocol" Base.iterate function Base.iterate(s::LinkedHashSet{T}, i::Int=1) where {T}
    i > length(s._map._keys) && return nothing
    (s._map._keys[i], i + 1)
end
