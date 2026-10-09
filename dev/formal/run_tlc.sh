#!/usr/bin/env bash
# Run every TLA+ model-checking instance under dev/formal with TLC.
#
# Each model is a pair: <Name>.tla (the model) and MC<Name>.tla + MC<Name>.cfg (the checked
# instance with concrete constants and its INVARIANT/PROPERTY list). A model may also ship
# MC<Name>Broken.cfg — an instance that deliberately violates the claim; TLC MUST report a
# violation for it, or the model is vacuous (the same discipline as the ratchet's negative
# tests). A Broken cfg's first line names the claim it violates, `\* expect: <Name>`: an
# INVARIANT of the cfg, a PROPERTY of it (TLC's temporal form names none), or Deadlock. It
# passes only when TLC reports that violation; a violation of any other claim (TypeOK
# included) fails, and so does a Broken cfg with no expect line. TypeOK is never an expect
# line: a Broken instance must break a claim, not the type invariant. TLC checks deadlock
# unless a cfg says CHECK_DEADLOCK FALSE (there is no `-deadlock` flag, which switches the
# check off for every cfg and ignores the cfg's entry): a model whose run ends gives its
# terminal states an explicit stutter. Exit 1 on any unexpected result.
set -euo pipefail
cd "$(dirname "$0")"
JAR="${TLA2TOOLS_JAR:-$HOME/.cache/wasmtarget/tla2tools.jar}"
if [ ! -f "$JAR" ]; then
  mkdir -p "$(dirname "$JAR")"
  curl -sSL -o "$JAR" https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar
fi
WORKERS="${TLC_WORKERS:-auto}"
# TLC_FAST=1 skips the instances listed in DEEP (each takes ~20-60 s):
# the inner loop (dev/lanes.sh) runs the rest in ~30 s; CI and `bash run_tlc.sh` run all.
DEEP="${TLC_DEEP:-MCClassIdDispatchCascade.cfg MCClassIdDispatchCascadeBroken.cfg MCClassIdDispatchTotal.cfg MCClassIdDispatchTotalBroken.cfg MCProvenDead.cfg MCStoragePointer.cfg MCDefiniteInit.cfg}"
fail=0
# Each instance gets its own TLC metadir: TLC names its default one after the current second,
# and two instances started within one second collided ("TLC writes its files to a directory
# whose name is generated from the current time", MCSidecar/MCSidecarBroken on CI).
meta=$(mktemp -d "${TMPDIR:-/tmp}/wt-tlc.XXXXXX")
trap 'rm -rf "$meta"' EXIT
# TLC_NIGHTLY=1 (the scheduled formal.yml job, 5-hour budget) also runs dev/formal/nightly/:
# instances too large for the 20-minute gate — same naming rules, checked against the
# models one directory up.
cfgs=(MC*.cfg)
[ "${TLC_NIGHTLY:-0}" = "1" ] && [ -d nightly ] && cfgs+=(nightly/MC*.cfg)
# TLC_SHARD=i/N (formal.yml's push matrix) checks every N-th instance from the i-th, i in 0..N-1,
# of the same sorted list: the N shards together check every instance exactly once.
if [ -n "${TLC_SHARD:-}" ]; then
  si=${TLC_SHARD%/*}; sn=${TLC_SHARD#*/}
  if ! [[ $si =~ ^[0-9]+$ && $sn =~ ^[1-9][0-9]*$ ]] || [ "$si" -ge "$sn" ]; then
    echo "TLC_SHARD=$TLC_SHARD: expected i/N with 0 <= i < N" >&2; exit 1
  fi
  shard=()
  for k in "${!cfgs[@]}"; do [ $((k % sn)) -eq "$si" ] && shard+=("${cfgs[$k]}"); done
  cfgs=("${shard[@]}")
  echo "  shard $si of $sn: ${#cfgs[@]} instances"
fi
for cfg in "${cfgs[@]}"; do
  [ -e "$cfg" ] || continue
  if [ "${TLC_FAST:-0}" = "1" ] && [[ " $DEEP " == *" $cfg "* ]]; then printf '  skip %-28s (deep; run without TLC_FAST)\n' "$cfg"; continue; fi
  # MC<Name>[Variant]Broken.cfg checks MC<Name>[Variant].tla when that module exists (a
  # variant with its own constants), else the model's MC<Name>.tla (a variant that only
  # flips a CONSTANT flag of the same instance).
  case "$cfg" in *Broken.cfg) expect=violation; tla="${cfg%Broken.cfg}.tla" ;; *) expect=ok; tla="${cfg%.cfg}.tla" ;; esac
  tla="${tla#nightly/}"   # a nightly instance checks the model's own MC module
  if [ ! -e "$tla" ] && [ "$expect" = violation ]; then
    base=$(ls MC*.tla | sed 's/\.tla$//' | awk -v c="${cfg%Broken.cfg}" 'index(c, $0) == 1 { print length($0), $0 }' | sort -rn | head -1 | cut -d" " -f2)
    [ -n "$base" ] && tla="$base.tla"
  fi
  if [ ! -e "$tla" ]; then printf '  FAIL %-28s no instance module %s\n' "$cfg" "$tla"; fail=1; continue; fi
  if [ "$expect" = violation ]; then
    want=$(head -1 "$cfg" | sed -n 's/^\\\* expect: \([A-Za-z0-9_]*\)[[:space:]]*$/\1/p')
    if [ -z "$want" ]; then printf '  FAIL %-28s no first line "\\* expect: <Name>"\n' "$cfg"; fail=1; continue; fi
    # a Broken instance breaks a claim; violating only the type invariant is a malformed model
    if [ "$want" = TypeOK ]; then printf '  FAIL %-28s expects TypeOK: a Broken cfg must break a claim, not the type invariant\n' "$cfg"; fail=1; continue; fi
    # the kind of claim it names: an INVARIANT or a PROPERTY the cfg lists (one per line
    # or under INVARIANTS/PROPERTIES), or Deadlock
    kind=$(awk -v w="$want" '/^[[:space:]]*\\\*/ { next }
      /^[A-Z_]+/ { sec = $1; $1 = "" } { for (i = 1; i <= NF; i++) if ($i == w) {
        if (sec ~ /^INVARIANTS?$/) k = "invariant"; else if (sec ~ /^PROPERT(Y|IES)$/) k = "temporal" } }
      END { print (w == "Deadlock" ? "Deadlock" : k) }' "$cfg")
    if [ -z "$kind" ]; then printf '  FAIL %-28s expects %s, which the cfg does not check\n' "$cfg" "$want"; fail=1; continue; fi
  fi
  # A Broken cfg runs on one worker: TLC's breadth-first search is then deterministic, so
  # the first violation it reports, the one its expect line names, is the same on every
  # run and machine (MCConstantsSkipChildBroken reported NoPartialIntern on two workers
  # and MutableNeverAliases on one and on `auto`).
  w="$WORKERS"; [ "$expect" = violation ] && w=1
  out=$(java -XX:+UseParallelGC -cp "$JAR" tlc2.TLC -workers "$w" -metadir "$meta/${cfg//\//_}" -config "$cfg" "$tla" 2>&1) || true
  # Classified with shell pattern matches, not `echo | grep -q`: under pipefail a
  # multi-megabyte counterexample trace makes `echo` die of SIGPIPE when grep -q
  # exits early, which misreported a real violation as "error" (found on Coercion).
  # a violation is named by the claim TLC reports: the invariant, "temporal" (TLC's
  # temporal form names no property), or Deadlock
  if [[ $out =~ Error:\ Invariant\ ([A-Za-z0-9_]+)\ is\ violated ]]; then result=violation; got=${BASH_REMATCH[1]}
  elif [[ "$out" == *"Error: Temporal properties were violated"* ]]; then result=violation; got=temporal
  elif [[ "$out" == *"Error: Deadlock reached"* ]]; then result=violation; got=Deadlock
  elif [[ "$out" == *"Model checking completed. No error has been found"* ]]; then result=ok
  else result=error; fi
  # a Broken cfg passes only on its own claim: the invariant by name, else the form
  if [ "$expect" = violation ]; then
    expect="violation of $want"
    if [ "$result" = violation ]; then
      if [ "$kind" = invariant ]; then [ "$got" = "$want" ] && got_claim=$want || got_claim=$got
      else [ "$got" = "$kind" ] && got_claim=$want || got_claim=$got; fi
      result="violation of $got_claim"
    fi
  fi
  # the LAST count is the final one (TLC prints progress counts on long runs); `|| true`
  # keeps a parse error (no count at all) on the FAIL path instead of aborting under set -e
  states=$(grep -oE "[0-9]+ distinct states found" <<< "$out" | tail -1 || true)
  if [ "$result" = "$expect" ]; then printf '  ok   %-28s %-9s %s\n' "$cfg" "$result" "${states:-}"
  else printf '  FAIL %-28s got %s, expected %s\n' "$cfg" "$result" "$expect"; echo "$out" | grep -E "^Error|Invariant|violated|Exception" | head -5; fail=1; fi
done
exit $fail
