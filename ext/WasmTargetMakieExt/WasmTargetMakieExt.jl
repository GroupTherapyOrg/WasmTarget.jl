module WasmTargetMakieExt

using WasmTarget: WASM_METHOD_TABLE, WasmFigure, WasmAxis, WasmPlotRef
using WasmTarget: _wasm_heatmap, _wasm_lines, _wasm_scatter, _wasm_display
using Makie
using Base.Experimental: @overlay

# ─── Figure overlay ──────────────────────────────────────────────────────
# Makie.Figure() → lightweight WasmFigure with fixed ID.
# JS side assigns the real Three.js renderer when instantiated.

@overlay WASM_METHOD_TABLE function Makie.Figure(; kwargs...)
    WasmFigure(Int64(1))
end

# ─── Axis overlay ────────────────────────────────────────────────────────
# Makie.Axis(fig[1,1]) → lightweight WasmAxis linked to the figure.

@overlay WASM_METHOD_TABLE function Makie.Axis(fig::WasmFigure, args...; kwargs...)
    WasmAxis(fig.id, Int64(1))
end

# ─── heatmap! overlay ────────────────────────────────────────────────────
# Calls imported JS function with axis ID + dimensions, then returns a
# WasmPlotRef. Uses Vector{Float64} as flattened matrix representation.

@overlay WASM_METHOD_TABLE function Makie.heatmap!(ax::WasmAxis, data::Vector{Float64}; kwargs...)
    _wasm_heatmap(ax.id, Int64(length(data)), Int64(1))
    WasmPlotRef(ax.id, Int64(1))
end

# ─── lines! overlay ──────────────────────────────────────────────────────
# Calls imported JS function with axis ID + point count.

@overlay WASM_METHOD_TABLE function Makie.lines!(ax::WasmAxis, x::Vector{Float64}, y::Vector{Float64}; kwargs...)
    _wasm_lines(ax.id, Int64(length(x)))
    WasmPlotRef(ax.id, Int64(2))
end

# ─── scatter! overlay ────────────────────────────────────────────────────
# Calls imported JS function with axis ID + point count.

@overlay WASM_METHOD_TABLE function Makie.scatter!(ax::WasmAxis, x::Vector{Float64}, y::Vector{Float64}; kwargs...)
    _wasm_scatter(ax.id, Int64(length(x)))
    WasmPlotRef(ax.id, Int64(3))
end

# ─── display overlay ────────────────────────────────────────────────────
# Calls imported JS function to trigger Three.js rendering.

@overlay WASM_METHOD_TABLE function Base.display(fig::WasmFigure)
    _wasm_display(fig.id)
    nothing
end

end # module
