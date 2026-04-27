() -> begin
    Div(:class => "space-y-16",
        # Hero
        Div(:class => "text-center space-y-6 pt-8",
            H1(:class => "no-rule text-5xl md:text-6xl font-serif font-bold text-warm-900 dark:text-warm-100",
                "Julia to WebAssembly"
            ),
            H1(:class => "no-rule text-5xl md:text-6xl font-serif font-bold text-accent-500",
                "Targeting WasmGC"
            ),
            P(:class => "text-lg text-warm-600 dark:text-warm-400 max-w-2xl mx-auto leading-relaxed",
                "Compile real Julia functions to WebAssembly that runs in any modern browser or Node.js. ",
                "No runtime, no LLVM. Inspired by ",
                A(:href => "https://dart.dev/web/wasm", :target => "_blank", :class => "text-accent-500 hover:text-accent-600 underline", "dart2wasm"),
                ". Powers ",
                A(:href => "https://github.com/GroupTherapyOrg/Therapy.jl", :target => "_blank", :class => "text-accent-500 hover:text-accent-600 underline", "Therapy.jl"),
                " for build-time island compilation."
            ),
            Div(:class => "flex gap-4 justify-center pt-4",
                A(:href => "/WasmTarget.jl/getting-started/",
                    :class => "px-6 py-3 bg-accent-600 hover:bg-accent-700 text-white rounded-lg font-medium transition-colors",
                    "Get Started"
                ),
                A(:href => "https://github.com/GroupTherapyOrg/WasmTarget.jl", :target => "_blank",
                    :class => "px-6 py-3 border border-warm-300 dark:border-warm-700 rounded-lg font-medium text-warm-700 dark:text-warm-300 hover:bg-warm-100 dark:hover:bg-warm-900 transition-colors",
                    "View on GitHub"
                )
            )
        ),
        # How It Works — pipeline + quick example side-by-side feel via stacked blocks
        Div(:class => "max-w-3xl mx-auto space-y-6",
            H2(:class => "text-2xl font-serif font-semibold text-warm-900 dark:text-warm-100", "How It Works"),
            P(:class => "text-warm-600 dark:text-warm-400 leading-relaxed",
                "Julia's compiler does the heavy lifting — parsing, macro expansion, type inference, optimization. ",
                "WasmTarget gets the fully type-inferred IR via ",
                Code(:class => "text-accent-500 font-mono", "Base.code_typed()"),
                " and translates it to WasmGC bytecode."
            ),
            Pre(:class => "bg-warm-900 dark:bg-warm-950 text-warm-200 p-6 rounded-lg overflow-x-auto border border-warm-800",
                Code(:class => "language-text text-sm font-mono",
                    "Julia source → Julia compiler (parse, lower, infer) → Typed IR → WasmTarget → .wasm")
            ),
            P(:class => "text-warm-600 dark:text-warm-400 leading-relaxed",
                "For functions with complex IR (GC internals, C library calls, deep dispatch), WasmTarget provides ",
                A(:href => "https://github.com/JuliaGPU/GPUCompiler.jl", :target => "_blank", :class => "text-accent-500 underline", "method overlays"),
                " — the same pattern CUDA.jl uses."
            ),
        ),
        # Quick example
        Div(:class => "max-w-3xl mx-auto space-y-4",
            H2(:class => "text-2xl font-serif font-semibold text-warm-900 dark:text-warm-100", "Quick Example"),
            Pre(:class => "bg-warm-900 dark:bg-warm-950 text-warm-200 p-6 rounded-lg overflow-x-auto border border-warm-800",
                Code(:class => "language-julia text-sm font-mono", """using WasmTarget
bytes = compile(sin, (Float64,))
write("sin.wasm", bytes)""")
            ),
            P(:class => "text-sm text-warm-500 dark:text-warm-500",
                "See ",
                A(:href => "/WasmTarget.jl/getting-started/", :class => "text-accent-500 hover:text-accent-600 underline", "Getting Started"),
                " for installation, or the ",
                A(:href => "/WasmTarget.jl/manual/", :class => "text-accent-500 hover:text-accent-600 underline", "Manual"),
                " for type mappings, control flow, and JS interop."
            )
        ),
        # Status cards
        Div(:class => "grid grid-cols-1 md:grid-cols-3 gap-6",
            Div(:class => "border border-warm-200 dark:border-warm-800 rounded-lg p-6 bg-warm-100/50 dark:bg-warm-900/50",
                Div(:class => "w-10 h-10 rounded-lg bg-accent-100 dark:bg-accent-900/50 flex items-center justify-center mb-4",
                    RawHtml("""<svg class="w-5 h-5 text-accent-600 dark:text-accent-400" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M9 11l3 3L22 4"/><path d="M21 12v7a2 2 0 01-2 2H5a2 2 0 01-2-2V5a2 2 0 012-2h11"/></svg>""")
                ),
                H3(:class => "font-semibold mb-2 text-warm-900 dark:text-warm-100", "176 functions, 2409 tests"),
                P(:class => "text-warm-600 dark:text-warm-400 text-sm leading-relaxed",
                    "127 native paths (real Base IR), 48 overlay reimplementations, 1 blocked. ",
                    "Verified across Int32 / Int64 / UInt32 / UInt64 / Float32 / Float64.")
            ),
            Div(:class => "border border-warm-200 dark:border-warm-800 rounded-lg p-6 bg-warm-100/50 dark:bg-warm-900/50",
                Div(:class => "w-10 h-10 rounded-lg bg-accent-secondary-100 dark:bg-accent-secondary-900/50 flex items-center justify-center mb-4",
                    RawHtml("""<svg class="w-5 h-5 text-accent-secondary-600 dark:text-accent-secondary-400" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/></svg>""")
                ),
                H3(:class => "font-semibold mb-2 text-warm-900 dark:text-warm-100", "Binaryen-optimized"),
                P(:class => "text-warm-600 dark:text-warm-400 text-sm leading-relaxed",
                    "Optional ", Code(:class => "text-accent-500 font-mono text-xs", "wasm-opt"),
                    " pass yields ~85% size reduction with zero behavioral regressions across the suite.")
            ),
            Div(:class => "border border-warm-200 dark:border-warm-800 rounded-lg p-6 bg-warm-100/50 dark:bg-warm-900/50",
                Div(:class => "w-10 h-10 rounded-lg bg-accent-100 dark:bg-accent-900/50 flex items-center justify-center mb-4",
                    RawHtml("""<svg class="w-5 h-5 text-accent-600 dark:text-accent-400" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="16 18 22 12 16 6"/><polyline points="8 6 2 12 8 18"/></svg>""")
                ),
                H3(:class => "font-semibold mb-2 text-warm-900 dark:text-warm-100", "Composable IR"),
                P(:class => "text-warm-600 dark:text-warm-400 text-sm leading-relaxed",
                    "Nested closures, deep compositions (8+ layers), and 20-function modules all verified. ",
                    "Functions in the same ", Code(:class => "text-accent-500 font-mono text-xs", "compile_multi"),
                    " call share the WasmGC type space.")
            )
        )
    )
end
