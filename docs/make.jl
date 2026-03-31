using Documenter
using WasmTarget

# Pre-compile WASM examples for live demos
include("build_wasm_examples.jl")

makedocs(
    sitename = "WasmTarget.jl",
    modules = [WasmTarget],
    checkdocs = :exports,
    warnonly = true,
    pages = [
        "Home" => "index.md",
        "Getting Started" => "getting-started.md",
        "Manual" => [
            "Type Mappings" => "manual/types.md",
            "Math Functions" => "manual/math.md",
            "Collections" => "manual/collections.md",
            "Structs & Tuples" => "manual/structs.md",
            "Control Flow" => "manual/control-flow.md",
            "JS Interop" => "manual/js-interop.md",
        ],
        "API Reference" => "api.md",
        "Playground" => "playground.md",
    ],
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://grouptherapyorg.github.io/WasmTarget.jl",
        assets = ["assets/wasm-runner.js"],
    ),
)
