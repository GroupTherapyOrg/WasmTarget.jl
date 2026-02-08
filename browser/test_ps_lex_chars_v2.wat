(module
  (type (;0;) (func (param f64 f64) (result f64)))
  (type (;1;) (array (mut i32)))
  (type (;2;) (struct (field i64)))
  (type (;3;) (struct (field (mut (ref null 1))) (field (mut (ref null 2)))))
  (type (;4;) (struct (field (mut i32)) (field (mut i32)) (field (mut i32)) (field (mut structref)) (field (mut structref))))
  (type (;5;) (struct (field (mut (ref null 1))) (field (mut i32)) (field (mut i32)) (field (mut i32)) (field (mut i32)) (field (mut i32)) (field (mut i64)) (field (mut i64)) (field (mut i64)) (field (mut i64)) (field (mut i64))))
  (type (;6;) (struct (field (mut i32)) (field (mut i32)) (field (mut i32)) (field (mut i64))))
  (type (;7;) (array (mut (ref null 6))))
  (type (;8;) (struct (field (mut (ref null 7))) (field (mut (ref null 2)))))
  (type (;9;) (struct (field i32) (field i32) (field i32) (field i32)))
  (type (;10;) (struct (field i64) (field i64) (field i64) (field i64)))
  (type (;11;) (struct (field (mut (ref null 5))) (field (mut i64)) (field (mut i32)) (field (mut (ref null 8))) (field (mut (ref null 9))) (field (mut (ref null 10)))))
  (type (;12;) (struct (field (mut i32)) (field (mut i32))))
  (type (;13;) (struct (field (mut (ref null 12))) (field (mut i32)) (field (mut i32)) (field (mut i32))))
  (type (;14;) (array (mut (ref null 13))))
  (type (;15;) (struct (field (mut (ref null 14))) (field (mut (ref null 2)))))
  (type (;16;) (array (mut (ref null 12))))
  (type (;17;) (struct (field (mut (ref null 16))) (field (mut (ref null 2)))))
  (type (;18;) (array (mut (ref null 17))))
  (type (;19;) (struct (field (mut (ref null 18))) (field (mut (ref null 2)))))
  (type (;20;) (struct (field (mut (ref null 12))) (field (mut i32)) (field (mut i32))))
  (type (;21;) (array (mut (ref null 20))))
  (type (;22;) (struct (field (mut (ref null 21))) (field (mut (ref null 2)))))
  (type (;23;) (struct (field (mut i64)) (field (mut i64)) (field (mut (ref null 1))) (field (mut (ref null 1)))))
  (type (;24;) (array (mut (ref null 23))))
  (type (;25;) (struct (field (mut (ref null 24))) (field (mut (ref null 2)))))
  (type (;26;) (struct (field i64) (field i64)))
  (type (;27;) (struct (field (mut (ref null 3))) (field (mut externref)) (field (mut (ref null 11))) (field (mut (ref null 15))) (field (mut i64)) (field (mut (ref null 19))) (field (mut (ref null 22))) (field (mut i64)) (field (mut (ref null 25))) (field (mut i64)) (field (mut (ref null 26)))))
  (type (;28;) (struct))
  (type (;29;) (func (param (ref null 1)) (result i32)))
  (type (;30;) (struct (field (mut arrayref))))
  (type (;31;) (struct (field (mut i64)) (field (mut i64))))
  (type (;32;) (func))
  (type (;33;) (func (param (ref null 3) (ref null 1) i64 (ref null 4)) (result (ref null 27))))
  (type (;34;) (struct (field (mut externref)) (field (mut i64)) (field (mut i64)) (field (mut structref)) (field (mut i64))))
  (type (;35;) (array (mut externref)))
  (type (;36;) (struct (field (mut (ref null 35))) (field (mut (ref null 2)))))
  (type (;37;) (struct (field (mut structref)) (field (mut externref)) (field (mut (ref null 34))) (field (mut (ref null 36))) (field (mut i32))))
  (type (;38;) (struct (field (mut (ref null 28))) (field (mut (ref null 1))) (field (mut (ref null 37)))))
  (type (;39;) (func (param (ref null 5)) (result (ref null 11))))
  (import "Math" "pow" (func (;0;) (type 0)))
  (tag (;0;) (type 32))
  (export "ps_lex_chars_v2" (func 1))
  (export "ParseStream" (func 2))
  (export "Lexer" (func 3))
  (func (;1;) (type 29) (param (ref null 1)) (result i32)
    (local i32 (ref null 1) (ref null 1) i64 (ref null 2) (ref null 3) (ref null 27) (ref null 11) (ref null 9) i32 i32 i32 i32 i32 i32 i32 i64 i32 i64 i64 i32 i64 i64 i32 i32 i32 i32 i32 i64 i32 i64 i64 i32 i32 i64 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i64 i32 i64 i64 i32 i32 i32 i32 i64 i32 i64 i64 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 i32 (ref null 1) (ref null 1) (ref null 1) i32 i32)
    block ;; label = @1
      block ;; label = @2
        block ;; label = @3
          local.get 0
          ref.cast (ref null 1)
          local.set 2
          local.get 2
          ref.cast (ref null 1)
          local.set 3
          local.get 2
          array.len
          i64.extend_i32_s
          local.set 4
          local.get 4
          struct.new 2
          ref.cast (ref null 2)
          local.set 5
          local.get 3
          local.get 5
          struct.new 3
          ref.cast (ref null 3)
          local.set 6
          local.get 6
          local.get 0
          i64.const 1
          i32.const 1
          i32.const 12
          i32.const 4
          struct.new 28
          struct.new 28
          struct.new 4
          call 2
          ref.cast (ref null 27)
          local.set 7
          local.get 7
          struct.get 27 2
          ref.cast (ref null 11)
          local.set 8
          local.get 8
          struct.get 11 4
          ref.cast (ref null 9)
          local.set 9
          i32.const 0
          local.set 10
          local.get 9
          struct.get 9 1
          local.set 11
          local.get 11
          local.set 12
          local.get 12
          i32.const -2147483648
          i32.lt_u
          local.set 13
          local.get 13
          i32.eqz
          br_if 0 (;@3;)
          local.get 12
          i64.const 24
          i32.wrap_i64
          i32.shr_u
          local.set 14
          local.get 14
          local.set 1
          br 2 (;@1;)
        end
        local.get 12
        i32.const -1
        i32.xor
        local.set 15
        local.get 15
        i32.clz
        local.set 16
        local.get 16
        i64.extend_i32_u
        local.set 17
        local.get 12
        i32.ctz
        local.set 18
        local.get 18
        i64.extend_i32_u
        local.set 19
        local.get 19
        i64.const 56
        i64.and
        local.set 20
        local.get 17
        i64.const 1
        i64.eq
        local.set 21
        i64.const 8
        local.get 17
        i64.mul
        local.set 22
        local.get 22
        local.get 20
        i64.add
        local.set 23
        i64.const 32
        local.get 23
        i64.lt_s
        local.set 24
        local.get 21
        local.get 24
        i32.or
        local.set 25
        local.get 12
        i32.const 12632256
        i32.and
        local.set 26
        local.get 26
        i32.const 8421504
        i32.xor
        local.set 27
        i64.const 0
        local.get 20
        i64.le_s
        local.set 28
        local.get 20
        local.set 29
        local.get 27
        local.get 29
        i32.wrap_i64
        i32.shr_u
        local.set 30
        local.get 20
        i64.const -1
        i64.xor
        i64.const 1
        i64.add
        local.set 31
        local.get 31
        local.set 32
        local.get 27
        local.get 32
        i32.wrap_i64
        i32.shl
        local.set 33
        local.get 30
        local.get 33
        local.get 28
        select
        local.set 34
        local.get 34
        i64.extend_i32_u
        local.set 35
        local.get 35
        i64.const 0
        i64.eq
        local.set 36
        i32.const 1
        local.get 36
        i32.and
        local.set 37
        local.get 37
        i32.eqz
        local.set 38
        local.get 12
        i64.const 24
        i32.wrap_i64
        i32.shr_u
        local.set 39
        local.get 39
        i32.const 192
        i32.eq
        local.set 40
        local.get 12
        i64.const 24
        i32.wrap_i64
        i32.shr_u
        local.set 41
        local.get 41
        i32.const 193
        i32.eq
        local.set 42
        local.get 40
        local.get 42
        i32.or
        local.set 43
        local.get 12
        i64.const 21
        i32.wrap_i64
        i32.shr_u
        local.set 44
        local.get 44
        i32.const 1796
        i32.eq
        local.set 45
        local.get 43
        local.get 45
        i32.or
        local.set 46
        local.get 12
        i64.const 20
        i32.wrap_i64
        i32.shr_u
        local.set 47
        local.get 47
        i32.const 3848
        i32.eq
        local.set 48
        local.get 46
        local.get 48
        i32.or
        local.set 49
        local.get 38
        local.get 49
        i32.or
        local.set 50
        local.get 25
        local.get 50
        i32.or
        local.set 51
        local.get 51
        i32.eqz
        br_if 0 (;@2;)
        local.get 11
        unreachable
        return
      end
      i64.const 0
      local.get 17
      i64.le_s
      local.set 52
      local.get 17
      local.set 53
      i32.const -1
      local.get 53
      i32.wrap_i64
      i32.shr_u
      local.set 54
      local.get 17
      i64.const -1
      i64.xor
      i64.const 1
      i64.add
      local.set 55
      local.get 55
      local.set 56
      i32.const -1
      local.get 56
      i32.wrap_i64
      i32.shl
      local.set 57
      local.get 54
      local.get 57
      local.get 52
      select
      local.set 58
      local.get 12
      local.get 58
      i32.and
      local.set 59
      i64.const 0
      local.get 20
      i64.le_s
      local.set 60
      local.get 20
      local.set 61
      local.get 59
      local.get 61
      i32.wrap_i64
      i32.shr_u
      local.set 62
      local.get 20
      i64.const -1
      i64.xor
      i64.const 1
      i64.add
      local.set 63
      local.get 63
      local.set 64
      local.get 59
      local.get 64
      i32.wrap_i64
      i32.shl
      local.set 65
      local.get 62
      local.get 65
      local.get 60
      select
      local.set 66
      local.get 66
      i32.const 127
      i32.and
      local.set 67
      local.get 67
      i64.const 0
      i32.wrap_i64
      i32.shr_u
      local.set 68
      local.get 66
      i32.const 32512
      i32.and
      local.set 69
      local.get 69
      i64.const 2
      i32.wrap_i64
      i32.shr_u
      local.set 70
      local.get 68
      local.get 70
      i32.or
      local.set 71
      local.get 66
      i32.const 8323072
      i32.and
      local.set 72
      local.get 72
      i64.const 4
      i32.wrap_i64
      i32.shr_u
      local.set 73
      local.get 71
      local.get 73
      i32.or
      local.set 74
      local.get 66
      i32.const 2130706432
      i32.and
      local.set 75
      local.get 75
      i64.const 6
      i32.wrap_i64
      i32.shr_u
      local.set 76
      local.get 74
      local.get 76
      i32.or
      local.set 77
      local.get 77
      local.set 1
      br 0 (;@1;)
    end
    local.get 1
    local.set 78
    local.get 78
    return
    unreachable
  )
  (func (;2;) (type 33) (param (ref null 3) (ref null 1) i64 (ref null 4)) (result (ref null 27))
    (local i64 i64 (ref null 1) (ref null 1) i64 i64 (ref null 2) i32 i64 i32 (ref null 30) i64 (ref null 5) i64 (ref null 2) i32 i64 i64 i64 i64 i32 i32 i64 i32 i64 i32 (ref null 30) (ref null 30) i64 i64 i64 i32 i64 i64 (ref null 31) i64 (ref null 31) (ref null 31) (ref null 31) i32 i32 i64 (ref null 31) i32 i32 i32 i64 (ref null 11) i32 i32 i64 i32 i64 i32 (ref null 20) (ref null 14) (ref null 14) (ref null 15) (ref null 18) (ref null 18) (ref null 19) (ref null 21) (ref null 21) (ref null 22) (ref null 21) (ref null 24) (ref null 24) (ref null 25) i64 i64 (ref null 26) (ref null 27) (ref null 1) (ref null 1) (ref null 1) i32 i32 i64 i64 i64 i64 (ref null 31) (ref null 31) i64 i64 i64 i64 i64 i64 (ref null 31) (ref null 31) i64 i64 i64 i64 i64 i64 i64 i64 i64 i64 (ref null 31) (ref null 31) i64 i64 i64 i64 (ref null 31) (ref null 31) i64 i64 i64 i64 i64 i64 (ref null 31) (ref null 31))
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
                                local.get 0
                                struct.get 3 0
                                ref.cast (ref null 1)
                                local.set 6
                                local.get 6
                                ref.cast (ref null 1)
                                local.set 7
                                i64.const 1
                                local.set 8
                                local.get 8
                                i64.const 1
                                i64.sub
                                local.set 9
                                local.get 0
                                struct.get 3 1
                                ref.cast (ref null 2)
                                local.set 10
                                i32.const 0
                                local.set 11
                                local.get 10
                                struct.get 2 0
                                local.set 12
                                i64.const 9223372036854775807
                                local.get 12
                                i64.lt_s
                                local.set 13
                                local.get 13
                                i32.eqz
                                br_if 0 (;@14;)
                                unreachable
                                local.set 14
                                local.get 14
                                throw 0
                                return
                              end
                              local.get 7
                              array.len
                              i64.extend_i32_s
                              local.set 15
                              local.get 7
                              i32.const 0
                              i32.const 1
                              i32.const 0
                              i32.const 1
                              i32.const 0
                              local.get 15
                              i64.const 9223372036854775807
                              i64.const 1
                              i64.const 0
                              i64.const -1
                              struct.new 5
                              ref.cast (ref null 5)
                              local.set 16
                              local.get 16
                              local.get 9
                              struct.set 5 9
                              local.get 9
                              drop
                              local.get 9
                              i64.const 1
                              i64.add
                              local.set 17
                              local.get 16
                              local.get 17
                              struct.set 5 8
                              local.get 17
                              drop
                              local.get 0
                              struct.get 3 1
                              ref.cast (ref null 2)
                              local.set 18
                              i32.const 0
                              local.set 19
                              local.get 18
                              struct.get 2 0
                              local.set 20
                              local.get 20
                              local.get 9
                              i64.add
                              local.set 21
                              local.get 16
                              local.get 21
                              struct.set 5 6
                              local.get 21
                              local.set 22
                              local.get 2
                              i64.const 1
                              i64.sub
                              local.set 23
                              local.get 16
                              struct.get 5 4
                              local.set 24
                              local.get 24
                              i32.eqz
                              local.set 25
                              local.get 25
                              i32.eqz
                              br_if 2 (;@11;)
                              local.get 16
                              struct.get 5 10
                              local.set 26
                              i64.const 0
                              local.get 26
                              i64.le_s
                              local.set 27
                              local.get 27
                              i32.eqz
                              br_if 1 (;@12;)
                              local.get 16
                              struct.get 5 10
                              local.set 28
                              local.get 23
                              local.get 28
                              i64.eq
                              local.set 29
                              local.get 29
                              i32.eqz
                              br_if 0 (;@13;)
                              br 2 (;@11;)
                            end
                            unreachable
                            local.set 30
                            local.get 30
                            throw 0
                            return
                          end
                          unreachable
                          local.set 31
                          local.get 31
                          throw 0
                          return
                        end
                        local.get 16
                        struct.get 5 6
                        local.set 32
                        local.get 32
                        i64.const 1
                        i64.add
                        local.set 33
                        local.get 16
                        struct.get 5 9
                        local.set 34
                        local.get 34
                        i64.const 0
                        i64.lt_s
                        local.set 35
                        i64.const 0
                        local.get 34
                        local.get 35
                        select
                        local.set 36
                        local.get 36
                        i64.const 1
                        i64.add
                        local.set 37
                        local.get 23
                        local.tee 81
                        i64.const 63
                        i64.shr_s
                        local.get 81
                        local.set 82
                        local.get 81
                        local.get 82
                        struct.new 31
                        ref.cast (ref null 31)
                        local.set 38
                        local.get 16
                        struct.get 5 9
                        local.set 39
                        local.get 39
                        local.tee 83
                        i64.const 63
                        i64.shr_s
                        local.get 83
                        local.set 84
                        local.get 83
                        local.get 84
                        struct.new 31
                        ref.cast (ref null 31)
                        local.set 40
                        local.get 38
                        local.get 40
                        local.set 85
                        local.set 86
                        local.get 86
                        struct.get 31 0
                        local.set 87
                        local.get 86
                        struct.get 31 1
                        local.set 88
                        local.get 85
                        struct.get 31 0
                        local.set 89
                        local.get 85
                        struct.get 31 1
                        local.set 90
                        local.get 87
                        local.get 89
                        i64.add
                        local.tee 91
                        local.get 87
                        i64.lt_u
                        i64.extend_i32_u
                        local.get 88
                        i64.add
                        local.get 90
                        i64.add
                        local.get 91
                        local.set 92
                        local.get 91
                        local.get 92
                        struct.new 31
                        ref.cast (ref null 31)
                        local.set 41
                        local.get 41
                        i64.const 1
                        i64.const 0
                        struct.new 31
                        local.set 93
                        local.set 94
                        local.get 94
                        struct.get 31 0
                        local.set 95
                        local.get 94
                        struct.get 31 1
                        local.set 96
                        local.get 93
                        struct.get 31 0
                        local.set 97
                        local.get 93
                        struct.get 31 1
                        local.set 98
                        local.get 95
                        local.get 97
                        i64.add
                        local.tee 99
                        local.get 95
                        i64.lt_u
                        i64.extend_i32_u
                        local.get 96
                        i64.add
                        local.get 98
                        i64.add
                        local.get 99
                        local.set 100
                        local.get 99
                        local.get 100
                        struct.new 31
                        ref.cast (ref null 31)
                        local.set 42
                        i64.const 9223372036854775807
                        i64.const 0
                        struct.new 31
                        local.get 42
                        local.set 105
                        local.set 106
                        local.get 106
                        struct.get 31 0
                        local.set 101
                        local.get 106
                        struct.get 31 1
                        local.set 102
                        local.get 105
                        struct.get 31 0
                        local.set 103
                        local.get 105
                        struct.get 31 1
                        local.set 104
                        local.get 102
                        local.get 104
                        i64.lt_s
                        local.get 102
                        local.get 104
                        i64.eq
                        local.get 101
                        local.get 103
                        i64.lt_u
                        i32.and
                        i32.or
                        local.set 43
                        local.get 43
                        i32.eqz
                        br_if 0 (;@10;)
                        i64.const 9223372036854775807
                        local.set 4
                        br 4 (;@6;)
                      end
                      local.get 42
                      i64.const -9223372036854775808
                      i64.const -1
                      struct.new 31
                      local.set 111
                      local.set 112
                      local.get 112
                      struct.get 31 0
                      local.set 107
                      local.get 112
                      struct.get 31 1
                      local.set 108
                      local.get 111
                      struct.get 31 0
                      local.set 109
                      local.get 111
                      struct.get 31 1
                      local.set 110
                      local.get 108
                      local.get 110
                      i64.lt_s
                      local.get 108
                      local.get 110
                      i64.eq
                      local.get 107
                      local.get 109
                      i64.lt_u
                      i32.and
                      i32.or
                      local.set 44
                      local.get 44
                      i32.eqz
                      br_if 0 (;@9;)
                      i64.const -9223372036854775808
                      local.set 4
                      br 3 (;@6;)
                    end
                    local.get 42
                    struct.get 31 0
                    local.set 45
                    local.get 45
                    local.tee 113
                    i64.const 63
                    i64.shr_s
                    local.get 113
                    local.set 114
                    local.get 113
                    local.get 114
                    struct.new 31
                    ref.cast (ref null 31)
                    local.set 46
                    local.get 42
                    local.get 46
                    local.set 119
                    local.set 120
                    local.get 120
                    struct.get 31 0
                    local.set 115
                    local.get 120
                    struct.get 31 1
                    local.set 116
                    local.get 119
                    struct.get 31 0
                    local.set 117
                    local.get 119
                    struct.get 31 1
                    local.set 118
                    local.get 115
                    local.get 117
                    i64.eq
                    local.get 116
                    local.get 118
                    i64.eq
                    i32.and
                    local.set 47
                    local.get 47
                    i32.eqz
                    br_if 0 (;@8;)
                    br 1 (;@7;)
                  end
                  unreachable
                  return
                end
                local.get 45
                local.set 4
                br 0 (;@6;)
              end
              local.get 33
              local.get 4
              i64.lt_s
              local.set 48
              local.get 48
              i32.eqz
              br_if 0 (;@5;)
              local.get 33
              local.set 5
              br 2 (;@3;)
            end
            local.get 4
            local.get 37
            i64.lt_s
            local.set 49
            local.get 49
            i32.eqz
            br_if 0 (;@4;)
            local.get 37
            local.set 5
            br 1 (;@3;)
          end
          local.get 4
          local.set 5
          br 0 (;@3;)
        end
        local.get 16
        local.get 5
        struct.set 5 8
        local.get 5
        local.set 50
        local.get 16
        call 3
        ref.cast (ref null 11)
        local.set 51
        local.get 3
        struct.get 4 0
        local.set 52
        local.get 3
        struct.get 4 1
        local.set 53
        local.get 2
        i64.const 1
        i64.sub
        local.set 54
        local.get 54
        i32.wrap_i64
        local.set 55
        local.get 55
        i64.extend_i32_u
        local.set 56
        local.get 54
        local.get 56
        i64.eq
        local.set 57
        local.get 57
        i32.eqz
        br_if 0 (;@2;)
        br 1 (;@1;)
      end
      unreachable
      return
    end
    ref.null 20
    local.set 58
    i32.const 16
    array.new_default 14
    ref.cast (ref null 14)
    local.set 59
    local.get 59
    ref.cast (ref null 14)
    local.set 60
    local.get 60
    i64.const 0
    struct.new 2
    struct.new 15
    ref.cast (ref null 15)
    local.set 61
    i32.const 16
    array.new_default 18
    ref.cast (ref null 18)
    local.set 62
    local.get 62
    ref.cast (ref null 18)
    local.set 63
    local.get 63
    i64.const 0
    struct.new 2
    struct.new 19
    ref.cast (ref null 19)
    local.set 64
    i32.const 16
    array.new_default 21
    ref.cast (ref null 21)
    local.set 65
    local.get 65
    ref.cast (ref null 21)
    local.set 66
    local.get 66
    i64.const 1
    struct.new 2
    struct.new 22
    ref.cast (ref null 22)
    local.set 67
    local.get 67
    struct.get 22 0
    ref.cast (ref null 21)
    local.set 68
    local.get 68
    i64.const 1
    i32.wrap_i64
    i32.const 1
    i32.sub
    local.get 58
    array.set 21
    local.get 58
    drop
    i32.const 16
    array.new_default 24
    ref.cast (ref null 24)
    local.set 69
    local.get 69
    ref.cast (ref null 24)
    local.set 70
    local.get 70
    i64.const 0
    struct.new 2
    struct.new 25
    ref.cast (ref null 25)
    local.set 71
    local.get 52
    i64.extend_i32_u
    local.set 72
    local.get 53
    i64.extend_i32_u
    local.set 73
    local.get 72
    local.get 73
    struct.new 26
    ref.cast (ref null 26)
    local.set 74
    local.get 0
    local.get 1
    extern.convert_any
    local.get 51
    local.get 61
    i64.const 1
    local.get 64
    local.get 67
    local.get 2
    local.get 71
    i64.const 0
    local.get 74
    struct.new 27
    ref.cast (ref null 27)
    local.set 75
    local.get 75
    return
    unreachable
  )
  (func (;3;) (type 39) (param (ref null 5)) (result (ref null 11))
    (local i64 i32 i32 i64 i32 i32 i64 i32 i32 i64 i32 i64 i32 i64 i32 i64 i64 i64 i64 i64 i64 i64 i32 i32 i64 i64 i32 (ref null 1) (ref null 1) i32 i32 i64 i64 i32 i32 i64 i32 i64 i32 i32 i32 i32 i32 i32 i32 i64 i64 i32 i32 i64 i64 i64 i32 i32 i32 i64 i64 i32 (ref null 1) i64 (ref null 1) i32 i32 i32 i32 i32 i64 i64 i32 (ref null 1) (ref null 1) i32 i32 i64 i64 i32 i32 i64 i32 i64 i64 i32 i32 i32 i64 i32 i64 i64 i64 i64 i64 i64 i64 i32 i32 i64 i64 i32 (ref null 1) (ref null 1) i32 i32 i64 i64 i32 i32 i64 i32 i64 i32 i32 i32 i32 i32 i32 i32 i64 i64 i32 i32 i64 i64 i64 i32 i32 i32 i64 i64 i32 (ref null 1) i64 (ref null 1) i32 i32 i32 i32 i32 i64 i64 i32 (ref null 1) (ref null 1) i32 i32 i64 i64 i32 i32 i64 i32 i64 i64 i32 i32 i32 i64 i32 i64 i64 i64 i64 i64 i64 i64 i32 i32 i64 i64 i32 (ref null 1) (ref null 1) i32 i32 i64 i64 i32 i32 i64 i32 i64 i32 i32 i32 i32 i32 i32 i32 i64 i64 i32 i32 i64 i64 i64 i32 i32 i32 i64 i64 i32 (ref null 1) i64 (ref null 1) i32 i32 i32 i32 i32 i64 i64 i32 (ref null 1) (ref null 1) i32 i32 i64 i64 i32 i32 i64 i32 i64 i64 i32 i32 i32 i64 i32 i64 i64 i64 i64 i64 i64 i64 i64 (ref null 7) (ref null 7) (ref null 8) (ref null 9) (ref null 10) (ref null 11))
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
                                                            local.get 0
                                                            struct.get 5 8
                                                            local.set 16
                                                            local.get 0
                                                            struct.get 5 9
                                                            local.set 17
                                                            local.get 16
                                                            local.get 17
                                                            i64.sub
                                                            local.set 18
                                                            local.get 18
                                                            i64.const 1
                                                            i64.sub
                                                            local.set 19
                                                            local.get 0
                                                            struct.get 5 8
                                                            local.set 20
                                                            local.get 20
                                                            i64.const 1
                                                            i64.sub
                                                            local.set 21
                                                            local.get 0
                                                            struct.get 5 6
                                                            local.set 22
                                                            local.get 22
                                                            local.get 21
                                                            i64.le_s
                                                            local.set 23
                                                            local.get 23
                                                            i32.eqz
                                                            br_if 0 (;@28;)
                                                            local.get 19
                                                            local.set 10
                                                            i32.const 0
                                                            local.set 11
                                                            local.get 19
                                                            local.set 12
                                                            i32.const 0
                                                            local.set 13
                                                            local.get 19
                                                            local.set 14
                                                            i32.const 0
                                                            local.set 15
                                                            br 27 (;@1;)
                                                          end
                                                          local.get 0
                                                          struct.get 5 2
                                                          local.set 24
                                                          local.get 24
                                                          i32.eqz
                                                          br_if 1 (;@26;)
                                                          local.get 0
                                                          struct.get 5 8
                                                          local.set 25
                                                          local.get 0
                                                          struct.get 5 6
                                                          local.set 26
                                                          local.get 26
                                                          local.get 25
                                                          i64.lt_s
                                                          local.set 27
                                                          local.get 27
                                                          i32.eqz
                                                          br_if 0 (;@27;)
                                                          struct.new 28
                                                          throw 0
                                                          return
                                                        end
                                                        local.get 0
                                                        struct.get 5 0
                                                        ref.cast (ref null 1)
                                                        local.set 28
                                                        local.get 28
                                                        ref.cast (ref null 1)
                                                        local.set 29
                                                        i32.const 0
                                                        local.set 30
                                                        local.get 29
                                                        local.get 25
                                                        i32.wrap_i64
                                                        i32.const 1
                                                        i32.sub
                                                        array.get 1
                                                        local.set 31
                                                        local.get 25
                                                        i64.const 1
                                                        i64.add
                                                        local.set 32
                                                        local.get 0
                                                        local.get 32
                                                        struct.set 5 8
                                                        local.get 32
                                                        local.set 33
                                                        br 1 (;@25;)
                                                      end
                                                      unreachable
                                                      return
                                                    end
                                                    local.get 31
                                                    i32.const -1
                                                    i32.xor
                                                    local.set 34
                                                    local.get 34
                                                    i32.clz
                                                    local.set 35
                                                    local.get 35
                                                    i64.extend_i32_u
                                                    local.set 36
                                                    local.get 36
                                                    i32.wrap_i64
                                                    local.set 37
                                                    local.get 37
                                                    i64.extend_i32_u
                                                    local.set 38
                                                    local.get 36
                                                    local.get 38
                                                    i64.eq
                                                    local.set 39
                                                    local.get 39
                                                    i32.eqz
                                                    br_if 0 (;@24;)
                                                    br 1 (;@23;)
                                                  end
                                                  unreachable
                                                  return
                                                end
                                                i32.const 4
                                                local.get 37
                                                i32.sub
                                                local.set 40
                                                i32.const 8
                                                local.get 40
                                                i32.mul
                                                local.set 41
                                                local.get 31
                                                local.set 42
                                                local.get 42
                                                i64.const 24
                                                i32.wrap_i64
                                                i32.shl
                                                local.set 43
                                                local.get 41
                                                i32.const 16
                                                i32.le_u
                                                local.set 44
                                                local.get 44
                                                if ;; label = @23
                                                else
                                                  local.get 43
                                                  local.set 3
                                                  br 3 (;@20;)
                                                end
                                                i64.const 16
                                                local.set 1
                                                local.get 43
                                                local.set 2
                                              end
                                              loop ;; label = @22
                                                block ;; label = @23
                                                  block ;; label = @24
                                                    block ;; label = @25
                                                      block ;; label = @26
                                                        block ;; label = @27
                                                          block ;; label = @28
                                                            i64.const 0
                                                            local.get 1
                                                            i64.le_s
                                                            local.set 45
                                                            local.get 1
                                                            local.set 46
                                                            local.get 41
                                                            i64.extend_i32_u
                                                            local.set 47
                                                            local.get 47
                                                            local.get 46
                                                            i64.le_u
                                                            local.set 48
                                                            local.get 45
                                                            local.get 48
                                                            i32.and
                                                            local.set 49
                                                            local.get 49
                                                            if ;; label = @29
                                                            else
                                                              local.get 2
                                                              local.set 3
                                                              br 9 (;@20;)
                                                            end
                                                            local.get 0
                                                            struct.get 5 8
                                                            local.set 50
                                                            local.get 50
                                                            i64.const 1
                                                            i64.sub
                                                            local.set 51
                                                            local.get 0
                                                            struct.get 5 6
                                                            local.set 52
                                                            local.get 52
                                                            local.get 51
                                                            i64.le_s
                                                            local.set 53
                                                            local.get 53
                                                            i32.eqz
                                                            local.set 54
                                                            local.get 54
                                                            if ;; label = @29
                                                            else
                                                              local.get 2
                                                              local.set 3
                                                              br 9 (;@20;)
                                                            end
                                                            local.get 0
                                                            struct.get 5 2
                                                            local.set 55
                                                            local.get 55
                                                            i32.eqz
                                                            br_if 1 (;@27;)
                                                            local.get 0
                                                            struct.get 5 8
                                                            local.set 56
                                                            local.get 0
                                                            struct.get 5 6
                                                            local.set 57
                                                            local.get 57
                                                            local.get 56
                                                            i64.lt_s
                                                            local.set 58
                                                            local.get 58
                                                            i32.eqz
                                                            br_if 0 (;@28;)
                                                            struct.new 28
                                                            throw 0
                                                            return
                                                          end
                                                          local.get 0
                                                          struct.get 5 0
                                                          ref.cast (ref null 1)
                                                          local.set 59
                                                          local.get 0
                                                          struct.get 5 8
                                                          local.set 60
                                                          local.get 59
                                                          ref.cast (ref null 1)
                                                          local.set 61
                                                          i32.const 0
                                                          local.set 62
                                                          local.get 61
                                                          local.get 60
                                                          i32.wrap_i64
                                                          i32.const 1
                                                          i32.sub
                                                          array.get 1
                                                          local.set 63
                                                          br 1 (;@26;)
                                                        end
                                                        unreachable
                                                        return
                                                      end
                                                      local.get 63
                                                      i32.const 192
                                                      i32.and
                                                      local.set 64
                                                      local.get 64
                                                      i32.const 128
                                                      i32.eq
                                                      local.set 65
                                                      local.get 65
                                                      i32.eqz
                                                      br_if 4 (;@21;)
                                                      local.get 0
                                                      struct.get 5 2
                                                      local.set 66
                                                      local.get 66
                                                      i32.eqz
                                                      br_if 1 (;@24;)
                                                      local.get 0
                                                      struct.get 5 8
                                                      local.set 67
                                                      local.get 0
                                                      struct.get 5 6
                                                      local.set 68
                                                      local.get 68
                                                      local.get 67
                                                      i64.lt_s
                                                      local.set 69
                                                      local.get 69
                                                      i32.eqz
                                                      br_if 0 (;@25;)
                                                      struct.new 28
                                                      throw 0
                                                      return
                                                    end
                                                    local.get 0
                                                    struct.get 5 0
                                                    ref.cast (ref null 1)
                                                    local.set 70
                                                    local.get 70
                                                    ref.cast (ref null 1)
                                                    local.set 71
                                                    i32.const 0
                                                    local.set 72
                                                    local.get 71
                                                    local.get 67
                                                    i32.wrap_i64
                                                    i32.const 1
                                                    i32.sub
                                                    array.get 1
                                                    local.set 73
                                                    local.get 67
                                                    i64.const 1
                                                    i64.add
                                                    local.set 74
                                                    local.get 0
                                                    local.get 74
                                                    struct.set 5 8
                                                    local.get 74
                                                    local.set 75
                                                    br 1 (;@23;)
                                                  end
                                                  unreachable
                                                  return
                                                end
                                                local.get 73
                                                local.set 76
                                                i64.const 0
                                                local.get 1
                                                i64.le_s
                                                local.set 77
                                                local.get 1
                                                local.set 78
                                                local.get 76
                                                local.get 78
                                                i32.wrap_i64
                                                i32.shl
                                                local.set 79
                                                local.get 1
                                                i64.const -1
                                                i64.xor
                                                i64.const 1
                                                i64.add
                                                local.set 80
                                                local.get 80
                                                local.set 81
                                                local.get 76
                                                local.get 81
                                                i32.wrap_i64
                                                i32.shr_u
                                                local.set 82
                                                local.get 79
                                                local.get 82
                                                local.get 77
                                                select
                                                local.set 83
                                                local.get 2
                                                local.get 83
                                                i32.or
                                                local.set 84
                                                local.get 1
                                                i64.const 8
                                                i64.sub
                                                local.set 85
                                                local.get 85
                                                local.set 1
                                                local.get 84
                                                local.set 2
                                                br 0 (;@22;)
                                              end
                                            end
                                            local.get 2
                                            local.set 3
                                          end
                                          local.get 3
                                          local.set 86
                                          local.get 0
                                          struct.get 5 8
                                          local.set 87
                                          local.get 0
                                          struct.get 5 9
                                          local.set 88
                                          local.get 87
                                          local.get 88
                                          i64.sub
                                          local.set 89
                                          local.get 89
                                          i64.const 1
                                          i64.sub
                                          local.set 90
                                          local.get 0
                                          struct.get 5 8
                                          local.set 91
                                          local.get 91
                                          i64.const 1
                                          i64.sub
                                          local.set 92
                                          local.get 0
                                          struct.get 5 6
                                          local.set 93
                                          local.get 93
                                          local.get 92
                                          i64.le_s
                                          local.set 94
                                          local.get 94
                                          i32.eqz
                                          br_if 0 (;@19;)
                                          local.get 90
                                          local.set 10
                                          i32.const 0
                                          local.set 11
                                          local.get 90
                                          local.set 12
                                          i32.const 0
                                          local.set 13
                                          local.get 90
                                          local.set 14
                                          local.get 86
                                          local.set 15
                                          br 18 (;@1;)
                                        end
                                        local.get 0
                                        struct.get 5 2
                                        local.set 95
                                        local.get 95
                                        i32.eqz
                                        br_if 1 (;@17;)
                                        local.get 0
                                        struct.get 5 8
                                        local.set 96
                                        local.get 0
                                        struct.get 5 6
                                        local.set 97
                                        local.get 97
                                        local.get 96
                                        i64.lt_s
                                        local.set 98
                                        local.get 98
                                        i32.eqz
                                        br_if 0 (;@18;)
                                        struct.new 28
                                        throw 0
                                        return
                                      end
                                      local.get 0
                                      struct.get 5 0
                                      ref.cast (ref null 1)
                                      local.set 99
                                      local.get 99
                                      ref.cast (ref null 1)
                                      local.set 100
                                      i32.const 0
                                      local.set 101
                                      local.get 100
                                      local.get 96
                                      i32.wrap_i64
                                      i32.const 1
                                      i32.sub
                                      array.get 1
                                      local.set 102
                                      local.get 96
                                      i64.const 1
                                      i64.add
                                      local.set 103
                                      local.get 0
                                      local.get 103
                                      struct.set 5 8
                                      local.get 103
                                      local.set 104
                                      br 1 (;@16;)
                                    end
                                    unreachable
                                    return
                                  end
                                  local.get 102
                                  i32.const -1
                                  i32.xor
                                  local.set 105
                                  local.get 105
                                  i32.clz
                                  local.set 106
                                  local.get 106
                                  i64.extend_i32_u
                                  local.set 107
                                  local.get 107
                                  i32.wrap_i64
                                  local.set 108
                                  local.get 108
                                  i64.extend_i32_u
                                  local.set 109
                                  local.get 107
                                  local.get 109
                                  i64.eq
                                  local.set 110
                                  local.get 110
                                  i32.eqz
                                  br_if 0 (;@15;)
                                  br 1 (;@14;)
                                end
                                unreachable
                                return
                              end
                              i32.const 4
                              local.get 108
                              i32.sub
                              local.set 111
                              i32.const 8
                              local.get 111
                              i32.mul
                              local.set 112
                              local.get 102
                              local.set 113
                              local.get 113
                              i64.const 24
                              i32.wrap_i64
                              i32.shl
                              local.set 114
                              local.get 112
                              i32.const 16
                              i32.le_u
                              local.set 115
                              local.get 115
                              if ;; label = @14
                              else
                                local.get 114
                                local.set 6
                                br 3 (;@11;)
                              end
                              i64.const 16
                              local.set 4
                              local.get 114
                              local.set 5
                            end
                            loop ;; label = @13
                              block ;; label = @14
                                block ;; label = @15
                                  block ;; label = @16
                                    block ;; label = @17
                                      block ;; label = @18
                                        block ;; label = @19
                                          i64.const 0
                                          local.get 4
                                          i64.le_s
                                          local.set 116
                                          local.get 4
                                          local.set 117
                                          local.get 112
                                          i64.extend_i32_u
                                          local.set 118
                                          local.get 118
                                          local.get 117
                                          i64.le_u
                                          local.set 119
                                          local.get 116
                                          local.get 119
                                          i32.and
                                          local.set 120
                                          local.get 120
                                          if ;; label = @20
                                          else
                                            local.get 5
                                            local.set 6
                                            br 9 (;@11;)
                                          end
                                          local.get 0
                                          struct.get 5 8
                                          local.set 121
                                          local.get 121
                                          i64.const 1
                                          i64.sub
                                          local.set 122
                                          local.get 0
                                          struct.get 5 6
                                          local.set 123
                                          local.get 123
                                          local.get 122
                                          i64.le_s
                                          local.set 124
                                          local.get 124
                                          i32.eqz
                                          local.set 125
                                          local.get 125
                                          if ;; label = @20
                                          else
                                            local.get 5
                                            local.set 6
                                            br 9 (;@11;)
                                          end
                                          local.get 0
                                          struct.get 5 2
                                          local.set 126
                                          local.get 126
                                          i32.eqz
                                          br_if 1 (;@18;)
                                          local.get 0
                                          struct.get 5 8
                                          local.set 127
                                          local.get 0
                                          struct.get 5 6
                                          local.set 128
                                          local.get 128
                                          local.get 127
                                          i64.lt_s
                                          local.set 129
                                          local.get 129
                                          i32.eqz
                                          br_if 0 (;@19;)
                                          struct.new 28
                                          throw 0
                                          return
                                        end
                                        local.get 0
                                        struct.get 5 0
                                        ref.cast (ref null 1)
                                        local.set 130
                                        local.get 0
                                        struct.get 5 8
                                        local.set 131
                                        local.get 130
                                        ref.cast (ref null 1)
                                        local.set 132
                                        i32.const 0
                                        local.set 133
                                        local.get 132
                                        local.get 131
                                        i32.wrap_i64
                                        i32.const 1
                                        i32.sub
                                        array.get 1
                                        local.set 134
                                        br 1 (;@17;)
                                      end
                                      unreachable
                                      return
                                    end
                                    local.get 134
                                    i32.const 192
                                    i32.and
                                    local.set 135
                                    local.get 135
                                    i32.const 128
                                    i32.eq
                                    local.set 136
                                    local.get 136
                                    i32.eqz
                                    br_if 4 (;@12;)
                                    local.get 0
                                    struct.get 5 2
                                    local.set 137
                                    local.get 137
                                    i32.eqz
                                    br_if 1 (;@15;)
                                    local.get 0
                                    struct.get 5 8
                                    local.set 138
                                    local.get 0
                                    struct.get 5 6
                                    local.set 139
                                    local.get 139
                                    local.get 138
                                    i64.lt_s
                                    local.set 140
                                    local.get 140
                                    i32.eqz
                                    br_if 0 (;@16;)
                                    struct.new 28
                                    throw 0
                                    return
                                  end
                                  local.get 0
                                  struct.get 5 0
                                  ref.cast (ref null 1)
                                  local.set 141
                                  local.get 141
                                  ref.cast (ref null 1)
                                  local.set 142
                                  i32.const 0
                                  local.set 143
                                  local.get 142
                                  local.get 138
                                  i32.wrap_i64
                                  i32.const 1
                                  i32.sub
                                  array.get 1
                                  local.set 144
                                  local.get 138
                                  i64.const 1
                                  i64.add
                                  local.set 145
                                  local.get 0
                                  local.get 145
                                  struct.set 5 8
                                  local.get 145
                                  local.set 146
                                  br 1 (;@14;)
                                end
                                unreachable
                                return
                              end
                              local.get 144
                              local.set 147
                              i64.const 0
                              local.get 4
                              i64.le_s
                              local.set 148
                              local.get 4
                              local.set 149
                              local.get 147
                              local.get 149
                              i32.wrap_i64
                              i32.shl
                              local.set 150
                              local.get 4
                              i64.const -1
                              i64.xor
                              i64.const 1
                              i64.add
                              local.set 151
                              local.get 151
                              local.set 152
                              local.get 147
                              local.get 152
                              i32.wrap_i64
                              i32.shr_u
                              local.set 153
                              local.get 150
                              local.get 153
                              local.get 148
                              select
                              local.set 154
                              local.get 5
                              local.get 154
                              i32.or
                              local.set 155
                              local.get 4
                              i64.const 8
                              i64.sub
                              local.set 156
                              local.get 156
                              local.set 4
                              local.get 155
                              local.set 5
                              br 0 (;@13;)
                            end
                          end
                          local.get 5
                          local.set 6
                        end
                        local.get 6
                        local.set 157
                        local.get 0
                        struct.get 5 8
                        local.set 158
                        local.get 0
                        struct.get 5 9
                        local.set 159
                        local.get 158
                        local.get 159
                        i64.sub
                        local.set 160
                        local.get 160
                        i64.const 1
                        i64.sub
                        local.set 161
                        local.get 0
                        struct.get 5 8
                        local.set 162
                        local.get 162
                        i64.const 1
                        i64.sub
                        local.set 163
                        local.get 0
                        struct.get 5 6
                        local.set 164
                        local.get 164
                        local.get 163
                        i64.le_s
                        local.set 165
                        local.get 165
                        i32.eqz
                        br_if 0 (;@10;)
                        local.get 161
                        local.set 10
                        i32.const 0
                        local.set 11
                        local.get 161
                        local.set 12
                        local.get 157
                        local.set 13
                        local.get 90
                        local.set 14
                        local.get 86
                        local.set 15
                        br 9 (;@1;)
                      end
                      local.get 0
                      struct.get 5 2
                      local.set 166
                      local.get 166
                      i32.eqz
                      br_if 1 (;@8;)
                      local.get 0
                      struct.get 5 8
                      local.set 167
                      local.get 0
                      struct.get 5 6
                      local.set 168
                      local.get 168
                      local.get 167
                      i64.lt_s
                      local.set 169
                      local.get 169
                      i32.eqz
                      br_if 0 (;@9;)
                      struct.new 28
                      throw 0
                      return
                    end
                    local.get 0
                    struct.get 5 0
                    ref.cast (ref null 1)
                    local.set 170
                    local.get 170
                    ref.cast (ref null 1)
                    local.set 171
                    i32.const 0
                    local.set 172
                    local.get 171
                    local.get 167
                    i32.wrap_i64
                    i32.const 1
                    i32.sub
                    array.get 1
                    local.set 173
                    local.get 167
                    i64.const 1
                    i64.add
                    local.set 174
                    local.get 0
                    local.get 174
                    struct.set 5 8
                    local.get 174
                    local.set 175
                    br 1 (;@7;)
                  end
                  unreachable
                  return
                end
                local.get 173
                i32.const -1
                i32.xor
                local.set 176
                local.get 176
                i32.clz
                local.set 177
                local.get 177
                i64.extend_i32_u
                local.set 178
                local.get 178
                i32.wrap_i64
                local.set 179
                local.get 179
                i64.extend_i32_u
                local.set 180
                local.get 178
                local.get 180
                i64.eq
                local.set 181
                local.get 181
                i32.eqz
                br_if 0 (;@6;)
                br 1 (;@5;)
              end
              unreachable
              return
            end
            i32.const 4
            local.get 179
            i32.sub
            local.set 182
            i32.const 8
            local.get 182
            i32.mul
            local.set 183
            local.get 173
            local.set 184
            local.get 184
            i64.const 24
            i32.wrap_i64
            i32.shl
            local.set 185
            local.get 183
            i32.const 16
            i32.le_u
            local.set 186
            local.get 186
            if ;; label = @5
            else
              local.get 185
              local.set 9
              br 3 (;@2;)
            end
            i64.const 16
            local.set 7
            local.get 185
            local.set 8
          end
          loop ;; label = @4
            block ;; label = @5
              block ;; label = @6
                block ;; label = @7
                  block ;; label = @8
                    block ;; label = @9
                      block ;; label = @10
                        i64.const 0
                        local.get 7
                        i64.le_s
                        local.set 187
                        local.get 7
                        local.set 188
                        local.get 183
                        i64.extend_i32_u
                        local.set 189
                        local.get 189
                        local.get 188
                        i64.le_u
                        local.set 190
                        local.get 187
                        local.get 190
                        i32.and
                        local.set 191
                        local.get 191
                        if ;; label = @11
                        else
                          local.get 8
                          local.set 9
                          br 9 (;@2;)
                        end
                        local.get 0
                        struct.get 5 8
                        local.set 192
                        local.get 192
                        i64.const 1
                        i64.sub
                        local.set 193
                        local.get 0
                        struct.get 5 6
                        local.set 194
                        local.get 194
                        local.get 193
                        i64.le_s
                        local.set 195
                        local.get 195
                        i32.eqz
                        local.set 196
                        local.get 196
                        if ;; label = @11
                        else
                          local.get 8
                          local.set 9
                          br 9 (;@2;)
                        end
                        local.get 0
                        struct.get 5 2
                        local.set 197
                        local.get 197
                        i32.eqz
                        br_if 1 (;@9;)
                        local.get 0
                        struct.get 5 8
                        local.set 198
                        local.get 0
                        struct.get 5 6
                        local.set 199
                        local.get 199
                        local.get 198
                        i64.lt_s
                        local.set 200
                        local.get 200
                        i32.eqz
                        br_if 0 (;@10;)
                        struct.new 28
                        throw 0
                        return
                      end
                      local.get 0
                      struct.get 5 0
                      ref.cast (ref null 1)
                      local.set 201
                      local.get 0
                      struct.get 5 8
                      local.set 202
                      local.get 201
                      ref.cast (ref null 1)
                      local.set 203
                      i32.const 0
                      local.set 204
                      local.get 203
                      local.get 202
                      i32.wrap_i64
                      i32.const 1
                      i32.sub
                      array.get 1
                      local.set 205
                      br 1 (;@8;)
                    end
                    unreachable
                    return
                  end
                  local.get 205
                  i32.const 192
                  i32.and
                  local.set 206
                  local.get 206
                  i32.const 128
                  i32.eq
                  local.set 207
                  local.get 207
                  i32.eqz
                  br_if 4 (;@3;)
                  local.get 0
                  struct.get 5 2
                  local.set 208
                  local.get 208
                  i32.eqz
                  br_if 1 (;@6;)
                  local.get 0
                  struct.get 5 8
                  local.set 209
                  local.get 0
                  struct.get 5 6
                  local.set 210
                  local.get 210
                  local.get 209
                  i64.lt_s
                  local.set 211
                  local.get 211
                  i32.eqz
                  br_if 0 (;@7;)
                  struct.new 28
                  throw 0
                  return
                end
                local.get 0
                struct.get 5 0
                ref.cast (ref null 1)
                local.set 212
                local.get 212
                ref.cast (ref null 1)
                local.set 213
                i32.const 0
                local.set 214
                local.get 213
                local.get 209
                i32.wrap_i64
                i32.const 1
                i32.sub
                array.get 1
                local.set 215
                local.get 209
                i64.const 1
                i64.add
                local.set 216
                local.get 0
                local.get 216
                struct.set 5 8
                local.get 216
                local.set 217
                br 1 (;@5;)
              end
              unreachable
              return
            end
            local.get 215
            local.set 218
            i64.const 0
            local.get 7
            i64.le_s
            local.set 219
            local.get 7
            local.set 220
            local.get 218
            local.get 220
            i32.wrap_i64
            i32.shl
            local.set 221
            local.get 7
            i64.const -1
            i64.xor
            i64.const 1
            i64.add
            local.set 222
            local.get 222
            local.set 223
            local.get 218
            local.get 223
            i32.wrap_i64
            i32.shr_u
            local.set 224
            local.get 221
            local.get 224
            local.get 219
            select
            local.set 225
            local.get 8
            local.get 225
            i32.or
            local.set 226
            local.get 7
            i64.const 8
            i64.sub
            local.set 227
            local.get 227
            local.set 7
            local.get 226
            local.set 8
            br 0 (;@4;)
          end
        end
        local.get 8
        local.set 9
      end
      local.get 9
      local.set 228
      local.get 0
      struct.get 5 8
      local.set 229
      local.get 0
      struct.get 5 9
      local.set 230
      local.get 229
      local.get 230
      i64.sub
      local.set 231
      local.get 231
      i64.const 1
      i64.sub
      local.set 232
      local.get 232
      local.set 10
      local.get 228
      local.set 11
      local.get 161
      local.set 12
      local.get 157
      local.set 13
      local.get 90
      local.set 14
      local.get 86
      local.set 15
    end
    local.get 0
    struct.get 5 8
    local.set 233
    local.get 0
    struct.get 5 9
    local.set 234
    local.get 233
    local.get 234
    i64.sub
    local.set 235
    local.get 235
    i64.const 1
    i64.sub
    local.set 236
    i32.const 16
    array.new_default 7
    ref.cast (ref null 7)
    local.set 237
    local.get 237
    ref.cast (ref null 7)
    local.set 238
    local.get 238
    i64.const 0
    struct.new 2
    struct.new 8
    ref.cast (ref null 8)
    local.set 239
    i32.const 536870912
    local.get 15
    local.get 13
    local.get 11
    struct.new 9
    ref.cast (ref null 9)
    local.set 240
    local.get 19
    local.get 14
    local.get 12
    local.get 10
    struct.new 10
    ref.cast (ref null 10)
    local.set 241
    local.get 0
    local.get 236
    i32.const 767
    local.get 239
    local.get 240
    local.get 241
    struct.new 11
    ref.cast (ref null 11)
    local.set 242
    local.get 242
    return
    unreachable
  )
)
