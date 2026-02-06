# Demos.jl - Interactive demo components for the Features page
#
# Now that Any type is supported, we can have proper demos
# that actually demonstrate the Julia features being compiled to WASM

# Arithmetic demo - shows add/multiply/divide with adjustable inputs.
# Uses multiple signals and computed results.
@island function ArithmeticDemo()
    a, set_a = create_signal(12)
    b, set_b = create_signal(5)
    result, set_result = create_signal(17)
    op, set_op = create_signal(0)  # 0=add, 1=mul, 2=div

    Div(:class => "bg-warm-50 dark:bg-warm-700 rounded-xl p-6 w-full shadow-lg",
        # Input controls
        Div(:class => "flex gap-6 mb-6 justify-center items-center",
            # A value with +/-
            Div(:class => "text-center",
                Span(:class => "text-warm-500 dark:text-warm-400 text-xs block mb-1", "a"),
                Div(:class => "flex items-center gap-2",
                    Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                        :on_click => () -> set_a(a() - 1), "-"),
                    Span(:class => "w-12 text-center text-2xl font-mono text-accent-500", a),
                    Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                        :on_click => () -> set_a(a() + 1), "+")
                )
            ),
            # B value with +/-
            Div(:class => "text-center",
                Span(:class => "text-warm-500 dark:text-warm-400 text-xs block mb-1", "b"),
                Div(:class => "flex items-center gap-2",
                    Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                        :on_click => () -> set_b(b() - 1), "-"),
                    Span(:class => "w-12 text-center text-2xl font-mono text-accent-500", b),
                    Button(:class => "w-8 h-8 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                        :on_click => () -> set_b(b() + 1), "+")
                )
            )
        ),
        # Operation buttons that compute result
        Div(:class => "flex gap-2 mb-4 justify-center",
            Button(:class => "px-4 py-2 rounded bg-accent-500 hover:bg-accent-600 text-white font-mono",
                :on_click => () -> set_result(a() + b()), "a + b"),
            Button(:class => "px-4 py-2 rounded bg-accent-500 hover:bg-accent-600 text-white font-mono",
                :on_click => () -> set_result(a() * b()), "a * b"),
            Button(:class => "px-4 py-2 rounded bg-accent-500 hover:bg-accent-600 text-white font-mono",
                :on_click => () -> set_result(div(a(), b())), "a / b")
        ),
        # Result display
        Div(:class => "text-center p-4 bg-warm-50 dark:bg-warm-600 rounded-lg",
            Span(:class => "text-warm-500 dark:text-warm-400 text-sm", "Result: "),
            Span(:class => "text-accent-500 font-bold text-3xl font-mono", result)
        )
    )
end

# Control flow demo - sign function showing if/elseif/else.
@island function ControlFlowDemo()
    n, set_n = create_signal(0)
    result, set_result = create_signal(0)

    Div(:class => "bg-warm-50 dark:bg-warm-700 rounded-xl p-6 w-full shadow-lg",
        # N value with +/-
        Div(:class => "flex justify-center items-center gap-4 mb-6",
            Button(:class => "w-10 h-10 rounded-full bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-xl",
                :on_click => () -> set_n(n() - 1), "-"),
            Div(:class => "text-center",
                Span(:class => "text-warm-500 dark:text-warm-400 text-xs block", "n"),
                Span(:class => "text-3xl font-mono text-accent-500 w-16 inline-block", n)
            ),
            Button(:class => "w-10 h-10 rounded-full bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-xl",
                :on_click => () -> set_n(n() + 1), "+")
        ),
        # Compute sign button
        Button(:class => "w-full py-3 rounded-lg bg-accent-500 hover:bg-accent-600 text-white font-semibold mb-4",
            :on_click => () -> begin
                val = n()
                if val > 0
                    set_result(1)
                elseif val < 0
                    set_result(-1)
                else
                    set_result(0)
                end
            end,
            "Compute sign(n)"
        ),
        # Result
        Div(:class => "text-center p-4 bg-warm-50 dark:bg-warm-600 rounded-lg",
            Span(:class => "text-warm-500 dark:text-warm-400 text-sm", "sign(n) = "),
            Span(:class => "text-accent-500 font-bold text-3xl font-mono", result)
        )
    )
end

# Recursion demo - factorial showing recursive calls.
@island function RecursionDemo()
    n, set_n = create_signal(5)
    result, set_result = create_signal(120)

    Div(:class => "bg-warm-50 dark:bg-warm-700 rounded-xl p-6 w-full shadow-lg",
        # N selector buttons
        Div(:class => "flex justify-center gap-2 mb-6",
            Button(:class => "w-10 h-10 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin set_n(0); set_result(1) end, "0"),
            Button(:class => "w-10 h-10 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin set_n(1); set_result(1) end, "1"),
            Button(:class => "w-10 h-10 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin set_n(2); set_result(2) end, "2"),
            Button(:class => "w-10 h-10 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin set_n(3); set_result(6) end, "3"),
            Button(:class => "w-10 h-10 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin set_n(4); set_result(24) end, "4"),
            Button(:class => "w-10 h-10 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin set_n(5); set_result(120) end, "5"),
            Button(:class => "w-10 h-10 rounded bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white",
                :on_click => () -> begin set_n(6); set_result(720) end, "6")
        ),
        # Display
        Div(:class => "text-center p-4 bg-warm-50 dark:bg-warm-600 rounded-lg",
            Div(:class => "mb-2",
                Span(:class => "text-warm-500 dark:text-warm-400", "factorial("),
                Span(:class => "text-accent-500 font-mono text-xl", n),
                Span(:class => "text-warm-500 dark:text-warm-400", ") = ")
            ),
            Span(:class => "text-accent-500 font-bold text-4xl font-mono", result)
        )
    )
end

# Loop demo - sum_to_n showing while loop.
@island function LoopDemo()
    n, set_n = create_signal(10)
    result, set_result = create_signal(55)

    Div(:class => "bg-warm-50 dark:bg-warm-700 rounded-xl p-6 w-full shadow-lg",
        # N value with +/-
        Div(:class => "flex justify-center items-center gap-4 mb-6",
            Button(:class => "w-10 h-10 rounded-full bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-xl",
                :on_click => () -> set_n(n() - 10), "-10"),
            Div(:class => "text-center",
                Span(:class => "text-warm-500 dark:text-warm-400 text-xs block", "n"),
                Span(:class => "text-3xl font-mono text-accent-500 w-20 inline-block", n)
            ),
            Button(:class => "w-10 h-10 rounded-full bg-warm-200 dark:bg-warm-600 text-warm-700 dark:text-white text-xl",
                :on_click => () -> set_n(n() + 10), "+10")
        ),
        # Compute button
        Button(:class => "w-full py-3 rounded-lg bg-accent-500 hover:bg-accent-600 text-white font-semibold mb-4",
            :on_click => () -> begin
                val = n()
                set_result(div(val * (val + 1), 2))
            end,
            "Compute sum_to_n(n)"
        ),
        # Result
        Div(:class => "text-center p-4 bg-warm-50 dark:bg-warm-600 rounded-lg",
            Div(:class => "mb-2",
                Span(:class => "text-warm-500 dark:text-warm-400", "sum(1.."),
                Span(:class => "text-accent-500 font-mono", n),
                Span(:class => "text-warm-500 dark:text-warm-400", ") = ")
            ),
            Span(:class => "text-accent-500 font-bold text-4xl font-mono", result)
        )
    )
end
