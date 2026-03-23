# Dispatch Discovery Spec — IR Type Registration for REAL Codegen

## §1: Problem Statement

The current self-hosted codegen (eval_julia.wasm) uses pre-baked CodeInfo and hand-emitted
opcodes for specific operations. The REAL codegen (compile_statement etc.) dispatches on
IR node types via `stmt isa Core.ReturnNode`, `stmt isa Core.GotoNode`, etc.

For the real codegen to run inside WASM, these `isa` checks must compile to `ref.test`
instructions on WasmGC struct types.

## §2: Core IR Types (~13)

| # | Julia Type | Key Fields | WasmGC Struct |
|---|-----------|------------|---------------|
| 1 | Core.SSAValue | id::Int | (i64) |
| 2 | Core.Argument | n::Int | (i64) |
| 3 | Core.GotoNode | label::Int | (i64) |
| 4 | Core.GotoIfNot | cond::Any, dest::Int | (anyref, i64) |
| 5 | Core.ReturnNode | val::Any (optional) | (anyref) |
| 6 | Core.PhiNode | edges::Vector{Int32}, values::Vector{Any} | (ref array, ref array) |
| 7 | Core.UpsilonNode | val::Any (optional) | (anyref) |
| 8 | Core.PhiCNode | values::Vector{Any} | (ref array) |
| 9 | Core.PiNode | val::Any, typ::Any | (anyref, anyref) |
| 10 | Core.NewvarNode | slot::SlotNumber | (ref $SlotNumber) |
| 11 | Core.SlotNumber | id::Int | (i64) |
| 12 | Expr | head::Symbol, args::Vector{Any} | (ref $Symbol, ref array) |
| 13 | SimpleCodeInfo | code, ssavaluetypes, ssaflags, debuginfo, nargs | (multi-field) |

## §3: How isa Compiles to ref.test

When WasmTarget.jl compiles `x isa SomeStructType`:
1. Value `x` is on the WASM stack (anyref or structref)
2. If value is externref: `any.convert_extern` first
3. `ref.test (ref $SomeStructTypeIdx)` — returns i32 (0 or 1)

This path is already implemented in `src/codegen/calls.jl` lines 1486-1490 for ConcreteRef types.

## §4: What Needs to Happen (D-001)

1. Compile a test function that takes Vector{Any} and dispatches via isa on IR types
2. All IR types used in isa checks must be registered in TypeRegistry
3. The compiled WASM must contain ref.test instructions (not hardcoded dispatch)
4. Verify by disassembling to WAT and searching for ref.test

## §5: Auto-Registration vs Explicit Registration

WasmTarget.jl auto-registers struct types when they appear as:
- Function return types
- Function argument types
- Fields of other registered structs

If Core IR types don't auto-register (because they're internal Julia types), we may need
to explicitly register them via `register_struct_type!` calls.

## §6: Test Function Template

```julia
function ir_dispatch_test(code::Vector{Any}, idx::Int32)::Int32
    stmt = code[idx]
    if stmt isa Core.ReturnNode
        return Int32(1)
    elseif stmt isa Core.GotoNode
        return Int32(2)
    elseif stmt isa Core.GotoIfNot
        return Int32(3)
    elseif stmt isa Expr
        return Int32(4)
    elseif stmt isa Core.SSAValue
        return Int32(5)
    elseif stmt isa Core.Argument
        return Int32(6)
    elseif stmt isa Core.PhiNode
        return Int32(7)
    end
    return Int32(0)
end
```

## §7: Verification

After compilation, disassemble and check:
```
wasm-tools print output.wasm | grep ref.test
```
Should see multiple ref.test instructions for different struct type indices.

## §8: Risk — Core Types May Not Have Fieldnames

Julia Core types (ReturnNode, GotoNode, etc.) are defined in C, not Julia.
`fieldnames(Core.ReturnNode)` returns `(:val,)` — they DO have Julia-visible fields.
So they should register as normal structs.

## §9: Implementation Steps for D-001

1. Write the test function from §6
2. Compile it with `compile(ir_dispatch_test, (Vector{Any}, Int32))`
3. Save the .wasm output
4. Disassemble with wasm-tools and check for ref.test
5. If ref.test is missing → trace TypeRegistry to see what types are registered
6. If types aren't registered → add explicit registration in compile pipeline
7. Test with actual IR nodes: create Vector{Any} with ReturnNode, GotoNode, etc.
8. Execute the compiled function and verify correct dispatch (returns 1, 2, 3, etc.)

## §10: Success Criteria

- [ ] Test function compiles without errors
- [ ] WAT output contains ref.test for at least ReturnNode, GotoNode, Expr types
- [ ] Runtime execution correctly identifies IR node types
- [ ] All 914+ existing tests still pass
