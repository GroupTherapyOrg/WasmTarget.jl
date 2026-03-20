"""
    IntKeyMap{V}

Drop-in replacement for Dict{Int,V} with sequential integer keys.
Uses Vector{Union{Nothing,V}} for O(1) access. Pre-sized to n elements.
Compiles to WasmGC trivially (array.get/array.set/array.len).
"""
struct IntKeyMap{V}
    data::Vector{Union{Nothing, V}}
    IntKeyMap{V}(n::Int) where V = new{V}(fill(nothing, n))
end

Base.getindex(m::IntKeyMap{V}, k::Int) where V = m.data[k]::V
Base.setindex!(m::IntKeyMap{V}, v::V, k::Int) where V = (m.data[k] = v; v)
Base.setindex!(m::IntKeyMap{V}, v, k::Int) where V = (m.data[k] = convert(V, v); convert(V, v))
Base.haskey(m::IntKeyMap, k::Int) = k >= 1 && k <= length(m.data) && m.data[k] !== nothing
Base.get(m::IntKeyMap{V}, k::Int, default) where V = haskey(m, k) ? m.data[k]::V : default
Base.delete!(m::IntKeyMap, k::Int) = (if k >= 1 && k <= length(m.data); m.data[k] = nothing; end; m)
Base.length(m::IntKeyMap) = count(!isnothing, m.data)

function Base.iterate(m::IntKeyMap{V}, state::Int=1) where V
    while state <= length(m.data)
        if m.data[state] !== nothing
            return (state => m.data[state]::V, state + 1)
        end
        state += 1
    end
    return nothing
end
