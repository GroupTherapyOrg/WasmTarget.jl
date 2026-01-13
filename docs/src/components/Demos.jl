# Demos.jl - Interactive demo components
#
# EXACTLY matching InteractiveCounter pattern:
# - Single signal
# - Simple +1/-1 handlers
# - Direct signal display

"""
Arithmetic demo - simple counter like InteractiveCounter.
"""
ArithmeticDemo = island(:ArithmeticDemo) do
    count, set_count = create_signal(0)

    Div(:class => "bg-white dark:bg-stone-700 rounded-xl p-6 w-full shadow-lg",
        Div(:class => "flex justify-center items-center gap-6",
            Button(:class => "w-12 h-12 rounded-full bg-cyan-500 text-white text-2xl font-bold",
                   :on_click => () -> set_count(count() - 1),
                   "-"),
            Span(:class => "text-5xl font-bold tabular-nums text-cyan-500",
                 count),
            Button(:class => "w-12 h-12 rounded-full bg-cyan-500 text-white text-2xl font-bold",
                   :on_click => () -> set_count(count() + 1),
                   "+")
        ),
        P(:class => "text-center text-stone-500 dark:text-stone-400 text-sm mt-4",
            "add/subtract demo"
        )
    )
end

"""
Control flow demo - simple counter.
"""
ControlFlowDemo = island(:ControlFlowDemo) do
    count, set_count = create_signal(0)

    Div(:class => "bg-white dark:bg-stone-700 rounded-xl p-6 w-full shadow-lg",
        Div(:class => "flex justify-center items-center gap-6",
            Button(:class => "w-12 h-12 rounded-full bg-cyan-500 text-white text-2xl font-bold",
                   :on_click => () -> set_count(count() - 1),
                   "-"),
            Span(:class => "text-5xl font-bold tabular-nums text-cyan-500",
                 count),
            Button(:class => "w-12 h-12 rounded-full bg-cyan-500 text-white text-2xl font-bold",
                   :on_click => () -> set_count(count() + 1),
                   "+")
        ),
        P(:class => "text-center text-stone-500 dark:text-stone-400 text-sm mt-4",
            "sign(n) demo"
        )
    )
end

"""
Recursion demo - simple counter.
"""
RecursionDemo = island(:RecursionDemo) do
    count, set_count = create_signal(5)

    Div(:class => "bg-white dark:bg-stone-700 rounded-xl p-6 w-full shadow-lg",
        Div(:class => "flex justify-center items-center gap-6",
            Button(:class => "w-12 h-12 rounded-full bg-cyan-500 text-white text-2xl font-bold",
                   :on_click => () -> set_count(count() - 1),
                   "-"),
            Span(:class => "text-5xl font-bold tabular-nums text-cyan-500",
                 count),
            Button(:class => "w-12 h-12 rounded-full bg-cyan-500 text-white text-2xl font-bold",
                   :on_click => () -> set_count(count() + 1),
                   "+")
        ),
        P(:class => "text-center text-stone-500 dark:text-stone-400 text-sm mt-4",
            "factorial(n) demo"
        )
    )
end

"""
Loop demo - simple counter.
"""
LoopDemo = island(:LoopDemo) do
    count, set_count = create_signal(10)

    Div(:class => "bg-white dark:bg-stone-700 rounded-xl p-6 w-full shadow-lg",
        Div(:class => "flex justify-center items-center gap-6",
            Button(:class => "w-12 h-12 rounded-full bg-cyan-500 text-white text-2xl font-bold",
                   :on_click => () -> set_count(count() - 1),
                   "-"),
            Span(:class => "text-5xl font-bold tabular-nums text-cyan-500",
                 count),
            Button(:class => "w-12 h-12 rounded-full bg-cyan-500 text-white text-2xl font-bold",
                   :on_click => () -> set_count(count() + 1),
                   "+")
        ),
        P(:class => "text-center text-stone-500 dark:text-stone-400 text-sm mt-4",
            "sum_to_n demo"
        )
    )
end
