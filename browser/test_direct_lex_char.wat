(module
  (type (;0;) (func (param f64 f64) (result f64)))
  (type (;1;) (array (mut i32)))
  (type (;2;) (struct (field i64)))
  (type (;3;) (struct (field (mut arrayref))))
  (type (;4;) (struct (field (mut (ref null 1))) (field (mut i32)) (field (mut i32)) (field (mut i32)) (field (mut i32)) (field (mut i32)) (field (mut i64)) (field (mut i64)) (field (mut i64)) (field (mut i64)) (field (mut i64))))
  (type (;5;) (struct))
  (type (;6;) (func))
  (type (;7;) (func (param (ref null 1)) (result externref)))
  (import "Math" "pow" (func (;0;) (type 0)))
  (tag (;0;) (type 6))
  (export "direct_lex_char" (func 1))
  (func (;1;) (type 7) (param (ref null 1)) (result externref)
    (local (ref null 1) (ref null 1) i64 (ref null 2) (ref null 1) i64 i64 i32 i64 i32 (ref null 3) i64 (ref null 4) i64 i32 i64 i64 i64 (ref null 5) (ref null 4) (ref null 4) (ref null 4) (ref null 4) (ref null 1) (ref null 1) (ref null 1) i32 i32)
    local.get 0
    ref.cast (ref null 1)
    local.set 1
    local.get 1
    ref.cast (ref null 1)
    local.set 2
    local.get 1
    array.len
    i64.extend_i32_s
    local.set 3
    local.get 3
    struct.new 2
    ref.cast (ref null 2)
    local.set 4
    local.get 2
    ref.cast (ref null 1)
    local.set 5
    i64.const 1
    local.set 6
    local.get 6
    i64.const 1
    i64.sub
    local.set 7
    i32.const 0
    local.set 8
    local.get 4
    struct.get 2 0
    local.set 9
    i64.const 9223372036854775807
    local.get 9
    i64.lt_s
    local.set 10
    local.get 10
    if (result externref) ;; label = @1
      unreachable
      local.set 11
      local.get 11
      throw 0
    else
      local.get 5
      array.len
      i64.extend_i32_s
      local.set 12
      local.get 5
      i32.const 0
      i32.const 1
      i32.const 0
      i32.const 1
      i32.const 0
      local.get 12
      i64.const 9223372036854775807
      i64.const 1
      i64.const 0
      i64.const -1
      struct.new 4
      ref.cast (ref null 4)
      local.set 13
      local.get 13
      local.get 7
      struct.set 4 9
      local.get 7
      drop
      local.get 7
      i64.const 1
      i64.add
      local.set 14
      local.get 13
      local.get 14
      struct.set 4 8
      local.get 14
      drop
      i32.const 0
      local.set 15
      local.get 4
      struct.get 2 0
      local.set 16
      local.get 16
      local.get 7
      i64.add
      local.set 17
      local.get 13
      local.get 17
      struct.set 4 6
      local.get 17
      local.set 18
      struct.new 5
      i32.const 76
      i32.const 101
      i32.const 120
      i32.const 101
      i32.const 114
      array.new_fixed 1 5
      unreachable
      ref.cast (ref null 5)
      local.set 19
      local.get 13
      unreachable
      ref.cast (ref null 4)
      local.set 20
      local.get 20
      i32.const 99
      i32.const 104
      i32.const 97
      i32.const 114
      i32.const 115
      array.new_fixed 1 5
      unreachable
      ref.cast (ref null 4)
      local.set 21
      local.get 21
      i64.const 2
      unreachable
      ref.cast (ref null 4)
      local.set 22
      local.get 22
      unreachable
      ref.cast (ref null 4)
      local.set 23
      local.get 23
      extern.convert_any
      return
    end
    unreachable
  )
)
