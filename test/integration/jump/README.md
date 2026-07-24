# JuMP → WasmGC capability certification

This directory owns WasmTarget's incremental JuMP/MathOptInterface capability
corpus. It is deliberately separate from Snapshot's public featured-notebook
corpus: these are compiler certification fixtures until a completed milestone is
explicitly promoted.

Every certified capability will move through the same evidence ladder:

1. native Julia is the semantic oracle;
2. raw, size-optimized, and speed-optimized Wasm must agree with native;
3. unsupported behavior must follow its explicitly declared diagnostic and
   static-fallback contract; an unexpected fallback for a claimed capability,
   a hang, or a fabricated result is a failure;
4. bounded generated cases use a recorded seed and bounds; a scalar mismatch
   identifies its exact input directly in the retained JSON artifact; later
   multi-parameter or compiler-shaped generators must add automated shrinking
   and a durable regression ledger before their own promotion;
5. a real Snapshot notebook exports without unexpected fallback and reacts
   correctly in Chromium and Firefox.

The current **MOI value/runtime prerequisites** candidate runs 76 finite
`Float64` inputs per MOI value case and 73 `Int64` inputs for the concrete
`OrderedDict` prerequisite. It does not import or execute JuMP, and therefore
does not claim that a `JuMP.Model`, JuMP macro, optimizer, or solver works.
Every input runs through native Julia, raw Wasm, `-Os`, and `-O3`; the seed,
bounds, input, and result are retained in the certification JSON. Because each
generated case has one scalar input tuple, that tuple is already the durable
minimal counterexample; promotion verifies the seed, count, and retained input
ledger. The Snapshot gate exports
`notebooks/00_moi_values.jl` both as a split static directory and as one embedded
HTML file, decodes and validates the authoritative report for both, and changes
all four prerequisite results in Chromium and Firefox. Browser evidence carries
the same clean WasmTarget SHA, Snapshot provenance, manifest digest, and report
digests as the export. The negative fixture is deliberately outside the claimed
profile: both browsers must show Snapshot's explicit static-fallback status and
must not pretend that its slider recomputes. This profile remains `candidate`
until the exact Linux, macOS, and Windows evidence matrices are green and the
promotion verifier accepts their complete input ledger; later tiers cannot
inherit the claim early.

`capabilities.toml` is the machine-readable claim surface. A green test does not
authorize a broader prose claim than the corresponding entry.

The committed environment tests the current WasmTarget checkout through
`[sources]` and pins exact JuMP and MathOptInterface versions. The runner records
the resolved manifest hash, actual package versions, platform, Node runtime,
and WasmTarget source revision in its result.

Run the current certification cases and retain the exact Wasm modules used as
evidence with:

```bash
artifact_root="$(mktemp -d)"
julia --project=test/integration/jump \
    test/integration/jump/run_certification.jl \
    "$artifact_root" \
    | tee "$artifact_root/jump-certification.json"
```

Each case runs in a fresh process group with a 150-second hard watchdog and a
120-second returned-compile threshold. The suite also has its own deadline and
bounded child output. This is required:
the first `MOI.Utilities.Model` reproducer historically stalled inside type-ID
assignment, before the Node runtime watchdog could help.
The retained `raw.wasm`, size-optimized, and speed-optimized modules are part of
the promotion authority: the cross-platform verifier checks their paths,
digests, Wasm headers, and independently validates their bytes with the pinned
`wasm-tools` release instead of trusting JSON summaries alone. It also
re-derives both optimized modules from the retained raw module, freshly
evaluates the committed native Julia canary for every retained input, and
re-executes every retained module against that oracle with the pinned Node
runtime.
Each platform therefore retains its exact module-digest ledger. Cross-platform
promotion compares the complete input/native/raw/size/speed semantic ledger,
not byte-identical module encodings; reproducible module identity is a separate
compiler property with its own fresh-process and multi-platform evidence gate.

Run the browser artifact locally with:

```bash
WT_VALIDATE=1 julia --startup-file=no --project=test/integration/jump/snapshot \
    test/integration/jump/run_snapshot_t0.jl /tmp/wt-jump-snapshot-t0

cd test/browser
npm ci
npx playwright install chromium firefox
cd ../..
julia --startup-file=no --project=test/integration/jump \
    test/integration/jump/run_browser_t0.jl /tmp/wt-jump-snapshot-t0
```

The browser gate covers both positive and deliberately unsupported notebooks as
split-directory and single-file exports in Chromium and Firefox. The positive
report must identify the exact five certified cells as full islands. The
negative report must identify the declared unsupported call and cell as an
honest static fallback in both delivery forms. Screenshots are retained as
supporting evidence; the DOM values and decoded Snapshot reports remain the
authority.

The Julia browser supervisor is part of the certification contract. It creates
an isolated process tree, applies startup and execution deadlines, bounds child
output, and terminates Node, Playwright, browsers, and their descendants on
failure. `test_browser_timeout_cleanup.jl` exercises that cleanup path with an
actual Julia → Node → child-Julia tree.
`test_snapshot_timeout_cleanup.jl` independently exercises the same
fail-closed contract for the Snapshot export supervisor.
