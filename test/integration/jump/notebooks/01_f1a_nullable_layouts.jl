### A Pluto.jl notebook ###
# v0.20.28

using Markdown
using InteractiveUtils

macro bind(def, element)
    return quote
        local iv = try
            Base.loaded_modules[
                Base.PkgId(
                    Base.UUID("6e696c72-6542-2067-7265-42206c756150"),
                    "AbstractPlutoDingetjes",
                ),
            ].Bonds.initial_value
        catch
            _ -> missing
        end
        local el = $(esc(element))
        global $(esc(def)) =
            Core.applicable(Base.get, el) ? Base.get(el) : iv(el)
        el
    end
end

# ╔═╡ 1a000001-0000-4000-8000-000000000001
using PlutoUI

# ╔═╡ 1a000004-0000-4000-8000-000000000004
md"""
# F1a: nullable MOI-derived layouts

This is browser evidence for one isolating compiler/runtime prerequisite. It
calls the same source-derived canary used by the native/raw/`-Os`/`-O3`
certification suite. It does **not** claim that `ObjectiveContainer`, a JuMP
model, optimizer, or solver works.
"""

# ╔═╡ 1a000005-0000-4000-8000-000000000005
@bind state Slider(0:3; default=0, show_value=true)

# ╔═╡ 1a000008-0000-4000-8000-000000000008
@bind x_slot Slider(1:6; default=5, show_value=true)

# ╔═╡ 1a000009-0000-4000-8000-000000000009
x = (-2, -1, 0, 1, 2, 17)[x_slot]

# ╔═╡ 1a000006-0000-4000-8000-000000000006
nullable_result =
    JumpF1NullableLayoutCanaries.f1_nullable_objective_layout(
        Int64(state),
        Int64(x),
    )

# ╔═╡ 1a000007-0000-4000-8000-000000000007
HTML(
    """<strong data-wt-jump-case="f1_nullable_objective_layout">$(nullable_result)</strong>""",
)

# ╔═╡ Cell order:
# ╠═1a000001-0000-4000-8000-000000000001
# ╟─1a000004-0000-4000-8000-000000000004
# ╠═1a000005-0000-4000-8000-000000000005
# ╠═1a000008-0000-4000-8000-000000000008
# ╠═1a000009-0000-4000-8000-000000000009
# ╠═1a000006-0000-4000-8000-000000000006
# ╠═1a000007-0000-4000-8000-000000000007
