# ── ExampleMath (Base) ──
# Plain Base math compiled to WasmGC: transcendentals (sin, exp) evaluated live
# as you drag the slider. No stdlib, no overlays — just Julia's own `sin`/`exp`
# lowered to wasm.

@island function ExampleMath(; x0::Float64 = 1.5)
    x, set_x = create_signal(x0)
    xr = create_memo(() -> floor(x() * 100.0 + 0.5) / 100.0)
    # f(x) = sin(x) * exp(-x/3) — a damped oscillation, Base transcendentals
    y  = create_memo(() -> floor(sin(x()) * exp(-x() / 3.0) * 1000.0 + 0.5) / 1000.0)

    return Div(:class => "space-y-4",
        Div(:class => "flex items-baseline justify-between",
            Span(:class => "text-sm font-mono text-warm-600 dark:text-warm-400", "x = ", Span(:class => "text-accent-500", xr)),
            Span(:class => "text-xs text-warm-500", "drag →")
        ),
        Input(:type => "range", :min => "0", :max => "12", :step => "0.05", :value => x0,
            :on_input => set_x,
            :class => "w-full accent-accent-500 cursor-pointer"),
        Div(:class => "rounded-lg border border-warm-200 dark:border-warm-800 p-4 bg-warm-100/50 dark:bg-warm-900/50",
            P(:class => "text-xs uppercase tracking-wide text-warm-500 mb-1", "f(x) = sin(x) · exp(−x/3)"),
            P(:class => "text-2xl font-mono text-warm-900 dark:text-warm-100", y)
        )
    )
end
