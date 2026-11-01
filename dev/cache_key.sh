#!/usr/bin/env bash
# dev/cache_key.sh <pathspec>... — the key a cached verdict is kept under in the common dir, read again
# only while every input it was computed from is unchanged: Base's own staleness rule ported
# (julia/base/loading.jl:4049 stale_cachefile, whose precompiled image is stale when its header's julia
# build or flags, a required module's build, or any include's content differs). Its inputs:
#   - the julia running: its commit, its build's tagged commit, its machine and its cache flags (the
#     header Base checks; never the version string alone, which two builds share);
#   - the pinned checkouts' heads (dart-lang/sdk, JuliaLang/julia, llvm-project), every pin a verdict reads;
#   - each file the pathspecs name, tracked or untracked, by its path and its content's blob id (`git
#     hash-object`), so a text moved between files changes the key as an edit does.
# Each cache passes its own program and readers among the pathspecs (dev/src_progress.sh, dev/skeleton.jl,
# test/parity_ratchet.jl for a lock's verdict), with src/, lib/WasmInterpreter, Manifest.toml and
# Project.toml (the required modules). Prints a 40-hex key.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
[ $# -ge 1 ] || { echo "cache_key: name the pathspecs the verdict reads" >&2; exit 2; }
{
    julia --startup-file=no -e 'print(Base.GIT_VERSION_INFO.commit, " ", Base.GIT_VERSION_INFO.tagged_commit, " ",
                                      Sys.MACHINE, " ", ccall(:jl_cache_flags, UInt8, ()), "\n")'
    for d in dart-sdk julia llvm-project; do
        printf '%s %s\n' "$d" "$(git -C "$HOME/.cache/wasmtarget/$d" rev-parse HEAD 2>/dev/null || echo none)"
    done
    # a named file git ignores (the Manifest) is an input too: read by its name
    files=$( { git ls-files -co --exclude-standard -- "$@"; for a in "$@"; do if [ -f "$a" ]; then echo "$a"; fi; done; } | LC_ALL=C sort -u)
    [ -n "$files" ] && paste -d' ' <(printf '%s\n' "$files") <(printf '%s\n' "$files" | git hash-object --stdin-paths)
} | git hash-object --stdin
