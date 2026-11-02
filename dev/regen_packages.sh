#!/usr/bin/env bash
# dev/regen_packages.sh — rewrites src/julia/packages.jl's generated blocks from the tree at HEAD and amends HEAD
# when they changed: run by dev/ship.sh's rebase --exec only after dev/merge_packages.sh merged the file with its
# blocks blanked. It includes dev/skeleton.jl afresh, never dev/SkeletonImage, whose ROOT is fixed when its image
# is built and may name another worktree; a ROOT that is not this tree refuses. Blanking every block and running
# it reproduces origin's file byte for byte (2026-11-02, 8.7 CPU-s)
set -euo pipefail
. dev/depot.sh; wt_depot_export "${WT_DEPOT_DIR:-$(pwd)}"
julia --project=. --startup-file=no -e 'include(joinpath(pwd(), "dev", "skeleton.jl")); S = Skeleton
normpath(S.ROOT) == normpath(pwd() * "/") || error("dev/skeleton.jl reads $(S.ROOT), not this tree")
t = S.packages_text(); t == read(S.PACKAGES, String) || write(S.PACKAGES, t)'
if ! git diff --quiet -- src/julia/packages.jl; then
  git commit -q --amend --no-edit -- src/julia/packages.jl
  echo "ship: src/julia/packages.jl's generated blocks rewritten into $(git log -1 --format=%h)"
fi
