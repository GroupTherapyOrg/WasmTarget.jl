# F3 — mutable closure capture (`Core.Box`): dart2wasm-aligned sub-loop

Part of the dart2wasm production-parity mission (branch `wt-dart2wasm-parity`). This is a
**multi-loop task**, run as a proper incremental loop — **NOT try/discard**. Each loop lands a
**committed, GREEN, non-breaking** step; the infrastructure PERSISTS and the behavior change
comes last, on a foundation that's already in place and tested.

## Goal
A closure that MUTATES a captured variable (`c=0; f=()->(c+=1); …; c`) compiles to FAITHFUL
wasm. Today it emits invalid wasm (`expected anyref, found i64`). The fix is dart2wasm's, not
Julia's: **go beyond Julia's lossy `Core.Box{contents::Any}` reification and type the cell
CONCRETELY** (`i64` for an int), exactly like dart2wasm's context fields
(`closures.dart:1102-1115`, `translateTypeOfLocalVariable`). See [[wt-f3-mutable-capture-dart2wasm]].

## Oracle & verification
- **HOW oracle:** dart2wasm `ClosureLayouter` — a captured variable is a TYPED field in a shared
  heap context struct (not a boxed top); only MUTATED captures (`Capture.written`) go in it.
- **Verification (every behavior-changing loop):** the FULL adversarial differential set (below)
  native-vs-wasm + `Pkg.test()` + migration byte-identity. **Independent adversarial re-verify is
  MANDATORY** — the agent's narrow backfill AND the full suite both passed while a prior attempt
  was silently wrong (the suite has blind spots; it also missed the fold + sort silent-wrongs).

## Root cause (why prior patches failed)
`c+=1` = `setfield!(box,:contents, getfield(box,:contents)+1)`. `getfield`→anyref; `+` unboxes →
`i64.add` → i64, but Julia INFERS the result `Any`. WT loses the actual-i64 fact through the
dynamic-`+`→setfield chain (the `compile_value` untyped-bytes **type-channel gap, ledger B1**) →
setfield boxes by the inferred type (Any → "don't box") → stores raw i64 into the anyref field.
Approach A (typed contents) SIDESTEPS B1 entirely: the field is i64, the value is i64, no boxing.

## The loops (each committed green, non-breaking until L2)
- **L0 — contents-type inference (additive, byte-identical, UNIT-tested).** A pure analysis
  `box_contents_type(code, box_ssa)` that returns the concrete Julia type a `Core.Box` holds, read
  off its `setfield!(box,:contents,v)` value type(s) in the IR (consistent ⇒ that type; else
  `nothing` = dynamic). NOT wired into codegen → byte-identical. Unit tests assert it returns
  `Int64`/`Float64`/`nothing` on counter/accum/heterogeneous IR. Commit.
- **L1 — specialized box registry (additive, dormant).** `registry.boxes::Dict{Type,BoxInfo}` +
  `get_box_type!(mod,reg,contents_type)` → a struct `{typeId:i32, contents:(mut <wasm of contents>)}`
  keyed by `contents_type` (NOT `registry.structs[Core.Box]` — that's one-type-per-Julia-type and
  would collide). No call sites yet → byte-identical. Unit-test the struct shape. Commit.
- **L2 — specialize the live sites (FIRST behavior change, hard-gated).** IMPLEMENTATION-READY MECHANISM
  (refined 2026-06-29 after the L2 investigation):
  - **KEY FINDING:** Julia ERASES the type — `c+=1` is a dynamic `Any + 1 :: Any` in the IR (no
    `add_int`), so you CANNOT verify the contents type from inference (a wrong turn — the L2a
    type-verification attempt was reverted). BUT WT already does `struct.get → i64; i64.const 1` — it
    computes reads + arithmetic at the OPERAND's real width; the ONLY failure is storing that i64 into
    the `Any` contents field. So: **type the contents field `i64` from the one reliable signal — the
    enclosing init (`c=0`→Int64, which `box_contents_type` gives) — and WT's existing typed arithmetic
    + the i64→i64 store just work.** No closure-body verification needed.
  - **4 sites, all → `get_box_type!(contents_wasm)` (same struct, keyed by contents wasm in box_types):**
    (1) `%new(Core.Box)` (compile_new, statements.jl:1632) → struct.new of get_box_type!(box_contents_type
    of THIS box in the enclosing IR). (2) setfield!(box,:contents,v) + (3) getfield(box,:contents)
    (calls.jl) → read the contents type OFF the box's now-typed struct (field 1) → plain struct.set/get,
    no box/unbox. (4) closure captured-box FIELD (`register_closure_type!`, structs.jl:121) — the ONLY
    site that can't see the contents type locally (only `Core.Box`).
  - **Cross-function glue (only for site 4):** a side-table `registry.box_contents_types::Dict{Type,
    WasmValType}` (closure_T → box-field contents wasm), POPULATED by a pre-pass over the enclosing fn's
    IR at compile-start (scan %new(Core.Box)+setfield init → box_contents_type; map the closure capturing
    it). register_closure_type! consults it (Core.Box field + entry present → get_box_type!(wasm); else
    anyref FALLBACK = current behavior, no regression). Natural compile order (entry before its closure
    body) keeps it populated before the closure struct is registered.
  - Gate: **counter** green first, then accumulator, then full `Pkg.test()` + migration byte-identity.
    Independent adversarial re-verify. Commit.
- **L3 — edge cases.** float accumulator, conditional mutation (`iseven(i)&&(c+=i)`), read-after,
  two-closures-SHARING-one-box, escaping closure (returned), return-unbox/narrowing; anyref-box
  FALLBACK for genuinely-dynamic contents (`box_contents_type`→nothing). Gate full adversarial set.
- **L4 — lock.** Restore `test/f3_mutable_capture_backfills.jl` (CI-wired shard 0) covering the full
  set; full suite green. Mark F3 done.

## Discipline
Commit GREEN each loop / never revert the whole effort (fix forward within a loop). Root-fix at the
emit site. Run `Pkg.test` not `runtests.jl`; background suites with no inner `&`; never edit src/
while a suite runs. After each behavior-changing loop, run the FULL adversarial set independently.

## Adversarial set (the L3/L4 gate — `::Int64`/`::Float64` return narrowing so values marshal)
counter (loop) · accumulator (`s+=i`) · two-closures-SHARING-one-box (`inc;dec` share `c`) ·
conditional (`iseven(i)&&(c+=i)` — was silently 0) · read-after-mutate (`f();f();c`) · float
accumulator (`s+=1.5`) · escaping (returned closure called outside) · return-the-capture. Every
mutation MUST propagate (capture-by-value silently dropping it is the #1 trap).
