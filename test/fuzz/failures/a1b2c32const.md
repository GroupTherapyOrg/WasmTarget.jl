---
id: a1b2c32const
status: fixed
category: wrong_value
kind: silent_wrong_value
construct: "byte-heuristic misparse: `i32.const 32` immediate (0x20) read as LOCAL_GET — `b ± 32` (ASCII case distance) replaced with zero default"
location: "src/codegen/statements.jl (trailing-local.get type-safety check)"
fn_name: vE_titlecase_family
arg_types: "(String,)"
first_seen: P3 julia-1.13 survey (titlecase suite failures)
---

# Gap `a1b2c32const` — `i32.const 32` immediate misparsed as LOCAL_GET, computation replaced by zero

**Category:** `wrong_value` &nbsp;•&nbsp; **Kind:** `silent_wrong_value` &nbsp;•&nbsp; **Location:** `src/codegen/statements.jl`

## Reproducer
Contract: this snippet **throws while the gap is present** and **runs cleanly once fixed**.

```julia
using WasmTarget
include(joinpath("test", "utils.jl"))
function vE(s::String)
    n = ncodeunits(s); bytes = UInt8[]; prev = true; i = 1
    while i <= n
        b = codeunit(s, i); c = b
        if b == UInt8(32)
            prev = true
        else
            if prev && b >= UInt8(97) && b <= UInt8(122)
                c = b - UInt8(32)
            elseif !prev && b >= UInt8(65) && b <= UInt8(90)
                c = b + UInt8(32)
            end
            prev = false
        end
        push!(bytes, c); i += 1
    end
    return String(bytes)
end
repro_p2()::Int64 = Int64(codeunit(vE("hELLO"), 2))
r = compare_julia_wasm(repro_p2)
r.pass || error("gap open: expected $(r.expected) got $(r.actual)")
```

## Symptom

`titlecase`/case-transform byte loops returned strings with the right **length**
but **zero content** (or stale untransformed bytes); the `b == ' '` space check
could likewise compile to constant false. Surfaced by the Julia 1.13 survey
(titlecase suite ×3, plus knock-on Dict{String}/fuzz entries), but the bug is
**version-agnostic** — 1.12 hit it in the same IR shape; the 1.12 titlecase
overlay merely landed on a local-index layout where the misdecoded index was
type-compatible, masking it.

## Root cause

`compile_statement`'s trailing-type-safety heuristic scanned **backward** through
`stmt_bytes` for `0x20` (LOCAL_GET) to find a trailing `local.get`. For
`b - UInt8(32)` the emitted bytes are `[local.get N, i32.const 32, i32.sub]` =
`[0x20, N, 0x41, 0x20, 0x6b]` — the `0x20` **immediate of `i32.const 32`**
matched the scan (the PURE-306 guard listed local/call/global/br predecessors
but not `0x41` i32.const). The following arithmetic opcode (`0x6b` i32.sub)
was then LEB-decoded as a bogus local index (107); whenever that random local
happened to be ref-typed, the check declared a type mismatch, truncated the
buffer, and replaced the whole computation with `i32.const 0`.

ASCII case distance is exactly 32 — the **only** i32.const whose immediate
collides with the LOCAL_GET opcode — so case-transform code was systematically
affected while nearly everything else dodged it. Whether the bug fired depended
on the function's local-index layout, which is why adding an unrelated read of
`bytes[2]` before `String(bytes)` "fixed" it and why 1.12/1.13 differed.

## Fix

1. `_last_instr_start(bytes)` (src/codegen/generate.jl): forward instruction
   parser using the shared `_skip_leb_count`/`_skip_gc_leb_count` tables (plus
   f32/f64.const payloads, GC prefix, br_table, 0xFC prefix). Returns the true
   start of the last instruction; 0 on truncated parse.
2. The trailing-local.get check and the compound-numeric `ends_with_leb_operand`
   check in `compile_statement` now use the forward parse instead of backward
   byte guessing.
3. `_skip_gc_leb_count` gained the missing entries (array.new_data/new_elem,
   array.fill, array.copy/init_data/init_elem) — same desync class as the
   P2-batch24 GC-immediate-table bug, latent in the other byte passes that
   share the table.
