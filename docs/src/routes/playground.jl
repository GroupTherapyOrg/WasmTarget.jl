# Playground page - Interactive Julia REPL powered by WasmGC interpreter
#
# Uses Suite.jl components for info panels. InterpreterPlayground island PRESERVED.
# The interpreter is a Julia interpreter compiled to WasmGC by WasmTarget.jl.

import Suite

# InterpreterPlayground is in a subdirectory of components_dir, so it needs explicit include
# (the framework only auto-loads top-level .jl files from components_dir)
include("../components/playground/interpreterplayground.jl")

"""
Main Playground page component.
"""
function PlaygroundPage()
    # Full-width playground container
    Div(:class => "w-full -mx-4 sm:-mx-6 lg:-mx-8 px-4 sm:px-6 lg:px-8",

            # Page Header
            Div(:class => "text-center mb-6",
                H1(:class => "text-3xl font-serif font-semibold text-warm-800 dark:text-warm-100",
                    "Julia Playground"
                ),
                P(:class => "text-warm-500 dark:text-warm-400 mt-2 max-w-2xl mx-auto",
                    "Write and run Julia code directly in your browser. ",
                    "Powered by a Julia interpreter compiled to WebAssembly by WasmTarget.jl."
                )
            ),

            # Playground Component (PRESERVED — interactive island)
            Div(:class => "border border-warm-700 rounded-xl overflow-hidden shadow-lg",
                InterpreterPlayground()
            ),

            # Info Panel — Suite.Card grid
            Div(:class => "mt-8 grid md:grid-cols-3 gap-6",

                # How it works
                Suite.Card(
                    Suite.CardHeader(Suite.CardTitle("How It Works")),
                    Suite.CardContent(
                        P(:class => "text-warm-600 dark:text-warm-400 text-sm",
                            "This playground runs a Julia interpreter that was written in Julia and compiled to WebAssembly (WasmGC) using WasmTarget.jl. Your code is parsed and executed entirely in your browser - no server required."
                        )
                    )
                ),

                # Supported Features
                Suite.Card(
                    Suite.CardHeader(Suite.CardTitle("Supported Features")),
                    Suite.CardContent(
                        Ul(:class => "text-warm-600 dark:text-warm-400 text-sm space-y-1",
                            Li("Variables and assignment"),
                            Li("Arithmetic operations"),
                            Li("Function definitions"),
                            Li("If/else conditionals"),
                            Li("While and for loops"),
                            Li("Recursion"),
                            Li("String operations"),
                            Li("println() output")
                        )
                    )
                ),

                # Keyboard Shortcuts
                Suite.Card(
                    Suite.CardHeader(Suite.CardTitle("Keyboard Shortcuts")),
                    Suite.CardContent(
                        Ul(:class => "text-warm-600 dark:text-warm-400 text-sm space-y-1",
                            Li(
                                Code(:class => "bg-warm-200 dark:bg-warm-700 px-1 rounded", "Ctrl"),
                                " + ",
                                Code(:class => "bg-warm-200 dark:bg-warm-700 px-1 rounded", "Enter"),
                                " - Run code"
                            ),
                            Li(
                                Code(:class => "bg-warm-200 dark:bg-warm-700 px-1 rounded", "Tab"),
                                " - Indent"
                            ),
                            Li(
                                Code(:class => "bg-warm-200 dark:bg-warm-700 px-1 rounded", "Ctrl"),
                                " + ",
                                Code(:class => "bg-warm-200 dark:bg-warm-700 px-1 rounded", "Z"),
                                " - Undo"
                            )
                        )
                    )
                )
            ),

            # Technical note
            Suite.Alert(class="mt-6",
                Suite.AlertTitle("100% Browser-Based"),
                Suite.AlertDescription(
                    "This playground runs entirely in your browser using WebAssembly. No code is sent to any server. ",
                    "The interpreter is built using WasmTarget.jl's WasmGC compilation, demonstrating that Julia can run in the browser without a traditional server backend."
                )
            )
    )
end

# Export
PlaygroundPage
