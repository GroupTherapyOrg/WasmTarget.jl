# MARCH 6 — exceptions (execution plan; census in PARITY_MASTER §MARCH 6)

ORDER (the march-3 lesson: interiors before channel inversions):
ONE lowering FIRST (shrinks catch surface 13→~2 sites), THEN the typed tag once, then finally.

## Slice A — unify the stackifier's label bookkeeping (byte-identical intent)
open_blocks::Vector{Int} + open_loops::Vector{Int} + the positional-math depth helpers
(stackified.jl:425-475) → ONE emission-ordered label_stack::Vector{Tuple{Symbol,Int}}
((:block,target)|(:loop,header)), depth = reverse-scan position. This is dart's one-label-
stack shape AND the prerequisite for a third kind (:try/:landing). NOTE the old math embeds
ordering assumptions (inner_loop_count correction) — where it disagrees with true emission
order, the OLD math is the suspect (cf. the multi-back-edge bug); the gate arbitrates.
Sites: init 425/428, helpers 437-475, pushes 1015/1024(+append)/983, pops 991/1414,
loop-close filter 1399-1407, _exit_depth 981, all get_*_depth callers.

## Slice B — try regions native in the stackifier
Region detection (EnterNode → TryRegion) in the analysis steps; at the enter block:
push (:landing,r)+(:try,r), emit block+try_table(catch_all→0); normal exit (leave/
catch_dest boundary): end try_table, br past handler (depth via the ONE stack), end
landing; handler blocks compile as PLAIN CFG blocks (the stackifier's phi machinery
already handles handler-edge phis — that's the whole point). Route: single-region
non-nested shapes first via flow.jl, drivers as fallback. Gate hard per shape class.

## Slice C — nesting + route ALL; delete the 13 drivers + the 643-LOC selector (R12→1).
## Slice D — the typed tag: FuncType([anyref-exn, stackTrace],[]); throw sites push
payload (13 sites, census list); catch binds via catch_clause + local_set; $current_exn
+ :the_exception die (R13→0; keep catch_all ONLY as the host-exception outer guard).
## Slice E — try/finally lowering (dart visitTryFinally finalizer-duplication) + the
compile.jl:1716 anomaly + full gate via dev/run_full_gate.sh.


## GATE CADENCE (Dale, 2026-07-05 — testing had ballooned to ~80% of wall-clock):
Inner loop = smoke + touched-subsystem battery ONLY (~1 min). Per commit = smoke +
ratchet, commit, ONE heavy shard IN THE BACKGROUND while dev continues (red ⇒ revert).
Full gate + fuzz = ONCE per march at PR time, detached behind dev/run_full_gate.sh.
NOTHING blocks the foreground >2 min. Env-gated changes need NO default-path shards.

## SLICE E VERDICT (2026-07-05): try/finally lowering = DIVERGENT-JUSTIFIED.
Julia's FRONT-END inlines finalizers on every exit path at lowering time — the typed
IR has NO runtime finally construct (dart lowers TryFinally itself because Kernel
carries the node). WT sees only the already-duplicated paths, which the ONE lowering
handles as plain CFG. The D9.4 differential battery (8 arms incl. the fixed f_fin4)
is the permanent guard. Recorded as a documented ceiling item, not a gap.


## MARCH 7 STATE (pipelined; see memory): funnel + 6 arms + Symbol interning +
content-addressed segments DONE. REMAINING (next session/slice): the literal
pre-pass + LAZY constants (init-fns before the compile.jl:1641 index freeze —
the one big M7 piece) · boxed-scalar dedup (dart 361-376, needs expectedType
at the scalar arms = post-march-8 material). R14/R15 prose revised to the
honest mutable floor.

## MARCH-13 CHAIN STATE (the two-arg megamorphic bug, links verified forward):
1-3 ✓ (discovery cliff / export dedup / forwarder gate — committed 0a05dd3).
4 ✓ safe (intrinsic-binop rebox when the SSA local is ref-typed — keyed on the REAL
local type). NEXT LINK (the failing store at 0x981): the value flows through the PHI
machinery — compile_phi_value / set_phi_locals_for_edge! re-emits the add at the edge
and its store-convert re-guesses (Any→anyref ≡ anyref) while raw i64 sits on the stack.
THE FIX = the phi-store funnel reads the RE-EMISSION's tracked type (the _pv_vb
builder's stack top — it already exists at flow.jl's emit_phi_local_set! path!) instead
of get_phi_edge_wasm_type's guess. THEN link 6: the phi-INIT null (t=0 entry edge).
GATING LAW: exit codes only.
