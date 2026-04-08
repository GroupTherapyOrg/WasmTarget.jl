module WasmTargetMakieExt

using WasmTarget: WASM_METHOD_TABLE, WasmFigure, WasmAxis, WasmPlotRef
using Makie
using Base.Experimental: @overlay

# ─── Figure overlay ──────────────────────────────────────────────────────
# Why: Makie.Figure() creates a complex Scene/Layout/Observable graph.
#      The WASM overlay returns a lightweight WasmFigure with a fixed ID.
#      The JS side assigns the real Three.js renderer ID when instantiated.

@overlay WASM_METHOD_TABLE function Makie.Figure(; kwargs...)
    WasmFigure(Int64(1))
end

# ─── Axis overlay ────────────────────────────────────────────────────────
# Why: Makie.Axis(fig[1,1]) creates layout cells, tick calculations, etc.
#      The WASM overlay returns a lightweight WasmAxis linked to the figure.
#      The JS side sets up the actual viewport/camera.

@overlay WASM_METHOD_TABLE function Makie.Axis(fig::WasmFigure, args...; kwargs...)
    WasmAxis(fig.id, Int64(1))
end

# ─── heatmap! overlays ───────────────────────────────────────────────────
# Why: Makie.heatmap!(ax, data) creates complex plot objects with observables.
#      The WASM overlay returns a WasmPlotRef tracking the axis + plot ID.
#      The actual Three.js heatmap is created by the JS import at the
#      island/E2E level (not in the overlay itself).
#      Matrix{Float64} doesn't compile yet — use Vector{Float64} + dimensions
#      as a flattened representation (row-major, pass rows/cols separately).

@overlay WASM_METHOD_TABLE function Makie.heatmap!(ax::WasmAxis, data::Vector{Float64}; kwargs...)
    WasmPlotRef(ax.id, Int64(1))
end

# ─── lines! overlay ─────────────────────────────────────────────────────
# Why: Makie.lines!(ax, x, y) builds line geometry with observables.
#      The WASM overlay returns a WasmPlotRef.

@overlay WASM_METHOD_TABLE function Makie.lines!(ax::WasmAxis, x::Vector{Float64}, y::Vector{Float64}; kwargs...)
    WasmPlotRef(ax.id, Int64(2))
end

# ─── scatter! overlay ────────────────────────────────────────────────────
# Why: Makie.scatter!(ax, x, y) builds scatter geometry with observables.
#      The WASM overlay returns a WasmPlotRef.

@overlay WASM_METHOD_TABLE function Makie.scatter!(ax::WasmAxis, x::Vector{Float64}, y::Vector{Float64}; kwargs...)
    WasmPlotRef(ax.id, Int64(3))
end

# ─── display overlay ────────────────────────────────────────────────────
# Why: Base.display(fig) triggers Makie's complex rendering pipeline.
#      The WASM overlay is a no-op — rendering is triggered by the JS side
#      after the WASM module finishes executing.

@overlay WASM_METHOD_TABLE function Base.display(fig::WasmFigure)
    nothing
end

end # module
