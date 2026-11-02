#!/usr/bin/env bash
# dev/src_progress.sh — the rebuild's src progress, which `dev/ship.sh` prints after every landing
# (L208; dev/LEDGER.md D40, Dale 2026-10-21: "how are things going? still in setup or actually building
# the src code??"). One source: L208 runs this program in the landing's check, and ship prints its line.
#
#   bash dev/src_progress.sh                      this tree: the dart definitions src/ ports, read
#                                                 from WasmTarget's @parity registry (A35S1), and the
#                                                 landings (commits) since src/ last changed
#   bash dev/src_progress.sh <anchored> <ported> <since> [<replaced> <gaps>]   the line for planted numbers (L208's negative)
#   bash dev/src_progress.sh kinds                 each counted anchor and its kind, one line each (`<kind>\t<anchor>`,
#                                                 a DartThrow's or DartAbstract's dart line after it), from
#                                                 which the line's counts are read back (A74S2)
#   bash dev/src_progress.sh code <base> <head>   exits 0 when the change from <base>'s merge base with
#                                                 <head> changes a line of code under src/ (a line neither
#                                                 blank nor a comment), 1 when it changes none, 2 when a
#                                                 revision names no commit: dev/ship.sh's port class (A66E4)
#
# Until legacy/ exists, src/ is still WT1's (1.A2c moves it), so the rebuild's src counts none and
# every landing since the rebuild began (REBUILD_START) is a src-less one. An anchored definition is
# a dart definition dev/skeleton.jl counts in scope (several Julia definitions may name one: a struct
# and its constructor; an enum's values and a field's accessors are parts of theirs), a ported one a
# counted definition src fills with no @unported stub left at its anchor; the generator anchors every
# in-scope definition (its `diff`), so the anchored count is its total.
# Intent: a status leads with src progress, so setup never passes for building. Band: from the
# NOTE_AFTER-th consecutive landing that changes nothing under src/, a note, never a failure.
set -euo pipefail
NOTE_AFTER=5
REBUILD_START=e2371eca08605231256dd5f3ee97609d6fc019a4   # chore(land): the march branch is wt2
cd "$(git rev-parse --show-toplevel)"
# the kinds (rejection_only_kinds, then Skeleton.dart_kinds) cost Julia's inference over every @parity
# method, about 15 CPU-s: kept in the common dir under dev/cache_key.sh's key (Base's staleness rule over
# every input the kinds read: the julia build, the pinned checkouts, src/, the interpreter it imports, the
# manifest, the dart reader and this program), recomputed when the key is new (dev/progress_kinds.jl); the
# line names the key and whether it read the cache
kinds_cache() {
    local dir key
    dir="$(git rev-parse --path-format=absolute --git-common-dir)/wt-rejection-kinds"; mkdir -p "$dir"
    key=$(bash dev/cache_key.sh src lib/WasmInterpreter Manifest.toml Project.toml dev/skeleton.jl dev/skeleton_scope.toml \
          dev/src_progress.sh dev/progress_kinds.jl dev/cache_key.sh) || { echo "src_progress: the kinds cache's key failed" >&2; return 1; }
    [[ $key =~ ^[0-9a-f]{40}$ ]] || { echo "src_progress: the kinds cache's key is no key ($key)" >&2; return 1; }
    echo "$dir/$key.tsv"
}
# a port is a change to src/'s code: its added and removed lines, the diff's file headers aside, less the
# blank ones and Julia's `#` comments (f4cc916d, comment only, ranked early as port work: A66E4)
if [ "${1:-}" = kinds ]; then
    . dev/depot.sh; wt_depot_export "$PWD"
    WT_KINDS_CACHE=$(kinds_cache) || exit 1; export WT_KINDS_CACHE
    exec julia --project=. --startup-file=no -e 'using WasmTarget
        include("dev/skeleton.jl")
        S = Skeleton.read_scope()
        counted = Set(Skeleton.anchor(f, d) for f in Skeleton.scope() for d in S.decls[f] if Skeleton.counted(d))
        es = [x for x in WasmTarget.REGISTRY if x isa WasmTarget.ParityEntry && WasmTarget._within(x.mod, WasmTarget)]
        include("dev/progress_kinds.jl")
        R, L, hit = progress_kinds(S, ENV["WT_KINDS_CACHE"])
        present = Set(x.anchor for x in es)
        stubbed = Set(x.anchor for x in es if x.anchor in counted && !x.ported)
        for a in sort!(collect(counted))
            k = !(a in present) ? :absent : a in stubbed ? :Unported_stub : get(R, a, :body)
            println(k, "\t", a, haskey(L, a) ? "\t" * L[a] : "")
        end'
fi
if [ "${1:-}" = code ]; then
    [ $# -eq 3 ] || { echo "src_progress: code <base> <head>"; exit 2; }
    for r in "$2" "$3"; do
        git rev-parse --verify -q "$r^{commit}" > /dev/null || { echo "src_progress: $r names no commit"; exit 2; }
    done
    # the pipeline's status is its last grep's alone: with pipefail, `grep -q` stopping at the first line of
    # code ends the commands before it by SIGPIPE on a large diff (141), read as an error
    set +eo pipefail
    git diff -U0 --no-color "$2...$3" -- src | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) (a/|b/|/dev/null)' |
        cut -c2- | grep -qvE '^[[:space:]]*(#.*)?$'
    exit $?
fi
started=1
if [ $# -eq 3 ] || [ $# -eq 5 ]; then
    anchored=$1; ported=$2; since=$3
    [ $# -eq 5 ] && { replaced=$4; gaps=$5; }
else
    if [ -d legacy ]; then
        # the worktree's private depot (dev/depot.sh), never the shared compiled cache another tree can
        # replace mid-run; and every entry of the package's modules (WasmBuilder, Dart2Wasm and theirs),
        # not the root module's alone, where no port lives
        . dev/depot.sh; wt_depot_export "$PWD"
        # the anchored count is the generator's in-scope total, each definition dev/skeleton.jl counts
        # (an enum's values and a field's accessors are parts of their definition, not more); a ported
        # one is a counted anchor src fills, no @unported entry left at it
        WT_KINDS_CACHE=$(kinds_cache) || exit 1; export WT_KINDS_CACHE
        counts=$(julia --project=. --startup-file=no -e 'using WasmTarget
            include("dev/skeleton.jl")
            S = Skeleton.read_scope()
            counted = Set(Skeleton.anchor(f, d) for f in Skeleton.scope() for d in S.decls[f] if Skeleton.counted(d))
            e = [x for x in WasmTarget.REGISTRY if x isa WasmTarget.ParityEntry && WasmTarget._within(x.mod, WasmTarget) && x.anchor in counted]
            stubbed = Set(x.anchor for x in e if !x.ported)
            ported = setdiff(Set(x.anchor for x in e), stubbed)
            # A55S13, A64E2: of the ported, those Julia'"'"'s inference finds never return, by kind
            # (rejection_only_kinds, then dev/skeleton.jl'"'"'s dart_kinds). Internal: the answer of Julia replacing a construct it never produces
            # (ruling A55S12); Unported (a dart definition) and Unquarantined (a Julia-only one,
            # src/julia/reject.jl): gaps; DartThrow: dart'"'"'s own body throws, a body; DartAbstract: dart
            # declares it abstract, no body to port, never counted
            include("dev/progress_kinds.jl")
            R, L, hit = progress_kinds(S, ENV["WT_KINDS_CACHE"])
            k(a) = get(R, a, :body)
            replaced = count(a -> k(a) === :Internal, ported)
            gaps = count(a -> k(a) in (:Unported, :Unquarantined), ported)
            abstract = count(a -> k(a) === :DartAbstract, ported)
            faithful = count(a -> k(a) === :DartThrow, ported)
            println(length(counted), " ", length(ported), " ", replaced, " ", gaps, " ", abstract, " ", faithful, " ", hit)') ||
            { echo "src: WasmTarget did not load, so its @parity registry gives no count"; exit 1; }
        read -r anchored ported replaced gaps abstract faithful kinds_read <<< "$counts"
        # the runtime's gaps: the Unported rejections anchored in the wasm runtime library of the same dart-lang/sdk
        # pin (sdk/lib/_internal/wasm/, A52S1), each a call a module would make into a runtime src/runtime/ has not
        # ported yet; counted as the sites rejecting and the distinct runtime definitions they name (the measure
        # both march monitors read, one source here)
        # (a line rejecting Unported, each runtime anchor on it: `Unported(standalone ? "<a>" : "<b>")` names two)
        rt=$(grep -rh 'Unported(' src | grep -oE '"sdk/lib/_internal/wasm/[^"]+"' || true)
        rt_sites=$(printf '%s' "$rt" | grep -c . || true); rt_defs=$(printf '%s' "$rt" | sort -u | grep -c . || true)
        last=$(git log -1 --format=%H -- src)
    else
        anchored=0; ported=0; last=$REBUILD_START; started=0
    fi
    since=$(git rev-list --count --no-merges "$last"..HEAD)
fi
# A55S13, and Dale 2026-10-29, "DO NOT allow stubs to be clalled complete": a definition whose whole body is one
# rejection is no port: an Internal one claims Julia never produces dart's construct, an Unported or Unquarantined
# one is a gap. The headline counts only definitions with a body; the rejection-only ones stand beside it, never in it
body=$(( ported - ${replaced:-0} - ${gaps:-0} - ${abstract:-0} ))
line="src: $body of $anchored anchored dart definitions ported with a body (every definition of each dart file src loads, dev/skeleton.jl)"
[ -n "${faithful:-}" ] && line="$line, $faithful of them a dart body that itself throws, ported as its throw"
line="$line; $since landing(s) since src/ last changed"
# the line sums to the anchored total by itself: an @unported stub (anchored, not ported) is a gap too
stubs=$(( anchored - ported ))
[ -n "${replaced:-}" ] && line="$line; not counted ported: $replaced that never return, Julia's inference finds, rejecting Internal (Julia's answer replacing dart's construct, each to triage), $(( gaps + stubs )) gap(s) still to fill ($gaps rejecting Unported or Unquarantined, $stubs an @unported stub) and ${abstract:-0} in place of a dart abstract declaration (no body to port); $body + $replaced + $(( gaps + stubs )) + ${abstract:-0} = $(( body + replaced + gaps + stubs + ${abstract:-0} )) of $anchored"
[ -n "${kinds_read:-}" ] && line="$line; the kinds cache: $kinds_read ($(basename "$WT_KINDS_CACHE" .tsv | cut -c1-12))"
[ -n "${rt_sites:-}" ] && line="$line; the runtime library: $rt_sites rejecting site(s) name $rt_defs definition(s) of sdk/lib/_internal/wasm/ still to port"
[ $started -eq 1 ] || line="$line (the rebuild's src/ not started: WT1 holds src/ until 1.A2c)"
echo "$line"
if [ "$since" -ge "$NOTE_AFTER" ]; then
    echo "src: note: $since consecutive landings changed nothing under src/; the rebuild needs a lane porting compiler src (D40)"
fi
exit 0
