() -> begin
    code_block = "bg-warm-900 dark:bg-warm-950 text-warm-200 p-4 rounded-lg text-sm font-mono overflow-x-auto border border-warm-800"

    # one example = the source that MAKES it (top) + the live wasm widget (bottom)
    example(tag, title, desc, code, widget) = Div(:class => "space-y-3",
        Div(:class => "flex items-center gap-3",
            Span(:class => "text-xs font-mono px-2 py-0.5 rounded bg-accent-100 dark:bg-accent-900/50 text-accent-700 dark:text-accent-300", tag),
            H2(:class => "text-xl font-semibold text-warm-900 dark:text-warm-100", title)
        ),
        P(:class => "text-warm-600 dark:text-warm-400 text-sm leading-relaxed", desc),
        Pre(:class => code_block, Code(:class => "language-julia", code)),
        Div(:class => "rounded-xl border border-warm-200 dark:border-warm-800 p-6 bg-warm-50 dark:bg-warm-900/30", widget)
    )

    Div(:class => "space-y-12 max-w-3xl mx-auto",
        Div(:class => "space-y-3",
            H1(:class => "text-3xl font-serif font-bold text-warm-900 dark:text-warm-100", "Interactive Examples"),
            P(:class => "text-warm-600 dark:text-warm-400 leading-relaxed",
                "Every widget below is a ",
                A(:href => "https://github.com/GroupTherapyOrg/Therapy.jl", :target => "_blank", :class => "text-accent-500 underline", "Therapy.jl"),
                " island whose reactive body — the ", Code(:class => "text-accent-500 font-mono text-xs", "create_memo"),
                " calls you see in the code — was compiled to WasmGC by WasmTarget and is running ",
                Span(:class => "font-semibold text-warm-800 dark:text-warm-200", "live in your browser"), ". ",
                "Move a slider and the Julia recomputes in wasm. No server, no Julia runtime — just the ",
                "compiled function reacting to a signal."
            )
        ),

        example("Base",
            "Transcendentals in wasm",
            "The plainest case: Julia's own sin and exp, lowered straight to WasmGC. Drag x to evaluate a damped oscillation live — no stdlib, no overlays.",
            """x, set_x = create_signal(1.5)

# Base sin/exp, compiled to wasm:
y = create_memo(() ->
    sin(x()) * exp(-x() / 3))""",
            ExampleMath()),

        example("stdlib · Statistics",
            "mean / std of a live vector",
            "Three sliders become a Vector{Float64}; the real Statistics stdlib reduces it. Building the vector and the reductions all run in wasm.",
            """a, set_a = create_signal(3.0)
b, set_b = create_signal(7.0)
c, set_c = create_signal(5.0)

m  = create_memo(() -> mean([a(), b(), c()]))
sd = create_memo(() -> std([a(), b(), c()]))""",
            ExampleStats()),

        example("stdlib · LinearAlgebra",
            "Norm of a 2×2 matrix",
            "Four sliders are the entries of a matrix. LinearAlgebra.norm runs on the assembled 2×2 — matrix construction and the (Frobenius) norm both in wasm.",
            """# four signals → a 2x2 matrix → its norm
nrm = create_memo(() ->
    norm([a() b()
          c() d()]))""",
            ExampleLinalg()),

        example("SciML · ForwardDiff",
            "Automatic differentiation, live",
            "The headline. Drag x and the right-hand value is f′(x) computed by real forward-mode autodiff — ForwardDiff dual numbers, compiled to wasm. It is exact, not a finite difference: for f(x) = x³ − 2x you can check f′(x) = 3x² − 2.",
            """x, set_x = create_signal(1.2)

# f'(x) by REAL forward-mode autodiff — ForwardDiff
# dual numbers, compiled to WasmGC, in your browser:
dfx = create_memo(() ->
    ForwardDiff.derivative(t -> t^3 - 2t, x()))""",
            ExampleAutodiff())
    )
end
