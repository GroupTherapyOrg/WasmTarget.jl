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
#
# dev/cache_key.sh --ids — each path on stdin (a file or a directory of the tree) with its id, `<path><TAB><id>`:
# a file's blob id; a directory's, the blob id of its listing joined, the content Base gives a directory
# include (julia/base/loading.jl:2358, `join(readdir(path))`); exit 1 when a path is missing, 2 when an id
# cannot be read. The one definition of an input's id, for a cache that records its inputs (dev/progress_kinds.jl).
# dev/cache_key.sh --fresh <file> — whether such a cache (lines `#input<TAB><path><TAB><id>`) is fresh: exit 0
# when every recorded input exists with its recorded id, 1 when one is missing or changed (stale), 2 when the
# file records no input or an id cannot be read. A port of Base's any_includes_stale (loading.jl:3994), which
# reads an image's includes from its header, never from its caller: the key below names the cache's program
# and pins, and the record its other inputs.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
input_ids() {
    local paths files dirs f
    paths=$(cat)
    files=""; dirs=""
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -d "$f" ]; then dirs="$dirs$f"$'\n'
        elif [ -f "$f" ]; then files="$files$f"$'\n'
        else return 1; fi
    done <<< "$paths"
    {
        if [ -n "$files" ]; then
            local ids
            ids=$(printf '%s' "$files" | git hash-object --stdin-paths) || return 2
            [ "$(printf '%s' "$files" | wc -l)" -eq "$(printf '%s\n' "$ids" | wc -l)" ] || return 2
            paste <(printf '%s' "$files") <(printf '%s\n' "$ids")
        fi
        if [ -n "$dirs" ]; then
            while IFS= read -r f; do
                [ -n "$f" ] || continue
                printf '%s\t%s\n' "$f" "$(LC_ALL=C ls -A "$f" | tr -d '\n' | git hash-object --stdin)" || return 2
            done <<< "$dirs"
        fi
    } | LC_ALL=C sort
}
if [ "${1:-}" = --ids ]; then
    rc=0; input_ids || rc=$?
    exit $rc
fi
if [ "${1:-}" = --fresh ]; then
    [ $# -eq 2 ] && [ -f "$2" ] || { echo "cache_key: --fresh <file>" >&2; exit 2; }
    rec=$(grep $'^#input\t' "$2" | cut -f2,3 | LC_ALL=C sort) || true
    [ -n "$rec" ] || { echo "cache_key: $2 records no input" >&2; exit 2; }
    rc=0; now=$(printf '%s\n' "$rec" | cut -f1 | input_ids) || rc=$?
    [ $rc -eq 0 ] || { [ $rc -eq 1 ] && exit 1; echo "cache_key: a recorded input of $2 could not be read" >&2; exit 2; }
    [ "$now" = "$rec" ] && exit 0
    exit 1
fi
# every input read or the key refused, located (D9, A78E1): a key computed past a failed input would serve a
# verdict whose inputs were never compared
# the julia's header (dev/julia_header.jl, its one definition): `--header <h>` when the caller is the julia that
# computes the verdict (the ratchet, which would otherwise start a julia per key, ~0.3 s each), never read
# from the environment (A83S8); else from the julia on PATH
if [ "${1:-}" = --header ]; then
    header=$2; shift 2
else
    header=$(julia --startup-file=no dev/julia_header.jl) || { echo "cache_key: the julia running gave no header" >&2; exit 1; }
fi
[ -n "$header" ] || { echo "cache_key: the julia running gave an empty header" >&2; exit 1; }
[ $# -ge 1 ] || { echo "cache_key: name the pathspecs the verdict reads" >&2; exit 2; }
pins=""
for d in dart-sdk julia llvm-project; do
    pins="$pins$d $(git -C "$HOME/.cache/wasmtarget/$d" rev-parse HEAD 2>/dev/null || echo none)"$'\n'
done
# a named file git ignores (the Manifest) is an input too: read by its name
files=$( { git ls-files -co --exclude-standard -- "$@"; for a in "$@"; do if [ -f "$a" ]; then echo "$a"; fi; done; } | LC_ALL=C sort -u)
listing=""
if [ -n "$files" ]; then
    while IFS= read -r f; do
        [ -f "$f" ] || { echo "cache_key: $f, an input git tracks, is missing" >&2; exit 1; }
    done <<< "$files"
    ids=$(printf '%s\n' "$files" | git hash-object --stdin-paths) || { echo "cache_key: an input could not be read" >&2; exit 1; }
    [ "$(printf '%s\n' "$files" | wc -l)" -eq "$(printf '%s\n' "$ids" | wc -l)" ] ||
        { echo "cache_key: $(printf '%s\n' "$files" | wc -l | tr -d ' ') inputs gave $(printf '%s\n' "$ids" | wc -l | tr -d ' ') ids" >&2; exit 1; }
    listing=$(paste -d' ' <(printf '%s\n' "$files") <(printf '%s\n' "$ids"))
fi
key=$(printf '%s\n%s%s\n' "$header" "$pins" "$listing" | git hash-object --stdin)
[[ $key =~ ^[0-9a-f]{40}$ ]] || { echo "cache_key: no key ($key)" >&2; exit 1; }
echo "$key"
