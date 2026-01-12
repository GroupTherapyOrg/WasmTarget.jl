# WasmPlayground.jl - Interactive Wasm playground island
#
# A simple interactive demo showing Julia compiled to WebAssembly.
# Demonstrates arithmetic operations and state management.

"""
Interactive Wasm playground - demonstrates Julia compiled to WebAssembly.

Features:
- Counter with +/- controls
- Multiply/divide operations
- Reset functionality
- All logic runs as WebAssembly in the browser
"""
WasmPlayground = island(:WasmPlayground) do
    # State: current value
    value, set_value = create_signal(0)

    Div(:class => "bg-stone-800 dark:bg-stone-950 rounded-2xl p-8 shadow-xl max-w-md mx-auto",
        # Title
        Div(:class => "text-center mb-6",
            H3(:class => "text-lg font-semibold text-cyan-400", "Julia WASM Playground"),
            P(:class => "text-stone-400 text-sm", "Try it out - all code runs as WebAssembly!")
        ),

        # Display
        Div(:class => "bg-stone-900 dark:bg-black rounded-xl p-6 mb-6 text-center",
            Span(:class => "text-5xl font-mono font-bold text-cyan-400 tabular-nums", value)
        ),

        # Primary controls: +1, -1
        Div(:class => "flex justify-center gap-4 mb-4",
            Button(:class => "w-16 h-16 rounded-xl text-2xl font-bold bg-stone-700 hover:bg-stone-600 text-white transition-all hover:scale-105 shadow-lg",
                :on_click => () -> set_value(value() - 1),
                "-1"
            ),
            Button(:class => "w-16 h-16 rounded-xl text-2xl font-bold bg-stone-700 hover:bg-stone-600 text-white transition-all hover:scale-105 shadow-lg",
                :on_click => () -> set_value(value() + 1),
                "+1"
            )
        ),

        # Secondary controls: x2, /2, +10, -10
        Div(:class => "flex justify-center gap-3 mb-4",
            Button(:class => "px-4 py-2 rounded-lg text-sm font-semibold bg-cyan-600 hover:bg-cyan-500 text-white transition-colors",
                :on_click => () -> set_value(value() * 2),
                "x2"
            ),
            Button(:class => "px-4 py-2 rounded-lg text-sm font-semibold bg-cyan-600 hover:bg-cyan-500 text-white transition-colors",
                :on_click => () -> set_value(div(value(), 2)),
                "/2"
            ),
            Button(:class => "px-4 py-2 rounded-lg text-sm font-semibold bg-cyan-600 hover:bg-cyan-500 text-white transition-colors",
                :on_click => () -> set_value(value() + 10),
                "+10"
            ),
            Button(:class => "px-4 py-2 rounded-lg text-sm font-semibold bg-cyan-600 hover:bg-cyan-500 text-white transition-colors",
                :on_click => () -> set_value(value() - 10),
                "-10"
            )
        ),

        # Reset
        Div(:class => "flex justify-center",
            Button(:class => "px-6 py-2 rounded-lg text-sm font-semibold bg-stone-600 hover:bg-stone-500 text-white transition-colors",
                :on_click => () -> set_value(0),
                "Reset"
            )
        ),

        # Footer
        P(:class => "text-center text-stone-500 text-xs mt-6",
            "Powered by WasmTarget.jl - 100% Julia, 0% JavaScript"
        )
    )
end
