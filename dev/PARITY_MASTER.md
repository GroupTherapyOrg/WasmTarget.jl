# The dart2wasm oracle and WasmTarget's scope

What counts as done is `dev/CHARTER.md`; the open work is `dev/MARCH.md`; the measured state
is the output of `julia --project=. test/parity_ratchet.jl`. This file holds the two facts
those rely on and do not restate: which dart2wasm is the oracle, and where WasmTarget's
supported surface ends.

## The oracle pin

dart-lang/sdk **`898a1e4bbfbc472dc0a9505dc7d2e4c21d6f856e`** — the compiler in
`pkg/dart2wasm/lib/`, the builder in `pkg/wasm_builder/lib/src/`
(<https://github.com/dart-lang/sdk/tree/898a1e4bbfbc472dc0a9505dc7d2e4c21d6f856e/pkg/dart2wasm>).
Every `@parity "<file>.dart:<line> <Symbol>"` anchor in `src/` cites a line at this commit, and
`AGENTS.md` pins the same hash (L128 compares the two). Moving the pin re-audits every anchor.

dart2wasm is a structural oracle, not a feature checklist: Julia and Dart have different
semantics, so a dart-shaped implementation is accepted only when native Julia agrees on
behavior, and anything Julia does not force stays out.

## The second oracle: LLVM's WebAssembly stackifier

dart2wasm has no counterpart for structuring control flow, since Kernel is already structured;
Julia's IR is a flat CFG of basic blocks. Where dart provides no port, the port comes from Julia's
compiler and a production compiler of another language (dev/LEDGER.md D42), never an invented
algorithm: llvm/llvm-project **`7a941dfb2877a0b8cf30323fefa85ad019e0b0f5`** (llvmorg-23.1.4),
the WebAssembly backend behind Rust, C, C++ and C#'s NativeAOT-LLVM:
`llvm/lib/Target/WebAssembly/WebAssemblyFixIrreducibleControlFlow.cpp`,
`WebAssemblyCFGSort.cpp` and `WebAssemblyCFGStackify.cpp`, with the loop and dominator headers they
cite (<https://github.com/llvm/llvm-project/tree/7a941dfb2877a0b8cf30323fefa85ad019e0b0f5/llvm/lib/Target/WebAssembly>).
`dev/fetch_llvm.sh` makes the sparse checkout at `~/.cache/wasmtarget/llvm-project`. The inputs are
Julia's own (D3): Core.Compiler's CFG and dominator tree stand where LLVM reads its
MachineFunction's blocks and MachineDominatorTree. The formal statement the model checks against is
Norman Ramsey, "Beyond Relooper: recursive translation of unstructured control flow to structured
control flow", ICFP 2022 (GHC's wasm backend, `GHC.Wasm.ControlFlow.FromCmm`).

## Scope

A reachable construct outside the supported surface rejects loudly and located
(`record_unsupported!`); an exclusion never permits a stub that returns a value.

- **One frozen, closed-world module.** Reflection, `eval`, world-age mutation and runtime
  method definition are not part of it; neither are async, tasks, threads, atomics or
  deferred loading. Dynamic dispatch covers the targets the closed world collects.
- **Native and host capabilities.** Arbitrary `ccall`, `dlopen`, `Ptr`-based libraries,
  BLAS/LAPACK/SuiteSparse binaries, the filesystem, sockets, host entropy and time do not
  become browser-safe because their Julia call sites are visible. Each needs an explicit host
  import, a pure-Julia overlay, or a separately built linear-memory sidecar module
  (its ownership protocol modeled in `dev/formal/Sidecar.tla`). Existing
  host JLL artifacts cannot be loaded by a browser.
- **Evidence.** The differential corpus proves the signatures and compositions it tests, not
  all of Julia; package support is established by end-to-end differential cases through
  ordinary package APIs.
