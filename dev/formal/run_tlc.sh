#!/usr/bin/env bash
# Run every TLA+ model-checking instance under dev/formal with TLC.
#
# Each model is a pair: <Name>.tla (the model) and MC<Name>.tla + MC<Name>.cfg (the checked
# instance with concrete constants and its INVARIANT/PROPERTY list). A model may also ship
# MC<Name>Broken.cfg — an instance that deliberately violates the claim; TLC MUST report a
# violation for it, or the model is vacuous (the same discipline as the ratchet's negative
# tests). Exit 1 on any unexpected result.
set -euo pipefail
cd "$(dirname "$0")"
JAR="${TLA2TOOLS_JAR:-$HOME/.cache/wasmtarget/tla2tools.jar}"
if [ ! -f "$JAR" ]; then
  mkdir -p "$(dirname "$JAR")"
  curl -sSL -o "$JAR" https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar
fi
WORKERS="${TLC_WORKERS:-auto}"
# TLC_FAST=1 skips the instances listed in DEEP (each explores >10^6 states, ~20-60 s):
# the inner loop (dev/lanes.sh) runs the rest in ~30 s; CI and `bash run_tlc.sh` run all.
DEEP="${TLC_DEEP:-MCClassIdDispatchCascade.cfg MCClassIdDispatchCascadeBroken.cfg MCClassIdDispatchTotal.cfg MCClassIdDispatchTotalBroken.cfg}"
fail=0
for cfg in MC*.cfg; do
  [ -e "$cfg" ] || continue
  if [ "${TLC_FAST:-0}" = "1" ] && [[ " $DEEP " == *" $cfg "* ]]; then printf '  skip %-28s (deep; run without TLC_FAST)\n' "$cfg"; continue; fi
  # MC<Name>[Variant]Broken.cfg checks MC<Name>[Variant].tla when that module exists (a
  # variant with its own constants), else the model's MC<Name>.tla (a variant that only
  # flips a CONSTANT flag of the same instance).
  case "$cfg" in *Broken.cfg) expect=violation; tla="${cfg%Broken.cfg}.tla" ;; *) expect=ok; tla="${cfg%.cfg}.tla" ;; esac
  if [ ! -e "$tla" ] && [ "$expect" = violation ]; then
    base=$(ls MC*.tla | sed 's/\.tla$//' | awk -v c="${cfg%Broken.cfg}" 'index(c, $0) == 1 { print length($0), $0 }' | sort -rn | head -1 | cut -d" " -f2)
    [ -n "$base" ] && tla="$base.tla"
  fi
  if [ ! -e "$tla" ]; then printf '  FAIL %-28s no instance module %s\n' "$cfg" "$tla"; fail=1; continue; fi
  out=$(java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers "$WORKERS" -config "$cfg" -deadlock "$tla" 2>&1) || true
  # Classified with shell pattern matches, not `echo | grep -q`: under pipefail a
  # multi-megabyte counterexample trace makes `echo` die of SIGPIPE when grep -q
  # exits early, which misreported a real violation as "error" (found on Coercion).
  if [[ "$out" == *"Error: Invariant "*" is violated"* || "$out" == *"Error: Temporal properties were violated"* || "$out" == *"Error: Deadlock reached"* ]]; then result=violation
  elif [[ "$out" == *"Model checking completed. No error has been found"* ]]; then result=ok
  else result=error; fi
  # the LAST count is the final one (TLC prints progress counts on long runs); `|| true`
  # keeps a parse error (no count at all) on the FAIL path instead of aborting under set -e
  states=$(grep -oE "[0-9]+ distinct states found" <<< "$out" | tail -1 || true)
  if [ "$result" = "$expect" ]; then printf '  ok   %-28s %-9s %s\n' "$cfg" "$result" "${states:-}"
  else printf '  FAIL %-28s got %s, expected %s\n' "$cfg" "$result" "$expect"; echo "$out" | grep -E "^Error|Invariant|violated|Exception" | head -5; fail=1; fi
done
exit $fail
