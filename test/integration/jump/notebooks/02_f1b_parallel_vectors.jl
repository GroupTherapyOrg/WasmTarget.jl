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

# ╔═╡ 1b000001-0000-4000-8000-000000000001
using PlutoUI

# ╔═╡ 1b000004-0000-4000-8000-000000000004
md"""
# F1b: MOI-derived parallel-vector lifecycle

These controls call the exact canaries used by the native/raw/`-Os`/`-O3`
suite. They isolate the three-vector topology used by pinned MOI plus a
separate ordinary-`Vector` identity stress. This is **not** an actual
`VariablesContainer` claim.
"""

# ╔═╡ 1b000005-0000-4000-8000-000000000005
@bind mode Slider(0:5; default=0, show_value=true)

# ╔═╡ 1b000006-0000-4000-8000-000000000006
@bind boundary Slider(1:13; default=3, show_value=true)

# ╔═╡ 1b000007-0000-4000-8000-000000000007
n = JumpF1ParallelVectorCanaries.BOUNDARY_N[Int(boundary)]

# ╔═╡ 1b000008-0000-4000-8000-000000000008
parallel_result =
    JumpF1ParallelVectorCanaries.f1_parallel_variable_layout(
        Int64(mode),
        n,
    )

# ╔═╡ 1b000009-0000-4000-8000-000000000009
reference_result =
    JumpF1ParallelVectorCanaries.f1_vector_reference_lifecycle(
        min(Int64(mode), Int64(3)),
        n,
    )

# ╔═╡ 1b000010-0000-4000-8000-000000000010
HTML("""
<dl>
  <dt>Parallel layout</dt>
  <dd><strong data-wt-jump-case="f1_parallel_variable_layout">$(parallel_result)</strong></dd>
  <dt>Reference lifecycle</dt>
  <dd><strong data-wt-jump-case="f1_vector_reference_lifecycle">$(reference_result)</strong></dd>
</dl>
""")

# ╔═╡ Cell order:
# ╠═1b000001-0000-4000-8000-000000000001
# ╟─1b000004-0000-4000-8000-000000000004
# ╠═1b000005-0000-4000-8000-000000000005
# ╠═1b000006-0000-4000-8000-000000000006
# ╠═1b000007-0000-4000-8000-000000000007
# ╠═1b000008-0000-4000-8000-000000000008
# ╠═1b000009-0000-4000-8000-000000000009
# ╠═1b000010-0000-4000-8000-000000000010
