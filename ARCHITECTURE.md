# WasmTarget.jl — Architecture

Build-time Julia-to-WasmGC compiler. Compiles Julia functions on the developer's machine, ships `.wasm` to the browser, executes with zero Julia runtime.

## Directory Structure

```
src/
├── WasmTarget.jl              318 lines   Entry point: compile(), compile_multi()
│
├── builder/                 2,898 lines   WASM binary format (stable)
│   ├── types.jl               488         NumType, RefType, JSValue, WasmGlobal, etc.
│   ├── instructions.jl      1,539         WasmModule, add_function!, add_import!, etc.
│   ├── writer.jl              151         LEB128 encoding, binary section serialization
│   └── validator.jl           720         WASM module validation
│
├── codegen/                42,333 lines   Julia IR → WASM (the core)
│   ├── ir.jl                   44         Base.code_typed() wrapper
│   ├── compile.jl           3,931         Main entry: compile(), compile_multi()
│   ├── context.jl           2,432         CompilationContext (per-function state)
│   ├── types.jl             1,910         TypeRegistry: Julia types → WasmGC types
│   ├── structs.jl           1,019         Struct/tuple registration and field access
│   ├── unions.jl              343         Union type discrimination (isa, Union{Nothing,T})
│   ├── flow.jl              2,606         Control flow analysis (loops, branches, phi nodes)
│   ├── conditionals.jl      3,276         If/else, GotoIfNot, short-circuit &&/||
│   ├── stackified.jl        2,044         Stackifier for complex control flow (sin/cos/exp)
│   ├── statements.jl        3,555         Statement compilation (assign, return, foreigncall)
│   ├── calls.jl             5,960         Function call compilation
│   ├── invoke.jl            4,360         Method invoke compilation
│   ├── dispatch.jl          1,425         Multiple dispatch support
│   ├── values.jl            1,186         SSA value tracking and local allocation
│   ├── generate.jl          2,474         WASM bytecode generation
│   ├── strings.jl             771         String operations (concat, compare, hash)
│   ├── dicts.jl             1,421         SimpleDict/StringDict (hash tables)
│   ├── int128.jl            1,413         Int128/UInt128 support
│   ├── int_key_map.jl          30         Int-keyed map utility
│   ├── wasm_constructors.jl 1,248         WASM instruction constructors
│   ├── helpers.jl              70         Shared helper functions
│   ├── packages.jl            178         Package extension infrastructure
│   ├── cache.jl               254         Compilation cache
│   └── sourcemap.jl           383         Source map generation
│
├── runtime/                 1,272 lines   Compiled-into-WASM helper functions
│   ├── intrinsics.jl           77         Julia intrinsic → WASM opcode mapping
│   ├── arrayops.jl            199         Array operations (push, pop, copy)
│   ├── stringops.jl           646         String functions compiled to WASM
│   └── simpledict.jl          350         Hash table implementation
│
├── packages/                   90 lines   Domain-specific extensions
│   └── statistics.jl           90         Statistics function registration
│
└── selfhost/                9,731 lines   Browser REPL (NOT loaded by default)
    ├── eval_julia.jl        1,274         Julia evaluator for browser
    ├── tokenizer.jl           392         Token-based parsing
    ├── bytebuffer.jl          298         Byte buffer for tokenizer
    └── typeinf/             7,767         Type inference reimplementation
        ├── ccall_replacements.jl  2,228   Runtime function replacements
        ├── subtype.jl             1,818   Subtype checking
        ├── matching.jl              545   Method matching
        └── ... 11 more files
```

**Core src/ (excluding selfhost): ~46.9K lines**
**Total src/: ~57K lines**

## Compilation Pipeline

```
Julia source code
        │
        ▼
Base.code_typed(f, arg_types)     Julia's compiler does parsing, macro expansion,
        │                          lowering, type inference, optimization
        ▼
Typed Julia IR                     Fully typed SSA form with GotoIfNot, PhiNode, etc.
        │
        ▼
codegen/compile.jl                 Analyze control flow, allocate locals,
        │                          register types, compile statements
        ▼
builder/instructions.jl            Build WasmModule with functions, types, imports
        │
        ▼
builder/writer.jl                  Serialize to WASM binary format
        │
        ▼
.wasm bytes                        Ready for browser/Node.js execution
```

## Key Abstractions

### TypeRegistry (codegen/types.jl)
Maps Julia types to WasmGC type indices. Handles structs, tuples, arrays, strings, unions.

### CompilationContext (codegen/context.jl)
Per-function compilation state: SSA locals, phi nodes, loop headers, block stack.

### FunctionRegistry (codegen/compile.jl)
Cross-function call resolution for `compile_multi()`. Maps function names to WASM indices.

### Control Flow (codegen/flow.jl + conditionals.jl + stackified.jl)
- **Simple functions** (<15 branches): Nested if/else blocks
- **Complex functions** (15+ branches): Stackifier algorithm with block/loop/br

## Type Mappings

| Julia | WASM | Implementation |
|-------|------|----------------|
| Int32, UInt32 | i32 | Direct |
| Int64, UInt64, Int | i64 | Direct |
| Float32 | f32 | Direct |
| Float64 | f64 | Direct |
| Bool | i32 | 0/1 |
| String | WasmGC array(i32) | One i32 per character |
| struct T | WasmGC struct | Fields map directly |
| Tuple{...} | WasmGC struct | Immutable |
| Vector{T} | WasmGC array | Mutable |
| JSValue | externref | JS object reference |
| WasmGlobal{T,IDX} | global | Phantom parameter, compile-time index |

## Testing

```bash
julia +1.12 --project=. test/runtests.jl    # Full build-time suite (1084+ tests)
julia +1.12 --project=. test/selfhost/runtests.jl  # Self-hosting tests (separate)
```

Test oracle: `compare_julia_wasm(f, args...)` runs function in both Julia and Node.js WASM, compares results.
