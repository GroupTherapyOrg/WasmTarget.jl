# MARCH 16 — FIRST-CLASS CLOSURES (the dart layouter)

## The dart anchors
- closures.dart:41-118 ClosureRepresentation: vtableStruct + closureStruct (+ instantiation
  machinery for GENERICS — N/A in WT: monomorphized).
- class_info.dart FieldIndex: closure struct = {classId 0, identityHash 1, context 2,
  vtable 3, runtimeType 4}.
- Vtable: one (ref func) entry per positional arity (vtableBaseIndex + posArgCount);
  named-combination entries N/A (WT kwargs pre-positionalized).
- code_generator: dynamic call = struct.get closure.vtable → struct.get entry[arity] →
  call_ref; KNOWN targets devirtualize to direct calls (WT's current static path = that
  fast lane, KEPT).

## The WT shape (deltas justified)
- closure struct: {classId 0, context 2→1, vtable 3→2} — identityHash deferred (DIM-3 hash
  slot campaign), runtimeType deferred (no RTI; typeof via classId).
- context struct: the EXISTING captured-fields struct (typed by march-F3 join) — becomes
  the `context` field's target instead of being the closure itself.
- vtable struct per ARITY-SET: fields = (ref null func) entries for arities 0..max.
  One immutable vtable GLOBAL per closure body (created at compile).
- trampoline per (closure body, arity): (closureBase, args...) → cast context → call body.
- dynamic call site (the currently loud-rejected function-value call): closure.vtable →
  entry[n] → call_ref. Static sites stay direct (dart devirtualizes too).

## Slices
A. the layouter: closure base struct + per-arity vtable structs + registry (types.jl).
B. closure ALLOCATION emits {classId, context, vtable-global} (compile_new/closure path).
C. trampolines + vtable globals per closure body.
D. the dynamic call site: call_ref through the vtable (replaces the loud reject).
E. threshold flip 9→2 (staged from march 13b) + the closure-selector exclusion removal.
Gate per slice; the march-13b staging notes anticipate E.
