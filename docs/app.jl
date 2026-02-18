#!/usr/bin/env julia
# WasmTarget.jl Documentation Site
#
# Usage (from WasmTarget.jl root directory):
#   julia --project=../Therapy.jl docs/app.jl dev    # Development server with HMR
#   julia --project=../Therapy.jl docs/app.jl build  # Build static site to docs/dist
#
# This site uses Therapy.jl's App framework with:
# - File-based routing from src/routes/
# - Automatic component loading from src/components/
# - Interactive Wasm components with HMR in dev mode

# Ensure we're using Therapy.jl and WasmTarget.jl
# For local development, both packages are in the parent TherapeuticJulia directory
if !haskey(ENV, "JULIA_PROJECT")
    # Running without --project, add paths manually
    parent_dir = dirname(dirname(@__DIR__))
    push!(LOAD_PATH, joinpath(parent_dir, "Therapy.jl"))
    push!(LOAD_PATH, dirname(@__DIR__))  # Add WasmTarget.jl
end

# Use local packages if available (for development)
local_therapy = joinpath(dirname(@__DIR__), "..", "Therapy.jl")
if isdir(local_therapy)
    push!(LOAD_PATH, local_therapy)
end
push!(LOAD_PATH, dirname(@__DIR__))  # Always add WasmTarget.jl itself

using Therapy

# Change to docs directory for relative paths
cd(@__DIR__)

# =============================================================================
# App Configuration
# =============================================================================

# Islands are auto-discovered from component files that use island()
app = App(
    routes_dir = "src/routes",
    components_dir = "src/components",
    title = "WasmTarget.jl",
    output_dir = "dist",
    # Base path for GitHub Pages (https://grouptherapyorg.github.io/WasmTarget.jl/)
    base_path = "/WasmTarget.jl",
    # App-level layout for SPA navigation (routes return just content, not wrapped in Layout)
    layout = :Layout
)

# =============================================================================
# Run - dev or build based on args
# =============================================================================

Therapy.run(app)

# =============================================================================
# Post-build: Copy playground assets to dist/playground/
# =============================================================================

if length(ARGS) >= 1 && ARGS[1] == "build"
    playground_dist = joinpath("dist", "playground")
    browser_dir = joinpath(dirname(@__DIR__), "browser")

    # Overwrite the route-generated index.html with the standalone playground
    # This replaces the docs layout wrapper entirely — the playground has its own UI
    src_html = joinpath(browser_dir, "playground.html")
    if isfile(src_html)
        cp(src_html, joinpath(playground_dist, "index.html"); force=true)
        println("  Replaced: playground/index.html (standalone playground)")
    end

    # Copy pipeline wasm (the playground loads it from relative path)
    src_wasm = joinpath(browser_dir, "pipeline-optimized.wasm")
    if isfile(src_wasm)
        cp(src_wasm, joinpath(playground_dist, "pipeline-optimized.wasm"); force=true)
        println("  Copied: playground/pipeline-optimized.wasm")
    end
end
