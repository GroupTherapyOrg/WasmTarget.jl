# ── ExampleLorenz (the homepage capstone: SciML × StaticArrays × WasmMakie) ──
# Drag the σ / ρ sliders and the Lorenz attractor is RE-SOLVED and RE-DRAWN live,
# entirely in the browser. The ODE is integrated by SimpleDiffEq's SimpleRK4 over
# an SVector{3} state, the coefficients fed through the problem parameters `p`, and
# the x–z trajectory is rendered by WasmMakie — all compiled to WasmGC by
# WasmTarget. No server, no precomputed frames: a real ODE solver + a real plotting
# stack running as one wasm module, reacting to the sliders.
#
# `using` the libraries here so the names resolve in the component module both when
# the island is run natively to discover its structure AND when its effect body is
# compiled to wasm (the WasmTargetSimpleDiffEqExt / WasmTargetStaticArraysExt
# overlays are already active in this process).
import WasmMakie as WM
using WasmMakie: lines!, scatter!
using SimpleDiffEq, SciMLBase, StaticArrays

# Top-level Lorenz right-hand side (out-of-place, SVector state). Parameters σ, ρ, β
# arrive through `p` — NOT closure-captured — so the rhs stays a concrete top-level
# function the memo can lower (and the 4-arg `ODEProblem(f,u0,tspan,p)` overlay
# threads `p` through). u' = [ σ(y−x), x(ρ−z)−y, xy−βz ].
_wt_lorenz(u, p, t) = SVector{3,Float64}(
    p[1] * (u[2] - u[1]),
    u[1] * (p[2] - u[3]) - u[2],
    u[1] * u[2] - p[3] * u[3],
)

@island function ExampleLorenz(; sigma0::Float64 = 10.0, rho0::Float64 = 28.0)
    sigma, set_sigma = create_signal(sigma0)
    rho,   set_rho   = create_signal(rho0)

    # rounded views for the labels (floor-based — no Printf in-wasm)
    sigr = create_memo(() -> floor(sigma() * 10.0 + 0.5) / 10.0)
    rhor = create_memo(() -> floor(rho()   * 10.0 + 0.5) / 10.0)

    # ── the reactive plot: re-solve + re-draw on every slider move ──
    create_effect(() -> begin
        σ = sigma()
        ρ = rho()
        β = 2.6666666666666665                       # 8/3, fixed
        p = (σ, ρ, β)                                # NTuple params (Vector params don't lower)

        # integrate the Lorenz system in wasm — SimpleRK4 over an SVector{3} state
        u0  = SVector{3,Float64}(1.0, 1.0, 1.0)
        sol = solve(ODEProblem(_wt_lorenz, u0, (0.0, 32.0), p), SimpleRK4(); dt = 0.012)

        # project the trajectory onto the x–z plane (the iconic butterfly)
        xs = Float64[]
        zs = Float64[]
        for u in sol.u
            push!(xs, u[1])
            push!(zs, u[3])
        end

        fig = WM.Figure(size = (900.0, 600.0))
        ax  = WM.Axis(fig[1, 1]; title = "Lorenz attractor — solved & drawn in WebAssembly",
                      subtitle = "SimpleDiffEq · StaticArrays · WasmMakie",
                      xlabel = "x", ylabel = "z")
        lines!(ax, xs, zs; color = :purple, linewidth = 1.0)
        WM.render!(fig, WM.WasmCtx())
    end)

    slider_row(label, valview, minv, maxv, step, value, setter) = Div(
        :class => "flex items-center gap-3",
        Span(:class => "text-xs font-mono text-warm-500 w-16 text-right", label),
        Input(:type => "range", :min => minv, :max => maxv, :step => step, :value => value,
            :on_input => setter,
            :class => "flex-1 accent-accent-500 cursor-pointer"),
        Span(:class => "text-sm font-mono text-accent-600 dark:text-accent-400 w-14 text-right", valview),
    )

    Div(
        :class => "flex flex-col items-center gap-4 w-full",
        Div(
            :class => "w-full max-w-3xl rounded-lg border border-warm-200 dark:border-warm-800 overflow-hidden bg-white dark:bg-warm-950",
            Canvas(
                :width => 900, :height => 600,
                :style => "display:block;width:100%;height:auto;",
            ),
        ),
        Div(
            :class => "w-full max-w-md flex flex-col gap-3 pt-1",
            slider_row("σ (sigma)", sigr, "4",  "18", "0.1", sigma0, set_sigma),
            slider_row("ρ (rho)",   rhor, "1",  "45", "0.1", rho0,   set_rho),
        ),
    )
end
