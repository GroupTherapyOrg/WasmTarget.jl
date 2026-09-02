;; Native linear-memory sidecar prototype (Phase 10.2, dev/PARITY_MASTER.md
;; roadmap item 3). Hand-written, no libc. This module owns its OWN linear
;; memory and exposes only scalar accessors + one compute entry — the shape
;; dart2wasm's ffiMemory / Pointer<T> boundary uses (parity below).
;;
;; parity(functions.dart:90 FunctionCollector.getFunction wasm:import/export;
;;        translator.dart:213 ffiMemory — a lazily-imported "ffi"."memory";
;;        intrinsics.dart:1630-1740 — dart emits INLINE f64.load/f64.store for
;;        scalar Pointer<T> access, exactly as this module's store_f64/load_f64
;;        bodies do). WasmTarget's builder has no scalar memory opcodes yet
;;        (bulk memory ops only), so the WT-side caller reaches these through
;;        accessor CALLS rather than inline loads/stores — the prototype's
;;        quarantine boundary until instr_builder.jl grows f64_load!/f64_store!
;;        mirroring intrinsics.dart:1656-1737.
;;
;; Ownership rule: this memory is per-call SCRATCH. No pointer or reference
;; ever crosses the host boundary — only i32 byte offsets and f64 scalars
;; (both plain numeric wasm value types, so `translate_external_type` maps
;; them to themselves unchanged; no GC ref, no shared object model with the
;; caller). `reset` rewinds the bump pointer to 0 between calls; nothing here
;; persists across a reset.
(module
  (memory (export "memory") 1)

  ;; Bump allocator state: byte offset of the next free cell.
  (global $bump (mut i32) (i32.const 0))

  ;; alloc(bytes) -> ptr. Returns the offset of a fresh `bytes`-byte region
  ;; and advances the bump pointer past it. No bounds checking (1 page =
  ;; 64KiB is ample for this prototype's differential cases).
  (func (export "alloc") (param $bytes i32) (result i32)
    (local $ptr i32)
    (local.set $ptr (global.get $bump))
    (global.set $bump (i32.add (global.get $bump) (local.get $bytes)))
    (local.get $ptr))

  ;; reset() rewinds the bump pointer to 0, discarding every allocation made
  ;; since the last reset (or module instantiation). Proves no state leaks
  ;; between calls to `daxpy` sharing one module instance.
  (func (export "reset")
    (global.set $bump (i32.const 0)))

  ;; store_f64(ptr, v): linear-memory scalar write. Mirrors dart2wasm's
  ;; inline f64.store for Pointer<Double>[i] = v (intrinsics.dart:1656).
  (func (export "store_f64") (param $ptr i32) (param $v f64)
    (f64.store (local.get $ptr) (local.get $v)))

  ;; load_f64(ptr) -> v: linear-memory scalar read. Mirrors dart2wasm's
  ;; inline f64.load for Pointer<Double>[i] (intrinsics.dart:1656).
  (func (export "load_f64") (param $ptr i32) (result f64)
    (f64.load (local.get $ptr)))

  ;; daxpy(n, a, x, y): y[i] = a*x[i] + y[i] for i in 0..n, in place over the
  ;; f64 regions at byte offsets x and y. No libc, no bulk-memory ops — a
  ;; straight-line scalar loop, same shape as a compiled dart Pointer<T> loop.
  (func (export "daxpy") (param $n i32) (param $a f64) (param $x i32) (param $y i32)
    (local $i i32)
    (local $xp i32)
    (local $yp i32)
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
        (local.set $xp (i32.add (local.get $x) (i32.mul (local.get $i) (i32.const 8))))
        (local.set $yp (i32.add (local.get $y) (i32.mul (local.get $i) (i32.const 8))))
        (f64.store (local.get $yp)
          (f64.add
            (f64.mul (local.get $a) (f64.load (local.get $xp)))
            (f64.load (local.get $yp))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop))))
)
