# WasmTarget.jl

A Julia-to-WebAssembly compiler targeting the WasmGC (Garbage Collection) proposal. WasmTarget compiles Julia functions directly to WebAssembly binaries that run in modern browsers and Node.js with WasmGC support.

## Current Status (Feb 2026)

**Self-hosting achieved.** WasmTarget can compile itself to WebAssembly.

| Milestone | Status | Details |
|-----------|--------|---------|
| **M1** | Complete | JuliaSyntax.parsestmt validates (477 funcs, 803KB) |
| **M1b** | Complete | JuliaSyntax v2.0.0-DEV validates (488 funcs, ~1MB) |
| **M2** | Complete | JuliaLowering._to_lowered_expr validates (32 funcs, 8KB) |
| **M3** | Complete | Core.Compiler.typeinf validates (6 funcs, 5KB) |
| **M4** | Complete | **WasmTarget.compile compiles itself (44 funcs, 15KB)** |
| **M5** | In Progress | Browser integration (JS runtime, string interop) |
| **M6** | Planned | Binaryen.js optimization |
| **M7** | Planned | GitHub Pages deployment with full Julia REPL |

## Features

- **Direct Compilation**: Julia functions to WebAssembly without intermediate languages
- **WasmGC Support**: Uses WebAssembly GC proposal for structs, arrays, and reference types
- **Type Support**: Integers (32/64/128-bit), floats, booleans, strings, symbols, structs, tuples, and arrays
- **Control Flow**: Full support for loops, recursion, branches, phi nodes, and complex conditionals
- **Multi-Function Modules**: Compile multiple functions into a single module with cross-function calls
- **Multiple Dispatch**: Same function name with different type signatures dispatches correctly
- **JS Interop**: `externref` support for holding JavaScript objects, import JS functions
- **Tables**: Function reference tables for indirect calls and dynamic dispatch
- **Linear Memory**: Memory sections with load/store operations and data initialization
- **Globals**: Mutable and immutable global variables, exportable to JS
- **String/Symbol Operations**: String concatenation, equality comparison, Symbol handling

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

### Simple Function

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

### Compile JuliaSyntax Parser

```julia
using WasmTarget, JuliaSyntax

# Wrapper to avoid Type{Expr} parameter
parse_expr_string(s::String) = parsestmt(Expr, s)

bytes = compile(parse_expr_string, (String,))
write("parsestmt.wasm", bytes)

# Validate
run(`wasm-tools validate --features=gc parsestmt.wasm`)
```

## Architecture: The PURE Route

WasmTarget uses Julia's existing compiler infrastructure rather than reimplementing it:

```
┌─────────────────────────────────────────────────────────────────┐
│                    COMPILE TIME (dev machine)                   │
│                                                                 │
│  Julia Source Code                                              │
│       ↓                                                         │
│  JuliaSyntax.parsestmt     → AST (Expr)              [M1b]      │
│       ↓                                                         │
│  JuliaLowering._to_lowered_expr → Lowered IR         [M2]       │
│       ↓                                                         │
│  Core.Compiler.typeinf     → Typed CodeInfo          [M3]       │
│       ↓                                                         │
│  WasmTarget.compile        → Wasm bytes              [M4]       │
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

### Self-Hosting Vision (M4 Complete)

WasmTarget compiles itself to WebAssembly:

```
parsestmt.wasm (488 funcs, ~1MB)   ← Parses Julia code
       ↓
lowering.wasm (32 funcs, ~8KB)     ← Lowers to IR
       ↓
typeinf.wasm (6 funcs, ~5KB)       ← Type inference
       ↓
codegen.wasm (44 funcs, ~15KB)     ← SELF-HOSTED COMPILER
       ↓
User's compiled Wasm               ← Runs in browser
```

The goal: a full Julia REPL in the browser, compiling Julia code to Wasm at native speed, with no server required.

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

### Will Likely Never Work

- **Full Julia Runtime**: No GC, tasks, channels, or IO. WasmGC provides the GC.
- **Arbitrary FFI**: Only Wasm imports/exports. No libc, BLAS, etc.
- **Closures**: Use structs or compile-time code generation instead.
- **Exceptions**: Use Result-type patterns (return `Union{T, Error}`).
- **Async/Await**: Use callbacks via JS interop.
- **Reflection**: `methods()`, `fieldnames()` etc. are compile-time only.

### Current Limitations (May Improve)

- **Base Coverage**: Focused on core primitives. Many Base functions not yet supported.
- **String Indexing**: Julia's UTF-8 semantics are complex. Use `str_char(s, i)` intrinsic.
- **Array Resize**: `push!`/`pop!` compile but require runtime support. WasmGC arrays are fixed-size internally; we wrap with capacity tracking.
- **Union Types**: Basic support. Complex unions may fail.

## Testing

```bash
# Run main test suite
julia +1.12 --project=. test/runtests.jl

# Verify all milestones pass
julia +1.12 --project=. scripts/test_milestones.jl
```

Tests require Node.js 20+ for WasmGC execution.

## Comparison with Other Projects

### Julia → WebAssembly Compilers

| Feature | WasmTarget.jl | WebAssemblyCompiler.jl |
|---------|--------------|------------------------|
| **Memory Model** | WasmGC (structs, arrays) | WasmGC via Binaryen |
| **Julia Version** | 1.12+ | 1.9+ |
| **IR Source** | `Base.code_typed()` | Julia IR via Binaryen |
| **Self-Hosting** | Yes (M4 complete) | No |
| **Status** | Active (2026) | Experimental (2023) |
| **Type Stability** | Required | Required |
| **Dynamic Dispatch** | No | No |

#### Type Support Comparison

| Type | WasmTarget.jl | WebAssemblyCompiler.jl |
|------|--------------|------------------------|
| `Int32`, `Int64` | ✅ | ✅ |
| `Int128` | ✅ (i64 pair) | ❌ |
| `Float32`, `Float64` | ✅ | ✅ |
| `Bool` | ✅ | ✅ |
| `String` | ✅ (array\<i32\>) | ✅ |
| `Symbol` | ✅ (array\<i32\>) | ✅ |
| `Vector{T}` | ✅ | ✅ (1D only) |
| Multi-dimensional arrays | ❌ | ❌ |
| `Dict` | ✅ (constants) | ✅ (no string keys) |
| `Tuple`, `NamedTuple` | ✅ | ✅ |
| User structs | ✅ | ✅ |
| `Union` types | Basic | ❌ |
| `Any` / externref | ✅ | ✅ |
| Pointers | ❌ | ❌ |

#### Control Flow Comparison

| Feature | WasmTarget.jl | WebAssemblyCompiler.jl |
|---------|--------------|------------------------|
| Loops | ✅ Full support | ✅ |
| Recursion | ✅ | ✅ |
| Phi nodes | ✅ (stackified) | Unknown |
| Complex conditionals | ✅ | ✅ |
| Exception handling | ❌ (use Result types) | ❌ |
| Varargs | ✅ | ✅ |
| Keyword arguments | ✅ | ✅ |

#### Key Differences

**WasmTarget.jl:**
- Directly compiles Julia's typed SSA IR to Wasm bytecode
- Handles complex control flow (141+ conditionals, phi nodes)
- Self-hosting: can compile its own compiler to Wasm
- Targets browser REPL as end goal (M5-M7)
- ~21K lines of Codegen.jl

**WebAssemblyCompiler.jl:**
- Uses Binaryen as intermediate representation
- Simpler compilation path (Julia IR → Binaryen → Wasm)
- Focuses on numerical/simulation use cases (Lorenz demo)
- No self-hosting goal
- Smaller codebase

### Architectural Inspiration: dart2wasm

WasmTarget's architecture is influenced by [dart2wasm](https://dart.dev/web/wasm), Dart's official WebAssembly compiler:

| Aspect | dart2wasm | WasmTarget.jl |
|--------|-----------|---------------|
| **Language** | Dart | Julia |
| **Memory** | WasmGC | WasmGC |
| **Frontend** | Shared Dart frontend | Julia's JuliaSyntax/JuliaLowering |
| **Output** | .wasm + .mjs runtime | .wasm binary |
| **JS Interop** | `@pragma("wasm:import/export")` | `externref` + imports |
| **Optimization** | Binaryen post-processing | Native Wasm emission |
| **GC** | WebAssembly GC proposal | WebAssembly GC proposal |
| **Status** | Production (Flutter Web) | Experimental (M5 in progress) |

**Shared approaches:**
- Both compile garbage-collected languages to WasmGC (no manual memory management)
- Both handle complex control flow with stackification
- Both support externref for JS object passing
- Both require type stability (Dart is statically typed; Julia requires inference)

**Key difference:** WasmTarget leverages Julia's *existing* compiler infrastructure (JuliaSyntax, JuliaLowering, Core.Compiler.typeinf) rather than building a separate frontend. This "PURE route" means WasmTarget benefits from upstream Julia improvements automatically.

### Other Related Projects

| Project | Description | Approach |
|---------|-------------|----------|
| [WebAssembly.jl](https://github.com/MikeInnes/WebAssembly.jl) | Wasm IR manipulation in Julia | Low-level tools |
| [Charlotte.jl](https://github.com/MikeInnes/Charlotte.jl) | Experimental Julia→JS/Wasm | Targets JS |
| [julia-wasm](https://github.com/Keno/julia-wasm) | Run full Julia runtime on Wasm | Emscripten |

WasmTarget.jl occupies a unique position: it's a *compiler* for Julia functions (not the full runtime), targeting WasmGC for efficient browser execution.

## Related Projects

WasmTarget.jl is the compiler foundation for **Therapy.jl**, a reactive web framework inspired by Leptos (Rust) and SolidJS, bringing Julia to the browser with fine-grained reactivity.

## License

MIT License
