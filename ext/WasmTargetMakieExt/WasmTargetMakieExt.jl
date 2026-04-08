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

end # module
