#!/usr/bin/env bash
# loop_guard.sh — mechanical anti-reward-hacking scan for the WasmTarget /loop.
#
# The autonomous soundness loop (see test/fuzz/LOOP.md §3) must fix codegen
# GENUINELY, never cheat the differential oracle. This scans the working diff for
# the known cheat patterns and exits non-zero (forcing human review) if any appear.
# False positives are fine — they just demand a human glance, which is the point.
#
# Usage:  test/fuzz/loop_guard.sh [base-ref]      (default base: HEAD)
# Exit 0 = clean · Exit 1 = suspicious diff (STOP, human review) · Exit 2 = setup error
set -uo pipefail

base="${1:-HEAD}"
root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "loop_guard: not in a git repo"; exit 2; }
cd "$root" || exit 2

# Diff over the source + the frozen oracle/generator surface.
watch_paths=(src/ test/fuzz/property.jl test/fuzz/generators.jl test/fuzz/statements.jl test/fuzz/catalogue.jl src/codegen/diagnostics.jl)
diff="$(git diff "$base" -- "${watch_paths[@]}" 2>/dev/null)"
added="$(printf '%s\n' "$diff" | grep -E '^\+' | grep -vE '^\+\+\+' || true)"

flagged=0
report() { printf 'GUARD  ✗ %s\n' "$1"; flagged=1; }

# 0. Frozen oracle policy: tolerances are hash-pinned so the loop can't widen them
#    to bury a divergence. Any change must be a deliberate human re-pin.
pol="test/fuzz/oracle_policy.jl"; polsha="test/fuzz/oracle_policy.jl.sha256"
if [ -f "$pol" ] && [ -f "$polsha" ]; then
  want="$(tr -d '[:space:]' < "$polsha")"
  got="$(shasum -a 256 "$pol" | awk '{print $1}')"
  [ "$want" = "$got" ] || report "oracle_policy.jl changed (sha $got != pinned $want) — tolerances are FROZEN; re-pin deliberately"
fi

# 1. Oracle bypass.
printf '%s\n' "$added" | grep -nqE 'strict[[:space:]]*=[[:space:]]*false' \
  && report "introduces strict=false — bypasses the soundness gate"

# 2. Wrong-value mask. Adding a :value_stub is the cardinal cheat (legitimate ONLY when
#    CLOSING the downgrade hole, G1 — flag it regardless so a human confirms intent).
printf '%s\n' "$added" | grep -nqE ':value_stub' \
  && report "adds a :value_stub (wrong-value mask) — only legitimate for G1; confirm"

# 3. Unreachable used as a fix (sound for value semantics, NOT a catchable-throw equiv).
printf '%s\n' "$added" | grep -nqE '\bUNREACHABLE\b|emit_unreachable|unreachable!\(' \
  && report "adds an unreachable emission — confirm it is sound, not a value/trap mask"

# 4. Oracle tamper: any touch to match/tolerance/sampling in property.jl.
if git diff --name-only "$base" -- test/fuzz/property.jl 2>/dev/null | grep -q .; then
  printf '%s\n' "$diff" | grep -nqE 'rtol|atol|vals_match|tree_matches|sample_inputs|vector_inputs' \
    && report "edits oracle tolerance / match / sampling in property.jl"
fi

# 5. Generator tamper: changing the input/literal surface to dodge a gap.
if git diff --name-only "$base" -- test/fuzz/generators.jl test/fuzz/statements.jl test/fuzz/catalogue.jl 2>/dev/null | grep -q .; then
  report "edits the generator (allowed ONLY for deliberate tier expansion — never to dodge a gap)"
fi

# 6. Strict-mode fatality table.
printf '%s\n' "$added" | grep -nqE 'soundness_fatal|TRIM_ENTRY_NAMES|_fatal[[:space:]]*=[[:space:]]*false' \
  && report "touches the strict-mode fatality logic in diagnostics.jl — confirm (G1?)"

# 7. Test deletion/skip as a "fix".
printf '%s\n' "$added" | grep -nqE '@test_skip|@test_broken' \
  && report "adds @test_skip/@test_broken — not a fix"

if [ "$flagged" -eq 1 ]; then
  echo "loop_guard: SUSPICIOUS DIFF — stop and get human review before committing."
  exit 1
fi
echo "loop_guard: clean."
exit 0
