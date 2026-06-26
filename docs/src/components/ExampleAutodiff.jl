# ── ExampleAutodiff (SciML / ForwardDiff) ──
# The headline interactive example: drag the slider and the DERIVATIVE is
# recomputed by REAL forward-mode automatic differentiation (ForwardDiff dual
# numbers), compiled to WasmGC by WasmTarget, running entirely in the browser.
# Not a finite difference, not a precomputed table — exact AD, live.
#
# `using ForwardDiff` here so the name resolves in the component module
# (Main.TherapyApp) both when the island is run natively to discover its
# structure AND when its memo is compiled to wasm (the WasmTargetForwardDiffExt
# overlays are already active in this process).
using ForwardDiff

@island function ExampleAutodiff(; x0::Float64 = 1.2)
    x, set_x = create_signal(x0)

    # rounded views for display (floor-based, no Printf needed in-wasm)
    xr  = create_memo(() -> floor(x() * 100.0 + 0.5) / 100.0)
    fx  = create_memo(() -> (t = x(); floor((t^3 - 2.0 * t) * 1000.0 + 0.5) / 1000.0))
    # f'(x) by REAL forward-mode autodiff — this call runs ForwardDiff in wasm
    dfx = create_memo(() -> floor(ForwardDiff.derivative(t -> t^3 - 2.0 * t, x()) * 1000.0 + 0.5) / 1000.0)

    return Div(:class => "space-y-4",
        Div(:class => "flex items-baseline justify-between",
            Span(:class => "text-sm font-mono text-warm-600 dark:text-warm-400", "x = ", Span(:class => "text-accent-500", xr)),
            Span(:class => "text-xs text-warm-500", "drag →")
        ),
        Input(:type => "range", :min => "-2", :max => "2", :step => "0.01", :value => x0,
            :on_input => set_x,
            :class => "w-full accent-accent-500 cursor-pointer"),
        Div(:class => "grid grid-cols-2 gap-3 pt-1",
            Div(:class => "rounded-lg border border-warm-200 dark:border-warm-800 p-4 bg-warm-100/50 dark:bg-warm-900/50",
                P(:class => "text-xs uppercase tracking-wide text-warm-500 mb-1", "f(x) = x³ − 2x"),
                P(:class => "text-2xl font-mono text-warm-900 dark:text-warm-100", fx)
            ),
            Div(:class => "rounded-lg border border-accent-200 dark:border-accent-900 p-4 bg-accent-50/60 dark:bg-accent-950/30",
                P(:class => "text-xs uppercase tracking-wide text-accent-600 dark:text-accent-400 mb-1", "f′(x) — ForwardDiff"),
                P(:class => "text-2xl font-mono text-accent-700 dark:text-accent-300", dfx)
            )
        )
    )
end
