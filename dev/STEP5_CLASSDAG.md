# STEP 5 — THE CLASS-DAG (dart class_info.dart:278-330)

dart: each class's wasm struct subtypes its SUPERCLASS's struct (Top → Object → … →
leaf, depth-tracked). WT today: every struct `sub $JlBase` (flat — census DIM-3's
main residual).

## THE WT SHAPE
- ABSTRACT Julia types get SYNTHETIC wasm structs ({classId:i32} only), each `sub` its
  parent's synthetic; the chain roots at $JlBase (=Any).
- CONCRETE structs/boxes/closure-base subtype their NEAREST abstract parent's synthetic
  instead of $JlBase directly. Field-prefix validity: synthetics carry only field 0
  (i32 classId) = the universal header ✓ every child extends it.
- Everything still transitively subtypes $JlBase → all existing ref.test/cast gates
  keep working; the DAG adds wasm-level hierarchy tests (isa Number = ref.test on the
  synthetic — a follow-up bonus) + real struct-LUB join targets for dispatch.

## ORDERING CONSTRAINT (wasm: supertypes precede subtypes in the type section)
ensure_abstract_struct! recurses parent-first (low indices); lazily-registered types
ensure their parent chain AT REGISTRATION (never a forward ref). No finalization pass
may mutate a declared supertype after code generation.

## SLICES
A. ensure_abstract_struct! + registration wiring (register_struct_type!,
   get_numeric_box_type!, the closure base) — parent synthetics at creation.
B. Internal closure contexts and vtables remain outside the Object class hierarchy.
C. Consumers audit (anything reading supertype_idx === base_struct_idx).
Full gate per slice.
