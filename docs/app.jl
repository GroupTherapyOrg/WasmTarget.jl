#!/usr/bin/env julia
# WasmTarget.jl Documentation Site
#
# Usage (from WasmTarget.jl root directory):
#   julia --project=docs docs/app.jl dev    # Development server with HMR
#   julia --project=docs docs/app.jl build  # Build static site to docs/dist
#
# This site dogfoods Therapy.jl's App framework with:
# - File-based routing from src/routes/
# - Automatic component loading from src/components/
# - WasmTarget.jl is the package being documented

if !haskey(ENV, "JULIA_PROJECT")
    using Pkg
    Pkg.activate(@__DIR__)
end

using Therapy

# Loaded so WasmTarget's weakdep extensions (Statistics / LinearAlgebra /
# ForwardDiff) activate in THIS process — the interactive examples on /examples/
# are @island components whose create_memo bodies call these libraries, and
# WasmTarget compiles them to WasmGC against the live overlay method table here.
using Statistics
using LinearAlgebra
using ForwardDiff
using StaticArrays
using SimpleDiffEq
using SciMLBase
using WasmMakie

# The homepage Lorenz island draws through WasmMakie's Canvas2D import surface —
# register the provider so Therapy backs the island's `render!` canvas ops with
# WasmMakie's JS glue + the host <canvas> (the generic provider contract, E-002).
Therapy.register_canvas_provider!(name = "WasmMakie",
    import_specs = WasmMakie.import_specs, js_glue = WasmMakie.js_glue)

cd(@__DIR__)

# =============================================================================
# App Configuration
# =============================================================================

app = App(
    routes_dir = "src/routes",
    components_dir = "src/components",
    title = "WasmTarget.jl",
    output_dir = "dist",
    base_path = "/WasmTarget.jl",
    layout = :Layout
)

# =============================================================================
# Run - dev or build based on args
# =============================================================================

Therapy.run(app)
