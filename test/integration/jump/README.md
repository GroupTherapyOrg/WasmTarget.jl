# JuMP → WasmGC certification

This directory owns WasmTarget's incremental JuMP/MathOptInterface capability
corpus. It is deliberately separate from Snapshot's public featured-notebook
corpus: these are compiler certification fixtures until a completed milestone is
explicitly promoted.

Every certified capability will move through the same evidence ladder:

1. native Julia is the semantic oracle;
2. raw, size-optimized, and speed-optimized Wasm must agree with native;
3. unsupported behavior must reject clearly rather than hang, fall back, or
   fabricate a result;
4. bounded generated cases are retained and shrunk through the existing fuzz
   ledger;
5. a real Snapshot notebook exports without unexpected fallback and reacts
   correctly in Chromium and Firefox.

The current foundation implements the native/raw/size/speed gate for the
candidate T0 canaries. Fuzz-ledger and browser-backed Snapshot gates are
required before T0 is promoted from `candidate` to `certified`; later tiers
cannot inherit those claims early.

`capabilities.toml` is the machine-readable claim surface. A green test does not
authorize a broader prose claim than the corresponding entry.

The committed environment tests the current WasmTarget checkout through
`[sources]` and pins exact JuMP and MathOptInterface versions. The runner records
the resolved manifest hash, actual package versions, platform, Node runtime,
and WasmTarget source revision in its result.

Run the current certification cases with:

```julia
julia --project=test/integration/jump \
    test/integration/jump/run_certification.jl
```

Each case runs in a fresh process group with a 150-second hard watchdog and a
120-second returned-compile threshold. The suite also has its own deadline and
bounded child output. This is required:
the first `MOI.Utilities.Model` reproducer historically stalled inside type-ID
assignment, before the Node runtime watchdog could help.
