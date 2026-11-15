#!/usr/bin/env bash
# dev/driver_evidence.sh <commit> --state <the climb's state> --main <the main repository> [--item <ref>]...
# A driver commit's evidence (the lead's rule, 2026-11-15: every driver commit queued on the sweep alone later needed a
# fix only the ratchet or the live system found), three stages, one verdict line each, run from a CLONE of the
# repository (never a worktree of the real one), each in a scratch directory of its own:
#   1. the sweep: test/climb_l228.py and every L228 break and the runner's plants (dev/l228_sweep.py) inside the door's
#      check profile at background QoS, on a fresh clone of <commit>;
#   2. the ratchet (test/parity_ratchet.jl) on a fresh clone of <commit>, its origin/wt2 the commit's parent, given the
#      climb's resolved Manifest and dev/climb's PREFS (a clone has neither) and WT_L228_SCOPE as dev/check.sh gives it,
#      unsandboxed at default priority, behind the machine's two gates (the 1-minute load under 12; swapins under 2,000
#      in 10 s), checked first;
#   3. the lander's next round replayed (dev/climb/walk.py) on a copy of <state>'s files, the queue's items and each
#      --item cherry-picked onto <commit>, inside the check profile;
#   4. dev/check.sh itself, executed as a land job runs it (door.land_job's variables: CHECK_LANDING, WT_PINS_READY,
#      CHECK_BASE=HEAD~1, WT_SRC_SET and WT_SRC_COSTS in the lander's form), in stage 2's clone, twice: on an EMPTY
#      handed set and on a one-file set (the score's lightest passed file), each to its verdict line (2026-11-15
#      02:36:41Z: ba442dc6, three green lines, died at check.sh line 99 under `set -u`, the one file never executed).
#      What it reaches (read on this tree): its tree and its .wtd, its first depot (${WT_DEPOT_DIR}/.wtd/depot), the
#      tree's common dir (the clone's .git: wt-line-stop, wt-held, wt-dart-corpus) and, read, $HOME/.cache/wasmtarget's
#      pins and $HOME/.julia; no push, no sudo, no dev/ship.sh, nothing of the door's TOP (dev/fetch_julia.sh, its one
#      network path, runs only without WT_PINS_READY). The set file is mode 0444, so check.sh's own rule (a set its
#      user can write is refused: `[ -w ]`, access(2)) holds unchanged, as the door's run directory makes it hold.
# It never runs dev/check.sh, dev/ship.sh, dev/climb/launch.sh or a climb.py loop, reaches no door and no sudo, and
# writes only its scratch (reading <state> and <main>). Exit 0 when all three are green; a stage it could not run is
# named "not run", never green.
set -uo pipefail
[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -lt 1 ] && { sed -n '2,16p' "$0"; exit 2; }
commit=$1; shift; state=""; main=""; items=()
while [ $# -gt 0 ]; do
  case "$1" in --state) state=$2; shift 2;; --main) main=$2; shift 2;; --item) items+=("$2"); shift 2;; *) echo "driver_evidence: unknown $1"; exit 2;; esac
done
[ -n "$state" ] && [ -n "$main" ] || { echo "driver_evidence: --state and --main are required"; exit 2; }
here=$(git rev-parse --show-toplevel) || exit 2
[ "$(git -C "$here" rev-parse --path-format=absolute --git-common-dir)" = "$here/.git" ] || { echo "driver_evidence: run from a clone, not a worktree"; exit 2; }
sha=$(git -C "$here" rev-parse "$commit^{commit}") || exit 2
s=$(mktemp -d "${TMPDIR:-/tmp}/driver-evidence-${sha:0:8}.XXXXXX"); mkdir -p "$s/home/tmp"
# its per-run scratch is removed at exit, green or red (each run's clones and copies are hundreds of MB: ten runs filled
# the disk to 22 GB free, 2026-11-15 03:50Z); kept across runs: the ratchet's depot (driver-evidence-depot) and the
# landing home's depot (driver-evidence-landing/u/_wtland/.wtd), each the compiled images of one fixed path
lroot="${TMPDIR:-/tmp}/driver-evidence-landing"; lhome="$lroot/u/_wtland"
cleanup() { rm -rf "$s" "$lhome/c" "$lhome/tree" "$lhome/tmp" "$lhome/sweep.json"; }
trap cleanup EXIT
jdk=$(/usr/libexec/java_home 2>/dev/null)
jar="${TLA2TOOLS_JAR:-$HOME/.cache/wasmtarget/tla2tools.jar}"
top=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import door; door.profile(sys.argv[2], [sys.argv[3]], kind="check"); print(door.TOP)' \
  "$here/dev/climb" "$s/check.sb" "$s/home") || { echo "driver_evidence: the check profile could not be written"; exit 2; }
# as a landing's check runs: CHECK_LANDING, and the door's tools first (its `ps`: the system's is setuid, which the
# profile does not execute)
boxed() { env -i HOME="$s/home" TMPDIR="$s/home/tmp" USER="$USER" LANG=en_US.UTF-8 DEVELOPER_DIR=/Library/Developer/CommandLineTools \
  CHECK_LANDING=1 TLA2TOOLS_JAR="$jar" PATH="$jdk/bin:$top/tools/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin" \
  taskpolicy -b /usr/bin/sandbox-exec -f "$s/check.sb" "$@" < /dev/null; }
# the landing's shape (stages 1 and 4): a scratch door root standing in for door.TOP, its landing user's home and tmp at
# <root>/u/_wtland (a landing's TMPDIR lies under the live root: 2026-11-15 03:11:53Z, a prefix test there dropped
# 67b171a2 and no stage here showed it), WT_L228_LIVE_TOP naming <root> for walk.py's live-root test alone; env -i
# with door.base_env's variables and door.land_job's, the JDK first on door.PATH, the pinned jar in the home as the
# door's pins give it, inside the door's check profile writing that home alone. Persistent across runs (its depot keeps
# the compiled images of $HOME/c, the path a land job's clone has); as door.argv runs a land job: env -i, nobootstrap
# (no Mach bootstrap port), the check profile, default QoS for check.sh. What still differs from a landing: the user (this
# one, not _wtland, so the harness's landing_sandboxed reads False and its root_refusal reads the scratch root, never
# the live one) and the build users' sealed homes; the shared depots are the door's own (door._shared), read
rm -rf "$lhome/tmp" "$lhome/c" "$lhome/tree"; mkdir -p "$lhome/tmp" "$lhome/.cache" "$lroot/pins"
# the pins as a landing user reads them: its ~/.cache/wasmtarget a link to the door's <root>/pins (door.py's home
# setup), which holds the pinned checkouts (door.pins mirrors this user's own: julia, utf8proc, llvm-project,
# dart-sdk; linked here to those same copies, read) and the jar
rm -rf "$lhome/.cache/wasmtarget"; ln -sfn "$lroot/pins" "$lhome/.cache/wasmtarget"
cp "$jar" "$lroot/pins/tla2tools.jar" 2>/dev/null
for n in julia utf8proc llvm-project dart-sdk; do
  [ -e "$HOME/.cache/wasmtarget/$n" ] && ln -sfn "$(cd "$HOME/.cache/wasmtarget/$n" && pwd -P)" "$lroot/pins/$n"
done
dpath=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import door; door.profile(sys.argv[2], [sys.argv[3]], kind="check"); print(door.PATH)' \
  "$here/dev/climb" "$s/landing.sb" "$lhome") || { echo "driver_evidence: the landing's profile could not be written"; exit 2; }
landed() { env -i HOME="$lhome" USER=_wtland LOGNAME=_wtland TMPDIR="$lhome/tmp" PATH="$jdk/bin:$dpath" LANG=en_US.UTF-8 \
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null JULIA_PKG_OFFLINE=true DEVELOPER_DIR=/Library/Developer/CommandLineTools \
  GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="$top/in/*" GIT_CONFIG_KEY_1=safe.directory \
  GIT_CONFIG_VALUE_1="$top/pins/*" CHECK_LANDING=1 CHECK_BASE=HEAD~1 WT_PINS_READY=1 WT_L228_LIVE_TOP="$lroot" "$@" < /dev/null; }
# the machine's gates before a heavy stage: the 1-minute load under 12, swapins under 2,000 in 10 s and the battery at
# 20% or more, waited for (every 30 s, at most 30 minutes, never a stage started past them); sets load, w0, w1 and pct
gates() {
  local t0; t0=$(date +%s)
  while :; do
    load=$(sysctl -n vm.loadavg | awk '{print $2}'); w0=$(vm_stat | awk '/Swapins/ {gsub(/\./, "", $2); print $2}')
    sleep 10; w1=$(vm_stat | awk '/Swapins/ {gsub(/\./, "", $2); print $2}')
    pct=$(pmset -g batt | sed -n 's/.*[[:space:]]\([0-9]*\)%;.*/\1/p' | head -1)
    awk -v l="$load" 'BEGIN { exit !(l < 12) }' && [ $((w1 - w0)) -lt 2000 ] && { [ -z "$pct" ] || [ "$pct" -ge 20 ]; } && return 0
    [ $(( $(date +%s) - t0 )) -lt 1800 ] || return 1
    sleep 20
  done
}
verdicts=(); red=0
# 1. the sweep, in the landing's shape
git clone -q --no-hardlinks "$here" "$lhome/tree" && git -C "$lhome/tree" checkout -q --detach "$sha"
landed "$top/tools/bin/nobootstrap" /usr/sbin/taskpolicy -b /usr/bin/sandbox-exec -f "$s/landing.sb" /usr/bin/python3 -I "$lhome/tree/dev/l228_sweep.py" "$lhome/tree" \
  --out "$lhome/sweep.json" > "$s/sweep.out" 2>&1; rc=$?
# the harness's own scratch left in the landing user's tmp (each section's, each walk's): none; the system's toolchain
# keeps its own caches there (xcrun_db), named, never counted
left=$(ls "$lhome/tmp" | grep -cE '^(l228-|walk-top-)'); other=$(ls "$lhome/tmp" | grep -vE '^(l228-|walk-top-)' | tr '\n' ' ')
[ "$left" = 0 ] || { echo "  the sweep left $left of the harness's scratch in the landing user's tmp: $(ls "$lhome/tmp" | grep -E '^(l228-|walk-top-)' | head -5 | tr '\n' ' ')" >> "$s/sweep.out"; rc=1; }
verdicts+=("1 sweep:   $( [ $rc = 0 ] && echo green || echo RED ) — $(head -1 "$s/sweep.out" | cut -c1-260)$([ "$left" = 0 ] && echo "; none of the harness's scratch left in the landing user's tmp${other:+ (the toolchain cache: $other)}" || echo "; LEFT $left of the harness's scratch in the landing user's tmp")"); [ $rc = 0 ] || red=1
# 2. the ratchet, behind the gates
if gates; then
  r="$s/ratchet"; git clone -q --no-hardlinks "$here" "$r" && git -C "$r" checkout -q --detach "$sha" && git -C "$r" update-ref refs/remotes/origin/wt2 "$sha~1"
  man=$(grep -l '^\[\[deps.WasmInterpreter\]\]' "$state"/env/*.toml 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
  if [ -z "$man" ]; then verdicts+=("2 ratchet: not run — no resolved Manifest naming WasmInterpreter in $state/env"); red=1
  else
    cp "$man" "$r/Manifest.toml"; printf '[WasmTarget]\nprecompile_workload = false\n' > "$r/LocalPreferences.toml"; mkdir -p "$r/.wtd"
    depot="${TMPDIR:-/tmp}/driver-evidence-depot"; mkdir -p "$depot"
    (cd "$r" && JULIA_DEPOT_PATH="$depot:$HOME/.julia:" WT_L228_SCOPE="$r/.wtd/l228-scope" julia --project=. --startup-file=no test/parity_ratchet.jl > "$s/ratchet.out" 2>&1); rc=$?
    broken=$(grep -c 'LOCK BROKEN\|REGRESSED' "$s/ratchet.out"); l=$(grep -o "L228's harness: .*" "$s/ratchet.out" | head -1 | cut -c1-200)
    verdicts+=("2 ratchet: $( [ $rc = 0 ] && echo green || echo RED ) — rc $rc, $broken lock(s) broken, scope $(cat "$r/.wtd/l228-scope" 2>/dev/null || echo none); $l (load $load, swapins +$((w1 - w0)), Manifest $(basename "$man"))")
    [ $rc = 0 ] || red=1
  fi
else verdicts+=("2 ratchet: not run — the machine's gates stayed shut 30 minutes (load $load, swapins +$((w1 - w0)) in 10 s, battery ${pct:-?}%)"); red=1; fi
# 3. the replay of the lander's next round
mkdir -p "$s/home/state"; for f in "$state"/*; do [ -f "$f" ] && cp "$f" "$s/home/state/"; done
mkdir -p "$s/home/state/env"; cp "$state"/env/*.json "$s/home/state/env/" 2>/dev/null
# its own clone (stage 1's is the landing home's); the queue's commits by their refs; each --item as its patch, read from
# <main> (a commit no ref holds is still given)
git clone -q --no-hardlinks "$here" "$s/home/tree" && git -C "$s/home/tree" checkout -q --detach "$sha"
git -C "$s/home/tree" fetch -q "$main" '+refs/heads/*:refs/remotes/main/*' 2>/dev/null
given=(); k=0
for it in "${items[@]+"${items[@]}"}"; do
  k=$((k + 1)); git -C "$main" format-patch -1 --stdout "$it" > "$s/home/item$k.patch" && given+=("patch:$s/home/item$k.patch") || given+=("$it")
done
boxed /usr/bin/python3 -I "$s/home/tree/dev/climb/walk.py" "$s/home/state" "$sha" "${given[@]+"${given[@]}"}" > "$s/walk.out" 2>&1; rc=$?
verdicts+=("3 replay:  $( [ $rc = 0 ] && echo green || echo RED ) — $(tail -1 "$s/walk.out" | cut -c1-200)"); [ $rc = 0 ] || red=1
# 4. dev/check.sh, executed: an empty handed set, then a one-file set
if [ ! -d "${r:-/nonexistent}/.git" ]; then verdicts+=("4 check.sh: not run — stage 2 made no clone"); red=1
elif ! gates; then verdicts+=("4 check.sh: not run — the machine's gates stayed shut 30 minutes (load $load, battery ${pct:-?}%)"); red=1
else
  hs=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("head", ""))' "$state/src-latest.json" 2>/dev/null)
  rec="$state/src-${hs:0:8}.tsv"
  light=$(awk -F'\t' '$2 == "passed" && $3 != "" { print $3 "\t" $1 }' "$rec" 2>/dev/null | sort -g | head -1 | cut -f2)
  mkdir -p "$s/sets"; awk -F'\t' '$2 == "passed" && $3 != "" { print $1 "\t" $3 }' "$rec" > "$s/sets/costs.tsv" 2>/dev/null
  for kind in empty one; do
    f="$s/sets/$kind.txt"; { printf '# head %s\n# score %s\n' "$sha" "$hs"; [ $kind = one ] && printf '%s\n' "$light"; } > "$f"; chmod 0444 "$f"
    # as door.land_job runs it: its clone at $HOME/c (the Manifest and preferences beside), WT_DEPOT_DIR its home,
    # the landing's shape and profile; the set file and the costs in a directory of this run's, read-only
    rm -rf "$lhome/c"; git clone -q --no-hardlinks "$r" "$lhome/c" && git -C "$lhome/c" checkout -q --detach "$sha" &&
      git -C "$lhome/c" update-ref refs/remotes/origin/wt2 "$sha~1"; cp "$r/Manifest.toml" "$r/LocalPreferences.toml" "$lhome/c/"
    rm -rf "$lhome/tmp"; mkdir -p "$lhome/tmp"
    # the depots beneath its own, door._shared's (the layer of origin's images, the Manifest's dependency images, the
    # door's julia depot: the door's, read, whose artifacts the check profile executes; this user's ~/.julia it does
    # not, 2026-11-15 04:16Z: every shard's wasm-opt refused to spawn)
    shared=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import door; c = sys.argv[2]
files = {n: open(f"{c}/{n}").read() for n in ("Manifest.toml", "LocalPreferences.toml")}
print(door._shared(files, sys.argv[3]))' "$here/dev/climb" "$lhome/c" "$(git -C "$lhome/c" rev-parse HEAD~1)")
    (cd "$lhome/c" && landed WT_SRC_SET="$f" WT_SRC_COSTS="$s/sets/costs.tsv" WT_DEPOT_DIR="$lhome" WT_SHARED_DEPOT="$shared" \
       "$top/tools/bin/nobootstrap" /usr/bin/sandbox-exec -f "$s/landing.sb" /bin/bash dev/check.sh > "$s/check-$kind.out" 2>&1); crc=$?
    cp "$lhome/c/.wtd/ratchet.out" "$s/check-$kind.ratchet.out" 2>/dev/null   # its ratchet's own, kept past the next clone
    cp "$lhome/c/.wtd/src_tests.1.out" "$s/check-$kind.shard1.out" 2>/dev/null   # and its first shard's
    last=$(grep '^check:' "$s/check-$kind.out" | tail -1 | cut -c1-200)
    want=""; [ $kind = empty ] && { grep -q "the lander's set is empty" "$s/check-$kind.out" || want=" (no empty-set line)"
      grep -q "src shards;" "$s/check-$kind.out" || want="$want (a shard ran on an empty set)"; }
    [ $kind = one ] && { grep -q "passed in 5 shards; 5 of 5 reported" "$s/check-$kind.out" || want=" (not 5 of 5 shards reported)"; }
    # 0 green; 10 red on D14's time alone, which the lander judges (quiet at both ends) and this machine is not
    ok=0; { [ $crc = 0 ] || [ $crc = 10 ]; } && [ -z "$want" ] && ok=1
    verdicts+=("4 check.sh ($kind set${light:+, $([ $kind = one ] && echo "$light")}): $([ $ok = 1 ] && echo green || echo RED) — exit $crc$want; $last")
    [ $ok = 1 ] || red=1
  done
fi
echo "driver_evidence: ${sha:0:10}"
printf '  %s\n' "${verdicts[@]}"
# a red stage's own output, its last lines, before the scratch goes (the scratch is removed at exit)
for v in "${verdicts[@]}"; do
  case "$v" in
    *RED*) n=${v%% *}
      case $n in 1) f="$s/sweep.out";; 2) f="$s/ratchet.out";; 3) f="$s/walk.out";; *) f="";; esac
      [ -n "$f" ] && [ -f "$f" ] && { echo "--- stage $n's output, its last lines:"; grep -E '✗|❌|BROKEN|ERROR|fault|refused|RED' "$f" | tail -25; } ;;
  esac
done
for kind in empty one; do
  [ -f "$s/check-$kind.out" ] && grep -q 'RED\|fails' "$s/check-$kind.out" && { echo "--- check.sh ($kind set), its last lines:"; tail -25 "$s/check-$kind.out"
    [ -f "$s/check-$kind.ratchet.out" ] && grep -E '✗|❌|BROKEN|ERROR' "$s/check-$kind.ratchet.out" | head -25
    [ -f "$s/check-$kind.shard1.out" ] && { echo "--- its first shard's output:"; grep -E 'ERROR|Error|error' "$s/check-$kind.shard1.out" | head -5 | cut -c1-300; }; }
done
exit $red
