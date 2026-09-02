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
fail=0
for cfg in MC*.cfg; do
  [ -e "$cfg" ] || continue
  case "$cfg" in *Broken.cfg) expect=violation; tla="${cfg%Broken.cfg}.tla" ;; *) expect=ok; tla="${cfg%.cfg}.tla" ;; esac
  out=$(java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers "$WORKERS" -config "$cfg" -deadlock "$tla" 2>&1) || true
  if echo "$out" | grep -qE "Error: Invariant .* is violated|Error: Temporal properties were violated|Error: Deadlock reached"; then result=violation
  elif echo "$out" | grep -qE "Model checking completed. No error has been found"; then result=ok
  else result=error; fi
  states=$(echo "$out" | grep -oE "[0-9]+ distinct states found" | head -1)
  if [ "$result" = "$expect" ]; then printf '  ok   %-28s %-9s %s\n' "$cfg" "$result" "${states:-}"
  else printf '  FAIL %-28s got %s, expected %s\n' "$cfg" "$result" "$expect"; echo "$out" | grep -E "^Error|Invariant|violated|Exception" | head -5; fail=1; fi
done
exit $fail
