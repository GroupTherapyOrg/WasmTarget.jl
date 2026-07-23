# WasmTarget parity history

This is the single archive for completed WasmTarget parity campaigns. It is not a
roadmap. Current status and next work live in [`PARITY_MASTER.md`](PARITY_MASTER.md);
machine truth lives in [`test/parity_ratchet.jl`](../test/parity_ratchet.jl) and
[`parity_baseline.toml`](parity_baseline.toml).

The original plans, detailed ledgers, intermediate counts, branch names, commands, and
resume points remain available in Git history before the 2026-07-22 documentation
consolidation. They are intentionally not reproduced as actionable checklists here.

## Typed builder and cleanup campaigns

The builder migration replaced raw byte-oriented instruction assembly with one typed,
stack-validating instruction IR. Follow-on cleanup deleted byte repair, parallel flow
generators, lax validation, post-emission type guessing, and fabricated fallback values.
These campaigns were formerly documented in `WASM_BUILDER_MIGRATION.md`,
`MIGRATION_PLAYBOOK.md`, `CLEANUP_LOOP.md`, `cleanup_ledger.md`, `FULLSTRICT.md`,
`MARCH4_STATEMENT_PLAN.md`, `MARCH17_ENFORCER.md`, and the early parity ledgers.

The migration deliberately separated typed instruction nodes, stack-aware construction,
and serialization. Temporary byte bridges made the conversion incremental, then ratchets
forced their deletion. A crucial later audit found that the validator existed while many
builders still ran lax; the enforcing-builder campaign burned down those mismatches and
made validation unconditional. Cleanup used targeted neutralization probes to distinguish
redundant repair passes from load-bearing behavior. Backfill tests captured real bugs,
including multivariable branch/phi behavior, before repair code was removed.

## Uniform values, objects, and class hierarchy

The representation campaigns established one conversion/boxing funnel, exact Julia
runtime classes, a nominal WasmGC class DAG, object identity, recursion groups, packed
arrays, and exact constant/global initialization. These campaigns were formerly tracked
in `LOOP_B_DESIGN.md`, `STEP5_CLASSDAG.md`, and `PARITY_LEDGER.md`.

The value campaign chose one classId-tagged object representation and one conversion
funnel rather than parallel numeric and union boxes. The class DAG requires supertypes
before subtypes in the Wasm type section. This ordering, exact class identity, and identity
hash became shared infrastructure for type tests, fields, constants, and selector dispatch.

## Closures and dynamic dispatch

The closure campaigns added typed mutable capture cells, closure contexts, one closure
object/vtable/function-type ABI, static tear-offs, and `call_ref`. The dispatch campaign
replaced the old FNV dispatch mechanism with one classId/selector-offset table and
closed-world target discovery. The detailed work formerly lived in `F3_LOOP.md`,
`MARCH16_CLOSURES.md`, `PARITY_LOOP.md`, and `PARITY_REORIENT.md`.

Mutable `Core.Box` support grew in stages: infer contents types, register specialized box
types, propagate capture types across functions, and recover precision past Julia's
`Box{Any}` erasure. First-class closures then use the shared object prefix plus context,
vtable, and function-type metadata. Known callees remain direct; erased calls load a typed
vtable entry and use `call_ref`.

## Exceptions and structured control flow

The exception and control campaigns moved exact Julia exception objects through a typed
tag, preserved bottom/throwing flow, unified symbolic labels, normalized supported
crossing regions, and made unsupported regions reject explicitly. The detailed plan was
formerly `MARCH6_PLAN.md` plus sections of the parity loop documents.

The statement inversion made the typed builder—not returned byte vectors—the live value
channel. Exception work then taught the same stackifier about try regions and typed
exception payloads instead of maintaining a second flow driver.

## Parity method

The campaigns used dart2wasm as the structural oracle and native Julia as the behavioral
oracle. A result type is a byproduct of typed emission, never something guessed afterward.
Passing differential tests alone never establishes structural correspondence, while
structural similarity never overrides Julia semantics. Old phase order, parity percentages,
and census counts are obsolete; current locks and reproductions decide current work.

## Why the archive was consolidated

The original files were valuable while their campaigns were active, but later searches
could surface stale `NEXT`, `LIVE`, `RESUME HERE`, and “remaining work” sections as if
they described the current tree. Consolidating the outcome here makes that impossible:

- completed architecture is stated once in `PARITY_MASTER.md` and locked in code;
- current boundaries require a present reproducer or source census;
- exact historical prose is archaeological evidence in Git, not a zombie backlog.
