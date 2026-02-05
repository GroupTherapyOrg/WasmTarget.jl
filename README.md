# WasmTarget.jl

<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="logo/wasm_dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="logo/wasm_light.svg">
    <img alt="Therapy.jl" src="logo/logo_light.svg" height="60">
  </picture>
</div>

A Julia-to-WebAssembly compiler targeting the WasmGC (Garbage Collection) proposal. WasmTarget compiles Julia functions directly to WebAssembly binaries that run in modern browsers and Node.js with WasmGC support.

## What Works Today (Tier 1)

WasmTarget can compile **simple, pure Julia functions** to WebAssembly that **actually executes correctly** in the browser.

### Verified Working (Feb 2026)

| Feature | Example | Status |
|---------|---------|--------|
| Integer arithmetic | `x -> x + Int32(1)` | **Works** |
| 64-bit arithmetic | `x -> x * Int64(2) + Int64(10)` | **Works** |
| Floating point | `x -> x * 2.0 + 1.5` | **Works** |
| Comparisons | `(x, y) -> x > y` | **Works** |
| If-else conditionals | `x -> x > 0 ? x : -x` | **Works** |
| Struct field access | `p -> p.x + p.y` | **Works** |
| Function calls | Multiple compiled functions calling each other | **Works** |

### Not Yet Working

| Feature | Status | Notes |
|---------|--------|-------|
| **While loops** | Broken | Single iteration only — control flow bug |
| **For loops** | Broken | Same underlying control flow issue |
| Complex control flow | Broken | 3+ conditionals with phi nodes |
| String operations | Partial | Basic ops work, complex patterns may fail |
| `parsestmt.wasm` | Crashes | Validates but traps at runtime ("unreachable") |

### Use Case: Therapy.jl Foundation

WasmTarget is designed to power [Therapy.jl](https://github.com/GroupTherapyOrg/Therapy.jl), a reactive web framework. For this use case:

```julia
# WORKS: Simple event handlers
using WasmTarget

validate_positive(x::Int32)::Int32 = x > Int32(0) ? Int32(1) : Int32(0)
bytes = compile(validate_positive, (Int32,))
# → Valid, executable wasm

# WORKS: Pure computations
scale_value(x::Float64)::Float64 = x * 2.5 + 10.0
bytes = compile(scale_value, (Float64,))
# → Valid, executable wasm

# DOES NOT WORK: Loops
function sum_to_n(n::Int32)::Int32
    total = Int32(0)
    i = Int32(1)
    while i <= n
        total += i
        i += Int32(1)
    end
    return total
end
bytes = compile(sum_to_n, (Int32,))
# → Compiles and validates, but only returns first iteration
```

## Future Vision (Tier 2) — Not Yet Working

The ultimate goal is a **full Julia REPL in the browser** with no server required:

```
┌─────────────────────────────────────────────────────────────────┐
│                    FUTURE: Browser Compiler                     │
│                                                                 │
│  User types: "f(x) = x^2"                                       │
│       ↓                                                         │
│  parsestmt.wasm  → AST (Expr)         [BROKEN: traps]          │
│       ↓                                                         │
│  lowering.wasm   → Lowered IR         [Untested in browser]    │
│       ↓                                                         │
│  typeinf.wasm    → Typed CodeInfo     [Untested in browser]    │
│       ↓                                                         │
│  codegen.wasm    → Wasm bytes         [BROKEN: fails validation]│
│       ↓                                                         │
│  WebAssembly.instantiate() → Running code                       │
└─────────────────────────────────────────────────────────────────┘
```

**Current State (Feb 2026):**
- `parsestmt.wasm` (488 funcs, 1.82MB) — Validates but crashes at runtime for ALL inputs
- `lowering.wasm` (32 funcs, 8KB) — Validates, never tested for execution
- `typeinf.wasm` (6 funcs, 5KB) — Validates, never tested for execution
- `codegen.wasm` — **REGRESSION**: Currently fails validation (was working 2026-01-28)

This Tier 2 vision is on hold until the Tier 1 control flow issues are resolved.

## Milestone Status (Honest Assessment)

| Milestone | Compiles | Validates | Executes | Notes |
|-----------|----------|-----------|----------|-------|
| **M1b** (parsestmt) | Yes (488 funcs) | Yes | **No** | Traps: "unreachable" for all inputs |
| **M2** (lowering) | Yes (32 funcs) | Yes | Unknown | Never tested in browser |
| **M3** (typeinf) | Yes (6 funcs) | Yes | Unknown | Never tested in browser |
| **M4** (codegen) | Yes | **No** | N/A | **REGRESSION**: func 1, offset 0x323 |
| Simple functions | Yes | Yes | **Yes** | Arithmetic, comparisons, if-else |
| Loops | Yes | Yes | **No** | Control flow bug |

**Key distinction**: "Validates" means structurally correct wasm. "Executes" means produces correct output.

## Requirements

- Julia 1.12+ (required for latest JuliaSyntax and type inference features)
- Node.js 20+ for testing (v23+ recommended for stable WasmGC support)
- `wasm-tools` for validation (`cargo install wasm-tools`)

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/GroupTherapyOrg/WasmTarget.jl")
```

## Quick Start

### Simple Function (This Works)

```julia
using WasmTarget

@noinline function add(a::Int32, b::Int32)::Int32
    return a + b
end

wasm_bytes = compile(add, (Int32, Int32))
write("add.wasm", wasm_bytes)
```

### Running in JavaScript

```javascript
const fs = require('fs');
const bytes = fs.readFileSync('add.wasm');

WebAssembly.instantiate(bytes).then(mod => {
    console.log(mod.instance.exports.add(5, 3)); // Output: 8
});
```

### Known-Working Example

```julia
using WasmTarget

# Conditional logic - works
@noinline function my_abs(x::Int32)::Int32
    if x < Int32(0)
        return -x
    else
        return x
    end
end

bytes = compile(my_abs, (Int32,))
write("abs.wasm", bytes)
run(`wasm-tools validate --features=gc abs.wasm`)  # PASS
# Execute in browser: my_abs(-5) returns 5 ✓
```

## Architecture: The PURE Route

WasmTarget uses Julia's existing compiler infrastructure:

```
┌─────────────────────────────────────────────────────────────────┐
│                    COMPILE TIME (dev machine)                   │
│                                                                 │
│  Julia Source Code                                              │
│       ↓                                                         │
│  JuliaSyntax.parsestmt     → AST (Expr)                        │
│       ↓                                                         │
│  JuliaLowering._to_lowered_expr → Lowered IR                   │
│       ↓                                                         │
│  Core.Compiler.typeinf     → Typed CodeInfo                    │
│       ↓                                                         │
│  WasmTarget.compile        → Wasm bytes                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    RUNTIME (browser/Node.js)                    │
│                                                                 │
│  WebAssembly.instantiate() → Running code                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Supported Types

| Julia Type | WebAssembly Type |
|------------|------------------|
| `Int32`, `UInt32` | `i32` |
| `Int64`, `UInt64`, `Int` | `i64` |
| `Int128`, `UInt128` | `(i64, i64)` pair |
| `Float32` | `f32` |
| `Float64` | `f64` |
| `Bool` | `i32` (0 or 1) |
| `String`, `Symbol` | WasmGC `array<i32>` |
| `Nothing` | `i32` (0) |
| User structs | WasmGC struct |
| `Tuple{...}` | WasmGC struct |
| `Vector{T}` | WasmGC `struct{array_ref, size}` |
| `Any` | `externref` |
| `JSValue` | `externref` |

## Project Structure

```
src/
  WasmTarget.jl              # Entry point: compile(), compile_multi()
  Builder/
    Types.jl                 # Wasm type definitions (I32, I64, RefType, etc.)
    Writer.jl                # Binary serialization to .wasm format
    Instructions.jl          # Module building, opcodes
  Compiler/
    IR.jl                    # Julia IR extraction via code_typed
    Codegen.jl               # IR → Wasm bytecode (~21K lines)
  Runtime/
    Intrinsics.jl            # Julia intrinsic → Wasm opcode mapping
    StringOps.jl             # str_char, str_len, etc. (recognized as intrinsics)
    ArrayOps.jl              # arr_new, arr_get, etc. (recognized as intrinsics)
    SimpleDict.jl            # Dictionary operations
    ByteBuffer.jl            # I/O abstraction
    Tokenizer.jl             # WASM-compilable tokenizer
```

## Known Limitations

### Permanent Limitations

- **Full Julia Runtime**: No GC, tasks, channels, or IO. WasmGC provides the GC.
- **Arbitrary FFI**: Only Wasm imports/exports. No libc, BLAS, etc.
- **Closures**: Use structs or compile-time code generation instead.
- **Exceptions**: Use Result-type patterns (return `Union{T, Error}`).
- **Async/Await**: Use callbacks via JS interop.
- **Reflection**: `methods()`, `fieldnames()` etc. are compile-time only.

### Current Limitations (Blocking Issues)

- **While/For Loops**: Control flow bug causes single iteration only
- **Complex Control Flow**: 3+ conditionals with phi nodes may fail
- **parsestmt.wasm**: Validates but crashes at runtime
- **M4 Self-Hosting**: Regression — currently fails validation

### Current Limitations (May Improve)

- **Base Coverage**: Focused on core primitives. Many Base functions not yet supported.
- **String Indexing**: Julia's UTF-8 semantics are complex. Use `str_char(s, i)` intrinsic.
- **Array Resize**: `push!`/`pop!` compile but require runtime support.
- **Union Types**: Basic support. Complex unions may fail.

## Testing

```bash
# Run main test suite
julia +1.12 --project=. test/runtests.jl

# Verify simple function execution (recommended)
julia +1.12 --project=. -e '
  using WasmTarget
  f(x::Int32)::Int32 = x + Int32(1)
  bytes = compile(f, (Int32,))
  write("/tmp/test.wasm", bytes)
  run(`wasm-tools validate --features=gc /tmp/test.wasm`)
  println("PASS")
'
```

## Comparison with Other Projects

### Julia → WebAssembly Compilers

| Feature | WasmTarget.jl | WebAssemblyCompiler.jl |
|---------|--------------|------------------------|
| **Memory Model** | WasmGC (structs, arrays) | WasmGC via Binaryen |
| **Simple Functions** | Working | Working |
| **Loops** | **Broken** | Working |
| **Self-Hosting Goal** | Yes (currently broken) | No |
| **Status** | Active (Feb 2026) | Experimental (2023) |

### Architectural Inspiration: dart2wasm

WasmTarget's architecture is influenced by [dart2wasm](https://dart.dev/web/wasm), Dart's official WebAssembly compiler:

| Aspect | dart2wasm | WasmTarget.jl |
|--------|-----------|---------------|
| **Language** | Dart | Julia |
| **Memory** | WasmGC | WasmGC |
| **Status** | Production (Flutter Web) | Experimental |
| **Loops** | Working | **Broken** |

## Roadmap

1. **Priority 1**: Fix loop control flow bug (blocking Therapy.jl)
2. **Priority 2**: Fix M4 validation regression
3. **Priority 3**: Get parsestmt.wasm executing (not just validating)
4. **Future**: Browser REPL (M5-M7)

## Related Projects

WasmTarget.jl is the compiler foundation for **Therapy.jl**, a reactive web framework inspired by Leptos (Rust) and SolidJS, bringing Julia to the browser with fine-grained reactivity.

## License

MIT License
