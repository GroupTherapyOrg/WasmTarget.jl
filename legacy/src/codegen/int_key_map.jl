"""
    IntKeyMap{V}

Drop-in replacement for Dict{Int,V} with sequential integer keys.
Uses Vector{Union{Nothing,V}} for O(1) access. Pre-sized to n elements.
Compiles to WasmGC trivially (array.get/array.set/array.len).
parity(quarantine: a dense map keyed by Julia's SSA statement index, WT's compile-time table for per-statement facts.)
"""
struct IntKeyMap{V}
    data::Vector{Union{Nothing, V}}
    function IntKeyMap{V}(n::Int)::IntKeyMap{V} where V
        return new{V}(fill(nothing, n))
    end
    function IntKeyMap{V}(data::Vector{Union{Nothing, V}})::IntKeyMap{V} where V
        return new{V}(data)
    end
end

# parity(quarantine: a dense map keyed by Julia's SSA statement index, WT's compile-time table for per-statement facts.)
Base.getindex(m::IntKeyMap{V}, k::Int) where V = m.data[k]::V
# parity(quarantine: a dense map keyed by Julia's SSA statement index, WT's compile-time table for per-statement facts.)
Base.setindex!(m::IntKeyMap{V}, v::V, k::Int) where V = (m.data[k] = v; v)
# parity(quarantine: a dense map keyed by Julia's SSA statement index, WT's compile-time table for per-statement facts.)
Base.setindex!(m::IntKeyMap{V}, v, k::Int) where V = (m.data[k] = convert(V, v); convert(V, v))
# parity(quarantine: a dense map keyed by Julia's SSA statement index, WT's compile-time table for per-statement facts.)
Base.haskey(m::IntKeyMap, k::Int) = k >= 1 && k <= length(m.data) && m.data[k] !== nothing
# parity(quarantine: a dense map keyed by Julia's SSA statement index, WT's compile-time table for per-statement facts.)
Base.get(m::IntKeyMap{V}, k::Int, default) where V = haskey(m, k) ? m.data[k]::V : default
# parity(quarantine: a dense map keyed by Julia's SSA statement index, WT's compile-time table for per-statement facts.)
Base.delete!(m::IntKeyMap, k::Int) = (if k >= 1 && k <= length(m.data); m.data[k] = nothing; end; m)
# parity(quarantine: a dense map keyed by Julia's SSA statement index, WT's compile-time table for per-statement facts.)
Base.length(m::IntKeyMap) = count(!isnothing, m.data)

# parity(quarantine: a dense map keyed by Julia's SSA statement index, WT's compile-time table for per-statement facts.)
function Base.iterate(m::IntKeyMap{V}, state::Int=1) where V
    while state <= length(m.data)
        if m.data[state] !== nothing
            return (state => m.data[state]::V, state + 1)
        end
        state += 1
    end
    return nothing
end
