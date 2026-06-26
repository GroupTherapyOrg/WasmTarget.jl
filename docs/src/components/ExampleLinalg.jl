# ── ExampleLinalg (stdlib / LinearAlgebra) ──
# Four sliders are the entries of a 2x2 matrix; its (Frobenius) norm is computed
# by the REAL LinearAlgebra stdlib, compiled to wasm. Each entry shows its live
# value so ‖A‖ = sqrt(a²+b²+c²+d²) can be checked by hand.
using LinearAlgebra

@island function ExampleLinalg(; a0::Float64 = 2.0, b0::Float64 = 1.0, c0::Float64 = 1.0, d0::Float64 = 3.0)
    a, set_a = create_signal(a0)
    b, set_b = create_signal(b0)
    c, set_c = create_signal(c0)
    d, set_d = create_signal(d0)

    ar = create_memo(() -> floor(a() * 10.0 + 0.5) / 10.0)
    br = create_memo(() -> floor(b() * 10.0 + 0.5) / 10.0)
    cr = create_memo(() -> floor(c() * 10.0 + 0.5) / 10.0)
    dr = create_memo(() -> floor(d() * 10.0 + 0.5) / 10.0)

    nrm = create_memo(() -> floor(LinearAlgebra.norm([a() b(); c() d()]) * 1000.0 + 0.5) / 1000.0)

    cell(label, valmemo, val0, set) = Div(:class => "space-y-1",
        Span(:class => "text-xs font-mono text-warm-600 dark:text-warm-400",
            label, " = ", Span(:class => "text-accent-500", valmemo)),
        Input(:type => "range", :min => "-4", :max => "4", :step => "0.1", :value => val0,
            :on_input => set, :class => "w-full accent-accent-500 cursor-pointer"))

    return Div(:class => "space-y-4",
        # 2x2 grid of labelled sliders — reads like the matrix entries
        Div(:class => "grid grid-cols-2 gap-x-8 gap-y-4",
            cell("a", ar, a0, set_a), cell("b", br, b0, set_b),
            cell("c", cr, c0, set_c), cell("d", dr, d0, set_d)
        ),
        Div(:class => "rounded-lg border border-warm-200 dark:border-warm-800 p-4 bg-warm-100/50 dark:bg-warm-900/50 text-center",
            P(:class => "text-xs uppercase tracking-wide text-warm-500 mb-1", "‖A‖ = norm of the 2×2 matrix"),
            P(:class => "text-2xl font-mono text-warm-900 dark:text-warm-100", nrm)
        )
    )
end
