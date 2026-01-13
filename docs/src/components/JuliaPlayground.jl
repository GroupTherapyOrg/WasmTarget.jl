# JuliaPlayground.jl - Rust Playground-style Julia REPL
#
# Architecture:
# - Ships trimmed Julia runtime (~2-5MB WASM) to browser
# - User writes ANY Julia code in editable textarea
# - "Run" compiles code via Julia compiler running in browser
# - Compiled WASM executes and shows result
#
# Follows Therapy.jl patterns: Int signals, simple handlers

# Starter code shown when page loads
const STARTER_CODE = """function sum_to_n(n::Int32)::Int32
    result = Int32(0)
    i = Int32(1)
    while i <= n
        result = result + i
        i = i + Int32(1)
    end
    return result
end

# Call: sum_to_n(100)"""

"""
Julia Playground - True REPL with arbitrary code execution.
User writes any Julia code in an editable textarea.
When trimmed Julia runtime is ready, "Run" compiles and executes it.
"""
JuliaPlayground = island(:JuliaPlayground) do
    # State - use Int signals like Therapy.jl patterns
    code, set_code = create_signal(STARTER_CODE)
    output, set_output = create_signal("")
    is_running, set_is_running = create_signal(0)  # 0=idle, 1=running

    Div(:class => "max-w-6xl mx-auto",
        # Top bar with Run button
        Div(:class => "flex items-center justify-between mb-4",
            # Left: Info text
            Span(:class => "text-stone-500 dark:text-stone-400 text-sm",
                "Edit Julia code below"
            ),

            # Right: Run button
            Button(:class => "flex items-center gap-2 bg-cyan-500 hover:bg-cyan-600 text-white px-6 py-2 rounded-lg font-semibold transition-colors shadow-lg shadow-cyan-500/20",
                :on_click => () -> begin
                    set_is_running(1)
                    set_output("Compiling... (trimmed runtime loading)")
                    set_is_running(0)
                end,
                # Play icon
                Svg(:class => "w-4 h-4", :fill => "currentColor", :viewBox => "0 0 24 24",
                    Path(:d => "M8 5v14l11-7z")
                ),
                "Run"
            )
        ),

        # Main content: Editor + Output side by side
        Div(:class => "grid lg:grid-cols-2 gap-4",
            # Code editor panel
            Div(:class => "flex flex-col",
                Div(:class => "flex items-center justify-between px-4 py-2 bg-stone-700 dark:bg-stone-800 rounded-t-xl",
                    Span(:class => "text-stone-300 text-sm font-medium", "Julia"),
                    Span(:class => "text-stone-500 text-xs", "Edit freely")
                ),
                Textarea(:class => "bg-stone-800 dark:bg-stone-900 p-4 rounded-b-xl text-sm text-stone-100 font-mono min-h-[400px] w-full resize-y focus:outline-none focus:ring-2 focus:ring-cyan-500",
                    :value => code,
                    :on_input => (e) -> set_code(e.target.value),
                    :spellcheck => "false"
                )
            ),

            # Output panel
            Div(:class => "flex flex-col",
                Div(:class => "flex items-center justify-between px-4 py-2 bg-stone-700 dark:bg-stone-800 rounded-t-xl",
                    Span(:class => "text-stone-300 text-sm font-medium", "Output"),
                    Span(:class => "text-amber-400 text-xs", "Runtime loading...")
                ),
                Div(:class => "bg-stone-900 dark:bg-black p-4 rounded-b-xl flex-1 min-h-[400px] font-mono overflow-auto",
                    Pre(:class => "text-sm text-stone-400 whitespace-pre-wrap", output)
                )
            )
        ),

        # Footer info
        Div(:class => "mt-6 p-4 bg-stone-100 dark:bg-stone-800 rounded-xl",
            P(:class => "text-stone-700 dark:text-stone-200 font-medium text-sm",
                "How it works"
            ),
            P(:class => "text-stone-500 dark:text-stone-400 text-xs mt-1",
                "A trimmed Julia runtime runs in your browser. When you click Run, your code is parsed by JuliaSyntax, type-inferred, and compiled to WebAssembly by WasmTarget.jl - all client-side."
            )
        )
    )
end
