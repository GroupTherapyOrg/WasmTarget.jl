# Regenerate the Snapshot.jl island-piece status lock from current WT codegen.
# Run after a (re-)harvest, or after a codegen change that legitimately flips a
# piece's status:
#
#     julia --project=. test/integration/regen_snapshot_lock.jl
#
# Commit the resulting snapshot_island_status.json alongside the change. The runtests
# testset asserts each piece's live status == the locked status (catches both
# regressions and fixes).
using WasmTarget
include(joinpath(@__DIR__, "..", "utils.jl"))
include(joinpath(@__DIR__, "snapshot_islands.jl"))
regenerate_snapshot_lock!()
