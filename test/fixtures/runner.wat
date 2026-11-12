;; The runner's fixtures (spec v16 X1), hand-written: each export returns, or passes back, a value of one of the judge's
;; leaf kinds (test/verdict.jl) at an edge, so a lossy marshal (two wasm values to one wire value) shows as a fixture's
;; wrong line. Assembled by `wasm-tools parse test/fixtures/runner.wat`; its bytes and each call's exact raw wire are
;; test/fixtures/runner_calls.tsv and runner_raw.tsv, both the judge's (G5).
(module
  (type $pair (struct (field i64) (field f64)))
  (type $nest (struct (field (ref $pair)) (field (ref null $pair))))
  (tag $exc (export "exc"))
  (global $n (mut i32) (i32.const 0))
  (func (export "i32") (param i32) (result i32) local.get 0)
  (func (export "i64") (param i64) (result i64) local.get 0)
  (func (export "f32") (param f32) (result f32) local.get 0)
  (func (export "f64") (param f64) (result f64) local.get 0)
  ;; a signaling NaN made in wasm and returned: its bits must leave unquieted
  (func (export "snan32") (result f32) f32.const nan:0x200000 f32.neg)
  (func (export "snan64") (result f64) (f64.reinterpret_i64 (i64.const 0x7ff4000000000001)))
  ;; a float argument's bits, read inside wasm: the argument reached its parameter unquieted
  (func (export "bits32") (param f32) (result i32) local.get 0 i32.reinterpret_f32)
  (func (export "bits64") (param f64) (result i64) local.get 0 i64.reinterpret_f64)
  ;; a nested aggregate returned by reference, and a reader of its leaves by index (a reader's shape: the answer's own
  ;; call inside wasm, the leaf picked by k)
  (func $make (param i64) (result (ref $nest))
    (struct.new $nest (struct.new $pair (local.get 0) (f64.const -0x0p+0)) (ref.null $pair)))
  (func (export "nest") (param i64) (result (ref null $nest)) (call $make (local.get 0)))
  (func (export "nest_i64") (param i64 i64) (result i64)
    (struct.get $pair 0 (struct.get $nest 0 (call $make (local.get 0)))))
  (func (export "nest_f64") (param i64 i64) (result f64)
    (struct.get $pair 1 (struct.get $nest 0 (call $make (local.get 0)))))
  (func (export "nest_null") (param i64 i64) (result i32)
    (ref.is_null (struct.get $nest 1 (call $make (local.get 0)))))
  ;; a String's leaves as readers read them: its ncodeunits (an i64) and each codeunit (a UInt8 in an i32), here "" and "é"
  (func (export "ncu") (param i64) (result i64) (select (i64.const 0) (i64.const 2) (i64.eqz (local.get 0))))
  (func (export "cu") (param i64) (result i32) (select (i32.const 0xc3) (i32.const 0xa9) (i64.eq (local.get 0) (i64.const 1))))
  (func (export "void"))
  (func (export "null") (result anyref) ref.null any)
  (func (export "ref") (result anyref) (ref.i31 (i32.const 1)))
  (func (export "throws") (param i32) (result i32) throw $exc)
  (func (export "traps") (result i32) unreachable)
  ;; a counter in the instance's global: every call must read 1, a fresh instance each (spec v16 X1, red's p5)
  (func (export "count") (result i32) (global.set $n (i32.add (global.get $n) (i32.const 1))) (global.get $n))
)
