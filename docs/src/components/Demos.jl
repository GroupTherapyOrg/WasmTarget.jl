# Demos.jl - Interactive demo components for the Features page
#
# These are Therapy.jl islands that demonstrate pre-compiled WASM functionality.
# Each demo shows a specific Julia feature compiled to WebAssembly.
#
# Pattern: Use Int signals like Therapy.jl examples (InteractiveCounter, TicTacToe)

"""
Arithmetic demo - add, multiply, divide with two number inputs.
"""
ArithmeticDemo = island(:ArithmeticDemo) do
    a, set_a = create_signal(12)
    b, set_b = create_signal(5)

    Div(:class => "bg-white dark:bg-stone-700 rounded-xl p-6 w-full shadow-lg",
        # Inputs with +/- buttons (like InteractiveCounter)
        Div(:class => "flex gap-6 mb-4 justify-center",
            # Input A
            Div(:class => "text-center",
                Label(:class => "text-stone-500 dark:text-stone-400 text-xs block mb-2", "a"),
                Div(:class => "flex items-center gap-2",
                    Button(:class => "w-8 h-8 rounded bg-stone-200 dark:bg-stone-600 hover:bg-stone-300 dark:hover:bg-stone-500 text-stone-700 dark:text-white",
                        :on_click => () -> set_a(a() - 1), "-"),
                    Span(:class => "w-10 text-center text-xl font-mono text-cyan-500", a),
                    Button(:class => "w-8 h-8 rounded bg-stone-200 dark:bg-stone-600 hover:bg-stone-300 dark:hover:bg-stone-500 text-stone-700 dark:text-white",
                        :on_click => () -> set_a(a() + 1), "+")
                )
            ),
            # Input B
            Div(:class => "text-center",
                Label(:class => "text-stone-500 dark:text-stone-400 text-xs block mb-2", "b"),
                Div(:class => "flex items-center gap-2",
                    Button(:class => "w-8 h-8 rounded bg-stone-200 dark:bg-stone-600 hover:bg-stone-300 dark:hover:bg-stone-500 text-stone-700 dark:text-white",
                        :on_click => () -> set_b(b() - 1), "-"),
                    Span(:class => "w-10 text-center text-xl font-mono text-cyan-500", b),
                    Button(:class => "w-8 h-8 rounded bg-stone-200 dark:bg-stone-600 hover:bg-stone-300 dark:hover:bg-stone-500 text-stone-700 dark:text-white",
                        :on_click => () -> set_b(b() + 1), "+")
                )
            )
        ),
        # Results
        Div(:class => "space-y-2 font-mono text-sm",
            Div(:class => "flex justify-between p-2 bg-stone-50 dark:bg-stone-600 rounded",
                Span(:class => "text-stone-500 dark:text-stone-400", "add(a, b)"),
                Span(:class => "text-cyan-500 font-bold", () -> string(a() + b()))
            ),
            Div(:class => "flex justify-between p-2 bg-stone-50 dark:bg-stone-600 rounded",
                Span(:class => "text-stone-500 dark:text-stone-400", "multiply(a, b)"),
                Span(:class => "text-cyan-500 font-bold", () -> string(a() * b()))
            ),
            Div(:class => "flex justify-between p-2 bg-stone-50 dark:bg-stone-600 rounded",
                Span(:class => "text-stone-500 dark:text-stone-400", "divide(a, b)"),
                Span(:class => "text-cyan-500 font-bold", () -> b() != 0 ? string(div(a(), b())) : "0")
            )
        )
    )
end

"""
Control flow demo - sign function with preset buttons.
"""
ControlFlowDemo = island(:ControlFlowDemo) do
    n, set_n = create_signal(0)

    Div(:class => "bg-white dark:bg-stone-700 rounded-xl p-6 w-full shadow-lg",
        # Quick buttons
        Div(:class => "flex gap-2 mb-4 justify-center",
            Button(:class => "px-4 py-2 bg-stone-200 dark:bg-stone-600 hover:bg-stone-300 dark:hover:bg-stone-500 rounded text-stone-700 dark:text-stone-200",
                :on_click => () -> set_n(-5), "-5"),
            Button(:class => "px-4 py-2 bg-stone-200 dark:bg-stone-600 hover:bg-stone-300 dark:hover:bg-stone-500 rounded text-stone-700 dark:text-stone-200",
                :on_click => () -> set_n(0), "0"),
            Button(:class => "px-4 py-2 bg-stone-200 dark:bg-stone-600 hover:bg-stone-300 dark:hover:bg-stone-500 rounded text-stone-700 dark:text-stone-200",
                :on_click => () -> set_n(5), "+5")
        ),
        # Result
        Div(:class => "flex justify-between p-3 bg-stone-50 dark:bg-stone-600 rounded font-mono",
            Span(:class => "text-stone-500 dark:text-stone-400", () -> "sign($(n()))"),
            Span(:class => "text-cyan-500 font-bold text-lg", () -> begin
                val = n()
                val > 0 ? "1" : (val < 0 ? "-1" : "0")
            end)
        )
    )
end

"""
Recursion demo - factorial with preset buttons.
"""
RecursionDemo = island(:RecursionDemo) do
    n, set_n = create_signal(5)

    Div(:class => "bg-white dark:bg-stone-700 rounded-xl p-6 w-full shadow-lg",
        # Quick buttons
        Div(:class => "flex gap-2 mb-4 justify-center flex-wrap",
            Button(:class => "px-3 py-1 bg-stone-200 dark:bg-stone-600 hover:bg-stone-300 dark:hover:bg-stone-500 rounded text-sm text-stone-700 dark:text-stone-200",
                :on_click => () -> set_n(0), "0"),
            Button(:class => "px-3 py-1 bg-stone-200 dark:bg-stone-600 hover:bg-stone-300 dark:hover:bg-stone-500 rounded text-sm text-stone-700 dark:text-stone-200",
                :on_click => () -> set_n(1), "1"),
            Button(:class => "px-3 py-1 bg-stone-200 dark:bg-stone-600 hover:bg-stone-300 dark:hover:bg-stone-500 rounded text-sm text-stone-700 dark:text-stone-200",
                :on_click => () -> set_n(2), "2"),
            Button(:class => "px-3 py-1 bg-stone-200 dark:bg-stone-600 hover:bg-stone-300 dark:hover:bg-stone-500 rounded text-sm text-stone-700 dark:text-stone-200",
                :on_click => () -> set_n(3), "3"),
            Button(:class => "px-3 py-1 bg-stone-200 dark:bg-stone-600 hover:bg-stone-300 dark:hover:bg-stone-500 rounded text-sm text-stone-700 dark:text-stone-200",
                :on_click => () -> set_n(4), "4"),
            Button(:class => "px-3 py-1 bg-stone-200 dark:bg-stone-600 hover:bg-stone-300 dark:hover:bg-stone-500 rounded text-sm text-stone-700 dark:text-stone-200",
                :on_click => () -> set_n(5), "5"),
            Button(:class => "px-3 py-1 bg-stone-200 dark:bg-stone-600 hover:bg-stone-300 dark:hover:bg-stone-500 rounded text-sm text-stone-700 dark:text-stone-200",
                :on_click => () -> set_n(6), "6")
        ),
        # Result
        Div(:class => "flex justify-between p-3 bg-stone-50 dark:bg-stone-600 rounded font-mono",
            Span(:class => "text-stone-500 dark:text-stone-400", () -> "factorial($(n()))"),
            Span(:class => "text-cyan-500 font-bold text-lg", () -> begin
                # Simple factorial computation
                val = n()
                result = 1
                for i in 2:val
                    result = result * i
                end
                string(result)
            end)
        )
    )
end

"""
Loop demo - sum to n with preset buttons.
"""
LoopDemo = island(:LoopDemo) do
    n, set_n = create_signal(10)

    Div(:class => "bg-white dark:bg-stone-700 rounded-xl p-6 w-full shadow-lg",
        # Quick buttons
        Div(:class => "flex gap-2 mb-4 justify-center",
            Button(:class => "px-4 py-2 bg-stone-200 dark:bg-stone-600 hover:bg-stone-300 dark:hover:bg-stone-500 rounded text-stone-700 dark:text-stone-200",
                :on_click => () -> set_n(10), "10"),
            Button(:class => "px-4 py-2 bg-stone-200 dark:bg-stone-600 hover:bg-stone-300 dark:hover:bg-stone-500 rounded text-stone-700 dark:text-stone-200",
                :on_click => () -> set_n(100), "100"),
            Button(:class => "px-4 py-2 bg-stone-200 dark:bg-stone-600 hover:bg-stone-300 dark:hover:bg-stone-500 rounded text-stone-700 dark:text-stone-200",
                :on_click => () -> set_n(1000), "1000")
        ),
        # Result
        Div(:class => "flex justify-between p-3 bg-stone-50 dark:bg-stone-600 rounded font-mono",
            Span(:class => "text-stone-500 dark:text-stone-400", () -> "sum_to_n($(n()))"),
            Span(:class => "text-cyan-500 font-bold text-lg", () -> begin
                val = n()
                string(div(val * (val + 1), 2))
            end)
        ),
        # Formula note
        P(:class => "text-stone-400 dark:text-stone-500 text-xs mt-3 text-center",
            "Uses n*(n+1)/2 formula"
        )
    )
end
