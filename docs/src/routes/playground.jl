# Playground page - Interactive Julia REPL powered by WasmGC interpreter
#
# This page provides a full interactive Julia playground where users can:
# 1. Write Julia code with CodeMirror 6 and Julia syntax highlighting
# 2. Execute code via the interpreter compiled to WasmGC by WasmTarget.jl
# 3. See output in real-time
#
# The interpreter is a Julia interpreter written in Julia (src/Interpreter/)
# that has been compiled to WasmGC. It runs entirely in the browser.
#
# Story: BROWSER-030

# InterpreterPlayground is in a subdirectory of components_dir, so it needs explicit include
# (the framework only auto-loads top-level .jl files from components_dir)
include("../components/playground/interpreterplayground.jl")

"""
Main Playground page component.

Provides a full-screen interactive Julia playground with:
- CodeMirror 6 editor with Julia syntax highlighting
- Run button to execute code
- Output panel showing execution results
- Example code snippets
"""
function PlaygroundPage()
    # Full-width playground container
    Div(:class => "w-full -mx-4 sm:-mx-6 lg:-mx-8 px-4 sm:px-6 lg:px-8",

            # Page Header
            Div(:class => "text-center mb-6",
                H1(:class => "text-3xl font-bold text-warm-800 dark:text-warm-100",
                    "Julia Playground"
                ),
                P(:class => "text-warm-500 dark:text-warm-400 mt-2 max-w-2xl mx-auto",
                    "Write and run Julia code directly in your browser. ",
                    "Powered by a Julia interpreter compiled to WebAssembly by WasmTarget.jl."
                )
            ),

            # Playground Component
            Div(:class => "border border-warm-700 rounded-xl overflow-hidden shadow-lg",
                InterpreterPlayground()
            ),

            # Info Panel
            Div(:class => "mt-8 grid md:grid-cols-3 gap-6",

                # How it works
                Div(:class => "p-6 bg-warm-100 dark:bg-warm-900 rounded-xl",
                    H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-100 mb-3",
                        "How It Works"
                    ),
                    P(:class => "text-warm-600 dark:text-warm-400 text-sm",
                        "This playground runs a Julia interpreter that was written in Julia and compiled to WebAssembly (WasmGC) using WasmTarget.jl. Your code is parsed and executed entirely in your browser - no server required."
                    )
                ),

                # Supported Features
                Div(:class => "p-6 bg-warm-100 dark:bg-warm-900 rounded-xl",
                    H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-100 mb-3",
                        "Supported Features"
                    ),
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
                ),

                # Keyboard Shortcuts
                Div(:class => "p-6 bg-warm-100 dark:bg-warm-900 rounded-xl",
                    H3(:class => "text-lg font-semibold text-warm-800 dark:text-warm-100 mb-3",
                        "Keyboard Shortcuts"
                    ),
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
            ),

            # Technical note
            Div(:class => "mt-6 p-4 bg-warm-50 dark:bg-warm-900/20 border border-warm-200 dark:border-warm-700 rounded-xl",
                Div(:class => "flex items-start gap-3",
                    # Icon
                    Div(:class => "flex-shrink-0 w-8 h-8 bg-accent-500 rounded-full flex items-center justify-center",
                        Svg(:class => "w-4 h-4 text-white", :fill => "none", :stroke => "currentColor", :viewBox => "0 0 24 24",
                            Path(:stroke_linecap => "round", :stroke_linejoin => "round", :stroke_width => "2",
                                :d => "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z")
                        )
                    ),
                    # Content
                    Div(:class => "flex-1",
                        P(:class => "text-warm-700 dark:text-warm-300 font-medium text-sm",
                            "100% Browser-Based"
                        ),
                        P(:class => "text-warm-500 dark:text-warm-400 text-xs mt-1",
                            "This playground runs entirely in your browser using WebAssembly. No code is sent to any server. ",
                            "The interpreter is built using WasmTarget.jl's WasmGC compilation, demonstrating that Julia can run in the browser without a traditional server backend."
                        )
                    )
                )
            )
    )
end

# Export
PlaygroundPage
