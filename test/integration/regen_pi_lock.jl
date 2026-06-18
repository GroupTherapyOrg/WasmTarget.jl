# Regenerate the PlutoIslands island-piece status lock from current WT codegen.
# Run after a (re-)harvest, or after a codegen change that legitimately flips a
# piece's status:
#
#     julia --project=. test/integration/regen_pi_lock.jl
#
# Commit the resulting pi_island_status.json alongside the change. The runtests
# testset asserts each piece's live status == the locked status (catches both
# regressions and fixes).
using WasmTarget
include(joinpath(@__DIR__, "..", "utils.jl"))
include(joinpath(@__DIR__, "pi_islands.jl"))
regenerate_pi_lock!()
