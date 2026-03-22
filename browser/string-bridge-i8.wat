(module
  ;; String type: packed i8 array (matches WasmTarget.jl's string representation)
  (type $string (array (mut i8)))

  ;; Create a new string of given byte length
  (func (export "str_new") (param $len i32) (result (ref $string))
    local.get $len
    array.new_default $string
  )

  ;; Set a byte at 0-based index
  (func (export "str_setbyte!") (param $arr (ref $string)) (param $idx i32) (param $val i32)
    local.get $arr
    local.get $idx
    local.get $val
    array.set $string
  )

  ;; Get a byte at 0-based index (unsigned)
  (func (export "str_byte") (param $arr (ref $string)) (param $idx i32) (result i32)
    local.get $arr
    local.get $idx
    array.get_u $string
  )

  ;; Get array length (number of bytes)
  (func (export "str_len") (param $arr (ref $string)) (result i32)
    local.get $arr
    array.len
  )
)
