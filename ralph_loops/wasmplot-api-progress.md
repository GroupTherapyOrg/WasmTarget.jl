# WasmPlot API Progress

## API-001 + API-002 (2026-04-10)

### Discovery
- Dumped 874-statement IR for full WasmPlot closure (Figure + Axis + lines! + render!)
- All WasmPlot functions ARE fully inlined by Julia's optimizer
- `#lines!#3` (kwarg body for lines!) appeared as `:invoke` but was stubbed
- Root cause: `check_and_add_external_method!` rejected kwarg wrappers from non-Base modules due to function singleton arg types (e.g., `typeof(lines!)`)

### Fix (compile.jl)
1. Added `_is_kwarg_wrapper = startswith(String(meth_name), "#")` to exempt kwarg wrappers from the function singleton check
2. Refactored `_autodiscover_closure_deps!` to reuse `check_and_add_external_method!` instead of its own Base-only filter

### Results
- `compile(closure, ())`: 155KB → 187KB (more functions compiled, `#lines!#3` no longer stubbed)
- WasmTarget tests: 2409 pass, 1 broken (unchanged)
- WasmPlot tests: 69 pass
- WasmPlot WASM compile: 11 pass
- Island compilation: 95KB WASM, no stub warnings

### Remaining issues
- End-to-end browser validation needed (API-005)

## API-003 (2026-04-10)

### Finding: NOT A REAL ISSUE
- Type instability only occurs with untyped Main globals (bare script variables)
- In Therapy.jl, signals provide typed values (CompilableSignal{Int64} → Int64)
- Typed `let` closure: zero `::Any` `:call` statements, `sin(::Float64)` resolves as `:invoke`
- Verified: typed closure compiles, island compiles to 95KB with no UNREACHABLE warnings

## API-004 (2026-04-10)

### Fix: Replace NAMED_COLORS Dict with if-else chain
- Removed `Dict{Symbol, RGBA}` lookup in `resolve_color(::Symbol)`
- Replaced with `c === :blue && return RGBA(...)` if-else chain
- Eliminates `jl_object_id` foreigncalls from the IR entirely

### Results
- IR: 874 → 594 statements (32% reduction)
- foreigncalls: 4 → 0
- WASM closure: 187KB → 129KB (31% reduction)
- WASM island: 95KB → 70KB (26% reduction)
- WasmPlot tests: 69 pass
- WasmPlot WASM compile: 11 pass
- Island compilation: 70KB WASM, no new warnings

### Remaining
- End-to-end browser validation (API-005) — blocked on render! codegen bug

## API-004 continued (2026-04-10)

### Additional fixes
1. **COLOR_CYCLE Vector → if-else cycle_color()** — module-level const Vector{RGBA} was null ref in WASM. Replaced with if-else chain.
2. **Typed dispatch for plot functions** — added `lines!(ax, x::Vector{Float64}, y::Vector{Float64}; ...)` to skip `Float64.(collect(x))` broadcasting. Same for scatter!/barplot!.
3. **WasmTarget: _apply_iterate isa fix** — `_apply_iterate(iterate, Core.tuple, vec)` was creating base struct, but `isa(result, Tuple{})` uses `ref.test` which needs the actual Tuple{} struct type. Fixed to emit `struct.new $Tuple_empty_type_idx` instead of `struct.new $base_idx`.

### Results after all fixes
- IR: 874 → 252 statements (71% reduction)
- foreigncalls: 4 → 0
- WASM island: 95KB → 65KB (32% reduction)
- All WasmPlot tests: 69 pass
- All WASM compile tests: 11 pass
- WasmTarget tests: 2409 pass, 1 broken (unchanged)
- Standalone tests in Node: data computation OK, Figure OK, Axis OK, lines! OK, handlers OK
- render! blocked: _render_axis! has codegen bug (stack underflow in drop instruction)

## API-005 investigation (2026-04-10)

### Status: blocked on render! codegen
- WASM validates (WebAssembly.validate=true)
- Instantiation succeeds with all 53 imports (21 canvas2d, 31 dom, 1 Math)
- Button handlers work (_hw1, _hw2)
- Effect traps with 'unreachable' before any canvas calls
- Root cause: `_render_axis!` cross-call function has WASM codegen bug
  - Standalone: "not enough arguments on stack for drop" validation error
  - Island: validates but hits stubbed/unreachable code path at runtime
- This is a WasmTarget codegen issue, not a WasmPlot API issue
