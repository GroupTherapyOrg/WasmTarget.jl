# ControlFlowDemo.jl - Demonstrates control flow (if/else, comparisons)

"""
Demo: Control flow operations compiled to Wasm.
Shows if/else branches with comparisons.
"""
ControlFlowDemo = island(:ControlFlowDemo) do
    n, set_n = create_signal(5)
    result, set_result = create_signal(1)  # 1 = positive

    Div(:class => "bg-stone-800 rounded-xl p-6",
        # Input
        Div(:class => "text-center mb-6",
            Label(:class => "text-stone-400 text-sm block mb-2", "n"),
            Div(:class => "flex items-center justify-center gap-2",
                Button(:class => "w-10 h-10 rounded bg-stone-700 hover:bg-stone-600 text-white text-lg",
                    :on_click => () -> set_n(n() - 5), "-5"),
                Button(:class => "w-8 h-8 rounded bg-stone-700 hover:bg-stone-600 text-white",
                    :on_click => () -> set_n(n() - 1), "-"),
                Span(:class => "w-16 text-center text-3xl font-mono text-cyan-400", n),
                Button(:class => "w-8 h-8 rounded bg-stone-700 hover:bg-stone-600 text-white",
                    :on_click => () -> set_n(n() + 1), "+"),
                Button(:class => "w-10 h-10 rounded bg-stone-700 hover:bg-stone-600 text-white text-lg",
                    :on_click => () -> set_n(n() + 5), "+5")
            )
        ),

        # Check buttons
        Div(:class => "flex justify-center gap-2 mb-4 flex-wrap",
            Button(:class => "px-3 py-2 rounded bg-cyan-600 hover:bg-cyan-500 text-white text-sm",
                :on_click => () -> set_result(n() > 0 ? 1 : 0),
                "n > 0?"
            ),
            Button(:class => "px-3 py-2 rounded bg-cyan-600 hover:bg-cyan-500 text-white text-sm",
                :on_click => () -> set_result(n() == 0 ? 1 : 0),
                "n == 0?"
            ),
            Button(:class => "px-3 py-2 rounded bg-cyan-600 hover:bg-cyan-500 text-white text-sm",
                :on_click => () -> set_result(n() < 0 ? 1 : 0),
                "n < 0?"
            ),
            Button(:class => "px-3 py-2 rounded bg-cyan-600 hover:bg-cyan-500 text-white text-sm",
                :on_click => () -> set_result(n() % 2 == 0 ? 1 : 0),
                "even?"
            )
        ),

        # Result display
        Div(:class => "bg-stone-900 rounded-lg p-4 text-center",
            P(:class => "text-stone-400 text-sm mb-1", "Result (1 = true, 0 = false)"),
            Span(:class => "text-3xl font-mono font-bold text-cyan-400", result)
        )
    )
end
