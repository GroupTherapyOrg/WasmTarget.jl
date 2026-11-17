;; The runner's patched fixtures (spec v17 Y1), hand-written: each constant is a float immediate whose 4 or 8 raw bytes
;; the driver overwrites with bits it draws each run (dev/climb/measure.py run_input), at the offsets
;; test/fixtures/runner_patch.tsv names, so the exact raw wire each call must produce follows from the drawn bits and no
;; runner can answer it from bytes it has seen. Assembled by test/fixtures/make_fixtures.py (wasm-tools parse), once;
;; nothing assembles at run or test time. Each sentinel is a NaN payload no other byte of the module repeats. A trap
;; and a wasm exception under the module's one exported tag live in the same drawn bytes, so a runner that spares the
;; bytes it knows lies on them too.
(module
  (tag $t (export "tag"))
  (func (export "p_i32") (result i32) (i32.reinterpret_f32 (f32.const nan:0x135724)))
  (func (export "p_i64") (result i64) (i64.reinterpret_f64 (f64.const nan:0x1357246813579)))
  (func (export "p_f32") (result f32) (f32.const nan:0x246813))
  (func (export "p_f64") (result f64) (f64.const nan:0x2468135792468))
  (func (export "p_add") (param i64) (result i64) (i64.add (local.get 0) (i64.reinterpret_f64 (f64.const nan:0x3579246813579))))
  (func (export "p_trap") unreachable)
  (func (export "p_throw") (throw $t))
)
