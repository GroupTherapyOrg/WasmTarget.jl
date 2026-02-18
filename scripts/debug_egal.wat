(module
  (type (;0;) (func (param f64 f64) (result f64)))
  (type (;1;) (struct (field i32)))
  (type (;2;) (struct (field i64)))
  (type (;3;) (struct (field f32)))
  (type (;4;) (struct (field f64)))
  (type (;5;) (array (mut i32)))
  (type (;6;) (struct (field (mut (ref null 5))) (field (mut externref)) (field (mut externref))))
  (type (;7;) (struct (field (mut (ref null 6))) (field (mut externref)) (field (mut externref)) (field (mut i32)) (field (mut i64)) (field (mut i64)) (field (mut i32))))
  (type (;8;) (array (mut (ref null 7))))
  (type (;9;) (struct (field (mut (ref null 8))) (field (mut (ref null 2)))))
  (type (;10;) (struct (field (mut (ref null 9))) (field (mut i64))))
  (type (;11;) (struct (field (mut (ref null 6))) (field (mut externref))))
  (type (;12;) (struct))
  (type (;13;) (array (mut externref)))
  (type (;14;) (struct (field (mut externref)) (field (mut externref)) (field (mut i64)) (field (mut i64))))
  (type (;15;) (struct (field (mut (ref null 5))) (field (mut (ref null 12))) (field (mut (ref null 5))) (field (mut (ref null 13))) (field (mut i64)) (field (mut i64)) (field (mut externref)) (field (mut externref)) (field (mut (ref null 13))) (field (mut (ref null 14))) (field (mut externref)) (field (mut i64)) (field (mut i32)) (field (mut i32)) (field (mut i32)) (field (mut i32)) (field (mut i32)) (field (mut i32))))
  (type (;16;) (struct (field (mut (ref null 15))) (field (mut structref)) (field (mut (ref null 13))) (field (mut (ref null 13))) (field (mut externref)) (field (mut i64)) (field (mut i32)) (field (mut i32))))
  (type (;17;) (func (param externref externref) (result i32)))
  (type (;18;) (struct (field (mut externref)) (field (mut externref))))
  (type (;19;) (func (param externref externref (ref null 10) i64) (result i32)))
  (type (;20;) (func (param (ref null 10) (ref null 6)) (result (ref null 7))))
  (type (;21;) (func (param (ref null 6) i32) (result (ref null 7))))
  (type (;22;) (func (param (ref null 7) externref (ref null 10) i64) (result i32)))
  (type (;23;) (func (param (ref null 7) externref (ref null 10) i32 i64) (result i32)))
  (type (;24;) (func (param (ref null 7) (ref null 10) i64) (result i64)))
  (type (;25;) (struct (field (mut (ref null 9))) (field (mut i64)) (field (mut i64)) (field (mut i64)) (field (mut i64)) (field (mut i64)) (field (mut (ref null 8))) (field (mut (ref null 8)))))
  (type (;26;) (struct (field (mut arrayref))))
  (type (;27;) (func))
  (type (;28;) (func (param externref (ref null 11) (ref null 10) i32 i64) (result i32)))
  (type (;29;) (func (param externref externref (ref null 10) i32 i64) (result i32)))
  (type (;30;) (func (param externref) (result i32)))
  (type (;31;) (func (param externref (ref null 6)) (result i32)))
  (type (;32;) (func (param (ref null 16) (ref null 16) (ref null 10) i64) (result i32)))
  (type (;33;) (func (param externref externref (ref null 10)) (result i32)))
  (type (;34;) (func (param (ref null 16) (ref null 16)) (result i32)))
  (type (;35;) (func (param externref externref) (result externref)))
  (type (;36;) (func (param externref externref i64) (result externref)))
  (type (;37;) (func (param (ref null 16) (ref null 16) i64) (result externref)))
  (type (;38;) (struct (field (mut (ref null 13))) (field (mut (ref null 2)))))
  (type (;39;) (struct (field (ref null 16))))
  (type (;40;) (struct (field (mut i64)) (field (mut i64))))
  (type (;41;) (struct (field (mut (ref null 38))) (field (mut (ref null 40))) (field (mut i32))))
  (type (;42;) (func (param externref) (result (ref null 41))))
  (type (;43;) (func (result i32)))
  (import "Math" "pow" (func (;0;) (type 0)))
  (tag (;0;) (type 27))
  (global (;0;) (mut (ref 16)) struct.new_default 16)
  (global (;1;) (mut (ref 16)) struct.new_default 16)
  (global (;2;) (mut (ref 15)) struct.new_default 15)
  (global (;3;) (mut (ref 16)) struct.new_default 16)
  (global (;4;) (mut (ref 15)) struct.new_default 15)
  (global (;5;) (mut (ref 16)) struct.new_default 16)
  (global (;6;) (mut (ref 15)) struct.new_default 15)
  (global (;7;) (mut (ref 16)) struct.new_default 16)
  (global (;8;) (mut (ref 15)) struct.new_default 15)
  (global (;9;) (mut (ref 16)) struct.new_default 16)
  (global (;10;) (mut (ref 15)) struct.new_default 15)
  (global (;11;) (mut (ref 16)) struct.new_default 16)
  (global (;12;) (mut (ref 15)) struct.new_default 15)
  (global (;13;) (mut (ref 16)) struct.new_default 16)
  (global (;14;) (mut (ref 15)) struct.new_default 15)
  (global (;15;) (mut (ref 16)) struct.new_default 16)
  (global (;16;) (mut (ref 15)) struct.new_default 15)
  (export "wasm_subtype" (func 1))
  (export "_subtype" (func 2))
  (export "lookup" (func 3))
  (export "VarBinding" (func 4))
  (export "_var_lt" (func 5))
  (export "_var_gt" (func 6))
  (export "_subtype_var" (func 7))
  (export "_record_var_occurrence" (func 8))
  (export "_subtype_unionall" (func 9))
  (export "_subtype_inner" (func 10))
  (export "_is_leaf_bound" (func 11))
  (export "_type_contains_var" (func 12))
  (export "_subtype_check" (func 13))
  (export "_subtype_datatypes" (func 14))
  (export "_forall_exists_equal" (func 15))
  (export "_tuple_subtype_env" (func 16))
  (export "_subtype_tuple_param" (func 17))
  (export "_datatype_subtype" (func 18))
  (export "_tuple_subtype" (func 19))
  (export "_subtype_param" (func 20))
  (export "wasm_type_intersection" (func 21))
  (export "_no_free_typevars" (func 22))
  (export "_intersect" (func 23))
  (export "_simple_join" (func 24))
  (export "_intersect_datatypes" (func 25))
  (export "_intersect_tuple" (func 26))
  (export "_intersect_same_name" (func 27))
  (export "_intersect_invariant" (func 28))
  (export "_intersect_different_names" (func 29))
  (export "wasm_matching_methods" (func 30))
  (export "test_egal_globals" (func 31))
  (export "test_egal_return" (func 32))
  (export "test_isect_1" (func 33))
  (start 34)
  (func (;1;) (type 17) (param externref externref) (result i32)
    (local i32 i32 i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32 eqref eqref eqref)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          local.get 0
          local.get 1
          any.convert_extern
          ref.cast eqref
          local.set 10
          any.convert_extern
          ref.cast eqref
          local.get 10
          ref.eq
          local.set 2
          local.get 2
          i32.eqz
          br_if 0 (;@3;)
          i32.const 1
          return
        end
        local.get 0
        global.get 0
        local.set 11
        any.convert_extern
        ref.cast eqref
        local.get 11
        ref.eq
        local.set 3
        local.get 3
        i32.eqz
        br_if 0 (;@2;)
        i32.const 1
        return
      end
      local.get 1
      global.get 1
      local.set 12
      any.convert_extern
      ref.cast eqref
      local.get 12
      ref.eq
      local.set 4
      local.get 4
      i32.eqz
      br_if 0 (;@1;)
      i32.const 1
      return
    end
    i32.const 16
    array.new_default 8
    ref.cast (ref null 8)
    local.set 5
    local.get 5
    ref.cast (ref null 8)
    local.set 6
    local.get 6
    i64.const 0
    struct.new 2
    struct.new 9
    ref.cast (ref null 9)
    local.set 7
    local.get 7
    i64.const 0
    struct.new 10
    ref.cast (ref null 10)
    local.set 8
    local.get 0
    local.get 1
    local.get 8
    i64.const 0
    call 2
    local.set 9
    local.get 9
    return
    unreachable
  )
  (func (;2;) (type 19) (param externref externref (ref null 10) i64) (result i32)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 (ref null 18) externref i32 (ref null 18) externref i32 i32 (ref null 18) externref i32 (ref null 18) externref i32 i32 (ref null 6) (ref null 7) i32 (ref null 6) (ref null 6) (ref null 7) i32 i32 i32 i32 i32 (ref null 7) (ref null 7) i32 i32 (ref null 7) (ref null 7) externref externref i32 (ref null 6) (ref null 7) i32 i64 i32 i64 i64 i32 i64 i64 i64 i64 i32 i64 i64 i32 externref i32 (ref null 6) externref i32 i32 externref i32 i32 (ref null 6) externref i32 (ref null 6) (ref null 7) i32 i64 i32 i64 i64 i32 i64 i64 i64 i64 i32 i64 i64 i32 externref i32 (ref null 6) externref i32 externref i32 i32 (ref null 16) externref i32 (ref null 6) (ref null 7) externref i32 (ref null 6) (ref null 7) externref i32 i32 i32 (ref null 6) (ref null 7) i32 i64 i32 i64 i64 i32 i64 i64 i64 i64 i32 i64 i64 i32 externref i32 (ref null 6) externref i32 i32 externref i32 i32 (ref null 6) externref i32 i32 i32 (ref null 6) (ref null 7) i32 i64 i32 i64 i64 i32 i64 i64 i64 i64 i32 i64 i64 i32 externref i32 (ref null 6) externref i32 externref i32 i32 (ref null 16) externref i32 (ref null 6) (ref null 6) i32 i32 i32 (ref null 7) i32 i64 i32 i64 i64 i32 i64 i64 i64 i64 i32 i64 i64 i32 i32 i32 externref i32 (ref null 7) externref i32 i32 externref i32 i32 (ref null 7) externref i32 (ref null 6) externref i32 i32 (ref null 6) (ref null 7) i32 i32 (ref null 7) i32 i64 i32 i64 i64 i32 i64 i64 i64 i64 i32 i64 i64 i32 i32 i32 externref i32 (ref null 7) externref i32 externref i32 i32 i32 i32 externref externref i32 externref externref externref externref i32 externref externref externref externref (ref null 16) externref i32 (ref null 6) externref i32 i32 (ref null 11) i32 i32 (ref null 11) i32 i32 i32 (ref null 16) (ref null 16) i32 eqref eqref eqref eqref eqref eqref eqref eqref eqref eqref eqref eqref eqref eqref)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  block ;; label = @8
                    block ;; label = @9
                      block ;; label = @10
                        block ;; label = @11
                          block ;; label = @12
                            block ;; label = @13
                              block ;; label = @14
                                block ;; label = @15
                                  block ;; label = @16
                                    block ;; label = @17
                                      block ;; label = @18
                                        block ;; label = @19
                                          block ;; label = @20
                                            block ;; label = @21
                                              block ;; label = @22
                                                block ;; label = @23
                                                  block ;; label = @24
                                                    block ;; label = @25
                                                      block ;; label = @26
                                                        block ;; label = @27
                                                          block ;; label = @28
                                                            block ;; label = @29
                                                              block ;; label = @30
                                                                block ;; label = @31
                                                                  block ;; label = @32
                                                                    block ;; label = @33
                                                                      block ;; label = @34
                                                                        block ;; label = @35
                                                                          block ;; label = @36
                                                                            block ;; label = @37
                                                                              block ;; label = @38
                                                                                block ;; label = @39
                                                                                  block ;; label = @40
                                                                                    block ;; label = @41
                                                                                      block ;; label = @42
                                                                                        block ;; label = @43
                                                                                          block ;; label = @44
                                                                                            block ;; label = @45
                                                                                              block ;; label = @46
                                                                                                block ;; label = @47
                                                                                                  block ;; label = @48
                                                                                                    block ;; label = @49
                                                                                                    block ;; label = @50
                                                                                                    block ;; label = @51
                                                                                                    block ;; label = @52
                                                                                                    block ;; label = @53
                                                                                                    block ;; label = @54
                                                                                                    block ;; label = @55
                                                                                                    block ;; label = @56
                                                                                                    block ;; label = @57
                                                                                                    block ;; label = @58
                                                                                                    block ;; label = @59
                                                                                                    block ;; label = @60
                                                                                                    block ;; label = @61
                                                                                                    block ;; label = @62
                                                                                                    block ;; label = @63
                                                                                                    block ;; label = @64
                                                                                                    block ;; label = @65
                                                                                                    block ;; label = @66
                                                                                                    block ;; label = @67
                                                                                                    block ;; label = @68
                                                                                                    block ;; label = @69
                                                                                                    block ;; label = @70
                                                                                                    block ;; label = @71
                                                                                                    block ;; label = @72
                                                                                                    block ;; label = @73
                                                                                                    block ;; label = @74
                                                                                                    block ;; label = @75
                                                                                                    block ;; label = @76
                                                                                                    block ;; label = @77
                                                                                                    block ;; label = @78
                                                                                                    block ;; label = @79
                                                                                                    block ;; label = @80
                                                                                                    block ;; label = @81
                                                                                                    block ;; label = @82
                                                                                                    block ;; label = @83
                                                                                                    block ;; label = @84
                                                                                                    block ;; label = @85
                                                                                                    block ;; label = @86
                                                                                                    block ;; label = @87
                                                                                                    block ;; label = @88
                                                                                                    block ;; label = @89
                                                                                                    local.get 0
                                                                                                    local.get 1
                                                                                                    any.convert_extern
                                                                                                    ref.cast eqref
                                                                                                    local.set 268
                                                                                                    any.convert_extern
                                                                                                    ref.cast eqref
                                                                                                    local.get 268
                                                                                                    ref.eq
                                                                                                    local.set 10
                                                                                                    local.get 10
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@89;)
                                                                                                    i32.const 1
                                                                                                    return
                                                                                                    end
                                                                                                    local.get 0
                                                                                                    global.get 0
                                                                                                    local.set 269
                                                                                                    any.convert_extern
                                                                                                    ref.cast eqref
                                                                                                    local.get 269
                                                                                                    ref.eq
                                                                                                    local.set 11
                                                                                                    local.get 11
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@88;)
                                                                                                    i32.const 1
                                                                                                    return
                                                                                                    end
                                                                                                    local.get 1
                                                                                                    global.get 1
                                                                                                    local.set 270
                                                                                                    any.convert_extern
                                                                                                    ref.cast eqref
                                                                                                    local.get 270
                                                                                                    ref.eq
                                                                                                    local.set 12
                                                                                                    local.get 12
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@87;)
                                                                                                    i32.const 1
                                                                                                    return
                                                                                                    end
                                                                                                    local.get 0
                                                                                                    any.convert_extern
                                                                                                    ref.test (ref 18)
                                                                                                    local.set 13
                                                                                                    local.get 13
                                                                                                    i32.eqz
                                                                                                    br_if 1 (;@85;)
                                                                                                    local.get 0
                                                                                                    any.convert_extern
                                                                                                    ref.cast (ref null 18)
                                                                                                    local.set 14
                                                                                                    local.get 14
                                                                                                    struct.get 18 0
                                                                                                    local.set 15
                                                                                                    local.get 15
                                                                                                    local.get 1
                                                                                                    local.get 2
                                                                                                    local.get 3
                                                                                                    call 2
                                                                                                    local.set 16
                                                                                                    local.get 16
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@86;)
                                                                                                    local.get 0
                                                                                                    any.convert_extern
                                                                                                    ref.cast (ref null 18)
                                                                                                    local.set 17
                                                                                                    local.get 17
                                                                                                    struct.get 18 1
                                                                                                    local.set 18
                                                                                                    local.get 18
                                                                                                    local.get 1
                                                                                                    local.get 2
                                                                                                    local.get 3
                                                                                                    call 2
                                                                                                    local.set 19
                                                                                                    local.get 19
                                                                                                    return
                                                                                                    end
                                                                                                    i32.const 0
                                                                                                    return
                                                                                                    end
                                                                                                    local.get 1
                                                                                                    any.convert_extern
                                                                                                    ref.test (ref 18)
                                                                                                    local.set 20
                                                                                                    local.get 20
                                                                                                    i32.eqz
                                                                                                    br_if 1 (;@83;)
                                                                                                    local.get 1
                                                                                                    any.convert_extern
                                                                                                    ref.cast (ref null 18)
                                                                                                    local.set 21
                                                                                                    local.get 21
                                                                                                    struct.get 18 0
                                                                                                    local.set 22
                                                                                                    local.get 0
                                                                                                    local.get 22
                                                                                                    local.get 2
                                                                                                    local.get 3
                                                                                                    call 2
                                                                                                    local.set 23
                                                                                                    local.get 23
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@84;)
                                                                                                    local.get 23
                                                                                                    return
                                                                                                    end
                                                                                                    local.get 1
                                                                                                    any.convert_extern
                                                                                                    ref.cast (ref null 18)
                                                                                                    local.set 24
                                                                                                    local.get 24
                                                                                                    struct.get 18 1
                                                                                                    local.set 25
                                                                                                    local.get 0
                                                                                                    local.get 25
                                                                                                    local.get 2
                                                                                                    local.get 3
                                                                                                    call 2
                                                                                                    local.set 26
                                                                                                    local.get 26
                                                                                                    return
                                                                                                    end
                                                                                                    local.get 0
                                                                                                    any.convert_extern
                                                                                                    ref.test (ref 6)
                                                                                                    local.set 27
                                                                                                    local.get 27
                                                                                                    i32.eqz
                                                                                                    br_if 62 (;@20;)
                                                                                                    local.get 0
                                                                                                    any.convert_extern
                                                                                                    ref.cast (ref null 6)
                                                                                                    local.set 28
                                                                                                    local.get 2
                                                                                                    local.get 28
                                                                                                    call 3
                                                                                                    ref.cast (ref null 7)
                                                                                                    local.set 29
                                                                                                    local.get 1
                                                                                                    any.convert_extern
                                                                                                    ref.test (ref 6)
                                                                                                    local.set 30
                                                                                                    local.get 30
                                                                                                    i32.eqz
                                                                                                    br_if 50 (;@32;)
                                                                                                    local.get 0
                                                                                                    any.convert_extern
                                                                                                    ref.cast (ref null 6)
                                                                                                    local.set 31
                                                                                                    local.get 1
                                                                                                    any.convert_extern
                                                                                                    ref.cast (ref null 6)
                                                                                                    local.set 32
                                                                                                    local.get 2
                                                                                                    local.get 32
                                                                                                    call 3
                                                                                                    ref.cast (ref null 7)
                                                                                                    local.set 33
                                                                                                    local.get 31
                                                                                                    local.get 32
                                                                                                    ref.eq
                                                                                                    local.set 34
                                                                                                    local.get 34
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@82;)
                                                                                                    i32.const 1
                                                                                                    return
                                                                                                    end
                                                                                                    local.get 29
                                                                                                    ref.is_null
                                                                                                    local.set 35
                                                                                                    local.get 35
                                                                                                    i32.eqz
                                                                                                    local.set 36
                                                                                                    local.get 36
                                                                                                    i32.eqz
                                                                                                    br_if 25 (;@56;)
                                                                                                    local.get 33
                                                                                                    ref.is_null
                                                                                                    local.set 37
                                                                                                    local.get 37
                                                                                                    i32.eqz
                                                                                                    local.set 38
                                                                                                    local.get 38
                                                                                                    i32.eqz
                                                                                                    br_if 25 (;@56;)
                                                                                                    local.get 33
                                                                                                    local.set 39
                                                                                                    local.get 29
                                                                                                    local.set 40
                                                                                                    local.get 40
                                                                                                    struct.get 7 3
                                                                                                    local.set 41
                                                                                                    local.get 39
                                                                                                    struct.get 7 3
                                                                                                    local.set 42
                                                                                                    local.get 41
                                                                                                    i32.eqz
                                                                                                    br_if 11 (;@70;)
                                                                                                    local.get 42
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@81;)
                                                                                                    local.get 33
                                                                                                    local.set 43
                                                                                                    local.get 29
                                                                                                    local.set 44
                                                                                                    local.get 44
                                                                                                    struct.get 7 1
                                                                                                    local.set 45
                                                                                                    local.get 43
                                                                                                    struct.get 7 2
                                                                                                    local.set 46
                                                                                                    local.get 45
                                                                                                    local.get 46
                                                                                                    local.get 2
                                                                                                    i64.const 0
                                                                                                    call 2
                                                                                                    local.set 47
                                                                                                    local.get 47
                                                                                                    return
                                                                                                    end
                                                                                                    local.get 1
                                                                                                    any.convert_extern
                                                                                                    ref.cast (ref null 6)
                                                                                                    local.set 48
                                                                                                    local.get 29
                                                                                                    local.set 49
                                                                                                    local.get 3
                                                                                                    i64.const 2
                                                                                                    i64.eq
                                                                                                    local.set 50
                                                                                                    local.get 50
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@80;)
                                                                                                    br 2 (;@78;)
                                                                                                    end
                                                                                                    local.get 2
                                                                                                    struct.get 10 1
                                                                                                    local.set 51
                                                                                                    i64.const 0
                                                                                                    local.get 51
                                                                                                    i64.lt_s
                                                                                                    local.set 52
                                                                                                    local.get 52
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@79;)
                                                                                                    br 1 (;@78;)
                                                                                                    end
                                                                                                    local.get 49
                                                                                                    struct.get 7 5
                                                                                                    local.set 53
                                                                                                    local.get 53
                                                                                                    i64.const 1
                                                                                                    i64.add
                                                                                                    local.set 54
                                                                                                    i64.const 2
                                                                                                    local.get 54
                                                                                                    i64.lt_s
                                                                                                    local.set 55
                                                                                                    i64.const 2
                                                                                                    local.get 54
                                                                                                    local.get 55
                                                                                                    select
                                                                                                    local.set 56
                                                                                                    local.get 49
                                                                                                    local.get 56
                                                                                                    struct.set 7 5
                                                                                                    local.get 56
                                                                                                    local.set 57
                                                                                                    br 1 (;@77;)
                                                                                                    end
                                                                                                    local.get 49
                                                                                                    struct.get 7 4
                                                                                                    local.set 58
                                                                                                    local.get 58
                                                                                                    i64.const 1
                                                                                                    i64.add
                                                                                                    local.set 59
                                                                                                    i64.const 2
                                                                                                    local.get 59
                                                                                                    i64.lt_s
                                                                                                    local.set 60
                                                                                                    i64.const 2
                                                                                                    local.get 59
                                                                                                    local.get 60
                                                                                                    select
                                                                                                    local.set 61
                                                                                                    local.get 49
                                                                                                    local.get 61
                                                                                                    struct.set 7 4
                                                                                                    local.get 61
                                                                                                    local.set 62
                                                                                                    br 0 (;@77;)
                                                                                                    end
                                                                                                    local.get 49
                                                                                                    struct.get 7 3
                                                                                                    local.set 63
                                                                                                    local.get 63
                                                                                                    i32.eqz
                                                                                                    br_if 4 (;@72;)
                                                                                                    local.get 49
                                                                                                    struct.get 7 2
                                                                                                    local.set 64
                                                                                                    local.get 64
                                                                                                    global.get 1
                                                                                                    local.set 271
                                                                                                    any.convert_extern
                                                                                                    ref.cast eqref
                                                                                                    local.get 271
                                                                                                    ref.eq
                                                                                                    local.set 65
                                                                                                    local.get 65
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@76;)
                                                                                                    local.get 49
                                                                                                    local.get 48
                                                                                                    extern.convert_any
                                                                                                    struct.set 7 2
                                                                                                    local.get 48
                                                                                                    ref.cast (ref null 6)
                                                                                                    local.set 66
                                                                                                    br 3 (;@73;)
                                                                                                    end
                                                                                                    local.get 49
                                                                                                    struct.get 7 2
                                                                                                    local.set 67
                                                                                                    local.get 48
                                                                                                    extern.convert_any
                                                                                                    local.get 67
                                                                                                    local.get 2
                                                                                                    i64.const 0
                                                                                                    call 2
                                                                                                    local.set 68
                                                                                                    local.get 68
                                                                                                    i32.eqz
                                                                                                    local.set 69
                                                                                                    local.get 69
                                                                                                    i32.eqz
                                                                                                    br_if 1 (;@74;)
                                                                                                    local.get 49
                                                                                                    struct.get 7 2
                                                                                                    local.set 70
                                                                                                    local.get 70
                                                                                                    local.get 48
                                                                                                    extern.convert_any
                                                                                                    local.get 2
                                                                                                    i64.const 0
                                                                                                    call 2
                                                                                                    local.set 71
                                                                                                    local.get 71
                                                                                                    i32.eqz
                                                                                                    local.set 72
                                                                                                    local.get 72
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@75;)
                                                                                                    i32.const 0
                                                                                                    local.set 4
                                                                                                    br 4 (;@71;)
                                                                                                    end
                                                                                                    br 1 (;@73;)
                                                                                                    end
                                                                                                    local.get 49
                                                                                                    local.get 48
                                                                                                    extern.convert_any
                                                                                                    struct.set 7 2
                                                                                                    local.get 48
                                                                                                    ref.cast (ref null 6)
                                                                                                    local.set 73
                                                                                                    end
                                                                                                    i32.const 1
                                                                                                    local.set 4
                                                                                                    br 1 (;@71;)
                                                                                                    end
                                                                                                    local.get 49
                                                                                                    struct.get 7 2
                                                                                                    local.set 74
                                                                                                    local.get 74
                                                                                                    local.get 48
                                                                                                    extern.convert_any
                                                                                                    local.get 2
                                                                                                    i64.const 0
                                                                                                    call 2
                                                                                                    local.set 75
                                                                                                    local.get 75
                                                                                                    local.set 4
                                                                                                    br 0 (;@71;)
                                                                                                    end
                                                                                                    local.get 4
                                                                                                    return
                                                                                                    end
                                                                                                    local.get 42
                                                                                                    i32.eqz
                                                                                                    br_if 11 (;@58;)
                                                                                                    local.get 0
                                                                                                    any.convert_extern
                                                                                                    ref.cast (ref null 6)
                                                                                                    local.set 76
                                                                                                    local.get 33
                                                                                                    local.set 77
                                                                                                    local.get 3
                                                                                                    i64.const 2
                                                                                                    i64.eq
                                                                                                    local.set 78
                                                                                                    local.get 78
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@69;)
                                                                                                    br 2 (;@67;)
                                                                                                    end
                                                                                                    local.get 2
                                                                                                    struct.get 10 1
                                                                                                    local.set 79
                                                                                                    i64.const 0
                                                                                                    local.get 79
                                                                                                    i64.lt_s
                                                                                                    local.set 80
                                                                                                    local.get 80
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@68;)
                                                                                                    br 1 (;@67;)
                                                                                                    end
                                                                                                    local.get 77
                                                                                                    struct.get 7 5
                                                                                                    local.set 81
                                                                                                    local.get 81
                                                                                                    i64.const 1
                                                                                                    i64.add
                                                                                                    local.set 82
                                                                                                    i64.const 2
                                                                                                    local.get 82
                                                                                                    i64.lt_s
                                                                                                    local.set 83
                                                                                                    i64.const 2
                                                                                                    local.get 82
                                                                                                    local.get 83
                                                                                                    select
                                                                                                    local.set 84
                                                                                                    local.get 77
                                                                                                    local.get 84
                                                                                                    struct.set 7 5
                                                                                                    local.get 84
                                                                                                    local.set 85
                                                                                                    br 1 (;@66;)
                                                                                                    end
                                                                                                    local.get 77
                                                                                                    struct.get 7 4
                                                                                                    local.set 86
                                                                                                    local.get 86
                                                                                                    i64.const 1
                                                                                                    i64.add
                                                                                                    local.set 87
                                                                                                    i64.const 2
                                                                                                    local.get 87
                                                                                                    i64.lt_s
                                                                                                    local.set 88
                                                                                                    i64.const 2
                                                                                                    local.get 87
                                                                                                    local.get 88
                                                                                                    select
                                                                                                    local.set 89
                                                                                                    local.get 77
                                                                                                    local.get 89
                                                                                                    struct.set 7 4
                                                                                                    local.get 89
                                                                                                    local.set 90
                                                                                                    br 0 (;@66;)
                                                                                                    end
                                                                                                    local.get 77
                                                                                                    struct.get 7 3
                                                                                                    local.set 91
                                                                                                    local.get 91
                                                                                                    i32.eqz
                                                                                                    br_if 5 (;@60;)
                                                                                                    local.get 77
                                                                                                    struct.get 7 1
                                                                                                    local.set 92
                                                                                                    local.get 92
                                                                                                    global.get 0
                                                                                                    local.set 272
                                                                                                    any.convert_extern
                                                                                                    ref.cast eqref
                                                                                                    local.get 272
                                                                                                    ref.eq
                                                                                                    local.set 93
                                                                                                    local.get 93
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@65;)
                                                                                                    local.get 77
                                                                                                    local.get 76
                                                                                                    extern.convert_any
                                                                                                    struct.set 7 1
                                                                                                    local.get 76
                                                                                                    ref.cast (ref null 6)
                                                                                                    local.set 94
                                                                                                    br 4 (;@61;)
                                                                                                    end
                                                                                                    local.get 77
                                                                                                    struct.get 7 1
                                                                                                    local.set 95
                                                                                                    local.get 95
                                                                                                    local.get 76
                                                                                                    local.set 273
                                                                                                    any.convert_extern
                                                                                                    ref.cast eqref
                                                                                                    local.get 273
                                                                                                    ref.eq
                                                                                                    local.set 96
                                                                                                    local.get 96
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@64;)
                                                                                                    br 3 (;@61;)
                                                                                                    end
                                                                                                    local.get 77
                                                                                                    struct.get 7 1
                                                                                                    local.set 97
                                                                                                    local.get 97
                                                                                                    drop
                                                                                                    i32.const 0
                                                                                                    local.set 98
                                                                                                    local.get 98
                                                                                                    i32.eqz
                                                                                                    local.set 99
                                                                                                    local.get 99
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@63;)
                                                                                                    br 1 (;@62;)
                                                                                                    end
                                                                                                    end
                                                                                                    local.get 77
                                                                                                    ref.null extern
                                                                                                    struct.set 7 1
                                                                                                    global.get 1
                                                                                                    ref.cast (ref null 16)
                                                                                                    local.set 100
                                                                                                    end
                                                                                                    i32.const 1
                                                                                                    local.set 5
                                                                                                    br 1 (;@59;)
                                                                                                    end
                                                                                                    local.get 77
                                                                                                    struct.get 7 1
                                                                                                    local.set 101
                                                                                                    local.get 76
                                                                                                    extern.convert_any
                                                                                                    local.get 101
                                                                                                    local.get 2
                                                                                                    i64.const 0
                                                                                                    call 2
                                                                                                    local.set 102
                                                                                                    local.get 102
                                                                                                    local.set 5
                                                                                                    br 0 (;@59;)
                                                                                                    end
                                                                                                    local.get 5
                                                                                                    return
                                                                                                    end
                                                                                                    local.get 1
                                                                                                    any.convert_extern
                                                                                                    ref.cast (ref null 6)
                                                                                                    local.set 103
                                                                                                    local.get 29
                                                                                                    local.set 104
                                                                                                    local.get 104
                                                                                                    struct.get 7 2
                                                                                                    local.set 105
                                                                                                    local.get 105
                                                                                                    local.get 103
                                                                                                    extern.convert_any
                                                                                                    local.get 2
                                                                                                    local.get 3
                                                                                                    call 2
                                                                                                    local.set 106
                                                                                                    local.get 106
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@57;)
                                                                                                    local.get 106
                                                                                                    return
                                                                                                    end
                                                                                                    local.get 0
                                                                                                    any.convert_extern
                                                                                                    ref.cast (ref null 6)
                                                                                                    local.set 107
                                                                                                    local.get 33
                                                                                                    local.set 108
                                                                                                    local.get 108
                                                                                                    struct.get 7 1
                                                                                                    local.set 109
                                                                                                    local.get 107
                                                                                                    extern.convert_any
                                                                                                    local.get 109
                                                                                                    local.get 2
                                                                                                    local.get 3
                                                                                                    call 2
                                                                                                    local.set 110
                                                                                                    local.get 110
                                                                                                    return
                                                                                                    end
                                                                                                    local.get 29
                                                                                                    ref.is_null
                                                                                                    local.set 111
                                                                                                    local.get 111
                                                                                                    i32.eqz
                                                                                                    local.set 112
                                                                                                    local.get 112
                                                                                                    i32.eqz
                                                                                                    br_if 10 (;@45;)
                                                                                                    local.get 1
                                                                                                    any.convert_extern
                                                                                                    ref.cast (ref null 6)
                                                                                                    local.set 113
                                                                                                    local.get 29
                                                                                                    local.set 114
                                                                                                    local.get 3
                                                                                                    i64.const 2
                                                                                                    i64.eq
                                                                                                    local.set 115
                                                                                                    local.get 115
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@55;)
                                                                                                    br 2 (;@53;)
                                                                                                    end
                                                                                                    local.get 2
                                                                                                    struct.get 10 1
                                                                                                    local.set 116
                                                                                                    i64.const 0
                                                                                                    local.get 116
                                                                                                    i64.lt_s
                                                                                                    local.set 117
                                                                                                    local.get 117
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@54;)
                                                                                                    br 1 (;@53;)
                                                                                                    end
                                                                                                    local.get 114
                                                                                                    struct.get 7 5
                                                                                                    local.set 118
                                                                                                    local.get 118
                                                                                                    i64.const 1
                                                                                                    i64.add
                                                                                                    local.set 119
                                                                                                    i64.const 2
                                                                                                    local.get 119
                                                                                                    i64.lt_s
                                                                                                    local.set 120
                                                                                                    i64.const 2
                                                                                                    local.get 119
                                                                                                    local.get 120
                                                                                                    select
                                                                                                    local.set 121
                                                                                                    local.get 114
                                                                                                    local.get 121
                                                                                                    struct.set 7 5
                                                                                                    local.get 121
                                                                                                    local.set 122
                                                                                                    br 1 (;@52;)
                                                                                                    end
                                                                                                    local.get 114
                                                                                                    struct.get 7 4
                                                                                                    local.set 123
                                                                                                    local.get 123
                                                                                                    i64.const 1
                                                                                                    i64.add
                                                                                                    local.set 124
                                                                                                    i64.const 2
                                                                                                    local.get 124
                                                                                                    i64.lt_s
                                                                                                    local.set 125
                                                                                                    i64.const 2
                                                                                                    local.get 124
                                                                                                    local.get 125
                                                                                                    select
                                                                                                    local.set 126
                                                                                                    local.get 114
                                                                                                    local.get 126
                                                                                                    struct.set 7 4
                                                                                                    local.get 126
                                                                                                    local.set 127
                                                                                                    br 0 (;@52;)
                                                                                                    end
                                                                                                    local.get 114
                                                                                                    struct.get 7 3
                                                                                                    local.set 128
                                                                                                    local.get 128
                                                                                                    i32.eqz
                                                                                                    br_if 4 (;@47;)
                                                                                                    local.get 114
                                                                                                    struct.get 7 2
                                                                                                    local.set 129
                                                                                                    local.get 129
                                                                                                    global.get 1
                                                                                                    local.set 274
                                                                                                    any.convert_extern
                                                                                                    ref.cast eqref
                                                                                                    local.get 274
                                                                                                    ref.eq
                                                                                                    local.set 130
                                                                                                    local.get 130
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@51;)
                                                                                                    local.get 114
                                                                                                    local.get 113
                                                                                                    extern.convert_any
                                                                                                    struct.set 7 2
                                                                                                    local.get 113
                                                                                                    ref.cast (ref null 6)
                                                                                                    local.set 131
                                                                                                    br 3 (;@48;)
                                                                                                    end
                                                                                                    local.get 114
                                                                                                    struct.get 7 2
                                                                                                    local.set 132
                                                                                                    local.get 113
                                                                                                    extern.convert_any
                                                                                                    local.get 132
                                                                                                    local.get 2
                                                                                                    i64.const 0
                                                                                                    call 2
                                                                                                    local.set 133
                                                                                                    local.get 133
                                                                                                    i32.eqz
                                                                                                    local.set 134
                                                                                                    local.get 134
                                                                                                    i32.eqz
                                                                                                    br_if 1 (;@49;)
                                                                                                    local.get 114
                                                                                                    struct.get 7 2
                                                                                                    local.set 135
                                                                                                    local.get 135
                                                                                                    local.get 113
                                                                                                    extern.convert_any
                                                                                                    local.get 2
                                                                                                    i64.const 0
                                                                                                    call 2
                                                                                                    local.set 136
                                                                                                    local.get 136
                                                                                                    i32.eqz
                                                                                                    local.set 137
                                                                                                    local.get 137
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@50;)
                                                                                                    i32.const 0
                                                                                                    local.set 6
                                                                                                    br 4 (;@46;)
                                                                                                    end
                                                                                                    br 1 (;@48;)
                                                                                                    end
                                                                                                    local.get 114
                                                                                                    local.get 113
                                                                                                    extern.convert_any
                                                                                                    struct.set 7 2
                                                                                                    local.get 113
                                                                                                    ref.cast (ref null 6)
                                                                                                    local.set 138
                                                                                                  end
                                                                                                  i32.const 1
                                                                                                  local.set 6
                                                                                                  br 1 (;@46;)
                                                                                                end
                                                                                                local.get 114
                                                                                                struct.get 7 2
                                                                                                local.set 139
                                                                                                local.get 139
                                                                                                local.get 113
                                                                                                extern.convert_any
                                                                                                local.get 2
                                                                                                i64.const 0
                                                                                                call 2
                                                                                                local.set 140
                                                                                                local.get 140
                                                                                                local.set 6
                                                                                                br 0 (;@46;)
                                                                                              end
                                                                                              local.get 6
                                                                                              return
                                                                                            end
                                                                                            local.get 33
                                                                                            ref.is_null
                                                                                            local.set 141
                                                                                            local.get 141
                                                                                            i32.eqz
                                                                                            local.set 142
                                                                                            local.get 142
                                                                                            i32.eqz
                                                                                            br_if 11 (;@33;)
                                                                                            local.get 0
                                                                                            any.convert_extern
                                                                                            ref.cast (ref null 6)
                                                                                            local.set 143
                                                                                            local.get 33
                                                                                            local.set 144
                                                                                            local.get 3
                                                                                            i64.const 2
                                                                                            i64.eq
                                                                                            local.set 145
                                                                                            local.get 145
                                                                                            i32.eqz
                                                                                            br_if 0 (;@44;)
                                                                                            br 2 (;@42;)
                                                                                          end
                                                                                          local.get 2
                                                                                          struct.get 10 1
                                                                                          local.set 146
                                                                                          i64.const 0
                                                                                          local.get 146
                                                                                          i64.lt_s
                                                                                          local.set 147
                                                                                          local.get 147
                                                                                          i32.eqz
                                                                                          br_if 0 (;@43;)
                                                                                          br 1 (;@42;)
                                                                                        end
                                                                                        local.get 144
                                                                                        struct.get 7 5
                                                                                        local.set 148
                                                                                        local.get 148
                                                                                        i64.const 1
                                                                                        i64.add
                                                                                        local.set 149
                                                                                        i64.const 2
                                                                                        local.get 149
                                                                                        i64.lt_s
                                                                                        local.set 150
                                                                                        i64.const 2
                                                                                        local.get 149
                                                                                        local.get 150
                                                                                        select
                                                                                        local.set 151
                                                                                        local.get 144
                                                                                        local.get 151
                                                                                        struct.set 7 5
                                                                                        local.get 151
                                                                                        local.set 152
                                                                                        br 1 (;@41;)
                                                                                      end
                                                                                      local.get 144
                                                                                      struct.get 7 4
                                                                                      local.set 153
                                                                                      local.get 153
                                                                                      i64.const 1
                                                                                      i64.add
                                                                                      local.set 154
                                                                                      i64.const 2
                                                                                      local.get 154
                                                                                      i64.lt_s
                                                                                      local.set 155
                                                                                      i64.const 2
                                                                                      local.get 154
                                                                                      local.get 155
                                                                                      select
                                                                                      local.set 156
                                                                                      local.get 144
                                                                                      local.get 156
                                                                                      struct.set 7 4
                                                                                      local.get 156
                                                                                      local.set 157
                                                                                      br 0 (;@41;)
                                                                                    end
                                                                                    local.get 144
                                                                                    struct.get 7 3
                                                                                    local.set 158
                                                                                    local.get 158
                                                                                    i32.eqz
                                                                                    br_if 5 (;@35;)
                                                                                    local.get 144
                                                                                    struct.get 7 1
                                                                                    local.set 159
                                                                                    local.get 159
                                                                                    global.get 0
                                                                                    local.set 275
                                                                                    any.convert_extern
                                                                                    ref.cast eqref
                                                                                    local.get 275
                                                                                    ref.eq
                                                                                    local.set 160
                                                                                    local.get 160
                                                                                    i32.eqz
                                                                                    br_if 0 (;@40;)
                                                                                    local.get 144
                                                                                    local.get 143
                                                                                    extern.convert_any
                                                                                    struct.set 7 1
                                                                                    local.get 143
                                                                                    ref.cast (ref null 6)
                                                                                    local.set 161
                                                                                    br 4 (;@36;)
                                                                                  end
                                                                                  local.get 144
                                                                                  struct.get 7 1
                                                                                  local.set 162
                                                                                  local.get 162
                                                                                  local.get 143
                                                                                  local.set 276
                                                                                  any.convert_extern
                                                                                  ref.cast eqref
                                                                                  local.get 276
                                                                                  ref.eq
                                                                                  local.set 163
                                                                                  local.get 163
                                                                                  i32.eqz
                                                                                  br_if 0 (;@39;)
                                                                                  br 3 (;@36;)
                                                                                end
                                                                                local.get 144
                                                                                struct.get 7 1
                                                                                local.set 164
                                                                                local.get 164
                                                                                drop
                                                                                i32.const 0
                                                                                local.set 165
                                                                                local.get 165
                                                                                i32.eqz
                                                                                local.set 166
                                                                                local.get 166
                                                                                i32.eqz
                                                                                br_if 0 (;@38;)
                                                                                br 1 (;@37;)
                                                                              end
                                                                            end
                                                                            local.get 144
                                                                            ref.null extern
                                                                            struct.set 7 1
                                                                            global.get 1
                                                                            ref.cast (ref null 16)
                                                                            local.set 167
                                                                          end
                                                                          i32.const 1
                                                                          local.set 7
                                                                          br 1 (;@34;)
                                                                        end
                                                                        local.get 144
                                                                        struct.get 7 1
                                                                        local.set 168
                                                                        local.get 143
                                                                        extern.convert_any
                                                                        local.get 168
                                                                        local.get 2
                                                                        i64.const 0
                                                                        call 2
                                                                        local.set 169
                                                                        local.get 169
                                                                        local.set 7
                                                                        br 0 (;@34;)
                                                                      end
                                                                      local.get 7
                                                                      return
                                                                    end
                                                                    local.get 0
                                                                    any.convert_extern
                                                                    ref.cast (ref null 6)
                                                                    local.set 170
                                                                    local.get 1
                                                                    any.convert_extern
                                                                    ref.cast (ref null 6)
                                                                    local.set 171
                                                                    local.get 170
                                                                    local.get 171
                                                                    ref.eq
                                                                    local.set 172
                                                                    local.get 172
                                                                    return
                                                                  end
                                                                  local.get 29
                                                                  ref.is_null
                                                                  local.set 173
                                                                  local.get 173
                                                                  i32.eqz
                                                                  local.set 174
                                                                  local.get 174
                                                                  i32.eqz
                                                                  br_if 10 (;@21;)
                                                                  local.get 29
                                                                  local.set 175
                                                                  local.get 3
                                                                  i64.const 2
                                                                  i64.eq
                                                                  local.set 176
                                                                  local.get 176
                                                                  i32.eqz
                                                                  br_if 0 (;@31;)
                                                                  br 2 (;@29;)
                                                                end
                                                                local.get 2
                                                                struct.get 10 1
                                                                local.set 177
                                                                i64.const 0
                                                                local.get 177
                                                                i64.lt_s
                                                                local.set 178
                                                                local.get 178
                                                                i32.eqz
                                                                br_if 0 (;@30;)
                                                                br 1 (;@29;)
                                                              end
                                                              local.get 175
                                                              struct.get 7 5
                                                              local.set 179
                                                              local.get 179
                                                              i64.const 1
                                                              i64.add
                                                              local.set 180
                                                              i64.const 2
                                                              local.get 180
                                                              i64.lt_s
                                                              local.set 181
                                                              i64.const 2
                                                              local.get 180
                                                              local.get 181
                                                              select
                                                              local.set 182
                                                              local.get 175
                                                              local.get 182
                                                              struct.set 7 5
                                                              local.get 182
                                                              local.set 183
                                                              br 1 (;@28;)
                                                            end
                                                            local.get 175
                                                            struct.get 7 4
                                                            local.set 184
                                                            local.get 184
                                                            i64.const 1
                                                            i64.add
                                                            local.set 185
                                                            i64.const 2
                                                            local.get 185
                                                            i64.lt_s
                                                            local.set 186
                                                            i64.const 2
                                                            local.get 185
                                                            local.get 186
                                                            select
                                                            local.set 187
                                                            local.get 175
                                                            local.get 187
                                                            struct.set 7 4
                                                            local.get 187
                                                            local.set 188
                                                            br 0 (;@28;)
                                                          end
                                                          local.get 175
                                                          struct.get 7 3
                                                          local.set 189
                                                          local.get 189
                                                          i32.eqz
                                                          br_if 4 (;@23;)
                                                          local.get 1
                                                          global.get 1
                                                          local.set 277
                                                          any.convert_extern
                                                          ref.cast eqref
                                                          local.get 277
                                                          ref.eq
                                                          local.set 190
                                                          local.get 190
                                                          i32.eqz
                                                          local.set 191
                                                          local.get 191
                                                          i32.eqz
                                                          br_if 3 (;@24;)
                                                          local.get 175
                                                          struct.get 7 2
                                                          local.set 192
                                                          local.get 192
                                                          global.get 1
                                                          local.set 278
                                                          any.convert_extern
                                                          ref.cast eqref
                                                          local.get 278
                                                          ref.eq
                                                          local.set 193
                                                          local.get 193
                                                          i32.eqz
                                                          br_if 0 (;@27;)
                                                          local.get 175
                                                          local.get 1
                                                          struct.set 7 2
                                                          local.get 1
                                                          any.convert_extern
                                                          ref.cast (ref null 7)
                                                          local.set 194
                                                          br 3 (;@24;)
                                                        end
                                                        local.get 175
                                                        struct.get 7 2
                                                        local.set 195
                                                        local.get 1
                                                        local.get 195
                                                        local.get 2
                                                        i64.const 0
                                                        call 2
                                                        local.set 196
                                                        local.get 196
                                                        i32.eqz
                                                        local.set 197
                                                        local.get 197
                                                        i32.eqz
                                                        br_if 1 (;@25;)
                                                        local.get 175
                                                        struct.get 7 2
                                                        local.set 198
                                                        local.get 198
                                                        local.get 1
                                                        local.get 2
                                                        i64.const 0
                                                        call 2
                                                        local.set 199
                                                        local.get 199
                                                        i32.eqz
                                                        local.set 200
                                                        local.get 200
                                                        i32.eqz
                                                        br_if 0 (;@26;)
                                                        i32.const 0
                                                        local.set 8
                                                        br 4 (;@22;)
                                                      end
                                                      br 1 (;@24;)
                                                    end
                                                    local.get 175
                                                    local.get 1
                                                    struct.set 7 2
                                                    local.get 1
                                                    any.convert_extern
                                                    ref.cast (ref null 7)
                                                    local.set 201
                                                  end
                                                  i32.const 1
                                                  local.set 8
                                                  br 1 (;@22;)
                                                end
                                                local.get 175
                                                struct.get 7 2
                                                local.set 202
                                                local.get 202
                                                local.get 1
                                                local.get 2
                                                i64.const 0
                                                call 2
                                                local.set 203
                                                local.get 203
                                                local.set 8
                                                br 0 (;@22;)
                                              end
                                              local.get 8
                                              return
                                            end
                                            local.get 0
                                            any.convert_extern
                                            ref.cast (ref null 6)
                                            local.set 204
                                            local.get 204
                                            struct.get 6 2
                                            local.set 205
                                            local.get 205
                                            local.get 1
                                            local.get 2
                                            local.get 3
                                            call 2
                                            local.set 206
                                            local.get 206
                                            return
                                          end
                                          local.get 1
                                          any.convert_extern
                                          ref.test (ref 6)
                                          local.set 207
                                          local.get 207
                                          i32.eqz
                                          br_if 15 (;@4;)
                                          local.get 1
                                          any.convert_extern
                                          ref.cast (ref null 6)
                                          local.set 208
                                          local.get 2
                                          local.get 208
                                          call 3
                                          ref.cast (ref null 7)
                                          local.set 209
                                          local.get 209
                                          ref.is_null
                                          local.set 210
                                          local.get 210
                                          i32.eqz
                                          local.set 211
                                          local.get 211
                                          i32.eqz
                                          br_if 14 (;@5;)
                                          local.get 209
                                          local.set 212
                                          local.get 3
                                          i64.const 2
                                          i64.eq
                                          local.set 213
                                          local.get 213
                                          i32.eqz
                                          br_if 0 (;@19;)
                                          br 2 (;@17;)
                                        end
                                        local.get 2
                                        struct.get 10 1
                                        local.set 214
                                        i64.const 0
                                        local.get 214
                                        i64.lt_s
                                        local.set 215
                                        local.get 215
                                        i32.eqz
                                        br_if 0 (;@18;)
                                        br 1 (;@17;)
                                      end
                                      local.get 212
                                      struct.get 7 5
                                      local.set 216
                                      local.get 216
                                      i64.const 1
                                      i64.add
                                      local.set 217
                                      i64.const 2
                                      local.get 217
                                      i64.lt_s
                                      local.set 218
                                      i64.const 2
                                      local.get 217
                                      local.get 218
                                      select
                                      local.set 219
                                      local.get 212
                                      local.get 219
                                      struct.set 7 5
                                      local.get 219
                                      local.set 220
                                      br 1 (;@16;)
                                    end
                                    local.get 212
                                    struct.get 7 4
                                    local.set 221
                                    local.get 221
                                    i64.const 1
                                    i64.add
                                    local.set 222
                                    i64.const 2
                                    local.get 222
                                    i64.lt_s
                                    local.set 223
                                    i64.const 2
                                    local.get 222
                                    local.get 223
                                    select
                                    local.set 224
                                    local.get 212
                                    local.get 224
                                    struct.set 7 4
                                    local.get 224
                                    local.set 225
                                    br 0 (;@16;)
                                  end
                                  local.get 212
                                  struct.get 7 3
                                  local.set 226
                                  local.get 226
                                  i32.eqz
                                  br_if 8 (;@7;)
                                  local.get 0
                                  global.get 0
                                  local.set 279
                                  any.convert_extern
                                  ref.cast eqref
                                  local.get 279
                                  ref.eq
                                  local.set 227
                                  local.get 227
                                  i32.eqz
                                  local.set 228
                                  local.get 228
                                  i32.eqz
                                  br_if 7 (;@8;)
                                  local.get 212
                                  struct.get 7 1
                                  local.set 229
                                  local.get 229
                                  global.get 0
                                  local.set 280
                                  any.convert_extern
                                  ref.cast eqref
                                  local.get 280
                                  ref.eq
                                  local.set 230
                                  local.get 230
                                  i32.eqz
                                  br_if 0 (;@15;)
                                  local.get 212
                                  local.get 0
                                  struct.set 7 1
                                  local.get 0
                                  any.convert_extern
                                  ref.cast (ref null 7)
                                  local.set 231
                                  br 7 (;@8;)
                                end
                                local.get 212
                                struct.get 7 1
                                local.set 232
                                local.get 232
                                local.get 0
                                any.convert_extern
                                ref.cast eqref
                                local.set 281
                                any.convert_extern
                                ref.cast eqref
                                local.get 281
                                ref.eq
                                local.set 233
                                local.get 233
                                i32.eqz
                                br_if 0 (;@14;)
                                br 6 (;@8;)
                              end
                              local.get 212
                              struct.get 7 1
                              local.set 234
                              local.get 234
                              drop
                              i32.const 0
                              local.set 235
                              local.get 235
                              i32.eqz
                              local.set 236
                              local.get 236
                              i32.eqz
                              br_if 0 (;@13;)
                              br 4 (;@9;)
                            end
                            local.get 0
                            drop
                            i32.const 0
                            local.set 237
                            local.get 237
                            i32.eqz
                            local.set 238
                            local.get 238
                            i32.eqz
                            br_if 0 (;@12;)
                            br 3 (;@9;)
                          end
                          local.get 0
                          local.set 239
                          local.get 212
                          struct.get 7 1
                          local.set 240
                          local.get 240
                          local.get 239
                          local.get 2
                          i64.const 0
                          call 2
                          local.set 241
                          local.get 241
                          i32.eqz
                          br_if 0 (;@11;)
                          local.get 0
                          local.set 242
                          local.get 212
                          local.get 242
                          struct.set 7 1
                          local.get 242
                          local.set 243
                          br 3 (;@8;)
                        end
                        local.get 0
                        local.set 244
                        local.get 212
                        struct.get 7 1
                        local.set 245
                        local.get 244
                        local.get 245
                        local.get 2
                        i64.const 0
                        call 2
                        local.set 246
                        local.get 246
                        i32.eqz
                        br_if 0 (;@10;)
                        br 2 (;@8;)
                      end
                      local.get 0
                      local.set 247
                      local.get 212
                      struct.get 7 1
                      local.set 248
                      unreachable
                      local.get 212
                      local.get 249
                      struct.set 7 1
                      local.get 249
                      local.set 250
                      br 1 (;@8;)
                    end
                    local.get 212
                    ref.null extern
                    struct.set 7 1
                    global.get 1
                    ref.cast (ref null 16)
                    local.set 251
                  end
                  i32.const 1
                  local.set 9
                  br 1 (;@6;)
                end
                local.get 212
                struct.get 7 1
                local.set 252
                local.get 0
                local.get 252
                local.get 2
                i64.const 0
                call 2
                local.set 253
                local.get 253
                local.set 9
                br 0 (;@6;)
              end
              local.get 9
              return
            end
            local.get 1
            any.convert_extern
            ref.cast (ref null 6)
            local.set 254
            local.get 254
            struct.get 6 1
            local.set 255
            local.get 0
            local.get 255
            local.get 2
            local.get 3
            call 2
            local.set 256
            local.get 256
            return
          end
          local.get 0
          any.convert_extern
          ref.test (ref 11)
          local.set 257
          local.get 257
          i32.eqz
          br_if 0 (;@3;)
          local.get 0
          any.convert_extern
          ref.cast (ref null 11)
          local.set 258
          local.get 1
          local.get 258
          local.get 2
          i32.const 0
          local.get 3
          call 9
          local.set 259
          local.get 259
          return
        end
        local.get 1
        any.convert_extern
        ref.test (ref 11)
        local.set 260
        local.get 260
        i32.eqz
        br_if 0 (;@2;)
        local.get 1
        any.convert_extern
        ref.cast (ref null 11)
        local.set 261
        local.get 0
        local.get 261
        local.get 2
        i32.const 1
        local.get 3
        call 9
        local.set 262
        local.get 262
        return
      end
      local.get 0
      any.convert_extern
      ref.test (ref 16)
      local.set 263
      local.get 263
      i32.eqz
      br_if 0 (;@1;)
      local.get 1
      any.convert_extern
      ref.test (ref 16)
      local.set 264
      local.get 264
      i32.eqz
      br_if 0 (;@1;)
      local.get 0
      any.convert_extern
      ref.cast (ref null 16)
      local.set 265
      local.get 1
      any.convert_extern
      ref.cast (ref null 16)
      local.set 266
      local.get 265
      local.get 266
      local.get 2
      local.get 3
      call 14
      local.set 267
      local.get 267
      return
    end
    i32.const 0
    return
    unreachable
  )
  (func (;3;) (type 20) (param (ref null 10) (ref null 6)) (result (ref null 7))
    (local i64 i64 i64 i64 i64 i32 i64 i64 i64 i64 i64 i64 i32 (ref null 9) (ref null 2) i32 i64 i32 i32 i32 i32 i64 i32 i64 i64 i32 i64 i64 i32 i64 i64 i32 i32 i32 i32 i32 i32 i32 (ref null 9) i32 i64 i64 (ref null 2) i32 i64 i64 i32 (ref null 2) (ref null 8) (ref null 7) (ref null 6) i32 (ref null 9) i32 i64 i64 (ref null 2) i32 i64 i64 i32 (ref null 2) (ref null 8) (ref null 7) i32 i64 i32)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  block ;; label = @8
                    block ;; label = @9
                      block ;; label = @10
                        block ;; label = @11
                          block ;; label = @12
                            block ;; label = @13
                              local.get 0
                              struct.get 10 0
                              local.set 15
                              local.get 15
                              struct.get 9 1
                              local.set 16
                              i32.const 0
                              local.set 17
                              local.get 16
                              struct.get 2 0
                              local.set 18
                              i64.const 1
                              local.get 18
                              i64.eq
                              local.set 19
                              local.get 19
                              i32.eqz
                              br_if 0 (;@13;)
                              i64.const 1
                              local.set 6
                              br 8 (;@5;)
                            end
                            local.get 18
                            i64.const 1
                            i64.lt_s
                            local.set 20
                            i32.const 0
                            local.get 20
                            i32.eq
                            local.set 21
                            local.get 21
                            i32.eqz
                            local.set 22
                            local.get 22
                            i32.eqz
                            br_if 0 (;@12;)
                            local.get 18
                            i64.const 1
                            i64.add
                            local.set 23
                            local.get 23
                            local.set 6
                            br 7 (;@5;)
                          end
                          local.get 18
                          i64.const 1
                          i64.lt_s
                          local.set 24
                          local.get 24
                          i32.eqz
                          br_if 0 (;@11;)
                          i64.const 1
                          local.get 18
                          i64.sub
                          local.set 25
                          local.get 25
                          local.set 2
                          i64.const -1
                          local.set 3
                          br 1 (;@10;)
                        end
                        local.get 18
                        i64.const 1
                        i64.sub
                        local.set 26
                        local.get 26
                        local.set 2
                        i64.const 1
                        local.set 3
                      end
                      local.get 2
                      i64.const 0
                      i64.lt_s
                      local.set 27
                      local.get 27
                      i32.eqz
                      br_if 0 (;@9;)
                      local.get 2
                      local.get 3
                      unreachable
                      local.get 28
                      local.set 4
                      br 1 (;@8;)
                    end
                    local.get 2
                    local.get 3
                    i64.rem_s
                    local.set 29
                    local.get 29
                    local.set 4
                  end
                  local.get 18
                  i64.const 1
                  i64.lt_s
                  local.set 30
                  local.get 30
                  i32.eqz
                  br_if 0 (;@7;)
                  i64.const 1
                  local.get 4
                  i64.sub
                  local.set 31
                  local.get 31
                  local.set 5
                  br 1 (;@6;)
                end
                i64.const 1
                local.get 4
                i64.add
                local.set 32
                local.get 32
                local.set 5
              end
              local.get 5
              local.set 6
            end
            local.get 18
            local.get 6
            i64.eq
            local.set 33
            local.get 33
            i32.eqz
            local.set 34
            local.get 18
            local.get 6
            i64.lt_s
            local.set 35
            i32.const 0
            local.get 35
            i32.eq
            local.set 36
            local.get 36
            i32.eqz
            local.set 37
            local.get 34
            local.get 37
            i32.and
            local.set 38
            local.get 38
            i32.eqz
            br_if 0 (;@4;)
            i32.const 1
            local.set 7
            br 1 (;@3;)
          end
          i32.const 0
          local.set 7
          local.get 18
          local.set 8
          local.get 18
          local.set 9
          br 0 (;@3;)
        end
        local.get 7
        i32.eqz
        local.set 39
        local.get 39
        i32.eqz
        br_if 1 (;@1;)
        local.get 8
        local.set 10
        local.get 9
        local.set 11
      end
      loop ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  local.get 0
                  struct.get 10 0
                  local.set 40
                  br 0 (;@7;)
                end
                local.get 40
                struct.get 9 0
                local.set 50
                local.get 50
                local.get 10
                i32.wrap_i64
                i32.const 1
                i32.sub
                array.get 8
                ref.cast (ref null 7)
                local.set 51
                local.get 51
                struct.get 7 0
                local.set 52
                local.get 52
                local.get 1
                ref.eq
                local.set 53
                local.get 53
                i32.eqz
                br_if 1 (;@5;)
                local.get 0
                struct.get 10 0
                local.set 54
                br 0 (;@6;)
              end
              local.get 54
              struct.get 9 0
              local.set 64
              local.get 64
              local.get 10
              i32.wrap_i64
              i32.const 1
              i32.sub
              array.get 8
              ref.cast (ref null 7)
              local.set 65
              local.get 65
              return
            end
            local.get 11
            local.get 6
            i64.eq
            local.set 66
            local.get 66
            i32.eqz
            br_if 0 (;@4;)
            i32.const 1
            local.set 14
            br 1 (;@3;)
          end
          local.get 11
          i64.const -1
          i64.add
          local.set 67
          local.get 67
          local.set 12
          local.get 67
          local.set 13
          i32.const 0
          local.set 14
          br 0 (;@3;)
        end
        local.get 14
        i32.eqz
        local.set 68
        local.get 68
        i32.eqz
        br_if 1 (;@1;)
        local.get 12
        local.set 10
        local.get 13
        local.set 11
        br 0 (;@2;)
      end
    end
    ref.null 7
    return
    unreachable
  )
  (func (;4;) (type 21) (param (ref null 6) i32) (result (ref null 7))
    (local externref externref (ref null 7))
    local.get 0
    struct.get 6 1
    local.set 2
    local.get 0
    struct.get 6 2
    local.set 3
    local.get 0
    local.get 2
    local.get 3
    local.get 1
    i64.const 0
    i64.const 0
    i32.const 0
    struct.new 7
    ref.cast (ref null 7)
    local.set 4
    local.get 4
    return
  )
  (func (;5;) (type 22) (param (ref null 7) externref (ref null 10) i64) (result i32)
    (local i32 i64 i32 i64 i64 i32 i64 i64 i64 i64 i32 i64 i64 i32 i32 i32 externref i32 (ref null 7) externref i32 i32 externref i32 i32 externref i32 eqref eqref)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  block ;; label = @8
                    block ;; label = @9
                      local.get 3
                      i64.const 2
                      i64.eq
                      local.set 4
                      local.get 4
                      i32.eqz
                      br_if 0 (;@9;)
                      br 2 (;@7;)
                    end
                    local.get 2
                    struct.get 10 1
                    local.set 5
                    i64.const 0
                    local.get 5
                    i64.lt_s
                    local.set 6
                    local.get 6
                    i32.eqz
                    br_if 0 (;@8;)
                    br 1 (;@7;)
                  end
                  local.get 0
                  struct.get 7 5
                  local.set 7
                  local.get 7
                  i64.const 1
                  i64.add
                  local.set 8
                  i64.const 2
                  local.get 8
                  i64.lt_s
                  local.set 9
                  i64.const 2
                  local.get 8
                  local.get 9
                  select
                  local.set 10
                  local.get 0
                  local.get 10
                  struct.set 7 5
                  local.get 10
                  local.set 11
                  br 1 (;@6;)
                end
                local.get 0
                struct.get 7 4
                local.set 12
                local.get 12
                i64.const 1
                i64.add
                local.set 13
                i64.const 2
                local.get 13
                i64.lt_s
                local.set 14
                i64.const 2
                local.get 13
                local.get 14
                select
                local.set 15
                local.get 0
                local.get 15
                struct.set 7 4
                local.get 15
                local.set 16
                br 0 (;@6;)
              end
              local.get 0
              struct.get 7 3
              local.set 17
              local.get 17
              i32.eqz
              br_if 4 (;@1;)
              local.get 1
              global.get 1
              local.set 31
              any.convert_extern
              ref.cast eqref
              local.get 31
              ref.eq
              local.set 18
              local.get 18
              i32.eqz
              local.set 19
              local.get 19
              i32.eqz
              br_if 3 (;@2;)
              local.get 0
              struct.get 7 2
              local.set 20
              local.get 20
              global.get 1
              local.set 32
              any.convert_extern
              ref.cast eqref
              local.get 32
              ref.eq
              local.set 21
              local.get 21
              i32.eqz
              br_if 0 (;@5;)
              local.get 0
              local.get 1
              struct.set 7 2
              local.get 1
              any.convert_extern
              ref.cast (ref null 7)
              local.set 22
              br 3 (;@2;)
            end
            local.get 0
            struct.get 7 2
            local.set 23
            local.get 1
            local.get 23
            local.get 2
            i64.const 0
            call 2
            local.set 24
            local.get 24
            i32.eqz
            local.set 25
            local.get 25
            i32.eqz
            br_if 1 (;@3;)
            local.get 0
            struct.get 7 2
            local.set 26
            local.get 26
            local.get 1
            local.get 2
            i64.const 0
            call 2
            local.set 27
            local.get 27
            i32.eqz
            local.set 28
            local.get 28
            i32.eqz
            br_if 0 (;@4;)
            i32.const 0
            return
          end
          br 1 (;@2;)
        end
        local.get 0
        local.get 1
        struct.set 7 2
        local.get 1
        drop
      end
      i32.const 1
      return
    end
    local.get 0
    struct.get 7 2
    local.set 29
    local.get 29
    local.get 1
    local.get 2
    i64.const 0
    call 2
    local.set 30
    local.get 30
    return
    unreachable
  )
  (func (;6;) (type 22) (param (ref null 7) externref (ref null 10) i64) (result i32)
    (local i32 i64 i32 i64 i64 i32 i64 i64 i64 i64 i32 i64 i64 i32 i32 i32 externref i32 (ref null 7) externref i32 externref i32 i32 i32 i32 externref externref i32 externref externref externref externref i32 externref externref externref externref externref i32 eqref eqref eqref)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  block ;; label = @8
                    block ;; label = @9
                      block ;; label = @10
                        block ;; label = @11
                          block ;; label = @12
                            block ;; label = @13
                              local.get 3
                              i64.const 2
                              i64.eq
                              local.set 4
                              local.get 4
                              i32.eqz
                              br_if 0 (;@13;)
                              br 2 (;@11;)
                            end
                            local.get 2
                            struct.get 10 1
                            local.set 5
                            i64.const 0
                            local.get 5
                            i64.lt_s
                            local.set 6
                            local.get 6
                            i32.eqz
                            br_if 0 (;@12;)
                            br 1 (;@11;)
                          end
                          local.get 0
                          struct.get 7 5
                          local.set 7
                          local.get 7
                          i64.const 1
                          i64.add
                          local.set 8
                          i64.const 2
                          local.get 8
                          i64.lt_s
                          local.set 9
                          i64.const 2
                          local.get 8
                          local.get 9
                          select
                          local.set 10
                          local.get 0
                          local.get 10
                          struct.set 7 5
                          local.get 10
                          local.set 11
                          br 1 (;@10;)
                        end
                        local.get 0
                        struct.get 7 4
                        local.set 12
                        local.get 12
                        i64.const 1
                        i64.add
                        local.set 13
                        i64.const 2
                        local.get 13
                        i64.lt_s
                        local.set 14
                        i64.const 2
                        local.get 13
                        local.get 14
                        select
                        local.set 15
                        local.get 0
                        local.get 15
                        struct.set 7 4
                        local.get 15
                        local.set 16
                        br 0 (;@10;)
                      end
                      local.get 0
                      struct.get 7 3
                      local.set 17
                      local.get 17
                      i32.eqz
                      br_if 8 (;@1;)
                      local.get 1
                      global.get 0
                      local.set 44
                      any.convert_extern
                      ref.cast eqref
                      local.get 44
                      ref.eq
                      local.set 18
                      local.get 18
                      i32.eqz
                      local.set 19
                      local.get 19
                      i32.eqz
                      br_if 7 (;@2;)
                      local.get 0
                      struct.get 7 1
                      local.set 20
                      local.get 20
                      global.get 0
                      local.set 45
                      any.convert_extern
                      ref.cast eqref
                      local.get 45
                      ref.eq
                      local.set 21
                      local.get 21
                      i32.eqz
                      br_if 0 (;@9;)
                      local.get 0
                      local.get 1
                      struct.set 7 1
                      local.get 1
                      any.convert_extern
                      ref.cast (ref null 7)
                      local.set 22
                      br 7 (;@2;)
                    end
                    local.get 0
                    struct.get 7 1
                    local.set 23
                    local.get 23
                    local.get 1
                    any.convert_extern
                    ref.cast eqref
                    local.set 46
                    any.convert_extern
                    ref.cast eqref
                    local.get 46
                    ref.eq
                    local.set 24
                    local.get 24
                    i32.eqz
                    br_if 0 (;@8;)
                    br 6 (;@2;)
                  end
                  local.get 0
                  struct.get 7 1
                  local.set 25
                  local.get 25
                  drop
                  i32.const 0
                  local.set 26
                  local.get 26
                  i32.eqz
                  local.set 27
                  local.get 27
                  i32.eqz
                  br_if 0 (;@7;)
                  br 4 (;@3;)
                end
                local.get 1
                drop
                i32.const 0
                local.set 28
                local.get 28
                i32.eqz
                local.set 29
                local.get 29
                i32.eqz
                br_if 0 (;@6;)
                br 3 (;@3;)
              end
              local.get 1
              local.set 30
              local.get 0
              struct.get 7 1
              local.set 31
              local.get 31
              local.get 30
              local.get 2
              i64.const 0
              call 2
              local.set 32
              local.get 32
              i32.eqz
              br_if 0 (;@5;)
              local.get 1
              local.set 33
              local.get 0
              local.get 33
              struct.set 7 1
              local.get 33
              local.set 34
              br 3 (;@2;)
            end
            local.get 1
            local.set 35
            local.get 0
            struct.get 7 1
            local.set 36
            local.get 35
            local.get 36
            local.get 2
            i64.const 0
            call 2
            local.set 37
            local.get 37
            i32.eqz
            br_if 0 (;@4;)
            br 2 (;@2;)
          end
          local.get 1
          local.set 38
          local.get 0
          struct.get 7 1
          local.set 39
          unreachable
          local.get 0
          local.get 40
          struct.set 7 1
          local.get 40
          local.set 41
          br 1 (;@2;)
        end
        local.get 0
        ref.null extern
        struct.set 7 1
        global.get 1
        drop
      end
      i32.const 1
      return
    end
    local.get 0
    struct.get 7 1
    local.set 42
    local.get 1
    local.get 42
    local.get 2
    i64.const 0
    call 2
    local.set 43
    local.get 43
    return
    unreachable
  )
  (func (;7;) (type 23) (param (ref null 7) externref (ref null 10) i32 i64) (result i32)
    (local i32 i32 i32 i64 i32 i64 i64 i32 i64 i64 i64 i64 i32 i64 i64 i32 i32 i32 externref i32 (ref null 7) externref i32 externref i32 i32 i32 i32 externref externref i32 externref externref externref externref i32 externref externref externref externref (ref null 16) externref i32 i32 i64 i32 i64 i64 i32 i64 i64 i64 i64 i32 i64 i64 i32 i32 i32 externref i32 (ref null 7) externref i32 i32 externref i32 i32 (ref null 7) externref i32 eqref eqref eqref eqref eqref)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  block ;; label = @8
                    block ;; label = @9
                      block ;; label = @10
                        block ;; label = @11
                          block ;; label = @12
                            block ;; label = @13
                              block ;; label = @14
                                block ;; label = @15
                                  block ;; label = @16
                                    block ;; label = @17
                                      block ;; label = @18
                                        block ;; label = @19
                                          block ;; label = @20
                                            block ;; label = @21
                                              block ;; label = @22
                                                block ;; label = @23
                                                  block ;; label = @24
                                                    block ;; label = @25
                                                      local.get 3
                                                      i32.eqz
                                                      br_if 14 (;@11;)
                                                      local.get 4
                                                      i64.const 2
                                                      i64.eq
                                                      local.set 7
                                                      local.get 7
                                                      i32.eqz
                                                      br_if 0 (;@25;)
                                                      br 2 (;@23;)
                                                    end
                                                    local.get 2
                                                    struct.get 10 1
                                                    local.set 8
                                                    i64.const 0
                                                    local.get 8
                                                    i64.lt_s
                                                    local.set 9
                                                    local.get 9
                                                    i32.eqz
                                                    br_if 0 (;@24;)
                                                    br 1 (;@23;)
                                                  end
                                                  local.get 0
                                                  struct.get 7 5
                                                  local.set 10
                                                  local.get 10
                                                  i64.const 1
                                                  i64.add
                                                  local.set 11
                                                  i64.const 2
                                                  local.get 11
                                                  i64.lt_s
                                                  local.set 12
                                                  i64.const 2
                                                  local.get 11
                                                  local.get 12
                                                  select
                                                  local.set 13
                                                  local.get 0
                                                  local.get 13
                                                  struct.set 7 5
                                                  local.get 13
                                                  local.set 14
                                                  br 1 (;@22;)
                                                end
                                                local.get 0
                                                struct.get 7 4
                                                local.set 15
                                                local.get 15
                                                i64.const 1
                                                i64.add
                                                local.set 16
                                                i64.const 2
                                                local.get 16
                                                i64.lt_s
                                                local.set 17
                                                i64.const 2
                                                local.get 16
                                                local.get 17
                                                select
                                                local.set 18
                                                local.get 0
                                                local.get 18
                                                struct.set 7 4
                                                local.get 18
                                                local.set 19
                                                br 0 (;@22;)
                                              end
                                              local.get 0
                                              struct.get 7 3
                                              local.set 20
                                              local.get 20
                                              i32.eqz
                                              br_if 8 (;@13;)
                                              local.get 1
                                              global.get 0
                                              local.set 76
                                              any.convert_extern
                                              ref.cast eqref
                                              local.get 76
                                              ref.eq
                                              local.set 21
                                              local.get 21
                                              i32.eqz
                                              local.set 22
                                              local.get 22
                                              i32.eqz
                                              br_if 7 (;@14;)
                                              local.get 0
                                              struct.get 7 1
                                              local.set 23
                                              local.get 23
                                              global.get 0
                                              local.set 77
                                              any.convert_extern
                                              ref.cast eqref
                                              local.get 77
                                              ref.eq
                                              local.set 24
                                              local.get 24
                                              i32.eqz
                                              br_if 0 (;@21;)
                                              local.get 0
                                              local.get 1
                                              struct.set 7 1
                                              local.get 1
                                              any.convert_extern
                                              ref.cast (ref null 7)
                                              local.set 25
                                              br 7 (;@14;)
                                            end
                                            local.get 0
                                            struct.get 7 1
                                            local.set 26
                                            local.get 26
                                            local.get 1
                                            any.convert_extern
                                            ref.cast eqref
                                            local.set 78
                                            any.convert_extern
                                            ref.cast eqref
                                            local.get 78
                                            ref.eq
                                            local.set 27
                                            local.get 27
                                            i32.eqz
                                            br_if 0 (;@20;)
                                            br 6 (;@14;)
                                          end
                                          local.get 0
                                          struct.get 7 1
                                          local.set 28
                                          local.get 28
                                          drop
                                          i32.const 0
                                          local.set 29
                                          local.get 29
                                          i32.eqz
                                          local.set 30
                                          local.get 30
                                          i32.eqz
                                          br_if 0 (;@19;)
                                          br 4 (;@15;)
                                        end
                                        local.get 1
                                        drop
                                        i32.const 0
                                        local.set 31
                                        local.get 31
                                        i32.eqz
                                        local.set 32
                                        local.get 32
                                        i32.eqz
                                        br_if 0 (;@18;)
                                        br 3 (;@15;)
                                      end
                                      local.get 1
                                      local.set 33
                                      local.get 0
                                      struct.get 7 1
                                      local.set 34
                                      local.get 34
                                      local.get 33
                                      local.get 2
                                      i64.const 0
                                      call 2
                                      local.set 35
                                      local.get 35
                                      i32.eqz
                                      br_if 0 (;@17;)
                                      local.get 1
                                      local.set 36
                                      local.get 0
                                      local.get 36
                                      struct.set 7 1
                                      local.get 36
                                      local.set 37
                                      br 3 (;@14;)
                                    end
                                    local.get 1
                                    local.set 38
                                    local.get 0
                                    struct.get 7 1
                                    local.set 39
                                    local.get 38
                                    local.get 39
                                    local.get 2
                                    i64.const 0
                                    call 2
                                    local.set 40
                                    local.get 40
                                    i32.eqz
                                    br_if 0 (;@16;)
                                    br 2 (;@14;)
                                  end
                                  local.get 1
                                  local.set 41
                                  local.get 0
                                  struct.get 7 1
                                  local.set 42
                                  unreachable
                                  local.get 0
                                  local.get 43
                                  struct.set 7 1
                                  local.get 43
                                  local.set 44
                                  br 1 (;@14;)
                                end
                                local.get 0
                                ref.null extern
                                struct.set 7 1
                                global.get 1
                                ref.cast (ref null 16)
                                local.set 45
                              end
                              i32.const 1
                              local.set 5
                              br 1 (;@12;)
                            end
                            local.get 0
                            struct.get 7 1
                            local.set 46
                            local.get 1
                            local.get 46
                            local.get 2
                            i64.const 0
                            call 2
                            local.set 47
                            local.get 47
                            local.set 5
                            br 0 (;@12;)
                          end
                          local.get 5
                          return
                        end
                        local.get 4
                        i64.const 2
                        i64.eq
                        local.set 48
                        local.get 48
                        i32.eqz
                        br_if 0 (;@10;)
                        br 2 (;@8;)
                      end
                      local.get 2
                      struct.get 10 1
                      local.set 49
                      i64.const 0
                      local.get 49
                      i64.lt_s
                      local.set 50
                      local.get 50
                      i32.eqz
                      br_if 0 (;@9;)
                      br 1 (;@8;)
                    end
                    local.get 0
                    struct.get 7 5
                    local.set 51
                    local.get 51
                    i64.const 1
                    i64.add
                    local.set 52
                    i64.const 2
                    local.get 52
                    i64.lt_s
                    local.set 53
                    i64.const 2
                    local.get 52
                    local.get 53
                    select
                    local.set 54
                    local.get 0
                    local.get 54
                    struct.set 7 5
                    local.get 54
                    local.set 55
                    br 1 (;@7;)
                  end
                  local.get 0
                  struct.get 7 4
                  local.set 56
                  local.get 56
                  i64.const 1
                  i64.add
                  local.set 57
                  i64.const 2
                  local.get 57
                  i64.lt_s
                  local.set 58
                  i64.const 2
                  local.get 57
                  local.get 58
                  select
                  local.set 59
                  local.get 0
                  local.get 59
                  struct.set 7 4
                  local.get 59
                  local.set 60
                  br 0 (;@7;)
                end
                local.get 0
                struct.get 7 3
                local.set 61
                local.get 61
                i32.eqz
                br_if 4 (;@2;)
                local.get 1
                global.get 1
                local.set 79
                any.convert_extern
                ref.cast eqref
                local.get 79
                ref.eq
                local.set 62
                local.get 62
                i32.eqz
                local.set 63
                local.get 63
                i32.eqz
                br_if 3 (;@3;)
                local.get 0
                struct.get 7 2
                local.set 64
                local.get 64
                global.get 1
                local.set 80
                any.convert_extern
                ref.cast eqref
                local.get 80
                ref.eq
                local.set 65
                local.get 65
                i32.eqz
                br_if 0 (;@6;)
                local.get 0
                local.get 1
                struct.set 7 2
                local.get 1
                any.convert_extern
                ref.cast (ref null 7)
                local.set 66
                br 3 (;@3;)
              end
              local.get 0
              struct.get 7 2
              local.set 67
              local.get 1
              local.get 67
              local.get 2
              i64.const 0
              call 2
              local.set 68
              local.get 68
              i32.eqz
              local.set 69
              local.get 69
              i32.eqz
              br_if 1 (;@4;)
              local.get 0
              struct.get 7 2
              local.set 70
              local.get 70
              local.get 1
              local.get 2
              i64.const 0
              call 2
              local.set 71
              local.get 71
              i32.eqz
              local.set 72
              local.get 72
              i32.eqz
              br_if 0 (;@5;)
              i32.const 0
              local.set 6
              br 4 (;@1;)
            end
            br 1 (;@3;)
          end
          local.get 0
          local.get 1
          struct.set 7 2
          local.get 1
          any.convert_extern
          ref.cast (ref null 7)
          local.set 73
        end
        i32.const 1
        local.set 6
        br 1 (;@1;)
      end
      local.get 0
      struct.get 7 2
      local.set 74
      local.get 74
      local.get 1
      local.get 2
      i64.const 0
      call 2
      local.set 75
      local.get 75
      local.set 6
      br 0 (;@1;)
    end
    local.get 6
    return
    unreachable
  )
  (func (;8;) (type 24) (param (ref null 7) (ref null 10) i64) (result i64)
    (local i32 i64 i32 i64 i64 i32 i64 i64 i64 i32 i64)
    local.get 2
    i64.const 2
    i64.eq
    local.set 3
    local.get 3
    if ;; label = @1
      local.get 0
      struct.get 7 4
      local.set 10
      local.get 10
      i64.const 1
      i64.add
      local.set 11
      i64.const 2
      local.get 11
      i64.lt_s
      local.set 12
      i64.const 2
      local.get 11
      local.get 12
      select
      local.set 13
      local.get 0
      local.get 13
      struct.set 7 4
      local.get 13
      local.get 13
      return
    else
      local.get 1
      struct.get 10 1
      local.set 4
      i64.const 0
      local.get 4
      i64.lt_s
      local.set 5
      local.get 5
      if ;; label = @2
        local.get 0
        struct.get 7 4
        local.set 10
        local.get 10
        i64.const 1
        i64.add
        local.set 11
        i64.const 2
        local.get 11
        i64.lt_s
        local.set 12
        i64.const 2
        local.get 11
        local.get 12
        select
        local.set 13
        local.get 0
        local.get 13
        struct.set 7 4
        local.get 13
        local.get 13
        return
      else
        local.get 0
        struct.get 7 5
        local.set 6
        local.get 6
        i64.const 1
        i64.add
        local.set 7
        i64.const 2
        local.get 7
        i64.lt_s
        local.set 8
        i64.const 2
        local.get 7
        local.get 8
        select
        local.set 9
        local.get 0
        local.get 9
        struct.set 7 5
        local.get 9
        drop
        local.get 9
        return
      end
    end
    unreachable
  )
  (func (;9;) (type 28) (param externref (ref null 11) (ref null 10) i32 i64) (result i32)
    (local i32 i64 i32 i64 i64 i64 i64 i64 i64 i32 i32 i32 i32 i32 i32 i32 i64 i32 i64 i64 i64 i64 i64 i64 i32 i32 (ref null 6) externref externref (ref null 7) (ref null 9) (ref null 8) (ref null 8) i64 (ref null 2) i32 i64 i64 i64 i64 i64 i32 (ref null 25) (ref null 2) (ref null 2) (ref null 2) i32 i64 (ref null 8) (ref null 7) externref i32 i32 (ref null 9) (ref null 2) i32 i64 i32 (ref null 2) i32 i64 i32 i64 i64 (ref null 2) i32 i64 i64 i32 (ref null 2) (ref null 8) (ref null 7) (ref null 2) i32 i64 i32 i64 i64 i32 i64 i32 i32 i32 (ref null 2) (ref null 2) i32 i64 i64 i64 i64 i32 (ref null 8) i32 i32 i32 (ref null 8) externref i64 i64 i32 i64 i32 (ref null 2) (ref null 2) (ref null 26) externref i32 externref i32 externref externref i32 i32 i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32 i32 i64 i32 i64 i32 externref i32 i32 externref i32 (ref null 16) i32 i32 i32 i32 i32 i32 i32 i32 (ref null 9) (ref null 2) i32 i64 i32 i32 i32 (ref null 9) i32 i64 i64 (ref null 2) i32 i64 i64 i32 (ref null 2) (ref null 8) (ref null 7) externref i32 i32 externref (ref null 6) externref i32 i32 externref (ref null 6) i32 externref i32 i32 externref (ref null 6) externref i32 i32 externref (ref null 6) i32 i32 i64 i32 (ref null 8) (ref null 8) i32 (ref null 9) (ref null 2) (ref null 2) eqref eqref eqref eqref eqref eqref eqref eqref eqref eqref)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  block ;; label = @8
                    block ;; label = @9
                      block ;; label = @10
                        block ;; label = @11
                          block ;; label = @12
                            block ;; label = @13
                              block ;; label = @14
                                block ;; label = @15
                                  block ;; label = @16
                                    block ;; label = @17
                                      block ;; label = @18
                                        block ;; label = @19
                                          block ;; label = @20
                                            block ;; label = @21
                                              block ;; label = @22
                                                block ;; label = @23
                                                  block ;; label = @24
                                                    block ;; label = @25
                                                      block ;; label = @26
                                                        block ;; label = @27
                                                          block ;; label = @28
                                                            block ;; label = @29
                                                              block ;; label = @30
                                                                block ;; label = @31
                                                                  block ;; label = @32
                                                                    block ;; label = @33
                                                                      local.get 1
                                                                      struct.get 11 0
                                                                      local.set 31
                                                                      local.get 31
                                                                      struct.get 6 1
                                                                      local.set 32
                                                                      local.get 31
                                                                      struct.get 6 2
                                                                      local.set 33
                                                                      local.get 31
                                                                      local.get 32
                                                                      local.get 33
                                                                      local.get 3
                                                                      i64.const 0
                                                                      i64.const 0
                                                                      i32.const 0
                                                                      struct.new 7
                                                                      ref.cast (ref null 7)
                                                                      local.set 34
                                                                      local.get 2
                                                                      struct.get 10 0
                                                                      local.set 35
                                                                      local.get 35
                                                                      struct.get 9 0
                                                                      local.set 36
                                                                      local.get 36
                                                                      ref.cast (ref null 8)
                                                                      local.set 37
                                                                      local.get 37
                                                                      array.len
                                                                      i64.extend_i32_s
                                                                      local.set 38
                                                                      local.get 35
                                                                      struct.get 9 1
                                                                      local.set 39
                                                                      i32.const 0
                                                                      local.set 40
                                                                      local.get 39
                                                                      struct.get 2 0
                                                                      local.set 41
                                                                      local.get 41
                                                                      i64.const 1
                                                                      i64.add
                                                                      local.set 42
                                                                      i64.const 1
                                                                      local.set 43
                                                                      local.get 43
                                                                      local.get 42
                                                                      i64.add
                                                                      local.set 44
                                                                      local.get 44
                                                                      i64.const 1
                                                                      i64.sub
                                                                      local.set 45
                                                                      local.get 38
                                                                      local.get 45
                                                                      i64.lt_s
                                                                      local.set 46
                                                                      local.get 46
                                                                      i32.eqz
                                                                      br_if 0 (;@33;)
                                                                      local.get 35
                                                                      local.get 45
                                                                      local.get 43
                                                                      local.get 42
                                                                      local.get 41
                                                                      local.get 38
                                                                      local.get 37
                                                                      local.get 36
                                                                      struct.new 25
                                                                      ref.cast (ref null 25)
                                                                      local.set 47
                                                                      local.get 35
                                                                      ref.cast (ref null 9)
                                                                      local.set 190
                                                                      local.get 190
                                                                      struct.get 9 0
                                                                      ref.cast (ref null 8)
                                                                      local.set 187
                                                                      local.get 187
                                                                      array.len
                                                                      local.set 189
                                                                      local.get 189
                                                                      i32.const 2
                                                                      i32.mul
                                                                      local.get 189
                                                                      i32.const 4
                                                                      i32.add
                                                                      local.get 189
                                                                      i32.const 2
                                                                      i32.mul
                                                                      local.get 189
                                                                      i32.const 4
                                                                      i32.add
                                                                      i32.ge_s
                                                                      select
                                                                      array.new_default 8
                                                                      local.set 188
                                                                      local.get 188
                                                                      i32.const 0
                                                                      local.get 187
                                                                      i32.const 0
                                                                      local.get 189
                                                                      array.copy 8 8
                                                                      local.get 190
                                                                      local.get 188
                                                                      struct.set 9 0
                                                                    end
                                                                    local.get 42
                                                                    struct.new 2
                                                                    ref.cast (ref null 2)
                                                                    local.set 48
                                                                    local.get 48
                                                                    local.set 191
                                                                    local.get 35
                                                                    local.get 191
                                                                    struct.set 9 1
                                                                    local.get 191
                                                                    ref.cast (ref null 2)
                                                                    local.set 49
                                                                    local.get 35
                                                                    struct.get 9 1
                                                                    local.set 50
                                                                    i32.const 0
                                                                    local.set 51
                                                                    local.get 50
                                                                    struct.get 2 0
                                                                    local.set 52
                                                                    local.get 35
                                                                    struct.get 9 0
                                                                    local.set 53
                                                                    local.get 53
                                                                    local.get 52
                                                                    i32.wrap_i64
                                                                    i32.const 1
                                                                    i32.sub
                                                                    local.get 34
                                                                    array.set 8
                                                                    local.get 34
                                                                    ref.cast (ref null 7)
                                                                    local.set 54
                                                                    local.get 1
                                                                    struct.get 11 1
                                                                    local.set 55
                                                                    local.get 3
                                                                    i32.eqz
                                                                    br_if 0 (;@32;)
                                                                    local.get 0
                                                                    local.get 55
                                                                    local.get 2
                                                                    local.get 4
                                                                    call 2
                                                                    local.set 56
                                                                    local.get 56
                                                                    local.set 5
                                                                    br 1 (;@31;)
                                                                  end
                                                                  local.get 55
                                                                  local.get 0
                                                                  local.get 2
                                                                  local.get 4
                                                                  call 2
                                                                  local.set 57
                                                                  local.get 57
                                                                  local.set 5
                                                                  br 0 (;@31;)
                                                                end
                                                                local.get 2
                                                                struct.get 10 0
                                                                local.set 58
                                                                local.get 58
                                                                struct.get 9 1
                                                                local.set 59
                                                                i32.const 0
                                                                local.set 60
                                                                local.get 59
                                                                struct.get 2 0
                                                                local.set 61
                                                                local.get 61
                                                                i64.const 0
                                                                i64.eq
                                                                local.set 62
                                                                local.get 62
                                                                i32.eqz
                                                                br_if 0 (;@30;)
                                                                i32.const 97
                                                                i32.const 114
                                                                i32.const 114
                                                                i32.const 97
                                                                i32.const 121
                                                                i32.const 32
                                                                i32.const 109
                                                                i32.const 117
                                                                i32.const 115
                                                                i32.const 116
                                                                i32.const 32
                                                                i32.const 98
                                                                i32.const 101
                                                                i32.const 32
                                                                i32.const 110
                                                                i32.const 111
                                                                i32.const 110
                                                                i32.const 45
                                                                i32.const 101
                                                                i32.const 109
                                                                i32.const 112
                                                                i32.const 116
                                                                i32.const 121
                                                                array.new_fixed 5 23
                                                                throw 0
                                                                return
                                                              end
                                                              local.get 58
                                                              struct.get 9 1
                                                              local.set 63
                                                              i32.const 0
                                                              local.set 64
                                                              local.get 63
                                                              struct.get 2 0
                                                              local.set 65
                                                              br 0 (;@29;)
                                                            end
                                                            local.get 58
                                                            struct.get 9 0
                                                            local.set 75
                                                            local.get 75
                                                            local.get 65
                                                            i32.wrap_i64
                                                            i32.const 1
                                                            i32.sub
                                                            array.get 8
                                                            ref.cast (ref null 7)
                                                            local.set 76
                                                            local.get 58
                                                            struct.get 9 1
                                                            local.set 77
                                                            i32.const 0
                                                            local.set 78
                                                            local.get 77
                                                            struct.get 2 0
                                                            local.set 79
                                                            i64.const 1
                                                            local.get 79
                                                            i64.le_s
                                                            local.set 80
                                                            local.get 80
                                                            i32.eqz
                                                            br_if 6 (;@22;)
                                                            local.get 79
                                                            i64.const 1
                                                            i64.sub
                                                            local.set 81
                                                            local.get 81
                                                            i64.const 1
                                                            i64.add
                                                            local.set 82
                                                            local.get 82
                                                            local.get 79
                                                            i64.le_s
                                                            local.set 83
                                                            local.get 83
                                                            i32.eqz
                                                            br_if 0 (;@28;)
                                                            local.get 79
                                                            local.set 6
                                                            br 1 (;@27;)
                                                          end
                                                          local.get 82
                                                          i64.const 1
                                                          i64.sub
                                                          local.set 84
                                                          local.get 84
                                                          local.set 6
                                                          br 0 (;@27;)
                                                        end
                                                        local.get 6
                                                        local.get 82
                                                        i64.lt_s
                                                        local.set 85
                                                        local.get 85
                                                        i32.eqz
                                                        br_if 0 (;@26;)
                                                        i32.const 1
                                                        local.set 7
                                                        br 1 (;@25;)
                                                      end
                                                      i32.const 0
                                                      local.set 7
                                                      local.get 82
                                                      local.set 8
                                                      local.get 82
                                                      local.set 9
                                                      br 0 (;@25;)
                                                    end
                                                    local.get 7
                                                    i32.eqz
                                                    local.set 86
                                                    local.get 86
                                                    i32.eqz
                                                    br_if 1 (;@23;)
                                                    local.get 8
                                                    local.set 10
                                                    local.get 9
                                                    local.set 11
                                                  end
                                                  loop ;; label = @24
                                                    block ;; label = @25
                                                      block ;; label = @26
                                                        block ;; label = @27
                                                          block ;; label = @28
                                                            br 0 (;@28;)
                                                          end
                                                          local.get 58
                                                          struct.get 9 0
                                                          local.set 96
                                                          i32.const 0
                                                          local.set 97
                                                          br 0 (;@27;)
                                                        end
                                                        ref.null 8
                                                        local.set 100
                                                        i64.const 0
                                                        local.set 102
                                                        local.get 102
                                                        local.set 103
                                                        unreachable
                                                        drop
                                                        local.get 11
                                                        local.get 6
                                                        i64.eq
                                                        local.set 104
                                                        local.get 104
                                                        i32.eqz
                                                        br_if 0 (;@26;)
                                                        i32.const 1
                                                        local.set 14
                                                        br 1 (;@25;)
                                                      end
                                                      local.get 11
                                                      i64.const 1
                                                      i64.add
                                                      local.set 105
                                                      local.get 105
                                                      local.set 12
                                                      local.get 105
                                                      local.set 13
                                                      i32.const 0
                                                      local.set 14
                                                      br 0 (;@25;)
                                                    end
                                                    local.get 14
                                                    i32.eqz
                                                    local.set 106
                                                    local.get 106
                                                    i32.eqz
                                                    br_if 1 (;@23;)
                                                    local.get 12
                                                    local.set 10
                                                    local.get 13
                                                    local.set 11
                                                    br 0 (;@24;)
                                                  end
                                                end
                                                local.get 81
                                                struct.new 2
                                                ref.cast (ref null 2)
                                                local.set 107
                                                local.get 107
                                                local.set 192
                                                local.get 58
                                                local.get 192
                                                struct.set 9 1
                                                local.get 192
                                                ref.cast (ref null 2)
                                                local.set 108
                                                br 1 (;@21;)
                                              end
                                              unreachable
                                              local.get 109
                                              throw 0
                                              return
                                            end
                                            local.get 5
                                            if ;; label = @21
                                            else
                                              local.get 5
                                              local.set 30
                                              br 20 (;@1;)
                                            end
                                            local.get 3
                                            if ;; label = @21
                                            else
                                              local.get 5
                                              local.set 18
                                              br 9 (;@12;)
                                            end
                                            local.get 34
                                            struct.get 7 1
                                            local.set 110
                                            local.get 110
                                            global.get 0
                                            local.set 193
                                            any.convert_extern
                                            ref.cast eqref
                                            local.get 193
                                            ref.eq
                                            local.set 111
                                            local.get 111
                                            i32.eqz
                                            br_if 0 (;@20;)
                                            local.get 111
                                            local.set 17
                                            br 7 (;@13;)
                                          end
                                          local.get 34
                                          struct.get 7 2
                                          local.set 112
                                          local.get 112
                                          global.get 1
                                          local.set 194
                                          any.convert_extern
                                          ref.cast eqref
                                          local.get 194
                                          ref.eq
                                          local.set 113
                                          local.get 113
                                          i32.eqz
                                          br_if 0 (;@19;)
                                          local.get 113
                                          local.set 16
                                          br 5 (;@14;)
                                        end
                                        local.get 34
                                        struct.get 7 1
                                        local.set 114
                                        local.get 34
                                        struct.get 7 2
                                        local.set 115
                                        local.get 114
                                        local.get 115
                                        any.convert_extern
                                        ref.cast eqref
                                        local.set 195
                                        any.convert_extern
                                        ref.cast eqref
                                        local.get 195
                                        ref.eq
                                        local.set 116
                                        local.get 116
                                        i32.eqz
                                        br_if 0 (;@18;)
                                        i32.const 1
                                        local.set 15
                                        br 3 (;@15;)
                                      end
                                      local.get 114
                                      global.get 0
                                      local.set 196
                                      any.convert_extern
                                      ref.cast eqref
                                      local.get 196
                                      ref.eq
                                      local.set 117
                                      local.get 117
                                      i32.eqz
                                      br_if 0 (;@17;)
                                      i32.const 1
                                      local.set 15
                                      br 2 (;@15;)
                                    end
                                    local.get 115
                                    global.get 1
                                    local.set 197
                                    any.convert_extern
                                    ref.cast eqref
                                    local.get 197
                                    ref.eq
                                    local.set 118
                                    local.get 118
                                    i32.eqz
                                    br_if 0 (;@16;)
                                    i32.const 1
                                    local.set 15
                                    br 1 (;@15;)
                                  end
                                  i32.const 16
                                  array.new_default 8
                                  ref.cast (ref null 8)
                                  local.set 119
                                  local.get 119
                                  ref.cast (ref null 8)
                                  local.set 120
                                  local.get 120
                                  i64.const 0
                                  struct.new 2
                                  struct.new 9
                                  ref.cast (ref null 9)
                                  local.set 121
                                  local.get 121
                                  i64.const 0
                                  struct.new 10
                                  ref.cast (ref null 10)
                                  local.set 122
                                  local.get 114
                                  local.get 115
                                  local.get 122
                                  i64.const 0
                                  call 2
                                  local.set 123
                                  local.get 123
                                  local.set 15
                                  br 0 (;@15;)
                                end
                                local.get 15
                                local.set 16
                              end
                              local.get 16
                              local.set 17
                            end
                            local.get 17
                            i32.eqz
                            local.set 124
                            local.get 124
                            if ;; label = @13
                            else
                              local.get 5
                              local.set 18
                              br 1 (;@12;)
                            end
                            i32.const 0
                            local.set 18
                          end
                          local.get 18
                          if ;; label = @12
                          else
                            local.get 18
                            local.set 20
                            br 5 (;@7;)
                          end
                          local.get 3
                          if ;; label = @12
                          else
                            local.get 18
                            local.set 20
                            br 5 (;@7;)
                          end
                          local.get 34
                          struct.get 7 5
                          local.set 125
                          i64.const 1
                          local.get 125
                          i64.lt_s
                          local.set 126
                          local.get 126
                          if ;; label = @12
                          else
                            local.get 18
                            local.set 20
                            br 5 (;@7;)
                          end
                          local.get 34
                          struct.get 7 4
                          local.set 127
                          local.get 127
                          i64.const 0
                          i64.eq
                          local.set 128
                          local.get 128
                          if ;; label = @12
                          else
                            local.get 18
                            local.set 20
                            br 5 (;@7;)
                          end
                          local.get 34
                          struct.get 7 1
                          local.set 129
                          local.get 129
                          global.get 0
                          local.set 198
                          any.convert_extern
                          ref.cast eqref
                          local.get 198
                          ref.eq
                          local.set 130
                          local.get 130
                          i32.eqz
                          local.set 131
                          local.get 131
                          if ;; label = @12
                          else
                            local.get 18
                            local.set 20
                            br 5 (;@7;)
                          end
                          local.get 34
                          struct.get 7 1
                          local.set 132
                          local.get 132
                          any.convert_extern
                          ref.test (ref 16)
                          local.set 133
                          local.get 133
                          i32.eqz
                          br_if 0 (;@11;)
                          local.get 132
                          any.convert_extern
                          ref.cast (ref null 16)
                          local.set 134
                          local.get 134
                          struct.get 16 7
                          local.set 135
                          local.get 135
                          i32.const 2
                          i32.and
                          local.set 136
                          local.get 136
                          i32.const 2
                          i32.eq
                          local.set 137
                          local.get 137
                          local.set 19
                          br 3 (;@8;)
                        end
                        local.get 132
                        drop
                        i32.const 0
                        local.set 138
                        local.get 138
                        i32.eqz
                        local.set 139
                        local.get 139
                        i32.eqz
                        br_if 1 (;@9;)
                        local.get 132
                        any.convert_extern
                        ref.test (ref 6)
                        local.set 140
                        local.get 140
                        i32.eqz
                        local.set 141
                        local.get 141
                        i32.eqz
                        br_if 0 (;@10;)
                        i32.const 1
                        local.set 19
                        br 2 (;@8;)
                      end
                    end
                    i32.const 0
                    local.set 19
                    br 0 (;@8;)
                  end
                  local.get 19
                  i32.eqz
                  local.set 142
                  local.get 142
                  if ;; label = @8
                  else
                    local.get 18
                    local.set 20
                    br 1 (;@7;)
                  end
                  i32.const 0
                  local.set 20
                end
                local.get 20
                if ;; label = @7
                else
                  local.get 20
                  local.set 30
                  br 6 (;@1;)
                end
                local.get 2
                struct.get 10 0
                local.set 143
                local.get 143
                struct.get 9 1
                local.set 144
                i32.const 0
                local.set 145
                local.get 144
                struct.get 2 0
                local.set 146
                i64.const 1
                local.get 146
                i64.le_s
                local.set 147
                local.get 147
                i32.eqz
                br_if 0 (;@6;)
                local.get 146
                local.set 21
                br 1 (;@5;)
              end
              i64.const 0
              local.set 21
              br 0 (;@5;)
            end
            local.get 21
            i64.const 1
            i64.lt_s
            local.set 148
            local.get 148
            i32.eqz
            br_if 0 (;@4;)
            i32.const 1
            local.set 22
            br 1 (;@3;)
          end
          i32.const 0
          local.set 22
          i64.const 1
          local.set 23
          i64.const 1
          local.set 24
          br 0 (;@3;)
        end
        local.get 22
        i32.eqz
        local.set 149
        local.get 149
        if ;; label = @3
        else
          local.get 20
          local.set 30
          br 2 (;@1;)
        end
        local.get 23
        local.set 25
        local.get 24
        local.set 26
      end
      loop ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  local.get 2
                  struct.get 10 0
                  local.set 150
                  br 0 (;@7;)
                end
                local.get 150
                struct.get 9 0
                local.set 160
                local.get 160
                local.get 25
                i32.wrap_i64
                i32.const 1
                i32.sub
                array.get 8
                ref.cast (ref null 7)
                local.set 161
                local.get 161
                struct.get 7 1
                local.set 162
                local.get 162
                global.get 0
                local.set 199
                any.convert_extern
                ref.cast eqref
                local.get 199
                ref.eq
                local.set 163
                local.get 163
                i32.eqz
                local.set 164
                local.get 164
                i32.eqz
                br_if 0 (;@6;)
                local.get 161
                struct.get 7 1
                local.set 165
                local.get 161
                struct.get 7 0
                local.set 166
                local.get 166
                struct.get 6 1
                local.set 167
                local.get 165
                local.get 167
                any.convert_extern
                ref.cast eqref
                local.set 200
                any.convert_extern
                ref.cast eqref
                local.get 200
                ref.eq
                local.set 168
                local.get 168
                i32.eqz
                local.set 169
                local.get 169
                i32.eqz
                br_if 0 (;@6;)
                local.get 161
                struct.get 7 1
                local.set 170
                local.get 34
                struct.get 7 0
                local.set 171
                local.get 170
                local.get 171
                call 12
                local.set 172
                local.get 172
                i32.eqz
                br_if 0 (;@6;)
                i32.const 0
                local.set 30
                br 5 (;@1;)
              end
              local.get 161
              struct.get 7 2
              local.set 173
              local.get 173
              global.get 1
              local.set 201
              any.convert_extern
              ref.cast eqref
              local.get 201
              ref.eq
              local.set 174
              local.get 174
              i32.eqz
              local.set 175
              local.get 175
              i32.eqz
              br_if 0 (;@5;)
              local.get 161
              struct.get 7 2
              local.set 176
              local.get 161
              struct.get 7 0
              local.set 177
              local.get 177
              struct.get 6 2
              local.set 178
              local.get 176
              local.get 178
              any.convert_extern
              ref.cast eqref
              local.set 202
              any.convert_extern
              ref.cast eqref
              local.get 202
              ref.eq
              local.set 179
              local.get 179
              i32.eqz
              local.set 180
              local.get 180
              i32.eqz
              br_if 0 (;@5;)
              local.get 161
              struct.get 7 2
              local.set 181
              local.get 34
              struct.get 7 0
              local.set 182
              local.get 181
              local.get 182
              call 12
              local.set 183
              local.get 183
              i32.eqz
              br_if 0 (;@5;)
              i32.const 0
              local.set 30
              br 4 (;@1;)
            end
            local.get 26
            local.get 21
            i64.eq
            local.set 184
            local.get 184
            i32.eqz
            br_if 0 (;@4;)
            i32.const 1
            local.set 29
            br 1 (;@3;)
          end
          local.get 26
          i64.const 1
          i64.add
          local.set 185
          local.get 185
          local.set 27
          local.get 185
          local.set 28
          i32.const 0
          local.set 29
          br 0 (;@3;)
        end
        local.get 29
        i32.eqz
        local.set 186
        local.get 186
        if ;; label = @3
        else
          local.get 20
          local.set 30
          br 2 (;@1;)
        end
        local.get 27
        local.set 25
        local.get 28
        local.set 26
        br 0 (;@2;)
      end
    end
    local.get 30
    return
    unreachable
  )
  (func (;10;) (type 29) (param externref externref (ref null 10) i32 i64) (result i32)
    (local i32 i32)
    local.get 3
    if (result i32) ;; label = @1
      local.get 0
      local.get 1
      local.get 2
      local.get 4
      call 2
      local.set 5
      local.get 5
    else
      local.get 1
      local.get 0
      local.get 2
      local.get 4
      call 2
      local.set 6
      local.get 6
    end
    return
  )
  (func (;11;) (type 30) (param externref) (result i32)
    (local i32 (ref null 16) i32 i32 i32 i32 i32 i32 i32)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          local.get 0
          any.convert_extern
          ref.test (ref 16)
          local.set 1
          local.get 1
          i32.eqz
          br_if 0 (;@3;)
          local.get 0
          any.convert_extern
          ref.cast (ref null 16)
          local.set 2
          local.get 2
          struct.get 16 7
          local.set 3
          local.get 3
          i32.const 2
          i32.and
          local.set 4
          local.get 4
          i32.const 2
          i32.eq
          local.set 5
          local.get 5
          return
        end
        local.get 0
        drop
        i32.const 0
        local.set 6
        local.get 6
        i32.eqz
        local.set 7
        local.get 7
        i32.eqz
        br_if 1 (;@1;)
        local.get 0
        any.convert_extern
        ref.test (ref 6)
        local.set 8
        local.get 8
        i32.eqz
        local.set 9
        local.get 9
        i32.eqz
        br_if 0 (;@2;)
        i32.const 1
        return
      end
    end
    i32.const 0
    return
    unreachable
  )
  (func (;12;) (type 31) (param externref (ref null 6)) (result i32)
    (local i32 externref i64 externref i64 externref i64 i32 i32 i32 i32 (ref null 18) externref i32 (ref null 18) externref i32 i32 (ref null 11) externref i32 (ref null 11) (ref null 6) i32 i32 (ref null 16) (ref null 13) i64 i32 (ref null 13) i32 i32 i64 i32 (ref null 13) i64 i32 eqref)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  block ;; label = @8
                    block ;; label = @9
                      block ;; label = @10
                        block ;; label = @11
                          local.get 0
                          local.get 1
                          local.set 39
                          any.convert_extern
                          ref.cast eqref
                          local.get 39
                          ref.eq
                          local.set 10
                          local.get 10
                          i32.eqz
                          br_if 0 (;@11;)
                          i32.const 1
                          return
                        end
                        local.get 0
                        any.convert_extern
                        ref.test (ref 6)
                        local.set 11
                        local.get 11
                        i32.eqz
                        br_if 0 (;@10;)
                        i32.const 0
                        return
                      end
                      local.get 0
                      any.convert_extern
                      ref.test (ref 18)
                      local.set 12
                      local.get 12
                      i32.eqz
                      br_if 1 (;@8;)
                      local.get 0
                      any.convert_extern
                      ref.cast (ref null 18)
                      local.set 13
                      local.get 13
                      struct.get 18 0
                      local.set 14
                      local.get 14
                      local.get 1
                      call 12
                      local.set 15
                      local.get 15
                      i32.eqz
                      br_if 0 (;@9;)
                      local.get 15
                      return
                    end
                    local.get 0
                    any.convert_extern
                    ref.cast (ref null 18)
                    local.set 16
                    local.get 16
                    struct.get 18 1
                    local.set 17
                    local.get 17
                    local.get 1
                    call 12
                    local.set 18
                    local.get 18
                    return
                  end
                  local.get 0
                  any.convert_extern
                  ref.test (ref 11)
                  local.set 19
                  local.get 19
                  i32.eqz
                  br_if 1 (;@6;)
                  local.get 0
                  any.convert_extern
                  ref.cast (ref null 11)
                  local.set 20
                  local.get 20
                  struct.get 11 1
                  local.set 21
                  local.get 21
                  local.get 1
                  call 12
                  local.set 22
                  local.get 22
                  i32.eqz
                  br_if 0 (;@7;)
                  local.get 22
                  return
                end
                local.get 0
                any.convert_extern
                ref.cast (ref null 11)
                local.set 23
                local.get 23
                struct.get 11 0
                local.set 24
                local.get 24
                local.get 1
                ref.eq
                local.set 25
                local.get 25
                return
              end
              local.get 0
              any.convert_extern
              ref.test (ref 16)
              local.set 26
              local.get 26
              i32.eqz
              br_if 4 (;@1;)
              local.get 0
              any.convert_extern
              ref.cast (ref null 16)
              local.set 27
              local.get 27
              struct.get 16 2
              local.set 28
              local.get 28
              local.get 28
              array.len
              i64.extend_i32_u
              local.set 29
              local.get 29
              i64.const 1
              i64.lt_s
              local.set 30
              local.get 30
              i32.eqz
              br_if 0 (;@5;)
              i32.const 1
              local.set 2
              br 1 (;@4;)
            end
            local.get 28
            i64.const 1
            local.get 28
            i64.const 1
            i32.wrap_i64
            i32.const 1
            i32.sub
            array.get 13
            any.convert_extern
            ref.cast (ref null 13)
            local.set 31
            i32.const 0
            local.set 2
            local.get 31
            extern.convert_any
            local.set 3
            i64.const 2
            local.set 4
            br 0 (;@4;)
          end
          local.get 2
          i32.eqz
          local.set 32
          local.get 32
          i32.eqz
          br_if 1 (;@2;)
          local.get 3
          local.set 5
          local.get 4
          local.set 6
        end
        loop ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                local.get 5
                local.get 1
                call 12
                local.set 33
                local.get 33
                i32.eqz
                br_if 0 (;@6;)
                i32.const 1
                return
              end
              local.get 28
              local.get 28
              array.len
              i64.extend_i32_u
              local.set 34
              local.get 34
              local.get 6
              i64.lt_s
              local.set 35
              local.get 35
              i32.eqz
              br_if 0 (;@5;)
              i32.const 1
              local.set 9
              br 1 (;@4;)
            end
            local.get 28
            local.get 6
            i32.wrap_i64
            i32.const 1
            i32.sub
            array.get 13
            any.convert_extern
            ref.cast (ref null 13)
            local.set 36
            local.get 6
            i64.const 1
            i64.add
            local.set 37
            local.get 36
            extern.convert_any
            local.set 7
            local.get 37
            local.set 8
            i32.const 0
            local.set 9
            br 0 (;@4;)
          end
          local.get 9
          i32.eqz
          local.set 38
          local.get 38
          i32.eqz
          br_if 1 (;@2;)
          local.get 7
          local.set 5
          local.get 8
          local.set 6
          br 0 (;@3;)
        end
      end
      i32.const 0
      return
    end
    i32.const 0
    return
    unreachable
  )
  (func (;13;) (type 17) (param externref externref) (result i32)
    (local i32 i32 i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32 eqref eqref eqref)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          local.get 0
          local.get 1
          any.convert_extern
          ref.cast eqref
          local.set 10
          any.convert_extern
          ref.cast eqref
          local.get 10
          ref.eq
          local.set 2
          local.get 2
          i32.eqz
          br_if 0 (;@3;)
          i32.const 1
          return
        end
        local.get 0
        global.get 0
        local.set 11
        any.convert_extern
        ref.cast eqref
        local.get 11
        ref.eq
        local.set 3
        local.get 3
        i32.eqz
        br_if 0 (;@2;)
        i32.const 1
        return
      end
      local.get 1
      global.get 1
      local.set 12
      any.convert_extern
      ref.cast eqref
      local.get 12
      ref.eq
      local.set 4
      local.get 4
      i32.eqz
      br_if 0 (;@1;)
      i32.const 1
      return
    end
    i32.const 16
    array.new_default 8
    ref.cast (ref null 8)
    local.set 5
    local.get 5
    ref.cast (ref null 8)
    local.set 6
    local.get 6
    i64.const 0
    struct.new 2
    struct.new 9
    ref.cast (ref null 9)
    local.set 7
    local.get 7
    i64.const 0
    struct.new 10
    ref.cast (ref null 10)
    local.set 8
    local.get 0
    local.get 1
    local.get 8
    i64.const 0
    call 2
    local.set 9
    local.get 9
    return
    unreachable
  )
  (func (;14;) (type 32) (param (ref null 16) (ref null 16) (ref null 10) i64) (result i32)
    (local (ref null 16) i64 i32 i64 i64 i64 i64 i64 i64 i32 i32 i32 i32 (ref null 15) i32 (ref null 15) i32 i32 (ref null 15) (ref null 15) i32 i32 i32 (ref null 13) i64 i32 (ref null 13) i32 i32 i32 i32 i32 i32 (ref null 15) (ref null 15) i32 i32 (ref null 16) i32 (ref null 13) (ref null 13) i64 i64 i32 i32 i32 i64 i64 i32 i32 i32 (ref null 13) (ref null 13) i32 i32 i32 i64 i32 i64 i64)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  block ;; label = @8
                    block ;; label = @9
                      block ;; label = @10
                        block ;; label = @11
                          block ;; label = @12
                            block ;; label = @13
                              block ;; label = @14
                                block ;; label = @15
                                  block ;; label = @16
                                    block ;; label = @17
                                      local.get 0
                                      local.get 1
                                      ref.eq
                                      local.set 15
                                      local.get 15
                                      i32.eqz
                                      br_if 0 (;@17;)
                                      i32.const 1
                                      return
                                    end
                                    local.get 1
                                    global.get 1
                                    ref.eq
                                    local.set 16
                                    local.get 16
                                    i32.eqz
                                    br_if 0 (;@16;)
                                    i32.const 1
                                    return
                                  end
                                  local.get 0
                                  struct.get 16 0
                                  local.set 17
                                  local.get 17
                                  ref.null 15
                                  ref.eq
                                  local.set 18
                                  local.get 18
                                  i32.eqz
                                  br_if 0 (;@15;)
                                  local.get 1
                                  struct.get 16 0
                                  local.set 19
                                  local.get 19
                                  ref.null 15
                                  ref.eq
                                  local.set 20
                                  local.get 20
                                  i32.eqz
                                  br_if 0 (;@15;)
                                  local.get 0
                                  local.get 1
                                  local.get 2
                                  local.get 3
                                  call 16
                                  local.set 21
                                  local.get 21
                                  return
                                end
                                local.get 0
                                struct.get 16 0
                                local.set 22
                                local.get 1
                                struct.get 16 0
                                local.set 23
                                local.get 22
                                ref.null 15
                                ref.eq
                                local.set 24
                                local.get 24
                                i32.eqz
                                br_if 2 (;@12;)
                                local.get 23
                                ref.null 15
                                ref.eq
                                local.set 25
                                local.get 25
                                i32.eqz
                                local.set 26
                                local.get 26
                                i32.eqz
                                br_if 2 (;@12;)
                                local.get 0
                                struct.get 16 2
                                local.set 27
                                local.get 27
                                local.get 27
                                array.len
                                i64.extend_i32_u
                                local.set 28
                                i64.const 0
                                local.get 28
                                i64.lt_s
                                local.set 29
                                local.get 29
                                i32.eqz
                                br_if 1 (;@13;)
                                local.get 27
                                i64.const 1
                                local.get 27
                                i64.const 1
                                i32.wrap_i64
                                i32.const 1
                                i32.sub
                                array.get 13
                                any.convert_extern
                                ref.cast (ref null 13)
                                local.set 30
                                local.get 30
                                ref.is_null
                                i32.eqz
                                local.set 31
                                local.get 31
                                i32.eqz
                                local.set 32
                                local.get 32
                                i32.eqz
                                br_if 1 (;@13;)
                                local.get 30
                                ref.is_null
                                i32.eqz
                                local.set 33
                                local.get 33
                                i32.eqz
                                br_if 0 (;@14;)
                                global.get 3
                                local.get 1
                                call 18
                                local.set 34
                                local.get 34
                                return
                              end
                              i32.const 0
                              return
                            end
                            i32.const 0
                            return
                          end
                          local.get 0
                          local.set 4
                        end
                        loop ;; label = @11
                          local.get 4
                          global.get 1
                          ref.eq
                          local.set 35
                          local.get 35
                          i32.eqz
                          local.set 36
                          local.get 36
                          i32.eqz
                          br_if 1 (;@10;)
                          local.get 4
                          struct.get 16 0
                          local.set 37
                          local.get 1
                          struct.get 16 0
                          local.set 38
                          local.get 37
                          local.get 38
                          ref.eq
                          local.set 39
                          local.get 39
                          i32.eqz
                          local.set 40
                          local.get 40
                          i32.eqz
                          br_if 1 (;@10;)
                          local.get 4
                          struct.get 16 1
                          ref.cast (ref null 16)
                          local.set 41
                          local.get 41
                          local.set 4
                          br 0 (;@11;)
                        end
                      end
                      local.get 4
                      global.get 1
                      ref.eq
                      local.set 42
                      local.get 42
                      i32.eqz
                      br_if 0 (;@9;)
                      i32.const 0
                      return
                    end
                    local.get 4
                    struct.get 16 2
                    local.set 43
                    local.get 1
                    struct.get 16 2
                    local.set 44
                    local.get 43
                    local.get 43
                    array.len
                    i64.extend_i32_u
                    local.set 45
                    local.get 44
                    local.get 44
                    array.len
                    i64.extend_i32_u
                    local.set 46
                    local.get 45
                    local.get 46
                    i64.eq
                    local.set 47
                    local.get 47
                    i32.eqz
                    local.set 48
                    local.get 48
                    i32.eqz
                    br_if 0 (;@8;)
                    i32.const 0
                    return
                  end
                  local.get 45
                  i64.const 0
                  i64.eq
                  local.set 49
                  local.get 49
                  i32.eqz
                  br_if 0 (;@7;)
                  i32.const 1
                  return
                end
                local.get 2
                struct.get 10 1
                local.set 50
                local.get 50
                i64.const 1
                i64.add
                local.set 51
                local.get 2
                local.get 51
                struct.set 10 1
                local.get 51
                drop
                i64.const 1
                local.get 45
                i64.le_s
                local.set 52
                local.get 52
                i32.eqz
                br_if 0 (;@6;)
                local.get 45
                local.set 5
                br 1 (;@5;)
              end
              i64.const 0
              local.set 5
              br 0 (;@5;)
            end
            local.get 5
            i64.const 1
            i64.lt_s
            local.set 53
            local.get 53
            i32.eqz
            br_if 0 (;@4;)
            i32.const 1
            local.set 6
            br 1 (;@3;)
          end
          i32.const 0
          local.set 6
          i64.const 1
          local.set 7
          i64.const 1
          local.set 8
          br 0 (;@3;)
        end
        local.get 6
        i32.eqz
        local.set 54
        local.get 54
        if ;; label = @3
        else
          i32.const 1
          local.set 14
          br 2 (;@1;)
        end
        local.get 7
        local.set 9
        local.get 8
        local.set 10
      end
      loop ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              local.get 43
              local.get 9
              i32.wrap_i64
              i32.const 1
              i32.sub
              array.get 13
              any.convert_extern
              ref.cast (ref null 13)
              local.set 55
              local.get 44
              local.get 9
              i32.wrap_i64
              i32.const 1
              i32.sub
              array.get 13
              any.convert_extern
              ref.cast (ref null 13)
              local.set 56
              local.get 55
              extern.convert_any
              local.get 56
              extern.convert_any
              local.get 2
              call 15
              local.set 57
              local.get 57
              i32.eqz
              local.set 58
              local.get 58
              i32.eqz
              br_if 0 (;@5;)
              i32.const 0
              local.set 14
              br 4 (;@1;)
            end
            local.get 10
            local.get 5
            i64.eq
            local.set 59
            local.get 59
            i32.eqz
            br_if 0 (;@4;)
            i32.const 1
            local.set 13
            br 1 (;@3;)
          end
          local.get 10
          i64.const 1
          i64.add
          local.set 60
          local.get 60
          local.set 11
          local.get 60
          local.set 12
          i32.const 0
          local.set 13
          br 0 (;@3;)
        end
        local.get 13
        i32.eqz
        local.set 61
        local.get 61
        if ;; label = @3
        else
          i32.const 1
          local.set 14
          br 2 (;@1;)
        end
        local.get 11
        local.set 9
        local.get 12
        local.set 10
        br 0 (;@2;)
      end
    end
    local.get 2
    struct.get 10 1
    local.set 62
    local.get 62
    i64.const 1
    i64.sub
    local.set 63
    local.get 2
    local.get 63
    struct.set 10 1
    local.get 63
    drop
    local.get 14
    return
    unreachable
  )
  (func (;15;) (type 33) (param externref externref (ref null 10)) (result i32)
    (local i32 i32 i32 i32 i32 (ref null 6) (ref null 7) i32 i32 i32 (ref null 6) (ref null 7) i32 i32 (ref null 6) (ref null 6) (ref null 7) (ref null 7) externref externref externref externref i32 (ref null 6) (ref null 6) i32 i32 (ref null 7) (ref null 7) (ref null 6) (ref null 7) externref externref i32 (ref null 6) i32 i32 (ref null 7) i32 (ref null 6) (ref null 7) i32 i32 (ref null 6) (ref null 7) externref externref i32 (ref null 6) i32 i32 (ref null 7) i32 i32 externref externref i32 externref externref i32 i32 eqref eqref)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  block ;; label = @8
                    block ;; label = @9
                      block ;; label = @10
                        block ;; label = @11
                          block ;; label = @12
                            block ;; label = @13
                              block ;; label = @14
                                block ;; label = @15
                                  local.get 0
                                  local.get 1
                                  any.convert_extern
                                  ref.cast eqref
                                  local.set 64
                                  any.convert_extern
                                  ref.cast eqref
                                  local.get 64
                                  ref.eq
                                  local.set 6
                                  local.get 6
                                  i32.eqz
                                  br_if 0 (;@15;)
                                  i32.const 1
                                  return
                                end
                                local.get 0
                                any.convert_extern
                                ref.test (ref 6)
                                local.set 7
                                local.get 7
                                i32.eqz
                                br_if 7 (;@7;)
                                local.get 0
                                any.convert_extern
                                ref.cast (ref null 6)
                                local.set 8
                                local.get 2
                                local.get 8
                                call 3
                                ref.cast (ref null 7)
                                local.set 9
                                local.get 9
                                ref.is_null
                                local.set 10
                                local.get 10
                                i32.eqz
                                local.set 11
                                local.get 11
                                i32.eqz
                                br_if 7 (;@7;)
                                local.get 1
                                any.convert_extern
                                ref.test (ref 6)
                                local.set 12
                                local.get 12
                                i32.eqz
                                br_if 3 (;@11;)
                                local.get 1
                                any.convert_extern
                                ref.cast (ref null 6)
                                local.set 13
                                local.get 2
                                local.get 13
                                call 3
                                ref.cast (ref null 7)
                                local.set 14
                                local.get 14
                                ref.is_null
                                local.set 15
                                local.get 15
                                i32.eqz
                                local.set 16
                                local.get 16
                                i32.eqz
                                br_if 3 (;@11;)
                                local.get 0
                                any.convert_extern
                                ref.cast (ref null 6)
                                local.set 17
                                local.get 1
                                any.convert_extern
                                ref.cast (ref null 6)
                                local.set 18
                                local.get 14
                                local.set 19
                                local.get 9
                                local.set 20
                                local.get 20
                                struct.get 7 1
                                local.set 21
                                local.get 20
                                struct.get 7 2
                                local.set 22
                                local.get 19
                                struct.get 7 1
                                local.set 23
                                local.get 19
                                struct.get 7 2
                                local.set 24
                                local.get 17
                                extern.convert_any
                                local.get 18
                                extern.convert_any
                                local.get 2
                                i64.const 2
                                call 2
                                local.set 25
                                local.get 25
                                i32.eqz
                                br_if 0 (;@14;)
                                local.get 0
                                any.convert_extern
                                ref.cast (ref null 6)
                                local.set 26
                                local.get 1
                                any.convert_extern
                                ref.cast (ref null 6)
                                local.set 27
                                local.get 27
                                extern.convert_any
                                local.get 26
                                extern.convert_any
                                local.get 2
                                i64.const 2
                                call 2
                                local.set 28
                                local.get 28
                                local.set 3
                                br 1 (;@13;)
                              end
                              i32.const 0
                              local.set 3
                            end
                            local.get 3
                            i32.eqz
                            local.set 29
                            local.get 29
                            i32.eqz
                            br_if 0 (;@12;)
                            local.get 14
                            local.set 30
                            local.get 9
                            local.set 31
                            local.get 31
                            local.get 21
                            struct.set 7 1
                            local.get 21
                            drop
                            local.get 31
                            local.get 22
                            struct.set 7 2
                            local.get 22
                            drop
                            local.get 30
                            local.get 23
                            struct.set 7 1
                            local.get 23
                            drop
                            local.get 30
                            local.get 24
                            struct.set 7 2
                            local.get 24
                            drop
                          end
                          local.get 3
                          return
                        end
                        local.get 0
                        any.convert_extern
                        ref.cast (ref null 6)
                        local.set 32
                        local.get 9
                        local.set 33
                        local.get 33
                        struct.get 7 1
                        local.set 34
                        local.get 33
                        struct.get 7 2
                        local.set 35
                        local.get 32
                        extern.convert_any
                        local.get 1
                        local.get 2
                        i64.const 2
                        call 2
                        local.set 36
                        local.get 36
                        i32.eqz
                        br_if 0 (;@10;)
                        local.get 0
                        any.convert_extern
                        ref.cast (ref null 6)
                        local.set 37
                        local.get 1
                        local.get 37
                        extern.convert_any
                        local.get 2
                        i64.const 2
                        call 2
                        local.set 38
                        local.get 38
                        local.set 4
                        br 1 (;@9;)
                      end
                      i32.const 0
                      local.set 4
                    end
                    local.get 4
                    i32.eqz
                    local.set 39
                    local.get 39
                    i32.eqz
                    br_if 0 (;@8;)
                    local.get 9
                    local.set 40
                    local.get 40
                    local.get 34
                    struct.set 7 1
                    local.get 34
                    drop
                    local.get 40
                    local.get 35
                    struct.set 7 2
                    local.get 35
                    drop
                  end
                  local.get 4
                  return
                end
                local.get 1
                any.convert_extern
                ref.test (ref 6)
                local.set 41
                local.get 41
                i32.eqz
                br_if 3 (;@3;)
                local.get 1
                any.convert_extern
                ref.cast (ref null 6)
                local.set 42
                local.get 2
                local.get 42
                call 3
                ref.cast (ref null 7)
                local.set 43
                local.get 43
                ref.is_null
                local.set 44
                local.get 44
                i32.eqz
                local.set 45
                local.get 45
                i32.eqz
                br_if 3 (;@3;)
                local.get 1
                any.convert_extern
                ref.cast (ref null 6)
                local.set 46
                local.get 43
                local.set 47
                local.get 47
                struct.get 7 1
                local.set 48
                local.get 47
                struct.get 7 2
                local.set 49
                local.get 0
                local.get 46
                extern.convert_any
                local.get 2
                i64.const 2
                call 2
                local.set 50
                local.get 50
                i32.eqz
                br_if 0 (;@6;)
                local.get 1
                any.convert_extern
                ref.cast (ref null 6)
                local.set 51
                local.get 51
                extern.convert_any
                local.get 0
                local.get 2
                i64.const 2
                call 2
                local.set 52
                local.get 52
                local.set 5
                br 1 (;@5;)
              end
              i32.const 0
              local.set 5
            end
            local.get 5
            i32.eqz
            local.set 53
            local.get 53
            i32.eqz
            br_if 0 (;@4;)
            local.get 43
            local.set 54
            local.get 54
            local.get 48
            struct.set 7 1
            local.get 48
            drop
            local.get 54
            local.get 49
            struct.set 7 2
            local.get 49
            drop
          end
          local.get 5
          return
        end
        local.get 0
        drop
        i32.const 0
        local.set 55
        local.get 55
        i32.eqz
        br_if 1 (;@1;)
        local.get 1
        drop
        i32.const 0
        local.set 56
        local.get 56
        i32.eqz
        br_if 1 (;@1;)
        local.get 0
        local.set 57
        local.get 1
        local.set 58
        local.get 57
        local.get 58
        local.get 2
        i64.const 2
        call 2
        local.set 59
        local.get 59
        i32.eqz
        br_if 0 (;@2;)
        local.get 0
        local.set 60
        local.get 1
        local.set 61
        local.get 61
        local.get 60
        local.get 2
        i64.const 2
        call 2
        local.set 62
        local.get 62
        return
      end
      i32.const 0
      return
    end
    local.get 0
    local.get 1
    any.convert_extern
    ref.cast eqref
    local.set 65
    any.convert_extern
    ref.cast eqref
    local.get 65
    ref.eq
    local.set 63
    local.get 63
    return
    unreachable
  )
  (func (;16;) (type 32) (param (ref null 16) (ref null 16) (ref null 10) i64) (result i32)
    (local i32 i64 i32 i64 i64 i64 i64 externref externref i64 i64 i32 i64 i32 i64 i64 i64 i64 externref externref i64 i64 i32 i64 i32 i64 i64 i64 i64 externref externref i64 i64 i32 i64 i32 i64 i64 i64 i64 externref externref i64 i64 i32 i32 i64 i32 i64 i64 i64 i64 externref externref i64 i64 i32 i64 i32 i64 i64 i64 i64 externref externref i64 i64 i32 i64 i32 i64 i64 i64 i64 externref externref i64 i64 i32 i32 (ref null 13) (ref null 13) i64 i64 i32 (ref null 13) i32 (ref null 13) (ref null 18) externref i32 (ref null 18) externref i64 i64 i64 i32 i32 i64 i32 i32 i32 (ref null 13) (ref null 13) i32 (ref null 18) externref i32 (ref null 18) externref i32 i32 i64 i32 i32 i64 i32 i32 (ref null 13) i32 (ref null 18) externref i32 (ref null 18) externref i32 i32 i64 i32 i64 i32 i64 i32 i32 i32 (ref null 13) (ref null 13) i32 (ref null 18) externref i32 (ref null 18) externref i32 i32 i64 i32 i32 i64 i32 i32 (ref null 13) i32 (ref null 18) externref i32 (ref null 18) externref i32 i32 i64 i32 i32 (ref null 13) i32 (ref null 13) (ref null 18) i32 (ref null 18) externref i64 i64 i64 i32 i32 i64 i32 i32 i32 (ref null 13) (ref null 13) i32 (ref null 18) externref i32 (ref null 18) externref i32 i32 i64 i32 (ref null 18) externref i32 i64 i32 i32 (ref null 13) i32 (ref null 18) externref i32 (ref null 18) externref i32 i32 i64 i32 i32 i32 i32 i32 i32 (ref null 13) (ref null 13) i32 (ref null 18) externref i32 (ref null 18) externref i32 i32 i64 i32)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  block ;; label = @8
                    block ;; label = @9
                      block ;; label = @10
                        block ;; label = @11
                          block ;; label = @12
                            block ;; label = @13
                              block ;; label = @14
                                block ;; label = @15
                                  block ;; label = @16
                                    block ;; label = @17
                                      block ;; label = @18
                                        block ;; label = @19
                                          block ;; label = @20
                                            block ;; label = @21
                                              block ;; label = @22
                                                block ;; label = @23
                                                  block ;; label = @24
                                                    block ;; label = @25
                                                      block ;; label = @26
                                                        block ;; label = @27
                                                          block ;; label = @28
                                                            block ;; label = @29
                                                              block ;; label = @30
                                                                block ;; label = @31
                                                                  block ;; label = @32
                                                                    block ;; label = @33
                                                                      block ;; label = @34
                                                                        block ;; label = @35
                                                                          block ;; label = @36
                                                                            block ;; label = @37
                                                                              block ;; label = @38
                                                                                block ;; label = @39
                                                                                  block ;; label = @40
                                                                                    block ;; label = @41
                                                                                      block ;; label = @42
                                                                                        block ;; label = @43
                                                                                          block ;; label = @44
                                                                                            block ;; label = @45
                                                                                              block ;; label = @46
                                                                                                block ;; label = @47
                                                                                                  block ;; label = @48
                                                                                                    block ;; label = @49
                                                                                                    block ;; label = @50
                                                                                                    block ;; label = @51
                                                                                                    block ;; label = @52
                                                                                                    block ;; label = @53
                                                                                                    block ;; label = @54
                                                                                                    block ;; label = @55
                                                                                                    block ;; label = @56
                                                                                                    block ;; label = @57
                                                                                                    block ;; label = @58
                                                                                                    block ;; label = @59
                                                                                                    block ;; label = @60
                                                                                                    block ;; label = @61
                                                                                                    block ;; label = @62
                                                                                                    local.get 0
                                                                                                    local.get 1
                                                                                                    ref.eq
                                                                                                    local.set 83
                                                                                                    local.get 83
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@62;)
                                                                                                    i32.const 1
                                                                                                    return
                                                                                                    end
                                                                                                    local.get 0
                                                                                                    struct.get 16 2
                                                                                                    local.set 84
                                                                                                    local.get 1
                                                                                                    struct.get 16 2
                                                                                                    local.set 85
                                                                                                    local.get 84
                                                                                                    local.get 84
                                                                                                    array.len
                                                                                                    i64.extend_i32_u
                                                                                                    local.set 86
                                                                                                    local.get 85
                                                                                                    local.get 85
                                                                                                    array.len
                                                                                                    i64.extend_i32_u
                                                                                                    local.set 87
                                                                                                    i64.const 0
                                                                                                    local.get 87
                                                                                                    i64.lt_s
                                                                                                    local.set 88
                                                                                                    local.get 88
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@61;)
                                                                                                    local.get 85
                                                                                                    local.get 87
                                                                                                    i32.wrap_i64
                                                                                                    i32.const 1
                                                                                                    i32.sub
                                                                                                    array.get 13
                                                                                                    any.convert_extern
                                                                                                    ref.cast (ref null 13)
                                                                                                    local.set 89
                                                                                                    local.get 89
                                                                                                    ref.is_null
                                                                                                    i32.eqz
                                                                                                    local.set 90
                                                                                                    local.get 90
                                                                                                    local.set 4
                                                                                                    br 1 (;@60;)
                                                                                                    end
                                                                                                    i32.const 0
                                                                                                    local.set 4
                                                                                                    end
                                                                                                    local.get 4
                                                                                                    i32.eqz
                                                                                                    br_if 31 (;@28;)
                                                                                                    local.get 85
                                                                                                    local.get 87
                                                                                                    i32.wrap_i64
                                                                                                    i32.const 1
                                                                                                    i32.sub
                                                                                                    array.get 13
                                                                                                    any.convert_extern
                                                                                                    ref.cast (ref null 13)
                                                                                                    local.set 91
                                                                                                    local.get 91
                                                                                                    drop
                                                                                                    ref.null 18
                                                                                                    local.set 92
                                                                                                    local.get 92
                                                                                                    struct.get 18 0
                                                                                                    local.set 93
                                                                                                    unreachable
                                                                                                    local.get 94
                                                                                                    i32.eqz
                                                                                                    br_if 15 (;@44;)
                                                                                                    local.get 92
                                                                                                    local.set 95
                                                                                                    local.get 95
                                                                                                    struct.get 18 1
                                                                                                    local.set 96
                                                                                                    local.get 96
                                                                                                    drop
                                                                                                    local.get 96
                                                                                                    any.convert_extern
                                                                                                    ref.cast (ref null 2)
                                                                                                    struct.get 2 0
                                                                                                    local.set 97
                                                                                                    local.get 87
                                                                                                    i64.const 1
                                                                                                    i64.sub
                                                                                                    local.set 98
                                                                                                    local.get 98
                                                                                                    local.get 97
                                                                                                    i64.add
                                                                                                    local.set 99
                                                                                                    local.get 86
                                                                                                    local.get 99
                                                                                                    i64.eq
                                                                                                    local.set 100
                                                                                                    local.get 100
                                                                                                    i32.eqz
                                                                                                    local.set 101
                                                                                                    local.get 101
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@59;)
                                                                                                    i32.const 0
                                                                                                    return
                                                                                                    end
                                                                                                    local.get 87
                                                                                                    i64.const 1
                                                                                                    i64.sub
                                                                                                    local.set 102
                                                                                                    i64.const 1
                                                                                                    local.get 102
                                                                                                    i64.le_s
                                                                                                    local.set 103
                                                                                                    local.get 103
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@58;)
                                                                                                    local.get 102
                                                                                                    local.set 5
                                                                                                    br 1 (;@57;)
                                                                                                    end
                                                                                                    i64.const 0
                                                                                                    local.set 5
                                                                                                    br 0 (;@57;)
                                                                                                    end
                                                                                                    local.get 5
                                                                                                    i64.const 1
                                                                                                    i64.lt_s
                                                                                                    local.set 104
                                                                                                    local.get 104
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@56;)
                                                                                                    i32.const 1
                                                                                                    local.set 6
                                                                                                    br 1 (;@55;)
                                                                                                    end
                                                                                                    i32.const 0
                                                                                                    local.set 6
                                                                                                    i64.const 1
                                                                                                    local.set 7
                                                                                                    i64.const 1
                                                                                                    local.set 8
                                                                                                    br 0 (;@55;)
                                                                                                    end
                                                                                                    local.get 6
                                                                                                    i32.eqz
                                                                                                    local.set 105
                                                                                                    local.get 105
                                                                                                    i32.eqz
                                                                                                    br_if 2 (;@52;)
                                                                                                    local.get 7
                                                                                                    local.set 9
                                                                                                    local.get 8
                                                                                                    local.set 10
                                                                                                    end
                                                                                                    loop ;; label = @54
                                                                                                    block ;; label = @55
                                                                                                    block ;; label = @56
                                                                                                    block ;; label = @57
                                                                                                    block ;; label = @58
                                                                                                    block ;; label = @59
                                                                                                    block ;; label = @60
                                                                                                    local.get 84
                                                                                                    local.get 9
                                                                                                    i32.wrap_i64
                                                                                                    i32.const 1
                                                                                                    i32.sub
                                                                                                    array.get 13
                                                                                                    any.convert_extern
                                                                                                    ref.cast (ref null 13)
                                                                                                    local.set 106
                                                                                                    local.get 85
                                                                                                    local.get 9
                                                                                                    i32.wrap_i64
                                                                                                    i32.const 1
                                                                                                    i32.sub
                                                                                                    array.get 13
                                                                                                    any.convert_extern
                                                                                                    ref.cast (ref null 13)
                                                                                                    local.set 107
                                                                                                    local.get 106
                                                                                                    ref.is_null
                                                                                                    i32.eqz
                                                                                                    local.set 108
                                                                                                    local.get 108
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@60;)
                                                                                                    ref.null 18
                                                                                                    local.set 109
                                                                                                    local.get 109
                                                                                                    struct.get 18 0
                                                                                                    local.set 110
                                                                                                    local.get 110
                                                                                                    local.set 11
                                                                                                    br 1 (;@59;)
                                                                                                    end
                                                                                                    local.get 106
                                                                                                    extern.convert_any
                                                                                                    local.set 11
                                                                                                    end
                                                                                                    local.get 107
                                                                                                    ref.is_null
                                                                                                    i32.eqz
                                                                                                    local.set 111
                                                                                                    local.get 111
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@58;)
                                                                                                    ref.null 18
                                                                                                    local.set 112
                                                                                                    local.get 112
                                                                                                    struct.get 18 0
                                                                                                    local.set 113
                                                                                                    local.get 113
                                                                                                    local.set 12
                                                                                                    br 1 (;@57;)
                                                                                                    end
                                                                                                    local.get 107
                                                                                                    extern.convert_any
                                                                                                    local.set 12
                                                                                                    end
                                                                                                    local.get 11
                                                                                                    local.get 12
                                                                                                    local.get 2
                                                                                                    i64.const 1
                                                                                                    call 2
                                                                                                    local.set 114
                                                                                                    local.get 114
                                                                                                    i32.eqz
                                                                                                    br_if 3 (;@53;)
                                                                                                    local.get 10
                                                                                                    local.get 5
                                                                                                    i64.eq
                                                                                                    local.set 115
                                                                                                    local.get 115
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@56;)
                                                                                                    i32.const 1
                                                                                                    local.set 15
                                                                                                    br 1 (;@55;)
                                                                                                    end
                                                                                                    local.get 10
                                                                                                    i64.const 1
                                                                                                    i64.add
                                                                                                    local.set 116
                                                                                                    local.get 116
                                                                                                    local.set 13
                                                                                                    local.get 116
                                                                                                    local.set 14
                                                                                                    i32.const 0
                                                                                                    local.set 15
                                                                                                    br 0 (;@55;)
                                                                                                    end
                                                                                                    local.get 15
                                                                                                    i32.eqz
                                                                                                    local.set 117
                                                                                                    local.get 117
                                                                                                    i32.eqz
                                                                                                    br_if 2 (;@52;)
                                                                                                    local.get 13
                                                                                                    local.set 9
                                                                                                    local.get 14
                                                                                                    local.set 10
                                                                                                    br 0 (;@54;)
                                                                                                    end
                                                                                                    end
                                                                                                    i32.const 0
                                                                                                    return
                                                                                                    end
                                                                                                    local.get 87
                                                                                                    local.get 86
                                                                                                    i64.le_s
                                                                                                    local.set 118
                                                                                                    local.get 118
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@51;)
                                                                                                    local.get 86
                                                                                                    local.set 16
                                                                                                    br 1 (;@50;)
                                                                                                    end
                                                                                                    local.get 87
                                                                                                    i64.const 1
                                                                                                    i64.sub
                                                                                                    local.set 119
                                                                                                    local.get 119
                                                                                                    local.set 16
                                                                                                    br 0 (;@50;)
                                                                                                    end
                                                                                                    local.get 16
                                                                                                    local.get 87
                                                                                                    i64.lt_s
                                                                                                    local.set 120
                                                                                                    local.get 120
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@49;)
                                                                                                    i32.const 1
                                                                                                    local.set 17
                                                                                                    br 1 (;@48;)
                                                                                                    end
                                                                                                    i32.const 0
                                                                                                    local.set 17
                                                                                                    local.get 87
                                                                                                    local.set 18
                                                                                                    local.get 87
                                                                                                    local.set 19
                                                                                                    br 0 (;@48;)
                                                                                                  end
                                                                                                  local.get 17
                                                                                                  i32.eqz
                                                                                                  local.set 121
                                                                                                  local.get 121
                                                                                                  i32.eqz
                                                                                                  br_if 2 (;@45;)
                                                                                                  local.get 18
                                                                                                  local.set 20
                                                                                                  local.get 19
                                                                                                  local.set 21
                                                                                                end
                                                                                                loop ;; label = @47
                                                                                                  block ;; label = @48
                                                                                                    block ;; label = @49
                                                                                                    block ;; label = @50
                                                                                                    block ;; label = @51
                                                                                                    block ;; label = @52
                                                                                                    block ;; label = @53
                                                                                                    local.get 84
                                                                                                    local.get 20
                                                                                                    i32.wrap_i64
                                                                                                    i32.const 1
                                                                                                    i32.sub
                                                                                                    array.get 13
                                                                                                    any.convert_extern
                                                                                                    ref.cast (ref null 13)
                                                                                                    local.set 122
                                                                                                    local.get 122
                                                                                                    ref.is_null
                                                                                                    i32.eqz
                                                                                                    local.set 123
                                                                                                    local.get 123
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@53;)
                                                                                                    ref.null 18
                                                                                                    local.set 124
                                                                                                    local.get 124
                                                                                                    struct.get 18 0
                                                                                                    local.set 125
                                                                                                    local.get 125
                                                                                                    local.set 22
                                                                                                    br 1 (;@52;)
                                                                                                    end
                                                                                                    local.get 122
                                                                                                    extern.convert_any
                                                                                                    local.set 22
                                                                                                    end
                                                                                                    local.get 93
                                                                                                    any.convert_extern
                                                                                                    ref.test (ref 18)
                                                                                                    local.set 126
                                                                                                    local.get 126
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@51;)
                                                                                                    local.get 93
                                                                                                    any.convert_extern
                                                                                                    ref.cast (ref null 18)
                                                                                                    local.set 127
                                                                                                    local.get 127
                                                                                                    struct.get 18 0
                                                                                                    local.set 128
                                                                                                    local.get 128
                                                                                                    local.set 23
                                                                                                    br 1 (;@50;)
                                                                                                    end
                                                                                                    local.get 93
                                                                                                    local.set 23
                                                                                                    end
                                                                                                    local.get 22
                                                                                                    local.get 23
                                                                                                    local.get 2
                                                                                                    i64.const 1
                                                                                                    call 2
                                                                                                    local.set 129
                                                                                                    local.get 129
                                                                                                    i32.eqz
                                                                                                    br_if 3 (;@46;)
                                                                                                    local.get 21
                                                                                                    local.get 16
                                                                                                    i64.eq
                                                                                                    local.set 130
                                                                                                    local.get 130
                                                                                                    i32.eqz
                                                                                                    br_if 0 (;@49;)
                                                                                                    i32.const 1
                                                                                                    local.set 26
                                                                                                    br 1 (;@48;)
                                                                                                    end
                                                                                                    local.get 21
                                                                                                    i64.const 1
                                                                                                    i64.add
                                                                                                    local.set 131
                                                                                                    local.get 131
                                                                                                    local.set 24
                                                                                                    local.get 131
                                                                                                    local.set 25
                                                                                                    i32.const 0
                                                                                                    local.set 26
                                                                                                    br 0 (;@48;)
                                                                                                  end
                                                                                                  local.get 26
                                                                                                  i32.eqz
                                                                                                  local.set 132
                                                                                                  local.get 132
                                                                                                  i32.eqz
                                                                                                  br_if 2 (;@45;)
                                                                                                  local.get 24
                                                                                                  local.set 20
                                                                                                  local.get 25
                                                                                                  local.set 21
                                                                                                  br 0 (;@47;)
                                                                                                end
                                                                                              end
                                                                                              i32.const 0
                                                                                              return
                                                                                            end
                                                                                            i32.const 1
                                                                                            return
                                                                                          end
                                                                                          local.get 87
                                                                                          i64.const 1
                                                                                          i64.sub
                                                                                          local.set 133
                                                                                          local.get 86
                                                                                          local.get 133
                                                                                          i64.lt_s
                                                                                          local.set 134
                                                                                          local.get 134
                                                                                          i32.eqz
                                                                                          br_if 0 (;@43;)
                                                                                          i32.const 0
                                                                                          return
                                                                                        end
                                                                                        local.get 87
                                                                                        i64.const 1
                                                                                        i64.sub
                                                                                        local.set 135
                                                                                        i64.const 1
                                                                                        local.get 135
                                                                                        i64.le_s
                                                                                        local.set 136
                                                                                        local.get 136
                                                                                        i32.eqz
                                                                                        br_if 0 (;@42;)
                                                                                        local.get 135
                                                                                        local.set 27
                                                                                        br 1 (;@41;)
                                                                                      end
                                                                                      i64.const 0
                                                                                      local.set 27
                                                                                      br 0 (;@41;)
                                                                                    end
                                                                                    local.get 27
                                                                                    i64.const 1
                                                                                    i64.lt_s
                                                                                    local.set 137
                                                                                    local.get 137
                                                                                    i32.eqz
                                                                                    br_if 0 (;@40;)
                                                                                    i32.const 1
                                                                                    local.set 28
                                                                                    br 1 (;@39;)
                                                                                  end
                                                                                  i32.const 0
                                                                                  local.set 28
                                                                                  i64.const 1
                                                                                  local.set 29
                                                                                  i64.const 1
                                                                                  local.set 30
                                                                                  br 0 (;@39;)
                                                                                end
                                                                                local.get 28
                                                                                i32.eqz
                                                                                local.set 138
                                                                                local.get 138
                                                                                i32.eqz
                                                                                br_if 2 (;@36;)
                                                                                local.get 29
                                                                                local.set 31
                                                                                local.get 30
                                                                                local.set 32
                                                                              end
                                                                              loop ;; label = @38
                                                                                block ;; label = @39
                                                                                  block ;; label = @40
                                                                                    block ;; label = @41
                                                                                      block ;; label = @42
                                                                                        block ;; label = @43
                                                                                          block ;; label = @44
                                                                                            local.get 84
                                                                                            local.get 31
                                                                                            i32.wrap_i64
                                                                                            i32.const 1
                                                                                            i32.sub
                                                                                            array.get 13
                                                                                            any.convert_extern
                                                                                            ref.cast (ref null 13)
                                                                                            local.set 139
                                                                                            local.get 85
                                                                                            local.get 31
                                                                                            i32.wrap_i64
                                                                                            i32.const 1
                                                                                            i32.sub
                                                                                            array.get 13
                                                                                            any.convert_extern
                                                                                            ref.cast (ref null 13)
                                                                                            local.set 140
                                                                                            local.get 139
                                                                                            ref.is_null
                                                                                            i32.eqz
                                                                                            local.set 141
                                                                                            local.get 141
                                                                                            i32.eqz
                                                                                            br_if 0 (;@44;)
                                                                                            ref.null 18
                                                                                            local.set 142
                                                                                            local.get 142
                                                                                            struct.get 18 0
                                                                                            local.set 143
                                                                                            local.get 143
                                                                                            local.set 33
                                                                                            br 1 (;@43;)
                                                                                          end
                                                                                          local.get 139
                                                                                          extern.convert_any
                                                                                          local.set 33
                                                                                        end
                                                                                        local.get 140
                                                                                        ref.is_null
                                                                                        i32.eqz
                                                                                        local.set 144
                                                                                        local.get 144
                                                                                        i32.eqz
                                                                                        br_if 0 (;@42;)
                                                                                        ref.null 18
                                                                                        local.set 145
                                                                                        local.get 145
                                                                                        struct.get 18 0
                                                                                        local.set 146
                                                                                        local.get 146
                                                                                        local.set 34
                                                                                        br 1 (;@41;)
                                                                                      end
                                                                                      local.get 140
                                                                                      extern.convert_any
                                                                                      local.set 34
                                                                                    end
                                                                                    local.get 33
                                                                                    local.get 34
                                                                                    local.get 2
                                                                                    i64.const 1
                                                                                    call 2
                                                                                    local.set 147
                                                                                    local.get 147
                                                                                    i32.eqz
                                                                                    br_if 3 (;@37;)
                                                                                    local.get 32
                                                                                    local.get 27
                                                                                    i64.eq
                                                                                    local.set 148
                                                                                    local.get 148
                                                                                    i32.eqz
                                                                                    br_if 0 (;@40;)
                                                                                    i32.const 1
                                                                                    local.set 37
                                                                                    br 1 (;@39;)
                                                                                  end
                                                                                  local.get 32
                                                                                  i64.const 1
                                                                                  i64.add
                                                                                  local.set 149
                                                                                  local.get 149
                                                                                  local.set 35
                                                                                  local.get 149
                                                                                  local.set 36
                                                                                  i32.const 0
                                                                                  local.set 37
                                                                                  br 0 (;@39;)
                                                                                end
                                                                                local.get 37
                                                                                i32.eqz
                                                                                local.set 150
                                                                                local.get 150
                                                                                i32.eqz
                                                                                br_if 2 (;@36;)
                                                                                local.get 35
                                                                                local.set 31
                                                                                local.get 36
                                                                                local.set 32
                                                                                br 0 (;@38;)
                                                                              end
                                                                            end
                                                                            i32.const 0
                                                                            return
                                                                          end
                                                                          local.get 87
                                                                          local.get 86
                                                                          i64.le_s
                                                                          local.set 151
                                                                          local.get 151
                                                                          i32.eqz
                                                                          br_if 0 (;@35;)
                                                                          local.get 86
                                                                          local.set 38
                                                                          br 1 (;@34;)
                                                                        end
                                                                        local.get 87
                                                                        i64.const 1
                                                                        i64.sub
                                                                        local.set 152
                                                                        local.get 152
                                                                        local.set 38
                                                                        br 0 (;@34;)
                                                                      end
                                                                      local.get 38
                                                                      local.get 87
                                                                      i64.lt_s
                                                                      local.set 153
                                                                      local.get 153
                                                                      i32.eqz
                                                                      br_if 0 (;@33;)
                                                                      i32.const 1
                                                                      local.set 39
                                                                      br 1 (;@32;)
                                                                    end
                                                                    i32.const 0
                                                                    local.set 39
                                                                    local.get 87
                                                                    local.set 40
                                                                    local.get 87
                                                                    local.set 41
                                                                    br 0 (;@32;)
                                                                  end
                                                                  local.get 39
                                                                  i32.eqz
                                                                  local.set 154
                                                                  local.get 154
                                                                  i32.eqz
                                                                  br_if 2 (;@29;)
                                                                  local.get 40
                                                                  local.set 42
                                                                  local.get 41
                                                                  local.set 43
                                                                end
                                                                loop ;; label = @31
                                                                  block ;; label = @32
                                                                    block ;; label = @33
                                                                      block ;; label = @34
                                                                        block ;; label = @35
                                                                          block ;; label = @36
                                                                            block ;; label = @37
                                                                              local.get 84
                                                                              local.get 42
                                                                              i32.wrap_i64
                                                                              i32.const 1
                                                                              i32.sub
                                                                              array.get 13
                                                                              any.convert_extern
                                                                              ref.cast (ref null 13)
                                                                              local.set 155
                                                                              local.get 155
                                                                              ref.is_null
                                                                              i32.eqz
                                                                              local.set 156
                                                                              local.get 156
                                                                              i32.eqz
                                                                              br_if 0 (;@37;)
                                                                              ref.null 18
                                                                              local.set 157
                                                                              local.get 157
                                                                              struct.get 18 0
                                                                              local.set 158
                                                                              local.get 158
                                                                              local.set 44
                                                                              br 1 (;@36;)
                                                                            end
                                                                            local.get 155
                                                                            extern.convert_any
                                                                            local.set 44
                                                                          end
                                                                          local.get 93
                                                                          any.convert_extern
                                                                          ref.test (ref 18)
                                                                          local.set 159
                                                                          local.get 159
                                                                          i32.eqz
                                                                          br_if 0 (;@35;)
                                                                          local.get 93
                                                                          any.convert_extern
                                                                          ref.cast (ref null 18)
                                                                          local.set 160
                                                                          local.get 160
                                                                          struct.get 18 0
                                                                          local.set 161
                                                                          local.get 161
                                                                          local.set 45
                                                                          br 1 (;@34;)
                                                                        end
                                                                        local.get 93
                                                                        local.set 45
                                                                      end
                                                                      local.get 44
                                                                      local.get 45
                                                                      local.get 2
                                                                      i64.const 1
                                                                      call 2
                                                                      local.set 162
                                                                      local.get 162
                                                                      i32.eqz
                                                                      br_if 3 (;@30;)
                                                                      local.get 43
                                                                      local.get 38
                                                                      i64.eq
                                                                      local.set 163
                                                                      local.get 163
                                                                      i32.eqz
                                                                      br_if 0 (;@33;)
                                                                      i32.const 1
                                                                      local.set 48
                                                                      br 1 (;@32;)
                                                                    end
                                                                    local.get 43
                                                                    i64.const 1
                                                                    i64.add
                                                                    local.set 164
                                                                    local.get 164
                                                                    local.set 46
                                                                    local.get 164
                                                                    local.set 47
                                                                    i32.const 0
                                                                    local.set 48
                                                                    br 0 (;@32;)
                                                                  end
                                                                  local.get 48
                                                                  i32.eqz
                                                                  local.set 165
                                                                  local.get 165
                                                                  i32.eqz
                                                                  br_if 2 (;@29;)
                                                                  local.get 46
                                                                  local.set 42
                                                                  local.get 47
                                                                  local.set 43
                                                                  br 0 (;@31;)
                                                                end
                                                              end
                                                              i32.const 0
                                                              return
                                                            end
                                                            i32.const 1
                                                            return
                                                          end
                                                          i64.const 0
                                                          local.get 86
                                                          i64.lt_s
                                                          local.set 166
                                                          local.get 166
                                                          i32.eqz
                                                          br_if 0 (;@27;)
                                                          local.get 84
                                                          local.get 86
                                                          i32.wrap_i64
                                                          i32.const 1
                                                          i32.sub
                                                          array.get 13
                                                          any.convert_extern
                                                          ref.cast (ref null 13)
                                                          local.set 167
                                                          local.get 167
                                                          ref.is_null
                                                          i32.eqz
                                                          local.set 168
                                                          local.get 168
                                                          local.set 49
                                                          br 1 (;@26;)
                                                        end
                                                        i32.const 0
                                                        local.set 49
                                                      end
                                                      local.get 49
                                                      i32.eqz
                                                      br_if 16 (;@9;)
                                                      local.get 84
                                                      local.get 86
                                                      i32.wrap_i64
                                                      i32.const 1
                                                      i32.sub
                                                      array.get 13
                                                      any.convert_extern
                                                      ref.cast (ref null 13)
                                                      local.set 169
                                                      local.get 169
                                                      drop
                                                      ref.null 18
                                                      local.set 170
                                                      unreachable
                                                      local.get 171
                                                      i32.eqz
                                                      br_if 15 (;@10;)
                                                      local.get 170
                                                      local.set 172
                                                      local.get 172
                                                      struct.get 18 1
                                                      local.set 173
                                                      local.get 173
                                                      drop
                                                      local.get 173
                                                      any.convert_extern
                                                      ref.cast (ref null 2)
                                                      struct.get 2 0
                                                      local.set 174
                                                      local.get 86
                                                      i64.const 1
                                                      i64.sub
                                                      local.set 175
                                                      local.get 175
                                                      local.get 174
                                                      i64.add
                                                      local.set 176
                                                      local.get 176
                                                      local.get 87
                                                      i64.eq
                                                      local.set 177
                                                      local.get 177
                                                      i32.eqz
                                                      local.set 178
                                                      local.get 178
                                                      i32.eqz
                                                      br_if 0 (;@25;)
                                                      i32.const 0
                                                      return
                                                    end
                                                    local.get 86
                                                    i64.const 1
                                                    i64.sub
                                                    local.set 179
                                                    i64.const 1
                                                    local.get 179
                                                    i64.le_s
                                                    local.set 180
                                                    local.get 180
                                                    i32.eqz
                                                    br_if 0 (;@24;)
                                                    local.get 179
                                                    local.set 50
                                                    br 1 (;@23;)
                                                  end
                                                  i64.const 0
                                                  local.set 50
                                                  br 0 (;@23;)
                                                end
                                                local.get 50
                                                i64.const 1
                                                i64.lt_s
                                                local.set 181
                                                local.get 181
                                                i32.eqz
                                                br_if 0 (;@22;)
                                                i32.const 1
                                                local.set 51
                                                br 1 (;@21;)
                                              end
                                              i32.const 0
                                              local.set 51
                                              i64.const 1
                                              local.set 52
                                              i64.const 1
                                              local.set 53
                                              br 0 (;@21;)
                                            end
                                            local.get 51
                                            i32.eqz
                                            local.set 182
                                            local.get 182
                                            i32.eqz
                                            br_if 2 (;@18;)
                                            local.get 52
                                            local.set 54
                                            local.get 53
                                            local.set 55
                                          end
                                          loop ;; label = @20
                                            block ;; label = @21
                                              block ;; label = @22
                                                block ;; label = @23
                                                  block ;; label = @24
                                                    block ;; label = @25
                                                      block ;; label = @26
                                                        local.get 84
                                                        local.get 54
                                                        i32.wrap_i64
                                                        i32.const 1
                                                        i32.sub
                                                        array.get 13
                                                        any.convert_extern
                                                        ref.cast (ref null 13)
                                                        local.set 183
                                                        local.get 85
                                                        local.get 54
                                                        i32.wrap_i64
                                                        i32.const 1
                                                        i32.sub
                                                        array.get 13
                                                        any.convert_extern
                                                        ref.cast (ref null 13)
                                                        local.set 184
                                                        local.get 183
                                                        ref.is_null
                                                        i32.eqz
                                                        local.set 185
                                                        local.get 185
                                                        i32.eqz
                                                        br_if 0 (;@26;)
                                                        ref.null 18
                                                        local.set 186
                                                        local.get 186
                                                        struct.get 18 0
                                                        local.set 187
                                                        local.get 187
                                                        local.set 56
                                                        br 1 (;@25;)
                                                      end
                                                      local.get 183
                                                      extern.convert_any
                                                      local.set 56
                                                    end
                                                    local.get 184
                                                    ref.is_null
                                                    i32.eqz
                                                    local.set 188
                                                    local.get 188
                                                    i32.eqz
                                                    br_if 0 (;@24;)
                                                    ref.null 18
                                                    local.set 189
                                                    local.get 189
                                                    struct.get 18 0
                                                    local.set 190
                                                    local.get 190
                                                    local.set 57
                                                    br 1 (;@23;)
                                                  end
                                                  local.get 184
                                                  extern.convert_any
                                                  local.set 57
                                                end
                                                local.get 56
                                                local.get 57
                                                local.get 2
                                                i64.const 1
                                                call 2
                                                local.set 191
                                                local.get 191
                                                i32.eqz
                                                br_if 3 (;@19;)
                                                local.get 55
                                                local.get 50
                                                i64.eq
                                                local.set 192
                                                local.get 192
                                                i32.eqz
                                                br_if 0 (;@22;)
                                                i32.const 1
                                                local.set 60
                                                br 1 (;@21;)
                                              end
                                              local.get 55
                                              i64.const 1
                                              i64.add
                                              local.set 193
                                              local.get 193
                                              local.set 58
                                              local.get 193
                                              local.set 59
                                              i32.const 0
                                              local.set 60
                                              br 0 (;@21;)
                                            end
                                            local.get 60
                                            i32.eqz
                                            local.set 194
                                            local.get 194
                                            i32.eqz
                                            br_if 2 (;@18;)
                                            local.get 58
                                            local.set 54
                                            local.get 59
                                            local.set 55
                                            br 0 (;@20;)
                                          end
                                        end
                                        i32.const 0
                                        return
                                      end
                                      local.get 170
                                      local.set 195
                                      local.get 195
                                      struct.get 18 0
                                      local.set 196
                                      local.get 86
                                      local.get 87
                                      i64.le_s
                                      local.set 197
                                      local.get 197
                                      i32.eqz
                                      br_if 0 (;@17;)
                                      local.get 87
                                      local.set 61
                                      br 1 (;@16;)
                                    end
                                    local.get 86
                                    i64.const 1
                                    i64.sub
                                    local.set 198
                                    local.get 198
                                    local.set 61
                                    br 0 (;@16;)
                                  end
                                  local.get 61
                                  local.get 86
                                  i64.lt_s
                                  local.set 199
                                  local.get 199
                                  i32.eqz
                                  br_if 0 (;@15;)
                                  i32.const 1
                                  local.set 62
                                  br 1 (;@14;)
                                end
                                i32.const 0
                                local.set 62
                                local.get 86
                                local.set 63
                                local.get 86
                                local.set 64
                                br 0 (;@14;)
                              end
                              local.get 62
                              i32.eqz
                              local.set 200
                              local.get 200
                              i32.eqz
                              br_if 2 (;@11;)
                              local.get 63
                              local.set 65
                              local.get 64
                              local.set 66
                            end
                            loop ;; label = @13
                              block ;; label = @14
                                block ;; label = @15
                                  block ;; label = @16
                                    block ;; label = @17
                                      block ;; label = @18
                                        block ;; label = @19
                                          local.get 85
                                          local.get 65
                                          i32.wrap_i64
                                          i32.const 1
                                          i32.sub
                                          array.get 13
                                          any.convert_extern
                                          ref.cast (ref null 13)
                                          local.set 201
                                          local.get 196
                                          any.convert_extern
                                          ref.test (ref 18)
                                          local.set 202
                                          local.get 202
                                          i32.eqz
                                          br_if 0 (;@19;)
                                          local.get 196
                                          any.convert_extern
                                          ref.cast (ref null 18)
                                          local.set 203
                                          local.get 203
                                          struct.get 18 0
                                          local.set 204
                                          local.get 204
                                          local.set 67
                                          br 1 (;@18;)
                                        end
                                        local.get 196
                                        local.set 67
                                      end
                                      local.get 201
                                      ref.is_null
                                      i32.eqz
                                      local.set 205
                                      local.get 205
                                      i32.eqz
                                      br_if 0 (;@17;)
                                      ref.null 18
                                      local.set 206
                                      local.get 206
                                      struct.get 18 0
                                      local.set 207
                                      local.get 207
                                      local.set 68
                                      br 1 (;@16;)
                                    end
                                    local.get 201
                                    extern.convert_any
                                    local.set 68
                                  end
                                  local.get 67
                                  local.get 68
                                  local.get 2
                                  i64.const 1
                                  call 2
                                  local.set 208
                                  local.get 208
                                  i32.eqz
                                  br_if 3 (;@12;)
                                  local.get 66
                                  local.get 61
                                  i64.eq
                                  local.set 209
                                  local.get 209
                                  i32.eqz
                                  br_if 0 (;@15;)
                                  i32.const 1
                                  local.set 71
                                  br 1 (;@14;)
                                end
                                local.get 66
                                i64.const 1
                                i64.add
                                local.set 210
                                local.get 210
                                local.set 69
                                local.get 210
                                local.set 70
                                i32.const 0
                                local.set 71
                                br 0 (;@14;)
                              end
                              local.get 71
                              i32.eqz
                              local.set 211
                              local.get 211
                              i32.eqz
                              br_if 2 (;@11;)
                              local.get 69
                              local.set 65
                              local.get 70
                              local.set 66
                              br 0 (;@13;)
                            end
                          end
                          i32.const 0
                          return
                        end
                        i32.const 1
                        return
                      end
                      i32.const 0
                      return
                    end
                    local.get 86
                    local.get 87
                    i64.eq
                    local.set 212
                    local.get 212
                    i32.eqz
                    local.set 213
                    local.get 213
                    i32.eqz
                    br_if 0 (;@8;)
                    i32.const 0
                    return
                  end
                  i64.const 1
                  local.get 86
                  i64.le_s
                  local.set 214
                  local.get 214
                  i32.eqz
                  br_if 0 (;@7;)
                  local.get 86
                  local.set 72
                  br 1 (;@6;)
                end
                i64.const 0
                local.set 72
                br 0 (;@6;)
              end
              local.get 72
              i64.const 1
              i64.lt_s
              local.set 215
              local.get 215
              i32.eqz
              br_if 0 (;@5;)
              i32.const 1
              local.set 73
              br 1 (;@4;)
            end
            i32.const 0
            local.set 73
            i64.const 1
            local.set 74
            i64.const 1
            local.set 75
            br 0 (;@4;)
          end
          local.get 73
          i32.eqz
          local.set 216
          local.get 216
          i32.eqz
          br_if 2 (;@1;)
          local.get 74
          local.set 76
          local.get 75
          local.set 77
        end
        loop ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  block ;; label = @8
                    block ;; label = @9
                      local.get 84
                      local.get 76
                      i32.wrap_i64
                      i32.const 1
                      i32.sub
                      array.get 13
                      any.convert_extern
                      ref.cast (ref null 13)
                      local.set 217
                      local.get 85
                      local.get 76
                      i32.wrap_i64
                      i32.const 1
                      i32.sub
                      array.get 13
                      any.convert_extern
                      ref.cast (ref null 13)
                      local.set 218
                      local.get 217
                      ref.is_null
                      i32.eqz
                      local.set 219
                      local.get 219
                      i32.eqz
                      br_if 0 (;@9;)
                      ref.null 18
                      local.set 220
                      local.get 220
                      struct.get 18 0
                      local.set 221
                      local.get 221
                      local.set 78
                      br 1 (;@8;)
                    end
                    local.get 217
                    extern.convert_any
                    local.set 78
                  end
                  local.get 218
                  ref.is_null
                  i32.eqz
                  local.set 222
                  local.get 222
                  i32.eqz
                  br_if 0 (;@7;)
                  ref.null 18
                  local.set 223
                  local.get 223
                  struct.get 18 0
                  local.set 224
                  local.get 224
                  local.set 79
                  br 1 (;@6;)
                end
                local.get 218
                extern.convert_any
                local.set 79
              end
              local.get 78
              local.get 79
              local.get 2
              i64.const 1
              call 2
              local.set 225
              local.get 225
              i32.eqz
              br_if 3 (;@2;)
              local.get 77
              local.get 72
              i64.eq
              local.set 226
              local.get 226
              i32.eqz
              br_if 0 (;@5;)
              i32.const 1
              local.set 82
              br 1 (;@4;)
            end
            local.get 77
            i64.const 1
            i64.add
            local.set 227
            local.get 227
            local.set 80
            local.get 227
            local.set 81
            i32.const 0
            local.set 82
            br 0 (;@4;)
          end
          local.get 82
          i32.eqz
          local.set 228
          local.get 228
          i32.eqz
          br_if 2 (;@1;)
          local.get 80
          local.set 76
          local.get 81
          local.set 77
          br 0 (;@3;)
        end
      end
      i32.const 0
      return
    end
    i32.const 1
    return
    unreachable
  )
  (func (;17;) (type 33) (param externref externref (ref null 10)) (result i32)
    (local externref externref i32 (ref null 18) externref i32 (ref null 18) externref i32)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          block ;; label = @4
            local.get 0
            any.convert_extern
            ref.test (ref 18)
            local.set 5
            local.get 5
            i32.eqz
            br_if 0 (;@4;)
            local.get 0
            any.convert_extern
            ref.cast (ref null 18)
            local.set 6
            local.get 6
            struct.get 18 0
            local.set 7
            local.get 7
            local.set 3
            br 1 (;@3;)
          end
          local.get 0
          local.set 3
        end
        local.get 1
        any.convert_extern
        ref.test (ref 18)
        local.set 8
        local.get 8
        i32.eqz
        br_if 0 (;@2;)
        local.get 1
        any.convert_extern
        ref.cast (ref null 18)
        local.set 9
        local.get 9
        struct.get 18 0
        local.set 10
        local.get 10
        local.set 4
        br 1 (;@1;)
      end
      local.get 1
      local.set 4
    end
    local.get 3
    local.get 4
    local.get 2
    i64.const 1
    call 2
    local.set 11
    local.get 11
    return
    unreachable
  )
  (func (;18;) (type 34) (param (ref null 16) (ref null 16)) (result i32)
    (local (ref null 16) i32 i32 i32 i32 i32 (ref null 16) i32)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          block ;; label = @4
            local.get 0
            local.get 1
            ref.eq
            local.set 3
            local.get 3
            i32.eqz
            br_if 0 (;@4;)
            i32.const 1
            return
          end
          local.get 1
          global.get 1
          ref.eq
          local.set 4
          local.get 4
          i32.eqz
          br_if 0 (;@3;)
          i32.const 1
          return
        end
        local.get 0
        local.set 2
      end
      loop ;; label = @2
        block ;; label = @3
          block ;; label = @4
            local.get 2
            global.get 1
            ref.eq
            local.set 5
            local.get 5
            i32.eqz
            local.set 6
            local.get 6
            i32.eqz
            br_if 3 (;@1;)
            local.get 2
            local.get 1
            ref.eq
            local.set 7
            local.get 7
            i32.eqz
            br_if 0 (;@4;)
            i32.const 1
            return
          end
          local.get 2
          struct.get 16 1
          ref.cast (ref null 16)
          local.set 8
          local.get 8
          local.get 2
          ref.eq
          local.set 9
          local.get 9
          i32.eqz
          br_if 0 (;@3;)
          br 2 (;@1;)
        end
        local.get 8
        local.set 2
        br 0 (;@2;)
      end
    end
    i32.const 0
    return
    unreachable
  )
  (func (;19;) (type 34) (param (ref null 16) (ref null 16)) (result i32)
    (local i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32)
    local.get 0
    local.get 1
    ref.eq
    local.set 2
    local.get 2
    if (result i32) ;; label = @1
      i32.const 1
    else
      i32.const 16
      array.new_default 8
      ref.cast (ref null 8)
      local.set 3
      local.get 3
      ref.cast (ref null 8)
      local.set 4
      local.get 4
      i64.const 0
      struct.new 2
      struct.new 9
      ref.cast (ref null 9)
      local.set 5
      local.get 5
      i64.const 0
      struct.new 10
      ref.cast (ref null 10)
      local.set 6
      local.get 0
      local.get 1
      local.get 6
      i64.const 1
      call 16
      local.set 7
      local.get 7
    end
    return
  )
  (func (;20;) (type 17) (param externref externref) (result i32)
    (local i32 i32 i32 i32 i32 i32 externref externref i32 i32 i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32 i32 i32 externref (ref null 18) externref i32 i32 i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32 i32 i32 (ref null 18) externref externref i32 i32 i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32 i32 i32 (ref null 18) (ref null 18) externref externref i32 i32 i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32 eqref eqref eqref eqref eqref eqref eqref eqref eqref eqref eqref eqref)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  block ;; label = @8
                    block ;; label = @9
                      block ;; label = @10
                        block ;; label = @11
                          block ;; label = @12
                            block ;; label = @13
                              block ;; label = @14
                                block ;; label = @15
                                  block ;; label = @16
                                    block ;; label = @17
                                      block ;; label = @18
                                        block ;; label = @19
                                          block ;; label = @20
                                            local.get 0
                                            drop
                                            i32.const 0
                                            local.set 6
                                            local.get 6
                                            i32.eqz
                                            br_if 4 (;@16;)
                                            local.get 1
                                            drop
                                            i32.const 0
                                            local.set 7
                                            local.get 7
                                            i32.eqz
                                            br_if 4 (;@16;)
                                            local.get 0
                                            local.set 8
                                            local.get 1
                                            local.set 9
                                            local.get 8
                                            local.get 9
                                            any.convert_extern
                                            ref.cast eqref
                                            local.set 58
                                            any.convert_extern
                                            ref.cast eqref
                                            local.get 58
                                            ref.eq
                                            local.set 10
                                            local.get 10
                                            i32.eqz
                                            br_if 0 (;@20;)
                                            i32.const 1
                                            local.set 2
                                            br 3 (;@17;)
                                          end
                                          local.get 8
                                          global.get 0
                                          local.set 59
                                          any.convert_extern
                                          ref.cast eqref
                                          local.get 59
                                          ref.eq
                                          local.set 11
                                          local.get 11
                                          i32.eqz
                                          br_if 0 (;@19;)
                                          i32.const 1
                                          local.set 2
                                          br 2 (;@17;)
                                        end
                                        local.get 9
                                        global.get 1
                                        local.set 60
                                        any.convert_extern
                                        ref.cast eqref
                                        local.get 60
                                        ref.eq
                                        local.set 12
                                        local.get 12
                                        i32.eqz
                                        br_if 0 (;@18;)
                                        i32.const 1
                                        local.set 2
                                        br 1 (;@17;)
                                      end
                                      i32.const 16
                                      array.new_default 8
                                      ref.cast (ref null 8)
                                      local.set 13
                                      local.get 13
                                      ref.cast (ref null 8)
                                      local.set 14
                                      local.get 14
                                      i64.const 0
                                      struct.new 2
                                      struct.new 9
                                      ref.cast (ref null 9)
                                      local.set 15
                                      local.get 15
                                      i64.const 0
                                      struct.new 10
                                      ref.cast (ref null 10)
                                      local.set 16
                                      local.get 8
                                      local.get 9
                                      local.get 16
                                      i64.const 0
                                      call 2
                                      local.set 17
                                      local.get 17
                                      local.set 2
                                      br 0 (;@17;)
                                    end
                                    local.get 2
                                    return
                                  end
                                  local.get 0
                                  drop
                                  i32.const 0
                                  local.set 18
                                  local.get 18
                                  i32.eqz
                                  br_if 4 (;@11;)
                                  local.get 1
                                  any.convert_extern
                                  ref.test (ref 18)
                                  local.set 19
                                  local.get 19
                                  i32.eqz
                                  br_if 4 (;@11;)
                                  local.get 0
                                  local.set 20
                                  local.get 1
                                  any.convert_extern
                                  ref.cast (ref null 18)
                                  local.set 21
                                  local.get 21
                                  struct.get 18 0
                                  local.set 22
                                  local.get 20
                                  local.get 22
                                  any.convert_extern
                                  ref.cast eqref
                                  local.set 61
                                  any.convert_extern
                                  ref.cast eqref
                                  local.get 61
                                  ref.eq
                                  local.set 23
                                  local.get 23
                                  i32.eqz
                                  br_if 0 (;@15;)
                                  i32.const 1
                                  local.set 3
                                  br 3 (;@12;)
                                end
                                local.get 20
                                global.get 0
                                local.set 62
                                any.convert_extern
                                ref.cast eqref
                                local.get 62
                                ref.eq
                                local.set 24
                                local.get 24
                                i32.eqz
                                br_if 0 (;@14;)
                                i32.const 1
                                local.set 3
                                br 2 (;@12;)
                              end
                              local.get 22
                              global.get 1
                              local.set 63
                              any.convert_extern
                              ref.cast eqref
                              local.get 63
                              ref.eq
                              local.set 25
                              local.get 25
                              i32.eqz
                              br_if 0 (;@13;)
                              i32.const 1
                              local.set 3
                              br 1 (;@12;)
                            end
                            i32.const 16
                            array.new_default 8
                            ref.cast (ref null 8)
                            local.set 26
                            local.get 26
                            ref.cast (ref null 8)
                            local.set 27
                            local.get 27
                            i64.const 0
                            struct.new 2
                            struct.new 9
                            ref.cast (ref null 9)
                            local.set 28
                            local.get 28
                            i64.const 0
                            struct.new 10
                            ref.cast (ref null 10)
                            local.set 29
                            local.get 20
                            local.get 22
                            local.get 29
                            i64.const 0
                            call 2
                            local.set 30
                            local.get 30
                            local.set 3
                            br 0 (;@12;)
                          end
                          local.get 3
                          return
                        end
                        local.get 0
                        any.convert_extern
                        ref.test (ref 18)
                        local.set 31
                        local.get 31
                        i32.eqz
                        br_if 4 (;@6;)
                        local.get 1
                        drop
                        i32.const 0
                        local.set 32
                        local.get 32
                        i32.eqz
                        br_if 4 (;@6;)
                        local.get 0
                        any.convert_extern
                        ref.cast (ref null 18)
                        local.set 33
                        local.get 1
                        local.set 34
                        local.get 33
                        struct.get 18 0
                        local.set 35
                        local.get 35
                        local.get 34
                        any.convert_extern
                        ref.cast eqref
                        local.set 64
                        any.convert_extern
                        ref.cast eqref
                        local.get 64
                        ref.eq
                        local.set 36
                        local.get 36
                        i32.eqz
                        br_if 0 (;@10;)
                        i32.const 1
                        local.set 4
                        br 3 (;@7;)
                      end
                      local.get 35
                      global.get 0
                      local.set 65
                      any.convert_extern
                      ref.cast eqref
                      local.get 65
                      ref.eq
                      local.set 37
                      local.get 37
                      i32.eqz
                      br_if 0 (;@9;)
                      i32.const 1
                      local.set 4
                      br 2 (;@7;)
                    end
                    local.get 34
                    global.get 1
                    local.set 66
                    any.convert_extern
                    ref.cast eqref
                    local.get 66
                    ref.eq
                    local.set 38
                    local.get 38
                    i32.eqz
                    br_if 0 (;@8;)
                    i32.const 1
                    local.set 4
                    br 1 (;@7;)
                  end
                  i32.const 16
                  array.new_default 8
                  ref.cast (ref null 8)
                  local.set 39
                  local.get 39
                  ref.cast (ref null 8)
                  local.set 40
                  local.get 40
                  i64.const 0
                  struct.new 2
                  struct.new 9
                  ref.cast (ref null 9)
                  local.set 41
                  local.get 41
                  i64.const 0
                  struct.new 10
                  ref.cast (ref null 10)
                  local.set 42
                  local.get 35
                  local.get 34
                  local.get 42
                  i64.const 0
                  call 2
                  local.set 43
                  local.get 43
                  local.set 4
                  br 0 (;@7;)
                end
                local.get 4
                return
              end
              local.get 0
              any.convert_extern
              ref.test (ref 18)
              local.set 44
              local.get 44
              i32.eqz
              br_if 4 (;@1;)
              local.get 1
              any.convert_extern
              ref.test (ref 18)
              local.set 45
              local.get 45
              i32.eqz
              br_if 4 (;@1;)
              local.get 0
              any.convert_extern
              ref.cast (ref null 18)
              local.set 46
              local.get 1
              any.convert_extern
              ref.cast (ref null 18)
              local.set 47
              local.get 46
              struct.get 18 0
              local.set 48
              local.get 47
              struct.get 18 0
              local.set 49
              local.get 48
              local.get 49
              any.convert_extern
              ref.cast eqref
              local.set 67
              any.convert_extern
              ref.cast eqref
              local.get 67
              ref.eq
              local.set 50
              local.get 50
              i32.eqz
              br_if 0 (;@5;)
              i32.const 1
              local.set 5
              br 3 (;@2;)
            end
            local.get 48
            global.get 0
            local.set 68
            any.convert_extern
            ref.cast eqref
            local.get 68
            ref.eq
            local.set 51
            local.get 51
            i32.eqz
            br_if 0 (;@4;)
            i32.const 1
            local.set 5
            br 2 (;@2;)
          end
          local.get 49
          global.get 1
          local.set 69
          any.convert_extern
          ref.cast eqref
          local.get 69
          ref.eq
          local.set 52
          local.get 52
          i32.eqz
          br_if 0 (;@3;)
          i32.const 1
          local.set 5
          br 1 (;@2;)
        end
        i32.const 16
        array.new_default 8
        ref.cast (ref null 8)
        local.set 53
        local.get 53
        ref.cast (ref null 8)
        local.set 54
        local.get 54
        i64.const 0
        struct.new 2
        struct.new 9
        ref.cast (ref null 9)
        local.set 55
        local.get 55
        i64.const 0
        struct.new 10
        ref.cast (ref null 10)
        local.set 56
        local.get 48
        local.get 49
        local.get 56
        i64.const 0
        call 2
        local.set 57
        local.get 57
        local.set 5
        br 0 (;@2;)
      end
      local.get 5
      return
    end
    i32.const 0
    return
    unreachable
  )
  (func (;21;) (type 35) (param externref externref) (result externref)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32 i32 i32 i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32 externref eqref eqref eqref eqref eqref eqref eqref eqref eqref eqref eqref)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  block ;; label = @8
                    block ;; label = @9
                      block ;; label = @10
                        block ;; label = @11
                          block ;; label = @12
                            block ;; label = @13
                              block ;; label = @14
                                block ;; label = @15
                                  local.get 0
                                  local.get 1
                                  any.convert_extern
                                  ref.cast eqref
                                  local.set 28
                                  any.convert_extern
                                  ref.cast eqref
                                  local.get 28
                                  ref.eq
                                  local.set 4
                                  local.get 4
                                  i32.eqz
                                  br_if 0 (;@15;)
                                  local.get 0
                                  return
                                end
                                local.get 0
                                global.get 0
                                local.set 29
                                any.convert_extern
                                ref.cast eqref
                                local.get 29
                                ref.eq
                                local.set 5
                                local.get 5
                                i32.eqz
                                br_if 0 (;@14;)
                                global.get 0
                                extern.convert_any
                                return
                              end
                              local.get 1
                              global.get 0
                              local.set 30
                              any.convert_extern
                              ref.cast eqref
                              local.get 30
                              ref.eq
                              local.set 6
                              local.get 6
                              i32.eqz
                              br_if 0 (;@13;)
                              global.get 0
                              extern.convert_any
                              return
                            end
                            local.get 0
                            global.get 1
                            local.set 31
                            any.convert_extern
                            ref.cast eqref
                            local.get 31
                            ref.eq
                            local.set 7
                            local.get 7
                            i32.eqz
                            br_if 0 (;@12;)
                            local.get 1
                            return
                          end
                          local.get 1
                          global.get 1
                          local.set 32
                          any.convert_extern
                          ref.cast eqref
                          local.get 32
                          ref.eq
                          local.set 8
                          local.get 8
                          i32.eqz
                          br_if 0 (;@11;)
                          local.get 0
                          return
                        end
                        local.get 0
                        call 22
                        local.set 9
                        local.get 9
                        i32.eqz
                        br_if 9 (;@1;)
                        local.get 1
                        call 22
                        local.set 10
                        local.get 10
                        i32.eqz
                        br_if 9 (;@1;)
                        local.get 0
                        local.get 1
                        any.convert_extern
                        ref.cast eqref
                        local.set 33
                        any.convert_extern
                        ref.cast eqref
                        local.get 33
                        ref.eq
                        local.set 11
                        local.get 11
                        i32.eqz
                        br_if 0 (;@10;)
                        i32.const 1
                        local.set 2
                        br 3 (;@7;)
                      end
                      local.get 0
                      global.get 0
                      local.set 34
                      any.convert_extern
                      ref.cast eqref
                      local.get 34
                      ref.eq
                      local.set 12
                      local.get 12
                      i32.eqz
                      br_if 0 (;@9;)
                      i32.const 1
                      local.set 2
                      br 2 (;@7;)
                    end
                    local.get 1
                    global.get 1
                    local.set 35
                    any.convert_extern
                    ref.cast eqref
                    local.get 35
                    ref.eq
                    local.set 13
                    local.get 13
                    i32.eqz
                    br_if 0 (;@8;)
                    i32.const 1
                    local.set 2
                    br 1 (;@7;)
                  end
                  i32.const 16
                  array.new_default 8
                  ref.cast (ref null 8)
                  local.set 14
                  local.get 14
                  ref.cast (ref null 8)
                  local.set 15
                  local.get 15
                  i64.const 0
                  struct.new 2
                  struct.new 9
                  ref.cast (ref null 9)
                  local.set 16
                  local.get 16
                  i64.const 0
                  struct.new 10
                  ref.cast (ref null 10)
                  local.set 17
                  local.get 0
                  local.get 1
                  local.get 17
                  i64.const 0
                  call 2
                  local.set 18
                  local.get 18
                  local.set 2
                  br 0 (;@7;)
                end
                local.get 2
                i32.eqz
                br_if 0 (;@6;)
                local.get 0
                return
              end
              local.get 1
              local.get 0
              any.convert_extern
              ref.cast eqref
              local.set 36
              any.convert_extern
              ref.cast eqref
              local.get 36
              ref.eq
              local.set 19
              local.get 19
              i32.eqz
              br_if 0 (;@5;)
              i32.const 1
              local.set 3
              br 3 (;@2;)
            end
            local.get 1
            global.get 0
            local.set 37
            any.convert_extern
            ref.cast eqref
            local.get 37
            ref.eq
            local.set 20
            local.get 20
            i32.eqz
            br_if 0 (;@4;)
            i32.const 1
            local.set 3
            br 2 (;@2;)
          end
          local.get 0
          global.get 1
          local.set 38
          any.convert_extern
          ref.cast eqref
          local.get 38
          ref.eq
          local.set 21
          local.get 21
          i32.eqz
          br_if 0 (;@3;)
          i32.const 1
          local.set 3
          br 1 (;@2;)
        end
        i32.const 16
        array.new_default 8
        ref.cast (ref null 8)
        local.set 22
        local.get 22
        ref.cast (ref null 8)
        local.set 23
        local.get 23
        i64.const 0
        struct.new 2
        struct.new 9
        ref.cast (ref null 9)
        local.set 24
        local.get 24
        i64.const 0
        struct.new 10
        ref.cast (ref null 10)
        local.set 25
        local.get 1
        local.get 0
        local.get 25
        i64.const 0
        call 2
        local.set 26
        local.get 26
        local.set 3
        br 0 (;@2;)
      end
      local.get 3
      i32.eqz
      br_if 0 (;@1;)
      local.get 1
      return
    end
    local.get 0
    local.get 1
    i64.const 0
    call 23
    local.set 27
    local.get 27
    return
    unreachable
  )
  (func (;22;) (type 30) (param externref) (result i32)
    (local i32 externref i64 externref i64 externref i64 i32 i32 i32 i32 (ref null 18) externref i32 (ref null 18) externref i32 i32 (ref null 16) (ref null 13) i64 i32 (ref null 13) i32 i32 i64 i32 (ref null 13) i64 i32)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  block ;; label = @8
                    block ;; label = @9
                      block ;; label = @10
                        local.get 0
                        any.convert_extern
                        ref.test (ref 6)
                        local.set 9
                        local.get 9
                        i32.eqz
                        br_if 0 (;@10;)
                        i32.const 0
                        return
                      end
                      local.get 0
                      any.convert_extern
                      ref.test (ref 11)
                      local.set 10
                      local.get 10
                      i32.eqz
                      br_if 0 (;@9;)
                      i32.const 0
                      return
                    end
                    local.get 0
                    any.convert_extern
                    ref.test (ref 18)
                    local.set 11
                    local.get 11
                    i32.eqz
                    br_if 1 (;@7;)
                    local.get 0
                    any.convert_extern
                    ref.cast (ref null 18)
                    local.set 12
                    local.get 12
                    struct.get 18 0
                    local.set 13
                    local.get 13
                    call 22
                    local.set 14
                    local.get 14
                    i32.eqz
                    br_if 0 (;@8;)
                    local.get 0
                    any.convert_extern
                    ref.cast (ref null 18)
                    local.set 15
                    local.get 15
                    struct.get 18 1
                    local.set 16
                    local.get 16
                    call 22
                    local.set 17
                    local.get 17
                    return
                  end
                  i32.const 0
                  return
                end
                local.get 0
                any.convert_extern
                ref.test (ref 16)
                local.set 18
                local.get 18
                i32.eqz
                br_if 5 (;@1;)
                local.get 0
                any.convert_extern
                ref.cast (ref null 16)
                local.set 19
                local.get 19
                struct.get 16 2
                local.set 20
                local.get 20
                local.get 20
                array.len
                i64.extend_i32_u
                local.set 21
                local.get 21
                i64.const 1
                i64.lt_s
                local.set 22
                local.get 22
                i32.eqz
                br_if 0 (;@6;)
                i32.const 1
                local.set 1
                br 1 (;@5;)
              end
              local.get 20
              i64.const 1
              local.get 20
              i64.const 1
              i32.wrap_i64
              i32.const 1
              i32.sub
              array.get 13
              any.convert_extern
              ref.cast (ref null 13)
              local.set 23
              i32.const 0
              local.set 1
              local.get 23
              extern.convert_any
              local.set 2
              i64.const 2
              local.set 3
              br 0 (;@5;)
            end
            local.get 1
            i32.eqz
            local.set 24
            local.get 24
            i32.eqz
            br_if 2 (;@2;)
            local.get 2
            local.set 4
            local.get 3
            local.set 5
          end
          loop ;; label = @4
            block ;; label = @5
              block ;; label = @6
                local.get 4
                call 22
                local.set 25
                local.get 25
                i32.eqz
                br_if 3 (;@3;)
                local.get 20
                local.get 20
                array.len
                i64.extend_i32_u
                local.set 26
                local.get 26
                local.get 5
                i64.lt_s
                local.set 27
                local.get 27
                i32.eqz
                br_if 0 (;@6;)
                i32.const 1
                local.set 8
                br 1 (;@5;)
              end
              local.get 20
              local.get 5
              i32.wrap_i64
              i32.const 1
              i32.sub
              array.get 13
              any.convert_extern
              ref.cast (ref null 13)
              local.set 28
              local.get 5
              i64.const 1
              i64.add
              local.set 29
              local.get 28
              extern.convert_any
              local.set 6
              local.get 29
              local.set 7
              i32.const 0
              local.set 8
              br 0 (;@5;)
            end
            local.get 8
            i32.eqz
            local.set 30
            local.get 30
            i32.eqz
            br_if 2 (;@2;)
            local.get 6
            local.set 4
            local.get 7
            local.set 5
            br 0 (;@4;)
          end
        end
        i32.const 0
        return
      end
      i32.const 1
      return
    end
    i32.const 1
    return
    unreachable
  )
  (func (;23;) (type 36) (param externref externref i64) (result externref)
    (local i32 i32 i32 i32 i32 i32 i32 i32 (ref null 18) externref externref externref externref externref i32 (ref null 18) externref externref externref externref externref i32 i32 i32 i32 (ref null 16) (ref null 16) externref i32 i32 i32 i32 i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32 i32 i32 i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) externref eqref eqref eqref eqref eqref eqref eqref eqref eqref eqref eqref)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  block ;; label = @8
                    block ;; label = @9
                      block ;; label = @10
                        block ;; label = @11
                          block ;; label = @12
                            block ;; label = @13
                              block ;; label = @14
                                block ;; label = @15
                                  block ;; label = @16
                                    block ;; label = @17
                                      block ;; label = @18
                                        block ;; label = @19
                                          block ;; label = @20
                                            block ;; label = @21
                                              local.get 0
                                              local.get 1
                                              any.convert_extern
                                              ref.cast eqref
                                              local.set 54
                                              any.convert_extern
                                              ref.cast eqref
                                              local.get 54
                                              ref.eq
                                              local.set 5
                                              local.get 5
                                              i32.eqz
                                              br_if 0 (;@21;)
                                              local.get 0
                                              return
                                            end
                                            local.get 0
                                            global.get 0
                                            local.set 55
                                            any.convert_extern
                                            ref.cast eqref
                                            local.get 55
                                            ref.eq
                                            local.set 6
                                            local.get 6
                                            i32.eqz
                                            br_if 0 (;@20;)
                                            global.get 0
                                            extern.convert_any
                                            return
                                          end
                                          local.get 1
                                          global.get 0
                                          local.set 56
                                          any.convert_extern
                                          ref.cast eqref
                                          local.get 56
                                          ref.eq
                                          local.set 7
                                          local.get 7
                                          i32.eqz
                                          br_if 0 (;@19;)
                                          global.get 0
                                          extern.convert_any
                                          return
                                        end
                                        local.get 0
                                        global.get 1
                                        local.set 57
                                        any.convert_extern
                                        ref.cast eqref
                                        local.get 57
                                        ref.eq
                                        local.set 8
                                        local.get 8
                                        i32.eqz
                                        br_if 0 (;@18;)
                                        local.get 1
                                        return
                                      end
                                      local.get 1
                                      global.get 1
                                      local.set 58
                                      any.convert_extern
                                      ref.cast eqref
                                      local.get 58
                                      ref.eq
                                      local.set 9
                                      local.get 9
                                      i32.eqz
                                      br_if 0 (;@17;)
                                      local.get 0
                                      return
                                    end
                                    local.get 0
                                    any.convert_extern
                                    ref.test (ref 18)
                                    local.set 10
                                    local.get 10
                                    i32.eqz
                                    br_if 0 (;@16;)
                                    local.get 0
                                    any.convert_extern
                                    ref.cast (ref null 18)
                                    local.set 11
                                    local.get 11
                                    struct.get 18 0
                                    local.set 12
                                    local.get 12
                                    local.get 1
                                    local.get 2
                                    call 23
                                    local.set 13
                                    local.get 11
                                    struct.get 18 1
                                    local.set 14
                                    local.get 14
                                    local.get 1
                                    local.get 2
                                    call 23
                                    local.set 15
                                    local.get 13
                                    local.get 15
                                    call 24
                                    local.set 16
                                    local.get 16
                                    return
                                  end
                                  local.get 1
                                  any.convert_extern
                                  ref.test (ref 18)
                                  local.set 17
                                  local.get 17
                                  i32.eqz
                                  br_if 0 (;@15;)
                                  local.get 1
                                  any.convert_extern
                                  ref.cast (ref null 18)
                                  local.set 18
                                  local.get 18
                                  struct.get 18 0
                                  local.set 19
                                  local.get 19
                                  local.get 0
                                  local.get 2
                                  call 23
                                  local.set 20
                                  local.get 18
                                  struct.get 18 1
                                  local.set 21
                                  local.get 21
                                  local.get 0
                                  local.get 2
                                  call 23
                                  local.set 22
                                  local.get 20
                                  local.get 22
                                  call 24
                                  local.set 23
                                  local.get 23
                                  return
                                end
                                local.get 0
                                any.convert_extern
                                ref.test (ref 11)
                                local.set 24
                                local.get 24
                                i32.eqz
                                br_if 0 (;@14;)
                                br 13 (;@1;)
                              end
                              local.get 1
                              any.convert_extern
                              ref.test (ref 11)
                              local.set 25
                              local.get 25
                              i32.eqz
                              br_if 0 (;@13;)
                              br 12 (;@1;)
                            end
                            local.get 0
                            any.convert_extern
                            ref.test (ref 16)
                            local.set 26
                            local.get 26
                            i32.eqz
                            br_if 0 (;@12;)
                            local.get 1
                            any.convert_extern
                            ref.test (ref 16)
                            local.set 27
                            local.get 27
                            i32.eqz
                            br_if 0 (;@12;)
                            local.get 0
                            any.convert_extern
                            ref.cast (ref null 16)
                            local.set 28
                            local.get 1
                            any.convert_extern
                            ref.cast (ref null 16)
                            local.set 29
                            local.get 28
                            local.get 29
                            local.get 2
                            call 25
                            local.set 30
                            local.get 30
                            return
                          end
                          local.get 0
                          call 22
                          local.set 31
                          local.get 31
                          i32.eqz
                          br_if 9 (;@2;)
                          local.get 1
                          call 22
                          local.set 32
                          local.get 32
                          i32.eqz
                          br_if 9 (;@2;)
                          local.get 0
                          local.get 1
                          any.convert_extern
                          ref.cast eqref
                          local.set 59
                          any.convert_extern
                          ref.cast eqref
                          local.get 59
                          ref.eq
                          local.set 33
                          local.get 33
                          i32.eqz
                          br_if 0 (;@11;)
                          i32.const 1
                          local.set 3
                          br 3 (;@8;)
                        end
                        local.get 0
                        global.get 0
                        local.set 60
                        any.convert_extern
                        ref.cast eqref
                        local.get 60
                        ref.eq
                        local.set 34
                        local.get 34
                        i32.eqz
                        br_if 0 (;@10;)
                        i32.const 1
                        local.set 3
                        br 2 (;@8;)
                      end
                      local.get 1
                      global.get 1
                      local.set 61
                      any.convert_extern
                      ref.cast eqref
                      local.get 61
                      ref.eq
                      local.set 35
                      local.get 35
                      i32.eqz
                      br_if 0 (;@9;)
                      i32.const 1
                      local.set 3
                      br 1 (;@8;)
                    end
                    i32.const 16
                    array.new_default 8
                    ref.cast (ref null 8)
                    local.set 36
                    local.get 36
                    ref.cast (ref null 8)
                    local.set 37
                    local.get 37
                    i64.const 0
                    struct.new 2
                    struct.new 9
                    ref.cast (ref null 9)
                    local.set 38
                    local.get 38
                    i64.const 0
                    struct.new 10
                    ref.cast (ref null 10)
                    local.set 39
                    local.get 0
                    local.get 1
                    local.get 39
                    i64.const 0
                    call 2
                    local.set 40
                    local.get 40
                    local.set 3
                    br 0 (;@8;)
                  end
                  local.get 3
                  i32.eqz
                  br_if 0 (;@7;)
                  local.get 0
                  return
                end
                local.get 1
                local.get 0
                any.convert_extern
                ref.cast eqref
                local.set 62
                any.convert_extern
                ref.cast eqref
                local.get 62
                ref.eq
                local.set 41
                local.get 41
                i32.eqz
                br_if 0 (;@6;)
                i32.const 1
                local.set 4
                br 3 (;@3;)
              end
              local.get 1
              global.get 0
              local.set 63
              any.convert_extern
              ref.cast eqref
              local.get 63
              ref.eq
              local.set 42
              local.get 42
              i32.eqz
              br_if 0 (;@5;)
              i32.const 1
              local.set 4
              br 2 (;@3;)
            end
            local.get 0
            global.get 1
            local.set 64
            any.convert_extern
            ref.cast eqref
            local.get 64
            ref.eq
            local.set 43
            local.get 43
            i32.eqz
            br_if 0 (;@4;)
            i32.const 1
            local.set 4
            br 1 (;@3;)
          end
          i32.const 16
          array.new_default 8
          ref.cast (ref null 8)
          local.set 44
          local.get 44
          ref.cast (ref null 8)
          local.set 45
          local.get 45
          i64.const 0
          struct.new 2
          struct.new 9
          ref.cast (ref null 9)
          local.set 46
          local.get 46
          i64.const 0
          struct.new 10
          ref.cast (ref null 10)
          local.set 47
          local.get 1
          local.get 0
          local.get 47
          i64.const 0
          call 2
          local.set 48
          local.get 48
          local.set 4
          br 0 (;@3;)
        end
        local.get 4
        i32.eqz
        br_if 0 (;@2;)
        local.get 1
        return
      end
      global.get 0
      extern.convert_any
      return
    end
    i32.const 16
    array.new_default 8
    ref.cast (ref null 8)
    local.set 49
    local.get 49
    ref.cast (ref null 8)
    local.set 50
    local.get 50
    i64.const 0
    struct.new 2
    struct.new 9
    ref.cast (ref null 9)
    local.set 51
    local.get 51
    i64.const 0
    struct.new 10
    ref.cast (ref null 10)
    local.set 52
    local.get 0
    local.get 1
    local.get 52
    local.get 2
    unreachable
    local.get 53
    return
    unreachable
  )
  (func (;24;) (type 35) (param externref externref) (result externref)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32 i32 i32 i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32 externref eqref eqref eqref eqref eqref eqref eqref eqref eqref)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  block ;; label = @8
                    block ;; label = @9
                      block ;; label = @10
                        block ;; label = @11
                          block ;; label = @12
                            block ;; label = @13
                              local.get 0
                              global.get 0
                              local.set 26
                              any.convert_extern
                              ref.cast eqref
                              local.get 26
                              ref.eq
                              local.set 4
                              local.get 4
                              i32.eqz
                              br_if 0 (;@13;)
                              local.get 1
                              return
                            end
                            local.get 1
                            global.get 0
                            local.set 27
                            any.convert_extern
                            ref.cast eqref
                            local.get 27
                            ref.eq
                            local.set 5
                            local.get 5
                            i32.eqz
                            br_if 0 (;@12;)
                            local.get 0
                            return
                          end
                          local.get 0
                          local.get 1
                          any.convert_extern
                          ref.cast eqref
                          local.set 28
                          any.convert_extern
                          ref.cast eqref
                          local.get 28
                          ref.eq
                          local.set 6
                          local.get 6
                          i32.eqz
                          br_if 0 (;@11;)
                          local.get 0
                          return
                        end
                        local.get 0
                        call 22
                        local.set 7
                        local.get 7
                        i32.eqz
                        br_if 9 (;@1;)
                        local.get 1
                        call 22
                        local.set 8
                        local.get 8
                        i32.eqz
                        br_if 9 (;@1;)
                        local.get 0
                        local.get 1
                        any.convert_extern
                        ref.cast eqref
                        local.set 29
                        any.convert_extern
                        ref.cast eqref
                        local.get 29
                        ref.eq
                        local.set 9
                        local.get 9
                        i32.eqz
                        br_if 0 (;@10;)
                        i32.const 1
                        local.set 2
                        br 3 (;@7;)
                      end
                      local.get 0
                      global.get 0
                      local.set 30
                      any.convert_extern
                      ref.cast eqref
                      local.get 30
                      ref.eq
                      local.set 10
                      local.get 10
                      i32.eqz
                      br_if 0 (;@9;)
                      i32.const 1
                      local.set 2
                      br 2 (;@7;)
                    end
                    local.get 1
                    global.get 1
                    local.set 31
                    any.convert_extern
                    ref.cast eqref
                    local.get 31
                    ref.eq
                    local.set 11
                    local.get 11
                    i32.eqz
                    br_if 0 (;@8;)
                    i32.const 1
                    local.set 2
                    br 1 (;@7;)
                  end
                  i32.const 16
                  array.new_default 8
                  ref.cast (ref null 8)
                  local.set 12
                  local.get 12
                  ref.cast (ref null 8)
                  local.set 13
                  local.get 13
                  i64.const 0
                  struct.new 2
                  struct.new 9
                  ref.cast (ref null 9)
                  local.set 14
                  local.get 14
                  i64.const 0
                  struct.new 10
                  ref.cast (ref null 10)
                  local.set 15
                  local.get 0
                  local.get 1
                  local.get 15
                  i64.const 0
                  call 2
                  local.set 16
                  local.get 16
                  local.set 2
                  br 0 (;@7;)
                end
                local.get 2
                i32.eqz
                br_if 0 (;@6;)
                local.get 1
                return
              end
              local.get 1
              local.get 0
              any.convert_extern
              ref.cast eqref
              local.set 32
              any.convert_extern
              ref.cast eqref
              local.get 32
              ref.eq
              local.set 17
              local.get 17
              i32.eqz
              br_if 0 (;@5;)
              i32.const 1
              local.set 3
              br 3 (;@2;)
            end
            local.get 1
            global.get 0
            local.set 33
            any.convert_extern
            ref.cast eqref
            local.get 33
            ref.eq
            local.set 18
            local.get 18
            i32.eqz
            br_if 0 (;@4;)
            i32.const 1
            local.set 3
            br 2 (;@2;)
          end
          local.get 0
          global.get 1
          local.set 34
          any.convert_extern
          ref.cast eqref
          local.get 34
          ref.eq
          local.set 19
          local.get 19
          i32.eqz
          br_if 0 (;@3;)
          i32.const 1
          local.set 3
          br 1 (;@2;)
        end
        i32.const 16
        array.new_default 8
        ref.cast (ref null 8)
        local.set 20
        local.get 20
        ref.cast (ref null 8)
        local.set 21
        local.get 21
        i64.const 0
        struct.new 2
        struct.new 9
        ref.cast (ref null 9)
        local.set 22
        local.get 22
        i64.const 0
        struct.new 10
        ref.cast (ref null 10)
        local.set 23
        local.get 1
        local.get 0
        local.get 23
        i64.const 0
        call 2
        local.set 24
        local.get 24
        local.set 3
        br 0 (;@2;)
      end
      local.get 3
      i32.eqz
      br_if 0 (;@1;)
      local.get 0
      return
    end
    unreachable
    local.get 25
    return
    unreachable
  )
  (func (;25;) (type 37) (param (ref null 16) (ref null 16) i64) (result externref)
    (local i32 i32 i32 i32 externref i32 (ref null 15) (ref null 15) i32 i32 externref i32 externref i32 i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32 i32 i32 i32 i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32 i32 i32 i32 i32 i32 i32 i32 i32)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  block ;; label = @8
                    block ;; label = @9
                      block ;; label = @10
                        block ;; label = @11
                          block ;; label = @12
                            block ;; label = @13
                              block ;; label = @14
                                block ;; label = @15
                                  block ;; label = @16
                                    block ;; label = @17
                                      block ;; label = @18
                                        block ;; label = @19
                                          block ;; label = @20
                                            block ;; label = @21
                                              local.get 0
                                              local.get 1
                                              ref.eq
                                              local.set 8
                                              local.get 8
                                              i32.eqz
                                              br_if 0 (;@21;)
                                              local.get 0
                                              extern.convert_any
                                              return
                                            end
                                            local.get 0
                                            struct.get 16 0
                                            local.set 9
                                            local.get 1
                                            struct.get 16 0
                                            local.set 10
                                            local.get 9
                                            ref.null 15
                                            ref.eq
                                            local.set 11
                                            local.get 11
                                            i32.eqz
                                            br_if 0 (;@20;)
                                            local.get 10
                                            ref.null 15
                                            ref.eq
                                            local.set 12
                                            local.get 12
                                            i32.eqz
                                            br_if 0 (;@20;)
                                            local.get 0
                                            local.get 1
                                            local.get 2
                                            call 26
                                            local.set 13
                                            local.get 13
                                            return
                                          end
                                          local.get 9
                                          local.get 10
                                          ref.eq
                                          local.set 14
                                          local.get 14
                                          i32.eqz
                                          br_if 0 (;@19;)
                                          local.get 0
                                          local.get 1
                                          local.get 2
                                          call 27
                                          local.set 15
                                          local.get 15
                                          return
                                        end
                                        local.get 0
                                        local.get 1
                                        ref.eq
                                        local.set 16
                                        local.get 16
                                        i32.eqz
                                        br_if 0 (;@18;)
                                        i32.const 1
                                        local.set 4
                                        br 5 (;@13;)
                                      end
                                      local.get 1
                                      global.get 1
                                      ref.eq
                                      local.set 17
                                      local.get 17
                                      i32.eqz
                                      br_if 0 (;@17;)
                                      i32.const 1
                                      local.set 4
                                      br 4 (;@13;)
                                    end
                                    i32.const 16
                                    array.new_default 8
                                    ref.cast (ref null 8)
                                    local.set 18
                                    local.get 18
                                    ref.cast (ref null 8)
                                    local.set 19
                                    local.get 19
                                    i64.const 0
                                    struct.new 2
                                    struct.new 9
                                    ref.cast (ref null 9)
                                    local.set 20
                                    local.get 20
                                    i64.const 0
                                    struct.new 10
                                    ref.cast (ref null 10)
                                    local.set 21
                                    local.get 0
                                    local.get 1
                                    ref.eq
                                    local.set 22
                                    local.get 22
                                    i32.eqz
                                    br_if 0 (;@16;)
                                    i32.const 1
                                    local.set 3
                                    br 2 (;@14;)
                                  end
                                  local.get 1
                                  global.get 1
                                  ref.eq
                                  local.set 23
                                  local.get 23
                                  i32.eqz
                                  br_if 0 (;@15;)
                                  i32.const 1
                                  local.set 3
                                  br 1 (;@14;)
                                end
                                local.get 0
                                local.get 1
                                local.get 21
                                i64.const 0
                                call 14
                                local.set 24
                                local.get 24
                                local.set 3
                                br 0 (;@14;)
                              end
                              local.get 3
                              local.set 4
                              br 0 (;@13;)
                            end
                            local.get 4
                            i32.eqz
                            br_if 0 (;@12;)
                            ref.null extern
                            local.set 7
                            br 11 (;@1;)
                          end
                          local.get 1
                          local.get 0
                          ref.eq
                          local.set 25
                          local.get 25
                          i32.eqz
                          br_if 0 (;@11;)
                          i32.const 1
                          local.set 6
                          br 5 (;@6;)
                        end
                        local.get 0
                        global.get 1
                        ref.eq
                        local.set 26
                        local.get 26
                        i32.eqz
                        br_if 0 (;@10;)
                        i32.const 1
                        local.set 6
                        br 4 (;@6;)
                      end
                      i32.const 16
                      array.new_default 8
                      ref.cast (ref null 8)
                      local.set 27
                      local.get 27
                      ref.cast (ref null 8)
                      local.set 28
                      local.get 28
                      i64.const 0
                      struct.new 2
                      struct.new 9
                      ref.cast (ref null 9)
                      local.set 29
                      local.get 29
                      i64.const 0
                      struct.new 10
                      ref.cast (ref null 10)
                      local.set 30
                      local.get 1
                      local.get 0
                      ref.eq
                      local.set 31
                      local.get 31
                      i32.eqz
                      br_if 0 (;@9;)
                      i32.const 1
                      local.set 5
                      br 2 (;@7;)
                    end
                    local.get 0
                    global.get 1
                    ref.eq
                    local.set 32
                    local.get 32
                    i32.eqz
                    br_if 0 (;@8;)
                    i32.const 1
                    local.set 5
                    br 1 (;@7;)
                  end
                  local.get 1
                  local.get 0
                  local.get 30
                  i64.const 0
                  call 14
                  local.set 33
                  local.get 33
                  local.set 5
                  br 0 (;@7;)
                end
                local.get 5
                local.set 6
                br 0 (;@6;)
              end
              local.get 6
              i32.eqz
              br_if 0 (;@5;)
              ref.null extern
              local.set 7
              br 4 (;@1;)
            end
            local.get 0
            struct.get 16 7
            local.set 34
            local.get 34
            i32.const 2
            i32.and
            local.set 35
            local.get 35
            i32.const 2
            i32.eq
            local.set 36
            local.get 36
            i32.eqz
            br_if 0 (;@4;)
            br 2 (;@2;)
          end
          local.get 1
          struct.get 16 7
          local.set 37
          local.get 37
          i32.const 2
          i32.and
          local.set 38
          local.get 38
          i32.const 2
          i32.eq
          local.set 39
          local.get 39
          i32.eqz
          br_if 0 (;@3;)
          br 1 (;@2;)
        end
        ref.null extern
        local.set 7
        br 1 (;@1;)
      end
      ref.null extern
      local.set 7
      br 0 (;@1;)
    end
    local.get 7
    return
    unreachable
  )
  (func (;26;) (type 37) (param (ref null 16) (ref null 16) i64) (result externref)
    (local i32 i32 i64 i32 i64 i64 i64 i64 i64 i64 i64 i32 i64 i32 i64 i64 i64 i64 i64 i64 i32 i32 i64 i32 i64 i64 i64 i64 i64 i64 i32 i32 i32 (ref null 13) (ref null 13) i64 i64 i32 (ref null 13) i32 i32 (ref null 13) i32 i32 i32 i32 i32 (ref null 13) (ref null 13) (ref null 2) (ref null 38) i32 i32 i32 (ref null 13) (ref null 13) i32 externref i32 i32 i64 i64 (ref null 2) i32 i64 i64 i32 (ref null 2) (ref null 13) externref i32 i64 i32 i32 i32 i32 i32 i64 i64 (ref null 2) i32 i64 i64 i32 (ref null 2) (ref null 13) externref (ref null 13) i32 i32 i64 i32 i32 i32 i32 i32 i64 i64 (ref null 2) i32 i64 i64 i32 (ref null 2) (ref null 13) externref (ref null 13) i32 i32 i64 i32 (ref null 16) (ref null 13) externref i32 externref i32 externref externref i32 eqref eqref eqref)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  block ;; label = @8
                    block ;; label = @9
                      block ;; label = @10
                        block ;; label = @11
                          block ;; label = @12
                            block ;; label = @13
                              block ;; label = @14
                                block ;; label = @15
                                  block ;; label = @16
                                    block ;; label = @17
                                      block ;; label = @18
                                        block ;; label = @19
                                          block ;; label = @20
                                            block ;; label = @21
                                              block ;; label = @22
                                                block ;; label = @23
                                                  block ;; label = @24
                                                    block ;; label = @25
                                                      block ;; label = @26
                                                        block ;; label = @27
                                                          block ;; label = @28
                                                            block ;; label = @29
                                                              block ;; label = @30
                                                                block ;; label = @31
                                                                  block ;; label = @32
                                                                    block ;; label = @33
                                                                      block ;; label = @34
                                                                        local.get 0
                                                                        local.get 1
                                                                        ref.eq
                                                                        local.set 35
                                                                        local.get 35
                                                                        i32.eqz
                                                                        br_if 0 (;@34;)
                                                                        local.get 0
                                                                        extern.convert_any
                                                                        return
                                                                      end
                                                                      local.get 0
                                                                      struct.get 16 2
                                                                      local.set 36
                                                                      local.get 1
                                                                      struct.get 16 2
                                                                      local.set 37
                                                                      local.get 36
                                                                      local.get 36
                                                                      array.len
                                                                      i64.extend_i32_u
                                                                      local.set 38
                                                                      local.get 37
                                                                      local.get 37
                                                                      array.len
                                                                      i64.extend_i32_u
                                                                      local.set 39
                                                                      i64.const 0
                                                                      local.get 38
                                                                      i64.lt_s
                                                                      local.set 40
                                                                      local.get 40
                                                                      i32.eqz
                                                                      br_if 0 (;@33;)
                                                                      local.get 36
                                                                      local.get 38
                                                                      i32.wrap_i64
                                                                      i32.const 1
                                                                      i32.sub
                                                                      array.get 13
                                                                      any.convert_extern
                                                                      ref.cast (ref null 13)
                                                                      local.set 41
                                                                      local.get 41
                                                                      ref.is_null
                                                                      i32.eqz
                                                                      local.set 42
                                                                      local.get 42
                                                                      local.set 3
                                                                      br 1 (;@32;)
                                                                    end
                                                                    i32.const 0
                                                                    local.set 3
                                                                  end
                                                                  i64.const 0
                                                                  local.get 39
                                                                  i64.lt_s
                                                                  local.set 43
                                                                  local.get 43
                                                                  i32.eqz
                                                                  br_if 0 (;@31;)
                                                                  local.get 37
                                                                  local.get 39
                                                                  i32.wrap_i64
                                                                  i32.const 1
                                                                  i32.sub
                                                                  array.get 13
                                                                  any.convert_extern
                                                                  ref.cast (ref null 13)
                                                                  local.set 44
                                                                  local.get 44
                                                                  ref.is_null
                                                                  i32.eqz
                                                                  local.set 45
                                                                  local.get 45
                                                                  local.set 4
                                                                  br 1 (;@30;)
                                                                end
                                                                i32.const 0
                                                                local.set 4
                                                              end
                                                              local.get 3
                                                              i32.eqz
                                                              local.set 46
                                                              local.get 46
                                                              i32.eqz
                                                              br_if 25 (;@4;)
                                                              local.get 4
                                                              i32.eqz
                                                              local.set 47
                                                              local.get 47
                                                              i32.eqz
                                                              br_if 25 (;@4;)
                                                              local.get 38
                                                              local.get 39
                                                              i64.eq
                                                              local.set 48
                                                              local.get 48
                                                              i32.eqz
                                                              local.set 49
                                                              local.get 49
                                                              i32.eqz
                                                              br_if 0 (;@29;)
                                                              global.get 0
                                                              extern.convert_any
                                                              return
                                                            end
                                                            local.get 38
                                                            i32.wrap_i64
                                                            local.tee 122
                                                            i32.const 16
                                                            local.get 122
                                                            i32.const 16
                                                            i32.ge_s
                                                            select
                                                            array.new_default 13
                                                            ref.cast (ref null 13)
                                                            local.set 50
                                                            local.get 50
                                                            ref.cast (ref null 13)
                                                            local.set 51
                                                            local.get 38
                                                            struct.new 2
                                                            ref.cast (ref null 2)
                                                            local.set 52
                                                            local.get 51
                                                            local.get 52
                                                            struct.new 38
                                                            ref.cast (ref null 38)
                                                            local.set 53
                                                            i64.const 1
                                                            local.get 38
                                                            i64.le_s
                                                            local.set 54
                                                            local.get 54
                                                            i32.eqz
                                                            br_if 0 (;@28;)
                                                            local.get 38
                                                            local.set 5
                                                            br 1 (;@27;)
                                                          end
                                                          i64.const 0
                                                          local.set 5
                                                          br 0 (;@27;)
                                                        end
                                                        local.get 5
                                                        i64.const 1
                                                        i64.lt_s
                                                        local.set 55
                                                        local.get 55
                                                        i32.eqz
                                                        br_if 0 (;@26;)
                                                        i32.const 1
                                                        local.set 6
                                                        br 1 (;@25;)
                                                      end
                                                      i32.const 0
                                                      local.set 6
                                                      i64.const 1
                                                      local.set 7
                                                      i64.const 1
                                                      local.set 8
                                                      br 0 (;@25;)
                                                    end
                                                    local.get 6
                                                    i32.eqz
                                                    local.set 56
                                                    local.get 56
                                                    i32.eqz
                                                    br_if 1 (;@23;)
                                                    local.get 7
                                                    local.set 9
                                                    local.get 8
                                                    local.set 10
                                                  end
                                                  loop ;; label = @24
                                                    block ;; label = @25
                                                      block ;; label = @26
                                                        block ;; label = @27
                                                          block ;; label = @28
                                                            block ;; label = @29
                                                              local.get 36
                                                              local.get 9
                                                              i32.wrap_i64
                                                              i32.const 1
                                                              i32.sub
                                                              array.get 13
                                                              any.convert_extern
                                                              ref.cast (ref null 13)
                                                              local.set 57
                                                              local.get 37
                                                              local.get 9
                                                              i32.wrap_i64
                                                              i32.const 1
                                                              i32.sub
                                                              array.get 13
                                                              any.convert_extern
                                                              ref.cast (ref null 13)
                                                              local.set 58
                                                              local.get 2
                                                              i64.const 0
                                                              i64.eq
                                                              local.set 59
                                                              local.get 59
                                                              i32.eqz
                                                              br_if 0 (;@29;)
                                                              i64.const 1
                                                              local.set 11
                                                              br 1 (;@28;)
                                                            end
                                                            local.get 2
                                                            local.set 11
                                                          end
                                                          local.get 57
                                                          extern.convert_any
                                                          local.get 58
                                                          extern.convert_any
                                                          local.get 11
                                                          call 23
                                                          local.set 60
                                                          local.get 60
                                                          global.get 0
                                                          local.set 123
                                                          any.convert_extern
                                                          ref.cast eqref
                                                          local.get 123
                                                          ref.eq
                                                          local.set 61
                                                          local.get 61
                                                          i32.eqz
                                                          br_if 0 (;@27;)
                                                          global.get 0
                                                          extern.convert_any
                                                          return
                                                        end
                                                        local.get 53
                                                        struct.get 38 0
                                                        local.set 71
                                                        local.get 71
                                                        local.get 9
                                                        i32.wrap_i64
                                                        i32.const 1
                                                        i32.sub
                                                        local.get 60
                                                        array.set 13
                                                        local.get 60
                                                        local.set 72
                                                        local.get 10
                                                        local.get 5
                                                        i64.eq
                                                        local.set 73
                                                        local.get 73
                                                        i32.eqz
                                                        br_if 0 (;@26;)
                                                        i32.const 1
                                                        local.set 14
                                                        br 1 (;@25;)
                                                      end
                                                      local.get 10
                                                      i64.const 1
                                                      i64.add
                                                      local.set 74
                                                      local.get 74
                                                      local.set 12
                                                      local.get 74
                                                      local.set 13
                                                      i32.const 0
                                                      local.set 14
                                                      br 0 (;@25;)
                                                    end
                                                    local.get 14
                                                    i32.eqz
                                                    local.set 75
                                                    local.get 75
                                                    i32.eqz
                                                    br_if 1 (;@23;)
                                                    local.get 12
                                                    local.set 9
                                                    local.get 13
                                                    local.set 10
                                                    br 0 (;@24;)
                                                  end
                                                end
                                                i64.const 1
                                                local.get 38
                                                i64.le_s
                                                local.set 76
                                                local.get 76
                                                i32.eqz
                                                br_if 0 (;@22;)
                                                local.get 38
                                                local.set 15
                                                br 1 (;@21;)
                                              end
                                              i64.const 0
                                              local.set 15
                                              br 0 (;@21;)
                                            end
                                            local.get 15
                                            i64.const 1
                                            i64.lt_s
                                            local.set 77
                                            local.get 77
                                            i32.eqz
                                            br_if 0 (;@20;)
                                            i32.const 1
                                            local.set 16
                                            br 1 (;@19;)
                                          end
                                          i32.const 0
                                          local.set 16
                                          i64.const 1
                                          local.set 17
                                          i64.const 1
                                          local.set 18
                                          br 0 (;@19;)
                                        end
                                        local.get 16
                                        i32.eqz
                                        local.set 78
                                        local.get 78
                                        i32.eqz
                                        br_if 2 (;@16;)
                                        local.get 17
                                        local.set 19
                                        local.get 18
                                        local.set 20
                                      end
                                      loop ;; label = @18
                                        block ;; label = @19
                                          block ;; label = @20
                                            block ;; label = @21
                                              br 0 (;@21;)
                                            end
                                            local.get 53
                                            struct.get 38 0
                                            local.set 88
                                            local.get 88
                                            local.get 19
                                            i32.wrap_i64
                                            i32.const 1
                                            i32.sub
                                            array.get 13
                                            local.set 89
                                            local.get 36
                                            local.get 19
                                            i32.wrap_i64
                                            i32.const 1
                                            i32.sub
                                            array.get 13
                                            any.convert_extern
                                            ref.cast (ref null 13)
                                            local.set 90
                                            local.get 89
                                            local.get 90
                                            local.set 124
                                            any.convert_extern
                                            ref.cast eqref
                                            local.get 124
                                            ref.eq
                                            local.set 91
                                            local.get 91
                                            i32.eqz
                                            br_if 3 (;@17;)
                                            local.get 20
                                            local.get 15
                                            i64.eq
                                            local.set 92
                                            local.get 92
                                            i32.eqz
                                            br_if 0 (;@20;)
                                            i32.const 1
                                            local.set 23
                                            br 1 (;@19;)
                                          end
                                          local.get 20
                                          i64.const 1
                                          i64.add
                                          local.set 93
                                          local.get 93
                                          local.set 21
                                          local.get 93
                                          local.set 22
                                          i32.const 0
                                          local.set 23
                                          br 0 (;@19;)
                                        end
                                        local.get 23
                                        i32.eqz
                                        local.set 94
                                        local.get 94
                                        i32.eqz
                                        br_if 2 (;@16;)
                                        local.get 21
                                        local.set 19
                                        local.get 22
                                        local.set 20
                                        br 0 (;@18;)
                                      end
                                    end
                                    i32.const 0
                                    local.set 24
                                    br 1 (;@15;)
                                  end
                                  i32.const 1
                                  local.set 24
                                  br 0 (;@15;)
                                end
                                local.get 24
                                i32.eqz
                                br_if 0 (;@14;)
                                local.get 0
                                extern.convert_any
                                return
                              end
                              i64.const 1
                              local.get 39
                              i64.le_s
                              local.set 95
                              local.get 95
                              i32.eqz
                              br_if 0 (;@13;)
                              local.get 39
                              local.set 25
                              br 1 (;@12;)
                            end
                            i64.const 0
                            local.set 25
                            br 0 (;@12;)
                          end
                          local.get 25
                          i64.const 1
                          i64.lt_s
                          local.set 96
                          local.get 96
                          i32.eqz
                          br_if 0 (;@11;)
                          i32.const 1
                          local.set 26
                          br 1 (;@10;)
                        end
                        i32.const 0
                        local.set 26
                        i64.const 1
                        local.set 27
                        i64.const 1
                        local.set 28
                        br 0 (;@10;)
                      end
                      local.get 26
                      i32.eqz
                      local.set 97
                      local.get 97
                      i32.eqz
                      br_if 2 (;@7;)
                      local.get 27
                      local.set 29
                      local.get 28
                      local.set 30
                    end
                    loop ;; label = @9
                      block ;; label = @10
                        block ;; label = @11
                          block ;; label = @12
                            br 0 (;@12;)
                          end
                          local.get 53
                          struct.get 38 0
                          local.set 107
                          local.get 107
                          local.get 29
                          i32.wrap_i64
                          i32.const 1
                          i32.sub
                          array.get 13
                          local.set 108
                          local.get 37
                          local.get 29
                          i32.wrap_i64
                          i32.const 1
                          i32.sub
                          array.get 13
                          any.convert_extern
                          ref.cast (ref null 13)
                          local.set 109
                          local.get 108
                          local.get 109
                          local.set 125
                          any.convert_extern
                          ref.cast eqref
                          local.get 125
                          ref.eq
                          local.set 110
                          local.get 110
                          i32.eqz
                          br_if 3 (;@8;)
                          local.get 30
                          local.get 25
                          i64.eq
                          local.set 111
                          local.get 111
                          i32.eqz
                          br_if 0 (;@11;)
                          i32.const 1
                          local.set 33
                          br 1 (;@10;)
                        end
                        local.get 30
                        i64.const 1
                        i64.add
                        local.set 112
                        local.get 112
                        local.set 31
                        local.get 112
                        local.set 32
                        i32.const 0
                        local.set 33
                        br 0 (;@10;)
                      end
                      local.get 33
                      i32.eqz
                      local.set 113
                      local.get 113
                      i32.eqz
                      br_if 2 (;@7;)
                      local.get 31
                      local.set 29
                      local.get 32
                      local.set 30
                      br 0 (;@9;)
                    end
                  end
                  i32.const 0
                  local.set 34
                  br 1 (;@6;)
                end
                i32.const 1
                local.set 34
                br 0 (;@6;)
              end
              local.get 34
              i32.eqz
              br_if 0 (;@5;)
              local.get 1
              extern.convert_any
              return
            end
            ref.null 16
            struct.new 39
            struct.get 39 0
            local.set 114
            unreachable
            unreachable
            local.get 116
            return
          end
          local.get 3
          i32.eqz
          br_if 0 (;@3;)
          local.get 4
          i32.eqz
          local.set 117
          local.get 117
          i32.eqz
          br_if 0 (;@3;)
          local.get 0
          local.get 36
          local.get 38
          local.get 1
          local.get 37
          local.get 39
          local.get 2
          unreachable
          local.get 118
          return
        end
        local.get 4
        i32.eqz
        br_if 0 (;@2;)
        local.get 3
        i32.eqz
        local.set 119
        local.get 119
        i32.eqz
        br_if 0 (;@2;)
        local.get 1
        local.get 37
        local.get 39
        local.get 0
        local.get 36
        local.get 38
        local.get 2
        unreachable
        local.get 120
        return
      end
      local.get 3
      i32.eqz
      br_if 0 (;@1;)
      local.get 4
      i32.eqz
      br_if 0 (;@1;)
      local.get 0
      local.get 36
      local.get 38
      local.get 1
      local.get 37
      local.get 39
      local.get 2
      unreachable
      local.get 121
      return
    end
    global.get 0
    extern.convert_any
    return
    unreachable
  )
  (func (;27;) (type 37) (param (ref null 16) (ref null 16) i64) (result externref)
    (local i64 i32 i64 i64 i64 i64 i64 i64 i32 (ref null 13) (ref null 13) i64 i64 i32 i32 i32 (ref null 13) (ref null 13) (ref null 2) (ref null 38) i32 i32 i32 (ref null 13) (ref null 13) externref i32 i32 i64 i64 (ref null 2) i32 i64 i64 i32 (ref null 2) (ref null 13) externref i32 i64 i32 externref (ref null 15) externref (ref null 13) (ref null 12) i32)
    block (result externref) ;; label = @1
      block ;; label = @2
        try_table (catch_all 0 (;@2;)) ;; label = @3
          local.get 0
          struct.get 16 2
          local.set 12
          local.get 1
          struct.get 16 2
          local.set 13
          local.get 12
          local.get 12
          array.len
          i64.extend_i32_u
          local.set 14
          local.get 13
          local.get 13
          array.len
          i64.extend_i32_u
          local.set 15
          local.get 14
          local.get 15
          i64.eq
          local.set 16
          local.get 16
          i32.eqz
          local.set 17
          global.get 0
          extern.convert_any
          return
          local.get 14
          i64.const 0
          i64.eq
          local.set 18
          local.get 0
          extern.convert_any
          return
          local.get 14
          i32.wrap_i64
          local.tee 49
          i32.const 16
          local.get 49
          i32.const 16
          i32.ge_s
          select
          array.new_default 13
          ref.cast (ref null 13)
          local.set 19
          local.get 19
          ref.cast (ref null 13)
          local.set 20
          local.get 14
          struct.new 2
          ref.cast (ref null 2)
          local.set 21
          local.get 20
          local.get 21
          struct.new 38
          ref.cast (ref null 38)
          local.set 22
          i64.const 1
          local.get 14
          i64.le_s
          local.set 23
          local.get 3
          i64.const 1
          i64.lt_s
          local.set 24
          local.get 4
          i32.eqz
          local.set 25
          local.get 12
          local.get 7
          i32.wrap_i64
          i32.const 1
          i32.sub
          array.get 13
          any.convert_extern
          ref.cast (ref null 13)
          local.set 26
          local.get 13
          local.get 7
          i32.wrap_i64
          i32.const 1
          i32.sub
          array.get 13
          any.convert_extern
          ref.cast (ref null 13)
          local.set 27
          local.get 26
          extern.convert_any
          local.get 27
          extern.convert_any
          call 28
          local.set 28
          local.get 28
          ref.is_null
          local.set 29
          global.get 0
          extern.convert_any
          return
          i32.const 0
          local.set 30
          local.get 7
          i64.const 1
          i64.sub
          local.set 31
          local.get 31
          local.set 32
          local.get 22
          struct.get 38 1
          local.set 33
          i32.const 0
          local.set 34
          local.get 33
          struct.get 2 0
          local.set 35
          local.get 35
          local.set 36
          local.get 32
          local.get 36
          i64.lt_u
          local.set 37
          local.get 7
          struct.new 2
          ref.cast (ref null 2)
          local.set 38
          throw 0
          return
          local.get 22
          struct.get 38 0
          local.set 39
          local.get 39
          local.get 7
          i32.wrap_i64
          i32.const 1
          i32.sub
          local.get 28
          array.set 13
          local.get 28
          local.set 40
          local.get 8
          local.get 3
          i64.eq
          local.set 41
          local.get 8
          i64.const 1
          i64.add
          local.set 42
          local.get 11
          i32.eqz
          local.set 43
          local.get 0
          struct.get 16 0
          local.set 45
          local.get 45
          struct.get 15 6
          local.set 46
          unreachable
          unreachable
          local.get 48
          extern.convert_any
          return
          br 1 (;@2;)
          br 1 (;@2;)
        end
      end
      global.get 0
      extern.convert_any
      return
    end
  )
  (func (;28;) (type 35) (param externref externref) (result externref)
    (local i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32 i32 i32 i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32 i32 i32 i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32 i32 i32 i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32 eqref eqref eqref eqref eqref eqref eqref eqref eqref eqref eqref eqref eqref)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  block ;; label = @8
                    block ;; label = @9
                      block ;; label = @10
                        block ;; label = @11
                          block ;; label = @12
                            block ;; label = @13
                              block ;; label = @14
                                block ;; label = @15
                                  block ;; label = @16
                                    block ;; label = @17
                                      block ;; label = @18
                                        block ;; label = @19
                                          block ;; label = @20
                                            local.get 0
                                            local.get 1
                                            any.convert_extern
                                            ref.cast eqref
                                            local.set 41
                                            any.convert_extern
                                            ref.cast eqref
                                            local.get 41
                                            ref.eq
                                            local.set 6
                                            local.get 6
                                            i32.eqz
                                            br_if 0 (;@20;)
                                            local.get 0
                                            return
                                          end
                                          local.get 0
                                          call 22
                                          local.set 7
                                          local.get 7
                                          i32.eqz
                                          br_if 9 (;@10;)
                                          local.get 1
                                          call 22
                                          local.set 8
                                          local.get 8
                                          i32.eqz
                                          br_if 9 (;@10;)
                                          local.get 0
                                          local.get 1
                                          any.convert_extern
                                          ref.cast eqref
                                          local.set 42
                                          any.convert_extern
                                          ref.cast eqref
                                          local.get 42
                                          ref.eq
                                          local.set 9
                                          local.get 9
                                          i32.eqz
                                          br_if 0 (;@19;)
                                          i32.const 1
                                          local.set 2
                                          br 3 (;@16;)
                                        end
                                        local.get 0
                                        global.get 0
                                        local.set 43
                                        any.convert_extern
                                        ref.cast eqref
                                        local.get 43
                                        ref.eq
                                        local.set 10
                                        local.get 10
                                        i32.eqz
                                        br_if 0 (;@18;)
                                        i32.const 1
                                        local.set 2
                                        br 2 (;@16;)
                                      end
                                      local.get 1
                                      global.get 1
                                      local.set 44
                                      any.convert_extern
                                      ref.cast eqref
                                      local.get 44
                                      ref.eq
                                      local.set 11
                                      local.get 11
                                      i32.eqz
                                      br_if 0 (;@17;)
                                      i32.const 1
                                      local.set 2
                                      br 1 (;@16;)
                                    end
                                    i32.const 16
                                    array.new_default 8
                                    ref.cast (ref null 8)
                                    local.set 12
                                    local.get 12
                                    ref.cast (ref null 8)
                                    local.set 13
                                    local.get 13
                                    i64.const 0
                                    struct.new 2
                                    struct.new 9
                                    ref.cast (ref null 9)
                                    local.set 14
                                    local.get 14
                                    i64.const 0
                                    struct.new 10
                                    ref.cast (ref null 10)
                                    local.set 15
                                    local.get 0
                                    local.get 1
                                    local.get 15
                                    i64.const 0
                                    call 2
                                    local.set 16
                                    local.get 16
                                    local.set 2
                                    br 0 (;@16;)
                                  end
                                  local.get 2
                                  i32.eqz
                                  br_if 4 (;@11;)
                                  local.get 1
                                  local.get 0
                                  any.convert_extern
                                  ref.cast eqref
                                  local.set 45
                                  any.convert_extern
                                  ref.cast eqref
                                  local.get 45
                                  ref.eq
                                  local.set 17
                                  local.get 17
                                  i32.eqz
                                  br_if 0 (;@15;)
                                  i32.const 1
                                  local.set 3
                                  br 3 (;@12;)
                                end
                                local.get 1
                                global.get 0
                                local.set 46
                                any.convert_extern
                                ref.cast eqref
                                local.get 46
                                ref.eq
                                local.set 18
                                local.get 18
                                i32.eqz
                                br_if 0 (;@14;)
                                i32.const 1
                                local.set 3
                                br 2 (;@12;)
                              end
                              local.get 0
                              global.get 1
                              local.set 47
                              any.convert_extern
                              ref.cast eqref
                              local.get 47
                              ref.eq
                              local.set 19
                              local.get 19
                              i32.eqz
                              br_if 0 (;@13;)
                              i32.const 1
                              local.set 3
                              br 1 (;@12;)
                            end
                            i32.const 16
                            array.new_default 8
                            ref.cast (ref null 8)
                            local.set 20
                            local.get 20
                            ref.cast (ref null 8)
                            local.set 21
                            local.get 21
                            i64.const 0
                            struct.new 2
                            struct.new 9
                            ref.cast (ref null 9)
                            local.set 22
                            local.get 22
                            i64.const 0
                            struct.new 10
                            ref.cast (ref null 10)
                            local.set 23
                            local.get 1
                            local.get 0
                            local.get 23
                            i64.const 0
                            call 2
                            local.set 24
                            local.get 24
                            local.set 3
                            br 0 (;@12;)
                          end
                          local.get 3
                          i32.eqz
                          br_if 0 (;@11;)
                          local.get 1
                          return
                        end
                        ref.null extern
                        return
                      end
                      local.get 0
                      local.get 1
                      any.convert_extern
                      ref.cast eqref
                      local.set 48
                      any.convert_extern
                      ref.cast eqref
                      local.get 48
                      ref.eq
                      local.set 25
                      local.get 25
                      i32.eqz
                      br_if 0 (;@9;)
                      i32.const 1
                      local.set 4
                      br 3 (;@6;)
                    end
                    local.get 0
                    global.get 0
                    local.set 49
                    any.convert_extern
                    ref.cast eqref
                    local.get 49
                    ref.eq
                    local.set 26
                    local.get 26
                    i32.eqz
                    br_if 0 (;@8;)
                    i32.const 1
                    local.set 4
                    br 2 (;@6;)
                  end
                  local.get 1
                  global.get 1
                  local.set 50
                  any.convert_extern
                  ref.cast eqref
                  local.get 50
                  ref.eq
                  local.set 27
                  local.get 27
                  i32.eqz
                  br_if 0 (;@7;)
                  i32.const 1
                  local.set 4
                  br 1 (;@6;)
                end
                i32.const 16
                array.new_default 8
                ref.cast (ref null 8)
                local.set 28
                local.get 28
                ref.cast (ref null 8)
                local.set 29
                local.get 29
                i64.const 0
                struct.new 2
                struct.new 9
                ref.cast (ref null 9)
                local.set 30
                local.get 30
                i64.const 0
                struct.new 10
                ref.cast (ref null 10)
                local.set 31
                local.get 0
                local.get 1
                local.get 31
                i64.const 0
                call 2
                local.set 32
                local.get 32
                local.set 4
                br 0 (;@6;)
              end
              local.get 4
              i32.eqz
              br_if 4 (;@1;)
              local.get 1
              local.get 0
              any.convert_extern
              ref.cast eqref
              local.set 51
              any.convert_extern
              ref.cast eqref
              local.get 51
              ref.eq
              local.set 33
              local.get 33
              i32.eqz
              br_if 0 (;@5;)
              i32.const 1
              local.set 5
              br 3 (;@2;)
            end
            local.get 1
            global.get 0
            local.set 52
            any.convert_extern
            ref.cast eqref
            local.get 52
            ref.eq
            local.set 34
            local.get 34
            i32.eqz
            br_if 0 (;@4;)
            i32.const 1
            local.set 5
            br 2 (;@2;)
          end
          local.get 0
          global.get 1
          local.set 53
          any.convert_extern
          ref.cast eqref
          local.get 53
          ref.eq
          local.set 35
          local.get 35
          i32.eqz
          br_if 0 (;@3;)
          i32.const 1
          local.set 5
          br 1 (;@2;)
        end
        i32.const 16
        array.new_default 8
        ref.cast (ref null 8)
        local.set 36
        local.get 36
        ref.cast (ref null 8)
        local.set 37
        local.get 37
        i64.const 0
        struct.new 2
        struct.new 9
        ref.cast (ref null 9)
        local.set 38
        local.get 38
        i64.const 0
        struct.new 10
        ref.cast (ref null 10)
        local.set 39
        local.get 1
        local.get 0
        local.get 39
        i64.const 0
        call 2
        local.set 40
        local.get 40
        local.set 5
        br 0 (;@2;)
      end
      local.get 5
      i32.eqz
      br_if 0 (;@1;)
      local.get 1
      return
    end
    ref.null extern
    return
    unreachable
  )
  (func (;29;) (type 37) (param (ref null 16) (ref null 16) i64) (result externref)
    (local i32 i32 i32 i32 i32 i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32 i32 i32 i32 i32 (ref null 8) (ref null 8) (ref null 9) (ref null 10) i32 i32 i32 i32 i32 i32 i32 i32 i32)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          block ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  block ;; label = @8
                    block ;; label = @9
                      block ;; label = @10
                        block ;; label = @11
                          block ;; label = @12
                            block ;; label = @13
                              block ;; label = @14
                                block ;; label = @15
                                  block ;; label = @16
                                    block ;; label = @17
                                      local.get 0
                                      local.get 1
                                      ref.eq
                                      local.set 7
                                      local.get 7
                                      i32.eqz
                                      br_if 0 (;@17;)
                                      i32.const 1
                                      local.set 4
                                      br 5 (;@12;)
                                    end
                                    local.get 1
                                    global.get 1
                                    ref.eq
                                    local.set 8
                                    local.get 8
                                    i32.eqz
                                    br_if 0 (;@16;)
                                    i32.const 1
                                    local.set 4
                                    br 4 (;@12;)
                                  end
                                  i32.const 16
                                  array.new_default 8
                                  ref.cast (ref null 8)
                                  local.set 9
                                  local.get 9
                                  ref.cast (ref null 8)
                                  local.set 10
                                  local.get 10
                                  i64.const 0
                                  struct.new 2
                                  struct.new 9
                                  ref.cast (ref null 9)
                                  local.set 11
                                  local.get 11
                                  i64.const 0
                                  struct.new 10
                                  ref.cast (ref null 10)
                                  local.set 12
                                  local.get 0
                                  local.get 1
                                  ref.eq
                                  local.set 13
                                  local.get 13
                                  i32.eqz
                                  br_if 0 (;@15;)
                                  i32.const 1
                                  local.set 3
                                  br 2 (;@13;)
                                end
                                local.get 1
                                global.get 1
                                ref.eq
                                local.set 14
                                local.get 14
                                i32.eqz
                                br_if 0 (;@14;)
                                i32.const 1
                                local.set 3
                                br 1 (;@13;)
                              end
                              local.get 0
                              local.get 1
                              local.get 12
                              i64.const 0
                              call 14
                              local.set 15
                              local.get 15
                              local.set 3
                              br 0 (;@13;)
                            end
                            local.get 3
                            local.set 4
                            br 0 (;@12;)
                          end
                          local.get 4
                          i32.eqz
                          br_if 0 (;@11;)
                          local.get 0
                          extern.convert_any
                          return
                        end
                        local.get 1
                        local.get 0
                        ref.eq
                        local.set 16
                        local.get 16
                        i32.eqz
                        br_if 0 (;@10;)
                        i32.const 1
                        local.set 6
                        br 5 (;@5;)
                      end
                      local.get 0
                      global.get 1
                      ref.eq
                      local.set 17
                      local.get 17
                      i32.eqz
                      br_if 0 (;@9;)
                      i32.const 1
                      local.set 6
                      br 4 (;@5;)
                    end
                    i32.const 16
                    array.new_default 8
                    ref.cast (ref null 8)
                    local.set 18
                    local.get 18
                    ref.cast (ref null 8)
                    local.set 19
                    local.get 19
                    i64.const 0
                    struct.new 2
                    struct.new 9
                    ref.cast (ref null 9)
                    local.set 20
                    local.get 20
                    i64.const 0
                    struct.new 10
                    ref.cast (ref null 10)
                    local.set 21
                    local.get 1
                    local.get 0
                    ref.eq
                    local.set 22
                    local.get 22
                    i32.eqz
                    br_if 0 (;@8;)
                    i32.const 1
                    local.set 5
                    br 2 (;@6;)
                  end
                  local.get 0
                  global.get 1
                  ref.eq
                  local.set 23
                  local.get 23
                  i32.eqz
                  br_if 0 (;@7;)
                  i32.const 1
                  local.set 5
                  br 1 (;@6;)
                end
                local.get 1
                local.get 0
                local.get 21
                i64.const 0
                call 14
                local.set 24
                local.get 24
                local.set 5
                br 0 (;@6;)
              end
              local.get 5
              local.set 6
              br 0 (;@5;)
            end
            local.get 6
            i32.eqz
            br_if 0 (;@4;)
            local.get 1
            extern.convert_any
            return
          end
          local.get 0
          struct.get 16 7
          local.set 25
          local.get 25
          i32.const 2
          i32.and
          local.set 26
          local.get 26
          i32.const 2
          i32.eq
          local.set 27
          local.get 27
          i32.eqz
          br_if 0 (;@3;)
          br 2 (;@1;)
        end
        local.get 1
        struct.get 16 7
        local.set 28
        local.get 28
        i32.const 2
        i32.and
        local.set 29
        local.get 29
        i32.const 2
        i32.eq
        local.set 30
        local.get 30
        i32.eqz
        br_if 0 (;@2;)
        br 1 (;@1;)
      end
      global.get 0
      extern.convert_any
      return
    end
    global.get 0
    extern.convert_any
    return
    unreachable
  )
  (func (;30;) (type 42) (param externref) (result (ref null 41))
    (local (ref null 41))
    i64.const -1
    local.get 0
    unreachable
    local.get 1
    return
  )
  (func (;31;) (type 43) (result i32)
    i32.const 1
    return
  )
  (func (;32;) (type 43) (result i32)
    (local externref i32 i32 i32 eqref)
    global.get 7
    extern.convert_any
    global.get 15
    extern.convert_any
    call 21
    local.set 0
    local.get 0
    global.get 7
    local.set 4
    any.convert_extern
    ref.cast eqref
    local.get 4
    ref.eq
    local.set 1
    local.get 1
    local.set 2
    local.get 2
    i32.const 1
    i32.and
    local.set 3
    local.get 3
    return
  )
  (func (;33;) (type 43) (result i32)
    (local externref i32 i32 i32 eqref)
    global.get 7
    extern.convert_any
    global.get 15
    extern.convert_any
    call 21
    local.set 0
    local.get 0
    global.get 7
    local.set 4
    any.convert_extern
    ref.cast eqref
    local.get 4
    ref.eq
    local.set 1
    local.get 1
    local.set 2
    local.get 2
    i32.const 1
    i32.and
    local.set 3
    local.get 3
    return
  )
  (func (;34;) (type 27)
    global.get 13
    global.get 14
    struct.set 16 0
    global.get 13
    global.get 15
    struct.set 16 1
    global.get 13
    i32.const 0
    array.new_default 13
    struct.set 16 2
    global.get 3
    global.get 4
    struct.set 16 0
    global.get 3
    global.get 5
    struct.set 16 1
    global.get 3
    i32.const 0
    array.new_default 13
    struct.set 16 2
    global.get 15
    global.get 16
    struct.set 16 0
    global.get 15
    global.get 1
    struct.set 16 1
    global.get 15
    i32.const 0
    array.new_default 13
    struct.set 16 2
    global.get 7
    global.get 8
    struct.set 16 0
    global.get 7
    global.get 9
    struct.set 16 1
    global.get 7
    i32.const 0
    array.new_default 13
    struct.set 16 2
    global.get 11
    global.get 12
    struct.set 16 0
    global.get 11
    global.get 13
    struct.set 16 1
    global.get 11
    i32.const 0
    array.new_default 13
    struct.set 16 2
    global.get 5
    global.get 6
    struct.set 16 0
    global.get 5
    global.get 1
    struct.set 16 1
    global.get 5
    ref.null extern
    array.new_fixed 13 1
    struct.set 16 2
    global.get 9
    global.get 10
    struct.set 16 0
    global.get 9
    global.get 11
    struct.set 16 1
    global.get 9
    i32.const 0
    array.new_default 13
    struct.set 16 2
    global.get 1
    global.get 2
    struct.set 16 0
    global.get 1
    global.get 1
    struct.set 16 1
    global.get 1
    i32.const 0
    array.new_default 13
    struct.set 16 2
    global.get 4
    global.get 3
    extern.convert_any
    struct.set 15 6
    global.get 12
    global.get 11
    extern.convert_any
    struct.set 15 6
    global.get 2
    global.get 1
    extern.convert_any
    struct.set 15 6
    global.get 14
    global.get 13
    extern.convert_any
    struct.set 15 6
    global.get 8
    global.get 7
    extern.convert_any
    struct.set 15 6
    global.get 16
    global.get 15
    extern.convert_any
    struct.set 15 6
    global.get 10
    global.get 9
    extern.convert_any
    struct.set 15 6
  )
)
