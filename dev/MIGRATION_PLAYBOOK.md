# InstrBuilder Migration Playbook (the loop's brain)

Goal: migrate ONE codegen function from raw `push!(bytes, Opcode.X)` emission onto the
typed `InstrBuilder`, **byte-for-byte identical**. This is mechanical. Follow exactly.

## The transform

A target function looks like:
```julia
function compile_foo(args..., ctx)::Vector{UInt8}
    bytes = UInt8[]
    push!(bytes, Opcode.LOCAL_GET); append!(bytes, encode_leb128_unsigned(idx))
    ...
    return bytes
end
```
Becomes:
```julia
function compile_foo(args..., ctx)::Vector{UInt8}
    b = InstrBuilder(; func_name="compile_foo", strict=false)   # strict=false: collect mode
    # if the fn CONSUMES values the caller left on the stack, declare them:
    seed_input!(b, WasmValType[<type per incoming stack slot, bottom→top>])
    local_get!(b, idx)
    ...
    return builder_code(b)
end
```

Rules:
1. `bytes = UInt8[]` → `b = InstrBuilder(; func_name="<name>", strict=false)`.
   (Use `strict=_wt_builder_strict()` for SELF-CONTAINED fns whose stack model you can
   make exact; use hard `strict=false` for byte-INSPECTING fns like compile_value.)
2. `return bytes` (every occurrence, incl. early returns) → `return builder_code(b)`.
3. If the function consumes operands the caller pushed (its doc says `Stack: [a,b] -> ...`),
   call `seed_input!(b, WasmValType[...])` right after constructing `b`, listing the
   incoming types bottom→top. If it produces everything itself (e.g. compile_value), no seed.
4. Type scratch locals so strict mode is accurate (optional but preferred): after the
   `push!(ctx.locals, T)` allocations, `builder_set_local_type!(b, idx, T)` for each.

## push! → typed method (byte-identical) cheatsheet

| raw bytes | typed |
|---|---|
| `push!(I32_CONST); append!(leb_s(v))` (or `push!(0x00)` for 0) | `i32_const!(b, v)` |
| `push!(I64_CONST); append!(leb_s(v))` | `i64_const!(b, v)` |
| `push!(F32_CONST); append!(reinterpret(UInt8,[Float32(x)]))` | `f32_const!(b, x)` |
| `push!(F64_CONST); append!(reinterpret(UInt8,[x]))` | `f64_const!(b, x)` |
| any no-immediate numeric/cmp/conv op `push!(OP)` (I64_ADD, I32_AND, I64_EQ, I64_SHL, I64_CLZ, REF_EQ, I32_WRAP_I64, I64_EXTEND_I32_U/S, I32_EQZ, …) | `num!(b, Opcode.OP)` |
| `push!(DROP)` | `drop!(b)` · `push!(SELECT)` | `select!(b)` |
| `push!(LOCAL_GET); append!(leb_u(i))` | `local_get!(b, i)` |
| `push!(LOCAL_SET\|LOCAL_TEE); leb_u(i)` | `local_set!(b,i)` / `local_tee!(b,i)` |
| `push!(GLOBAL_GET); leb_u(i)` | `global_get!(b, i, <type or AnyRef>)` |
| `push!(GLOBAL_SET); leb_u(i)` | `global_set!(b, i)` |
| `push!(BLOCK\|LOOP); push!(0x40)` (void) | `block!(b)` / `loop!(b)` |
| `push!(BLOCK\|LOOP\|IF); push!(0x7F)` (i32 result) | `block!(b,0x7F; results=WasmValType[I32])` etc. (pass the byte 0x40/0x7C..0x7F or a WasmValType; NEVER LEB-encode it) |
| `push!(IF); push!(0x40)` | `if_!(b)` · `push!(ELSE)` | `else_!(b)` · `push!(END)` | `end_block!(b)` |
| `push!(BR); leb_u(d)` / `push!(BR_IF); leb_u(d)` | `br!(b,d)` / `br_if!(b,d)` |
| `push!(RETURN)` | `return_!(b)` · `push!(UNREACHABLE)` (or bare `push!(bytes,0x00)`) | `unreachable!(b)` · `push!(NOP)` | `nop!(b)` |
| `push!(CALL); leb_u(f)` | `call!(b, f, params::Vector, results::Vector)` (caller knows the sig) |
| `push!(CALL_INDIRECT); leb_u(type); leb_u(table)` | `call_indirect!(b, type, table, params, results)` |
| `push!(REF_NULL); push!(UInt8(AnyRef\|StructRef\|ArrayRef\|EqRef\|ExternRef\|I31Ref))` | `ref_null!(b, AnyRef)` etc. (RefType arg) |
| `push!(REF_NULL); append!(leb_s(type_idx))` | `ref_null!(b, Int64(type_idx), ConcreteRef(UInt32(type_idx), true))` |
| `push!(REF_FUNC); leb_u(f)` | `ref_func!(b, f, <reftype>)` |
| `push!(REF_IS_NULL)` | `ref_is_null!(b)` · `push!(REF_AS_NON_NULL)` | `ref_as_non_null!(b)` |
| `push!(GC_PREFIX); push!(STRUCT_NEW); leb_u(t)` | `struct_new!(b, t, WasmValType[<field types>])` (or `WasmValType[]` if annoying — only affects model, not bytes) |
| `…STRUCT_NEW_DEFAULT…` | `struct_new_default!(b, t)` |
| `…STRUCT_GET\|_S\|_U; leb_u(t); leb_u(f)` | `struct_get!(b, t, f, <fieldtype>; signed=nothing\|true\|false)` |
| `…STRUCT_SET; leb_u(t); leb_u(f)` | `struct_set!(b, t, f, <fieldtype>)` |
| `…ARRAY_NEW; leb_u(t)` | `array_new!(b, t, <elemtype>)` · `…ARRAY_NEW_DEFAULT…` | `array_new_default!(b, t)` |
| `…ARRAY_NEW_FIXED; leb_u(t); leb_u(n)` | `array_new_fixed!(b, t, n, <elemtype>)` |
| `…ARRAY_NEW_DATA; leb_u(t); leb_u(seg)` | `array_new_data!(b, t, seg)` |
| `…ARRAY_GET\|_S\|_U; leb_u(t)` | `array_get!(b, t, <elemtype>; signed=nothing\|true\|false)` |
| `…ARRAY_SET; leb_u(t)` | `array_set!(b, t, <elemtype>)` · `…ARRAY_LEN` | `array_len!(b)` |
| `…ARRAY_COPY; leb_u(d); leb_u(s)` | `array_copy!(b, d, s)` · `…ARRAY_FILL; leb_u(t)` | `array_fill!(b, t)` |
| `…REF_CAST\|REF_CAST_NULL; leb_s(idx)` | `ref_cast!(b, Int64(idx), nullable::Bool)` |
| `…REF_CAST\|REF_CAST_NULL; push!(UInt8(I31Ref\|ArrayRef\|StructRef))` | `ref_cast!(b, I31Ref, nullable)` (RefType arg) |
| `…REF_TEST\|REF_TEST_NULL; leb_s(idx)` | `ref_test!(b, Int64(idx), nullable)` |
| `…ANY_CONVERT_EXTERN` | `any_convert_extern!(b)` · `…EXTERN_CONVERT_ANY` | `extern_convert_any!(b)` |
| `…REF_I31` | `ref_i31!(b)` · `…I31_GET_S\|_U` | `i31_get_s!(b)` / `i31_get_u!(b)` |

## Bridges (do NOT recurse into un-migrated callees)

- A call to ANOTHER emitter that returns `Vector{UInt8}` (`compile_value`, `compile_call`,
  `compile_invoke`, `compile_new`, `compile_foreigncall`, `emit_int128_*`, another emitter),
  spliced via `append!(bytes, callee(...))`:
  → `emit_raw!(b, callee(...); pushes=WasmValType[<types it leaves on the stack>])`
  Use `pushes=WasmValType[infer_value_wasm_type(val, ctx)]` for value producers, or the
  known result types. If it consumes stack values first, add `pops=<n>`.
- An external `emit_*!(bytes, ...)` helper that mutates a buffer (`emit_type_id!`,
  `_narrow_generic_local!`, `emit_numeric_to_externref!`): build into a LOCAL temp then splice:
  `tb = UInt8[]; emit_type_id!(tb, ctx.type_registry, T); emit_raw!(b, tb; pushes=WasmValType[I32])`.
  (emit_type_id! pushes 1 i32; _narrow_generic_local! is net-0; check each.)
- RARE complex ops with vector immediates (`SELECT_T` 0x1C, `TRY_TABLE` 0x1F): build the
  exact bytes into a local `UInt8[]` and `emit_raw!(b, that; pops=…, pushes=WasmValType[…])`.
- BYTE-INSPECTING branches (code that does `field_val_bytes[1] == Opcode.X`,
  `any(byt == GC_PREFIX for byt in elem_bytes)`, LEB-decodes a recursive result): KEEP the
  local `UInt8[]` buffer + its inspection logic UNCHANGED; only the FINAL `append!(bytes, buf)`
  becomes `emit_raw!(b, buf; pushes=WasmValType[…])`. These fns stay `strict=false`.

## Gotchas (learned the hard way)
- **`b` is the builder now** — if any loop/comprehension used `b` as an iterator
  (e.g. `any(b == Opcode.X for b in bytes)`), RENAME it (`byt`). Shadowing = silent bug.
- **Blocktype is a SINGLE byte** (0x40 void, 0x7F i32 …), or multi-byte for ConcreteRef
  results — `block!`/`if_!`/`loop!` handle it; NEVER LEB-encode 0x7F (that was a real bug).
- **i32.const 0** appears as `push!(I32_CONST); push!(0x00)` AND `i32_const!(b,0)` →
  both emit `41 00`. Likewise `i64_const!(b,0)` for `push!(I64_CONST); push!(0x00)`.
- **`-1` as i64**: `push!(I64_CONST); push!(0x7F)` → `i64_const!(b, -1)` (leb_s(-1)=0x7F).
- **Dead code**: if the old body builds `bytes` then ignores it (e.g. delegates), DELETE
  the dead build (don't migrate it). Real bloat removal.
- **DON'T touch `src/builder/instr_ir.jl` or `instr_builder.jl`** — the IR is complete. If
  you hit an op with no method, bridge it via `emit_raw!`. (Touching shared files = conflict.)
- **carry/value left on the stack across local.set of OTHER values** is fine — the model
  tracks it; just emit the ops in order.
- **`pushes` must never wrap a possibly-`nothing` value** (round-4 regression): when you bridge
  with `emit_raw!(b, buf; pushes=WasmValType[val])` and `val` comes from a lookup that can return
  `nothing` (`get_phi_edge_wasm_type`, `get_concrete_wasm_type`, any `get_*_wasm_type`), guard it:
  `pushes = val === nothing ? WasmValType[] : WasmValType[val]`. `WasmValType[nothing]` throws at
  construction. This is byte-safe (pushes only feeds the model). Type CONSTANTS (I32/AnyRef/…) and
  `infer_value_wasm_type(...)` calls are always non-nothing — no guard needed there.

## Verify (per the loop, not per agent)
Byte-identity is checked centrally: compile the frozen corpus, sha each, diff against the
pre-migration baseline (`dev/migration_baseline.txt`). Identical = success. A diff names
which corpus function changed → maps to the offending file. The migration is correct iff
the diff is empty (modulo the known-nondeterministic UInt128-max case).
