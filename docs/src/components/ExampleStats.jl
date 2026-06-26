# ── ExampleStats (stdlib / Statistics) ──
# Three sliders feed a Vector{Float64}; mean and standard deviation are computed
# by the REAL Statistics stdlib, compiled to wasm. Each slider shows its live
# value so the mean/std can be checked by hand.
using Statistics

@island function ExampleStats(; a0::Float64 = 3.0, b0::Float64 = 7.0, c0::Float64 = 5.0)
    a, set_a = create_signal(a0)
    b, set_b = create_signal(b0)
    c, set_c = create_signal(c0)

    # rounded live values for the slider labels
    ar = create_memo(() -> floor(a() * 10.0 + 0.5) / 10.0)
    br = create_memo(() -> floor(b() * 10.0 + 0.5) / 10.0)
    cr = create_memo(() -> floor(c() * 10.0 + 0.5) / 10.0)

    m  = create_memo(() -> floor(Statistics.mean([a(), b(), c()]) * 1000.0 + 0.5) / 1000.0)
    sd = create_memo(() -> floor(Statistics.std([a(), b(), c()]) * 1000.0 + 0.5) / 1000.0)

    row(label, valmemo, val0, set) = Div(:class => "flex items-center gap-4",
        Span(:class => "w-16 text-sm font-mono text-warm-600 dark:text-warm-400",
            label, " = ", Span(:class => "text-accent-500", valmemo)),
        Input(:type => "range", :min => "0", :max => "10", :step => "0.1", :value => val0,
            :on_input => set, :class => "flex-1 accent-accent-500 cursor-pointer"))

    return Div(:class => "space-y-4",
        Div(:class => "space-y-2",
            row("a", ar, a0, set_a),
            row("b", br, b0, set_b),
            row("c", cr, c0, set_c)
        ),
        Div(:class => "grid grid-cols-2 gap-3 pt-1",
            Div(:class => "rounded-lg border border-warm-200 dark:border-warm-800 p-4 bg-warm-100/50 dark:bg-warm-900/50",
                P(:class => "text-xs uppercase tracking-wide text-warm-500 mb-1", "mean(a, b, c)"),
                P(:class => "text-2xl font-mono text-warm-900 dark:text-warm-100", m)
            ),
            Div(:class => "rounded-lg border border-warm-200 dark:border-warm-800 p-4 bg-warm-100/50 dark:bg-warm-900/50",
                P(:class => "text-xs uppercase tracking-wide text-warm-500 mb-1", "std(a, b, c)"),
                P(:class => "text-2xl font-mono text-warm-900 dark:text-warm-100", sd)
            )
        )
    )
end
