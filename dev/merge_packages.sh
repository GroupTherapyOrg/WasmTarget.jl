#!/usr/bin/env bash
# dev/merge_packages.sh — git's merge driver for src/julia/packages.jl in dev/ship.sh's rebase (%O %A %B, set
# there with `git -c merge.wt-packages.driver=...`, named by .gitattributes). The file's blocks between a
# "written by dev/skeleton.jl write" marker and its "# ---- end of" marker are the generator's (L210 compares
# them), so they are blanked in all three versions and the rest merges with git merge-file: a conflict in the
# prose or a module's header stays a conflict, and the blocks cannot conflict. The merge is marked in
# $WT_PACKAGES_MERGED, so the rebase's --exec rewrites the blocks from the commit's own tree
# (dev/regen_packages.sh) before its check. precedent(git: gitattributes(5) "Defining a custom merge driver",
# git-merge-file(1)); taking either whole side dropped the other's lines outside the blocks (10:38: `import
# ..WasmBuilder` lost, "UndefVarError: WasmBuilder not defined in WasmTarget.LLVM")
set -uo pipefail
# a start marker without its end, or an end without its start, would blank every line after it and merge the
# truncated text cleanly: such a version is refused, a conflict that stops the rebase (march-monitor-a, 12:08)
blank() { awk '/written by dev\/skeleton\.jl write ----$/{if (skip) exit 3; print; skip=1; next}
  /^# ---- end of /{if (!skip) exit 3; skip=0} !skip; END{if (skip) exit 3}' "$1" > "$1.wtblank" && mv "$1.wtblank" "$1"; }
blank "$1" && blank "$2" && blank "$3" || exit 2
git merge-file "$2" "$1" "$3"; rc=$?
[ -n "${WT_PACKAGES_MERGED:-}" ] && touch "$WT_PACKAGES_MERGED"
exit $rc
