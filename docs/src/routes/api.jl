# API Reference page - Placeholder
#
# Will contain full API documentation

function Api()
    Layout(
        # Header
        Div(:class => "py-12 text-center",
            H1(:class => "text-4xl font-bold text-stone-800 dark:text-stone-100 mb-4",
                "API Reference"
            ),
            P(:class => "text-xl text-stone-500 dark:text-stone-400 max-w-2xl mx-auto",
                "Complete API documentation for WasmTarget.jl"
            )
        ),

        # Coming soon notice
        Div(:class => "py-16 text-center",
            Div(:class => "bg-cyan-50 dark:bg-cyan-950/30 rounded-2xl p-12 max-w-2xl mx-auto",
                Div(:class => "w-16 h-16 bg-cyan-100 dark:bg-cyan-900/50 rounded-full flex items-center justify-center mx-auto mb-6",
                    Svg(:class => "w-8 h-8 text-cyan-500", :fill => "none", :viewBox => "0 0 24 24", :stroke => "currentColor", :stroke_width => "2",
                        Path(:stroke_linecap => "round", :stroke_linejoin => "round",
                             :d => "M12 6.253v13m0-13C10.832 5.477 9.246 5 7.5 5S4.168 5.477 3 6.253v13C4.168 18.477 5.754 18 7.5 18s3.332.477 4.5 1.253m0-13C13.168 5.477 14.754 5 16.5 5c1.747 0 3.332.477 4.5 1.253v13C19.832 18.477 18.247 18 16.5 18c-1.746 0-3.332.477-4.5 1.253")
                    )
                ),
                H2(:class => "text-2xl font-bold text-stone-800 dark:text-stone-100 mb-4",
                    "Documentation Coming Soon"
                ),
                P(:class => "text-stone-600 dark:text-stone-300 mb-8",
                    "Full API documentation is being written. In the meantime, check out the README and source code on GitHub."
                ),
                A(:href => "https://github.com/TherapeuticJulia/WasmTarget.jl",
                  :class => "inline-block bg-cyan-500 hover:bg-cyan-600 text-white px-6 py-3 rounded-lg font-medium transition-colors",
                  :target => "_blank",
                  "View README on GitHub"
                )
            )
        ),

        # Quick reference preview
        Div(:class => "py-12",
            H2(:class => "text-2xl font-bold text-stone-800 dark:text-stone-100 mb-8 text-center",
                "Quick Reference"
            ),

            # API sections
            Div(:class => "grid md:grid-cols-2 lg:grid-cols-3 gap-6 max-w-5xl mx-auto",
                ApiCard(
                    "compile()",
                    "Compile a single Julia function to WebAssembly bytes.",
                    "compile(f, arg_types) -> Vector{UInt8}"
                ),
                ApiCard(
                    "compile_multi()",
                    "Compile multiple functions into a single Wasm module.",
                    "compile_multi([(f, types, name), ...]) -> Vector{UInt8}"
                ),
                ApiCard(
                    "WasmModule()",
                    "Create an empty Wasm module for low-level building.",
                    "mod = WasmModule()"
                ),
                ApiCard(
                    "add_function!()",
                    "Add a function to a Wasm module.",
                    "add_function!(mod, params, results, locals, body)"
                ),
                ApiCard(
                    "add_import!()",
                    "Import a function from JavaScript.",
                    "add_import!(mod, \"js\", \"log\", [I32], [])"
                ),
                ApiCard(
                    "to_bytes()",
                    "Serialize a WasmModule to binary .wasm format.",
                    "bytes = to_bytes(mod)"
                )
            )
        ),

        # Supported types
        Div(:class => "py-12 bg-white dark:bg-stone-800 rounded-2xl shadow-sm",
            H2(:class => "text-2xl font-bold text-stone-800 dark:text-stone-100 mb-8 text-center",
                "Type Constants"
            ),
            Div(:class => "flex flex-wrap justify-center gap-3 px-8",
                TypeBadge("I32"),
                TypeBadge("I64"),
                TypeBadge("F32"),
                TypeBadge("F64"),
                TypeBadge("ExternRef"),
                TypeBadge("FuncRef"),
                TypeBadge("AnyRef")
            ),
            P(:class => "text-center text-stone-500 dark:text-stone-400 text-sm mt-6",
                "Use these constants when building Wasm modules manually"
            )
        )
    )
end

"""
API card component.
"""
function ApiCard(name, description, signature)
    Div(:class => "bg-stone-50 dark:bg-stone-700 rounded-xl p-6",
        H3(:class => "text-lg font-semibold text-cyan-600 dark:text-cyan-400 font-mono mb-2", name),
        P(:class => "text-stone-600 dark:text-stone-300 text-sm mb-4", description),
        Code(:class => "text-xs bg-stone-200 dark:bg-stone-800 px-2 py-1 rounded text-stone-700 dark:text-stone-300", signature)
    )
end

"""
Type badge component.
"""
function TypeBadge(name)
    Span(:class => "px-4 py-2 bg-stone-100 dark:bg-stone-700 rounded-lg font-mono text-sm text-stone-700 dark:text-stone-200", name)
end

# Export the page component
Api
