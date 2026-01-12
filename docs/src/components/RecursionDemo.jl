# RecursionDemo.jl - Demonstrates loops

"""
Demo: Loop-based computation compiled to Wasm.
Shows iterative factorial calculation.
"""
RecursionDemo = island(:RecursionDemo) do
    n, set_n = create_signal(5)
    result, set_result = create_signal(120)  # 5! = 120

    Div(:class => "bg-stone-800 rounded-xl p-6",
        # Input
        Div(:class => "text-center mb-6",
            Label(:class => "text-stone-400 text-sm block mb-2", "n"),
            Div(:class => "flex items-center justify-center gap-2",
                Button(:class => "w-8 h-8 rounded bg-stone-700 hover:bg-stone-600 text-white",
                    :on_click => () -> set_n(n() > 0 ? n() - 1 : 0),
                    "-"
                ),
                Span(:class => "w-12 text-center text-3xl font-mono text-cyan-400", n),
                Button(:class => "w-8 h-8 rounded bg-stone-700 hover:bg-stone-600 text-white",
                    :on_click => () -> set_n(n() < 12 ? n() + 1 : 12),
                    "+"
                )
            ),
            P(:class => "text-stone-500 text-xs mt-2", "(max 12 to prevent overflow)")
        ),

        # Preset buttons for quick factorial values
        Div(:class => "flex justify-center gap-2 mb-4 flex-wrap",
            Button(:class => "px-3 py-2 rounded bg-cyan-600 hover:bg-cyan-500 text-white text-sm",
                :on_click => () -> begin set_n(0); set_result(1) end,
                "0! = 1"
            ),
            Button(:class => "px-3 py-2 rounded bg-cyan-600 hover:bg-cyan-500 text-white text-sm",
                :on_click => () -> begin set_n(5); set_result(120) end,
                "5! = 120"
            ),
            Button(:class => "px-3 py-2 rounded bg-cyan-600 hover:bg-cyan-500 text-white text-sm",
                :on_click => () -> begin set_n(10); set_result(3628800) end,
                "10! = 3628800"
            )
        ),

        # Result display
        Div(:class => "bg-stone-900 rounded-lg p-4 text-center",
            P(:class => "text-stone-400 text-sm mb-1", "n!"),
            Span(:class => "text-3xl font-mono font-bold text-cyan-400", result)
        ),

        P(:class => "text-center text-stone-500 text-xs mt-4",
            "Factorial uses recursive Wasm function calls"
        )
    )
end
