# Demos.jl - Interactive demo components for the Features page
#
# Pattern: Match InteractiveCounter exactly
# - Simple handlers: () -> set_signal(value)
# - Direct signal display: signal (not () -> computed)
# - No string() or complex computations in display

"""
Arithmetic demo - shows result signal updated by operation buttons.
"""
ArithmeticDemo = island(:ArithmeticDemo) do
    a, set_a = create_signal(12)
    b, set_b = create_signal(5)
    result, set_result = create_signal(17)  # Start with a + b

    Div(:class => "bg-white dark:bg-stone-700 rounded-xl p-6 w-full shadow-lg",
        # Inputs with +/- buttons
        Div(:class => "flex gap-6 mb-4 justify-center",
            # A controls
            Div(:class => "text-center",
                Span(:class => "text-stone-500 dark:text-stone-400 text-xs block mb-2", "a"),
                Div(:class => "flex items-center gap-2",
                    Button(:class => "w-8 h-8 rounded bg-stone-200 dark:bg-stone-600 text-stone-700 dark:text-white",
                        :on_click => () -> set_a(a() - 1), "-"),
                    Span(:class => "w-10 text-center text-xl font-mono text-cyan-500", a),
                    Button(:class => "w-8 h-8 rounded bg-stone-200 dark:bg-stone-600 text-stone-700 dark:text-white",
                        :on_click => () -> set_a(a() + 1), "+")
                )
            ),
            # B controls
            Div(:class => "text-center",
                Span(:class => "text-stone-500 dark:text-stone-400 text-xs block mb-2", "b"),
                Div(:class => "flex items-center gap-2",
                    Button(:class => "w-8 h-8 rounded bg-stone-200 dark:bg-stone-600 text-stone-700 dark:text-white",
                        :on_click => () -> set_b(b() - 1), "-"),
                    Span(:class => "w-10 text-center text-xl font-mono text-cyan-500", b),
                    Button(:class => "w-8 h-8 rounded bg-stone-200 dark:bg-stone-600 text-stone-700 dark:text-white",
                        :on_click => () -> set_b(b() + 1), "+")
                )
            )
        ),
        # Operation buttons
        Div(:class => "flex gap-2 mb-4 justify-center",
            Button(:class => "px-3 py-1 rounded bg-cyan-500 text-white text-sm",
                :on_click => () -> set_result(a() + b()), "+"),
            Button(:class => "px-3 py-1 rounded bg-cyan-500 text-white text-sm",
                :on_click => () -> set_result(a() - b()), "-"),
            Button(:class => "px-3 py-1 rounded bg-cyan-500 text-white text-sm",
                :on_click => () -> set_result(a() * b()), "*"),
            Button(:class => "px-3 py-1 rounded bg-cyan-500 text-white text-sm",
                :on_click => () -> set_result(div(a(), b())), "/")
        ),
        # Result display
        Div(:class => "text-center p-3 bg-stone-50 dark:bg-stone-600 rounded",
            Span(:class => "text-stone-500 dark:text-stone-400 text-sm", "Result: "),
            Span(:class => "text-cyan-500 font-bold text-2xl font-mono", result)
        )
    )
end

"""
Control flow demo - sign function.
"""
ControlFlowDemo = island(:ControlFlowDemo) do
    n, set_n = create_signal(0)
    result, set_result = create_signal(0)

    Div(:class => "bg-white dark:bg-stone-700 rounded-xl p-6 w-full shadow-lg",
        # Input buttons
        Div(:class => "flex gap-2 mb-4 justify-center",
            Button(:class => "px-4 py-2 bg-stone-200 dark:bg-stone-600 rounded text-stone-700 dark:text-stone-200",
                :on_click => () -> begin set_n(-5); set_result(-1) end, "-5"),
            Button(:class => "px-4 py-2 bg-stone-200 dark:bg-stone-600 rounded text-stone-700 dark:text-stone-200",
                :on_click => () -> begin set_n(0); set_result(0) end, "0"),
            Button(:class => "px-4 py-2 bg-stone-200 dark:bg-stone-600 rounded text-stone-700 dark:text-stone-200",
                :on_click => () -> begin set_n(5); set_result(1) end, "+5")
        ),
        # Display
        Div(:class => "text-center",
            Div(:class => "mb-2",
                Span(:class => "text-stone-500 dark:text-stone-400", "n = "),
                Span(:class => "text-cyan-500 font-mono text-xl", n)
            ),
            Div(:class => "p-3 bg-stone-50 dark:bg-stone-600 rounded",
                Span(:class => "text-stone-500 dark:text-stone-400", "sign(n) = "),
                Span(:class => "text-cyan-500 font-bold text-2xl font-mono", result)
            )
        )
    )
end

"""
Recursion demo - factorial.
"""
RecursionDemo = island(:RecursionDemo) do
    n, set_n = create_signal(5)
    result, set_result = create_signal(120)  # 5! = 120

    Div(:class => "bg-white dark:bg-stone-700 rounded-xl p-6 w-full shadow-lg",
        # Input buttons with precomputed results
        Div(:class => "flex gap-2 mb-4 justify-center flex-wrap",
            Button(:class => "px-3 py-1 bg-stone-200 dark:bg-stone-600 rounded text-sm text-stone-700 dark:text-stone-200",
                :on_click => () -> begin set_n(0); set_result(1) end, "0"),
            Button(:class => "px-3 py-1 bg-stone-200 dark:bg-stone-600 rounded text-sm text-stone-700 dark:text-stone-200",
                :on_click => () -> begin set_n(1); set_result(1) end, "1"),
            Button(:class => "px-3 py-1 bg-stone-200 dark:bg-stone-600 rounded text-sm text-stone-700 dark:text-stone-200",
                :on_click => () -> begin set_n(2); set_result(2) end, "2"),
            Button(:class => "px-3 py-1 bg-stone-200 dark:bg-stone-600 rounded text-sm text-stone-700 dark:text-stone-200",
                :on_click => () -> begin set_n(3); set_result(6) end, "3"),
            Button(:class => "px-3 py-1 bg-stone-200 dark:bg-stone-600 rounded text-sm text-stone-700 dark:text-stone-200",
                :on_click => () -> begin set_n(4); set_result(24) end, "4"),
            Button(:class => "px-3 py-1 bg-stone-200 dark:bg-stone-600 rounded text-sm text-stone-700 dark:text-stone-200",
                :on_click => () -> begin set_n(5); set_result(120) end, "5"),
            Button(:class => "px-3 py-1 bg-stone-200 dark:bg-stone-600 rounded text-sm text-stone-700 dark:text-stone-200",
                :on_click => () -> begin set_n(6); set_result(720) end, "6")
        ),
        # Display
        Div(:class => "text-center p-3 bg-stone-50 dark:bg-stone-600 rounded",
            Span(:class => "text-stone-500 dark:text-stone-400", "factorial("),
            Span(:class => "text-cyan-500 font-mono", n),
            Span(:class => "text-stone-500 dark:text-stone-400", ") = "),
            Span(:class => "text-cyan-500 font-bold text-2xl font-mono", result)
        )
    )
end

"""
Loop demo - sum to n.
"""
LoopDemo = island(:LoopDemo) do
    n, set_n = create_signal(10)
    result, set_result = create_signal(55)  # sum(1..10) = 55

    Div(:class => "bg-white dark:bg-stone-700 rounded-xl p-6 w-full shadow-lg",
        # Input buttons with precomputed results
        Div(:class => "flex gap-2 mb-4 justify-center",
            Button(:class => "px-4 py-2 bg-stone-200 dark:bg-stone-600 rounded text-stone-700 dark:text-stone-200",
                :on_click => () -> begin set_n(10); set_result(55) end, "10"),
            Button(:class => "px-4 py-2 bg-stone-200 dark:bg-stone-600 rounded text-stone-700 dark:text-stone-200",
                :on_click => () -> begin set_n(100); set_result(5050) end, "100"),
            Button(:class => "px-4 py-2 bg-stone-200 dark:bg-stone-600 rounded text-stone-700 dark:text-stone-200",
                :on_click => () -> begin set_n(1000); set_result(500500) end, "1000")
        ),
        # Display
        Div(:class => "text-center p-3 bg-stone-50 dark:bg-stone-600 rounded",
            Span(:class => "text-stone-500 dark:text-stone-400", "sum_to_n("),
            Span(:class => "text-cyan-500 font-mono", n),
            Span(:class => "text-stone-500 dark:text-stone-400", ") = "),
            Span(:class => "text-cyan-500 font-bold text-2xl font-mono", result)
        )
    )
end
