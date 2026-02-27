# WasmTarget.jl

<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="logo/wasm_dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="logo/wasm_light.svg">
    <img alt="WasmTarget.jl" src="logo/wasm_light.svg" height="60">
  </picture>

  **A Julia-to-WebAssembly compiler targeting WasmGC.**

  Compile real Julia functions to WebAssembly that runs in any modern browser or Node.js — no runtime, no server, no LLVM.

  Same architecture as [dart2wasm](https://dart.dev/web/wasm) (Dart's official Wasm compiler for Flutter Web).

  [![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE.md)
</div>

---

## How It Works

Julia compiles code through a 4-stage pipeline: parsing, lowering, type inference, and codegen. Normally the last stage emits native machine code via LLVM. WasmTarget replaces that last stage with a WasmGC backend — but it also does something more ambitious: it compiles each of the other three stages *themselves* to WebAssembly, so the entire pipeline can run in the browser.

### The 4-Stage Julia Compiler Pipeline

```
"1 + 1"                          ← Julia source code (a string)
   ↓
JuliaSyntax.parsestmt            ← PARSING: string → AST (Expr)
   ↓
JuliaLowering.to_lowered_expr    ← LOWERING: Expr → lowered IR
   ↓
Core.Compiler.typeinf            ← TYPE INFERENCE: IR → fully typed CodeInfo
   ↓
WasmTarget.compile               ← CODEGEN: typed IR → WasmGC bytecode
   ↓
.wasm binary                     ← runs in any browser or Node.js
```

Each of these stages is a real Julia package (`JuliaSyntax.jl`, `JuliaLowering.jl`, `Core.Compiler`). WasmTarget uses `Base.code_typed()` to get the fully type-inferred IR from stages 1-3, then translates that IR to WasmGC bytecode. No LLVM involved — Julia's typed IR maps directly to Wasm instructions.

### Build-Time vs Self-Hosting

**Build-time** (working today): Run the whole pipeline on your dev machine. Ship only the compiled `.wasm` to the browser. This is how dart2wasm powers Flutter Web — no language runtime ships to the browser.

```
Dev machine: Julia code → WasmTarget.jl → .wasm (KB to few MB)
Browser:     Just the compiled .wasm — no Julia runtime needed
```

**Self-hosting** (in progress): Compile each pipeline stage itself to Wasm using WasmTarget. Then the *entire compiler* runs in the browser — users type Julia code and it compiles + executes client-side with no server.

```
WasmTarget.compile(JuliaSyntax.parsestmt, ...)   → parsestmt.wasm  (488 funcs, 2.2MB)
WasmTarget.compile(JuliaLowering.lower, ...)     → lowering.wasm   (32 funcs, 8KB)
WasmTarget.compile(Core.Compiler.typeinf, ...)   → typeinf.wasm    (6 funcs, 5KB)
WasmTarget.compile(WasmTarget.compile, ...)      → codegen.wasm    (38 funcs, 18KB)
```

These four `.wasm` modules plus [Binaryen.js](https://github.com/WebAssembly/binaryen) (for optimization) form a complete Julia-to-Wasm compiler that runs entirely in the browser:

```
User types "1 + 1" in browser
  → parsestmt.wasm  parses it          → AST (Expr)
  → lowering.wasm   lowers it          → Lowered IR
  → typeinf.wasm    infers types       → Typed CodeInfo
  → codegen.wasm    emits bytecode     → Raw .wasm bytes
  → Binaryen.js     optimizes          → Optimized .wasm
  → WebAssembly.instantiate()          → 2
```

This is ~564 Julia functions across 4 pipeline stages compiled to correct, executable Wasm. We're methodically working through this bottom-up — auditing every IR pattern each stage needs, testing each in isolation against native Julia, and fixing the codegen until they match exactly.

### Why This Approach

This is the same architecture as [dart2wasm](https://dart.dev/web/wasm): reuse the language's existing compiler infrastructure, add a WasmGC backend. Julia's compiler does the hard work (parsing, type inference, optimization) — WasmTarget translates the result. Anything Julia's compiler can type-infer, WasmTarget can (in principle) compile. No custom parser, no subset language, no special annotations.

## Quick Start

```julia
using WasmTarget

# Any pure Julia function
function add(a::Int32, b::Int32)::Int32
    return a + b
end

# Compile to Wasm
wasm_bytes = compile(add, (Int32, Int32))
write("add.wasm", wasm_bytes)
```

```javascript
// Run in browser or Node.js
const bytes = fs.readFileSync('add.wasm');
const { instance } = await WebAssembly.instantiate(bytes);
console.log(instance.exports.add(5, 3)); // → 8
```

## What Works Today

1475+ functions validated. Verified correct against native Julia output via automated comparison harness.

| Feature | Status | Example |
|---------|--------|---------|
| Integer arithmetic (32/64/128-bit) | **Working** | `x + Int32(1)`, `a * Int64(2)` |
| Floating point (32/64-bit) | **Working** | `x * 2.0 + 1.5` |
| Comparisons and boolean logic | **Working** | `x > y`, `a && b \|\| c` |
| If/else, ternary | **Working** | `x > 0 ? x : -x` |
| While/for loops | **Working** | `while i <= n; total += i; end` |
| Structs (mutable and immutable) | **Working** | Field access, construction, `===` |
| Tuples and NamedTuples | **Working** | `(a, b, c)`, `(x=1, y=2)` |
| Arrays (Vector, Matrix) | **Working** | `push!`, `getindex`, `setindex!`, iteration |
| Strings | **Working** | Concatenation, indexing, comparison |
| Closures | **Working** | Captured variables compile to WasmGC structs |
| Try/catch/throw | **Working** | Wasm `try_table` + `throw` |
| Union{Nothing, T} | **Working** | `isa` discrimination, tagged unions |
| Multi-function modules | **Working** | Cross-function calls, multiple dispatch |
| JS interop (externref) | **Working** | Import/export, DOM manipulation |
| Wasm globals | **Working** | Mutable/immutable, exported to JS |
| Recursive types | **Working** | Self-referential structs (e.g., tree nodes) |
| Hash tables | **Working** | Int32 and String key dictionaries |

### Build-Time Compilation Use Case

WasmTarget powers [Therapy.jl](https://github.com/GroupTherapyOrg/Therapy.jl), a reactive web framework that uses Julia macros for compile-time optimization, fine-grained reactivity, and SSR with hydration. WasmTarget compiles event handlers, reactive computations, and UI logic to Wasm at build time. The framework handles the DOM layer. No Julia runtime ships to the browser — just compiled `.wasm` files.

## Self-Hosting Progress

Each pipeline stage is being audited independently: catalog every IR pattern the stage needs, test each in isolation against native Julia, fix the codegen, verify correctness. Only after all 4 stages are individually clean do we stitch them together.

| Stage | Module | Funcs | Validates | Executes | Correct | Status |
|-------|--------|-------|-----------|----------|---------|--------|
| **Parse** | parsestmt.wasm | 488 | Yes | Partial | Partial | `parse!` correct for 5 inputs; `build_tree` crashes on stub |
| **Lower** | lowering.wasm | 32 | Yes | Untested | Untested | Blocked by Parse |
| **Infer** | typeinf.wasm | 6 | Yes | Untested | Untested | Blocked by Lower |
| **Codegen** | codegen.wasm | 38 | Yes | Untested | Untested | Blocked by Infer |

**Verification levels** (we take these seriously):
- **Validates** = `wasm-tools validate` passes (structurally correct Wasm)
- **Executes** = runs in Node.js without crashing
- **Correct** = output matches native Julia exactly (verified by `compare_julia_wasm`)

We never claim something "works" at a level it hasn't been verified at. An automated comparison harness (`compare_julia_wasm`) runs every function natively in Julia and in Wasm, then checks for exact match. Ground truth snapshots persist across sessions.

### Recent Progress (Feb 2026)

The parsestmt stage has been the focus. A systematic audit found 1,133 IR patterns across 488 functions, classified as:
- 386 tested, 31 stubbed, 8 broken, 708 handled but untested

Major codegen bugs found and fixed through this process:
- `===` on immutable structs was using `ref.eq` (pointer identity) instead of field-by-field comparison
- `isa(x, T)` for function parameters (`Core.Argument`) wasn't checking `arg_types`
- PiNode references weren't counted in `count_ssa_uses!`, causing phi local duplication
- Pointer arithmetic had a double-push bug in `add_ptr`/`sub_ptr`/`pointerref`
- `jl_ptr_to_array_1d` foreigncall was missing

Current blocker: `build_tree` (Expr construction phase) hits a stubbed method (`Base._replace_`) that was excluded from auto-discovery. This is a known gap, not a mysterious crash.

## Base Julia Feasibility

We audited Julia's Base standard library to understand what WasmTarget can realistically compile. The results are more optimistic than expected.

### Will compile with current approach

These areas are **pure Julia all the way down** — no C calls, no system dependencies. Just arithmetic, comparisons, bit manipulation, and struct operations that map directly to Wasm instructions.

| Area | Evidence | Notes |
|------|----------|-------|
| **Int, Float, Complex, Rational** | 0 ccalls in IR | All arithmetic is Core.Intrinsics → Wasm opcodes |
| **sin, cos, exp, log, tan, etc.** | Pure Julia polynomials | Migrated from openlibm before Julia 1.10. ~10KB Wasm each |
| **sqrt, abs, floor, ceil, round** | LLVM intrinsics | Map directly to `f64.sqrt`, `f64.abs`, `f64.floor`, etc. |
| **Vector, Matrix, sort, map, filter** | 0 ccalls in IR | WasmGC arrays with get/set/length |
| **Broadcasting (.+, .*, etc.)** | Pure Julia | Complex control flow but no system deps |
| **Dict, Set** | 0 ccalls | Pure Julia hash table (string hashing needs small bridge) |
| **Tuple, NamedTuple** | 0 ccalls | Pure structs, resolved at compile time |
| **IOBuffer** | 0 ccalls | Pure Julia in-memory I/O |
| **Random (Xoshiro256++)** | 0 ccalls | Pure bit manipulation on UInt64 |
| **Dates (arithmetic, formatting)** | 0 ccalls | Pure Julia (except `now()` needs JS `Date.now()` bridge) |
| **Printf/@sprintf** | 0 ccalls | Format parsing is compile-time macros |
| **try/catch/throw** | Already working | Wasm `try_table` + `throw` |
| **Type system, macros, @generated** | N/A | Resolved by Julia's compiler before WasmTarget sees the IR |
| **Generic linear algebra (non-BLAS)** | 0 ccalls | Integer matmul, custom-type matmul: pure Julia |

### Needs a JS bridge (solvable)

Small, well-defined interop boundaries. Most of the string bridge is already built.

| Area | What's needed | Effort |
|------|---------------|--------|
| **String allocation** | `jl_alloc_string`, `jl_string_ptr` | Already handled |
| **print/stdout** | Write to IOBuffer, bridge to `console.log` | Small |
| **Regex** | PCRE2 ccalls → use JS `RegExp` via imports | Medium |
| **Unicode (case, category)** | utf8proc ccalls → import JS `String.toLowerCase()` etc. | Medium |
| **now()** | libc time → import JS `Date.now()` | Trivial |
| **show/repr/string()** | Only string allocation foreigncalls | Mostly done |

### Hard walls (won't compile)

These either require massive C libraries or OS-level operations that don't exist in Wasm.

| Area | Why | Impact on users |
|------|-----|-----------------|
| **BigInt / BigFloat** | 162 ccalls to GMP/MPFR C libraries | Low — rare in web apps |
| **File system** | 58 libuv ccalls, browsers have no FS | Expected |
| **Networking / sockets** | 57 libuv ccalls | Use `fetch()` via JS imports instead |
| **Tasks / Threads** | Deep runtime scheduler in C | Single-threaded Wasm; use JS async |
| **BLAS / LAPACK** | 182 ccalls to Fortran libraries | Generic Julia matmul still works, just no optimized BLAS |
| **eval / include** | Requires full Julia compiler at runtime | Rare in non-metaprogramming code |
| **Serialization** | Runtime type creation via ccalls | JSON-style via Dict+String works fine |
| **ENV / ARGS / shell commands** | OS-level operations | Not applicable in browser |
| **Finalizers / WeakRef** | GC runtime ccalls | WasmGC handles normal allocation transparently |

### Bottom line

**~70-75%** of typical Julia user code compiles straightforwardly with the current approach. Another **~15-20%** needs small JS bridges (mostly already built). Only **~5-10%** hits hard walls — and those are things that don't exist in a browser anyway.

For numeric/scientific computing and web application code, the coverage is even higher (~85-90%) since that code is predominantly arithmetic, arrays, strings, structs, and control flow.

## Roadmap

### Stage 1: Parse (M_PATTERNS) — in progress

- [x] IR audit: catalog all 1,133 patterns across 488 functions
- [x] Pattern classification: 386 tested, 31 stubbed, 8 broken, 708 untested
- [x] Comparison harness: `compare_julia_wasm` for automated correctness verification
- [x] Ground truth snapshots: persistent native Julia results for complex types
- [x] Fix `===` on immutable structs (field-by-field comparison)
- [x] Fix `isa` for Core.Argument parameters
- [x] Fix PiNode reference counting
- [x] Fix pointer arithmetic double-push
- [x] `parse!` (403 funcs) executes and produces correct output for test inputs
- [ ] Retroactive ground truth verification of all 403 parse! functions
- [ ] Fix `build_tree` stubs (`Base._replace_`, `reduce_empty`)
- [ ] Full `parsestmt(Expr, "1+1")` correct end-to-end

### Stage 2: Lower (M_LOWER) — blocked by Stage 1

- [ ] Adapt audit script for JuliaLowering entry points (32 funcs)
- [ ] Classify patterns, fix with `compare_julia_wasm`
- [ ] `lowering.wasm` correct for test inputs

### Stage 3: Type Inference (M_TYPEINF) — blocked by Stage 2

- [ ] Adapt audit script for Core.Compiler.typeinf (6 funcs)
- [ ] Classify patterns, fix
- [ ] `typeinf.wasm` correct for test inputs

### Stage 4: Codegen (M_CODEGEN) — blocked by Stage 3

- [ ] Adapt audit script for WasmTarget self-hosting (38 funcs)
- [ ] This is WasmTarget compiling *itself* — may uncover recursive/meta patterns
- [ ] `codegen.wasm` correct for test inputs

### Stage 5: Integration (M_PIPELINE) — blocked by Stage 4

- [ ] Stitch all 4 stages + Binaryen.js in browser
- [ ] `"1+1"` → parse → lower → typeinf → codegen → optimize → execute → `2`
- [ ] End-to-end in Node.js first, then browser

### Stage 6: Expand (M_EXPAND) — blocked by Stage 5

Each new expression adds exactly one dimension. Fix patterns as they surface.

- [ ] `"2+2"` (value generalization)
- [ ] `"2*3"` (new operator)
- [ ] `"x = 1"` (assignment)
- [ ] `"[1,1] + [1,1]"` (arrays)
- [ ] `"sin(pi)"` (math — pure Julia, should compile)
- [ ] `"f(x) = x^2; f(3)"` (function definition + call)

## Architecture

### Compilation Flow

```
Julia Source Code
     ↓
JuliaSyntax.parsestmt        → AST (Expr)
     ↓
JuliaLowering.to_lowered_expr  → Lowered IR
     ↓
Core.Compiler.typeinf        → Typed CodeInfo (fully type-inferred)
     ↓
WasmTarget.compile           → WasmGC bytecode (.wasm)
     ↓
Browser / Node.js            → WebAssembly.instantiate() → Running code
```

Steps 1-3 happen at compile time on the dev machine using Julia's own compiler. WasmTarget only handles step 4. For self-hosting mode, steps 1-4 are each compiled to their own `.wasm` module so the whole pipeline runs in the browser.

### Type Mappings

| Julia Type | WebAssembly Type |
|------------|------------------|
| `Int32`, `UInt32` | `i32` |
| `Int64`, `UInt64`, `Int` | `i64` |
| `Int128`, `UInt128` | `(i64, i64)` struct |
| `Float32` | `f32` |
| `Float64` | `f64` |
| `Bool` | `i32` (0 or 1) |
| `String`, `Symbol` | WasmGC `array<i32>` |
| `Nothing` | `i32` (0) |
| User structs | WasmGC struct |
| `Tuple{...}` | WasmGC struct (immutable) |
| `Vector{T}` | WasmGC `struct{array_ref, size}` |
| `Matrix{T}` | WasmGC `struct{array_ref, size_tuple}` |
| `Any` | `externref` |
| `JSValue` | `externref` |

### Project Structure

```
src/
  WasmTarget.jl              # Entry point: compile(), compile_multi()
  Builder/
    Types.jl                 # Wasm type definitions (I32, I64, RefType, etc.)
    Writer.jl                # Binary serialization to .wasm format
    Instructions.jl          # Module building, opcodes
    Validator.jl             # Stack validator (catches type errors at emit time)
  Compiler/
    IR.jl                    # Julia IR extraction via code_typed
    Codegen.jl               # IR → Wasm bytecode (~21K lines)
  Runtime/
    Intrinsics.jl            # Julia intrinsic → Wasm opcode mapping
    StringOps.jl             # String operations (recognized as intrinsics)
    ArrayOps.jl              # Array operations (recognized as intrinsics)
    SimpleDict.jl            # Hash table with Int32 keys
    ByteBuffer.jl            # I/O abstraction
scripts/
    audit_ir_patterns.jl     # Catalogs all IR patterns in a compilation target
    classify_patterns.jl     # Classifies patterns: tested/untested/stubbed/broken
test/
    runtests.jl              # 325 tests across 31 phases
    utils.jl                 # compare_julia_wasm, ground truth snapshots, Node.js harness
```

## Comparison with Other Approaches

### Julia-to-Wasm Compilers

| | WasmTarget.jl | WebAssemblyCompiler.jl | Charlotte.jl |
|---|---|---|---|
| **Memory model** | WasmGC (GC structs/arrays) | WasmGC via Binaryen | Linear memory |
| **IR source** | `Base.code_typed` (typed) | `Base.code_typed` | Custom |
| **Loops** | Working | Working | N/A |
| **Closures** | Working | No | No |
| **Try/catch** | Working | No | No |
| **Union types** | Working | No | No |
| **Self-hosting goal** | Yes (in progress) | No | No |
| **Status** | Active (Feb 2026) | Experimental (2023) | Archived |

### dart2wasm (architectural model)

WasmTarget follows the same design as dart2wasm — reuse the language's existing compiler for parsing/type inference, add a WasmGC backend:

| | dart2wasm | WasmTarget.jl |
|---|---|---|
| **Language** | Dart | Julia |
| **Frontend** | Dart CFE | Julia's compiler |
| **IR** | Kernel IR | Typed CodeInfo |
| **Backend** | → WasmGC | → WasmGC |
| **Runtime** | `.mjs` companion | JS imports/exports |
| **Production use** | Flutter Web | In development |

## Requirements

- Julia 1.12+ (required for JuliaSyntax v2 and type inference features)
- Node.js 22+ for testing (WasmGC support required)
- `wasm-tools` for validation (`cargo install wasm-tools`)

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/GroupTherapyOrg/WasmTarget.jl")
```

## Testing

```bash
# Full test suite (325 tests)
julia +1.12 --project=. test/runtests.jl

# Quick verification
julia +1.12 --project=. -e '
  using WasmTarget
  f(x::Int32)::Int32 = x + Int32(1)
  bytes = compile(f, (Int32,))
  write("/tmp/test.wasm", bytes)
  run(`wasm-tools validate --features=gc /tmp/test.wasm`)
  println("PASS")
'

# Comparison testing (verify Wasm matches native Julia)
julia +1.12 --project=. -e '
  using WasmTarget; include("test/utils.jl")
  r = compare_julia_wasm(x -> x + Int32(1), Int32(5))
  println(r.pass ? "CORRECT" : "MISMATCH: expected=$(r.expected) actual=$(r.actual)")
'
```

## License

Apache License 2.0 — see [LICENSE.md](LICENSE.md)
