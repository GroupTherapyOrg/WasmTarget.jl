# ArithmeticDemo.jl - Demonstrates basic arithmetic operations

"""
Demo: Integer arithmetic operations compiled to Wasm.
Shows add, subtract, multiply, divide with interactive controls.
"""
ArithmeticDemo = island(:ArithmeticDemo) do
    a, set_a = create_signal(10)
    b, set_b = create_signal(3)
    result, set_result = create_signal(13)  # Start with a + b
    op_name, set_op_name = create_signal(0)  # 0=add, 1=sub, 2=mul, 3=div

    Div(:class => "bg-stone-800 rounded-xl p-6",
        # Inputs
        Div(:class => "flex items-center justify-center gap-6 mb-6",
            # Input A
            Div(:class => "text-center",
                Label(:class => "text-stone-400 text-sm block mb-2", "a"),
                Div(:class => "flex items-center gap-2",
                    Button(:class => "w-8 h-8 rounded bg-stone-700 hover:bg-stone-600 text-white",
                        :on_click => () -> set_a(a() - 1), "-"),
                    Span(:class => "w-12 text-center text-2xl font-mono text-cyan-400", a),
                    Button(:class => "w-8 h-8 rounded bg-stone-700 hover:bg-stone-600 text-white",
                        :on_click => () -> set_a(a() + 1), "+")
                )
            ),
            # Input B
            Div(:class => "text-center",
                Label(:class => "text-stone-400 text-sm block mb-2", "b"),
                Div(:class => "flex items-center gap-2",
                    Button(:class => "w-8 h-8 rounded bg-stone-700 hover:bg-stone-600 text-white",
                        :on_click => () -> set_b(b() - 1), "-"),
                    Span(:class => "w-12 text-center text-2xl font-mono text-cyan-400", b),
                    Button(:class => "w-8 h-8 rounded bg-stone-700 hover:bg-stone-600 text-white",
                        :on_click => () -> set_b(b() + 1), "+")
                )
            )
        ),

        # Operation buttons
        Div(:class => "flex justify-center gap-2 mb-4",
            Button(:class => "px-4 py-2 rounded bg-cyan-600 hover:bg-cyan-500 text-white font-mono",
                :on_click => () -> set_result(a() + b()),
                "a + b"
            ),
            Button(:class => "px-4 py-2 rounded bg-cyan-600 hover:bg-cyan-500 text-white font-mono",
                :on_click => () -> set_result(a() - b()),
                "a - b"
            ),
            Button(:class => "px-4 py-2 rounded bg-cyan-600 hover:bg-cyan-500 text-white font-mono",
                :on_click => () -> set_result(a() * b()),
                "a * b"
            ),
            Button(:class => "px-4 py-2 rounded bg-cyan-600 hover:bg-cyan-500 text-white font-mono",
                :on_click => () -> set_result(div(a(), b())),
                "a / b"
            )
        ),

        # Result display
        Div(:class => "bg-stone-900 rounded-lg p-4 text-center",
            P(:class => "text-stone-400 text-sm mb-1", "Result"),
            Span(:class => "text-3xl font-mono font-bold text-cyan-400", result)
        )
    )
end
