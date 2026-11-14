# Byte identity of modules built with wasm_builder's builders (dev/MARCH.md 1.B): each case builds a
# module through ModuleBuilder and the instruction builder and serializes it to the bytes
# `wasm-tools parse` (1.244.0) gives the text beside it, which `wasm-tools validate` accepts; the goldens
# are those bytes. A misuse dart's builder catches in an assert rejects at the emitting call.

module BuilderModulesTest

using Test
using WasmTarget

const W = WasmTarget.WasmBuilder
const I = W.IR

module_bytes(mb) = (s = W.Serializer(); W.serialize(s, W.build(mb)); W.data(s))

rejects(f) = try
    f()
    false
catch e
    e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.InvalidModule
end

# sum(n) = n + (n-1) + ... + 1, counting the loop's turns in a global, logging the sum through an import
function sum_module()
    local mb = W.ModuleBuilder("m", nothing)
    local i32 = I.NumType_i32
    local sig = W.define_function(mb.types[], I.ValueType[i32], I.ValueType[i32])
    local log = W.var"import"(mb.functions[], "env", "log", W.define_function(mb.types[], I.ValueType[i32], I.ValueType[]))
    local counter = W.define(mb.globals[], I.GlobalType(i32))
    W.i32_const(counter.initializer, 0)
    W.var"end"(counter.initializer)
    local f = W.define(mb.functions[], sig)
    local b = W.body(f)
    local n = W.locals(f)[1]
    local acc = W.add_local(b, i32)
    local outer = W.block(b)
    local top = W.loop(b)
    W.local_get(b, n); W.i32_eqz(b); W.br_if(b, outer)
    W.local_get(b, acc); W.local_get(b, n); W.i32_add(b); W.local_set(b, acc)
    W.local_get(b, n); W.i32_const(b, 1); W.i32_sub(b); W.local_set(b, n)
    W.global_get(b, counter); W.i32_const(b, 1); W.i32_add(b); W.global_set(b, counter)
    W.br(b, top)
    W.var"end"(b)
    W.var"end"(b)
    W.local_get(b, acc); W.call(b, log)
    W.local_get(b, acc); W.i32_const(b, 10); W.i32_gt_s(b)
    W.if_(b, I.ValueType[], I.ValueType[i32])
    W.i32_const(b, 1)
    W.else_(b)
    W.i32_const(b, 0)
    W.var"end"(b)
    W.var"end"(b)
    W.var"export"(mb.exports, "sum", f)
    return mb
end

# a self-referential struct, an i8 array, casts, struct.new/get/set and array.new_default/len
function gc_module()
    local mb = W.ModuleBuilder("m", nothing)
    local node = W.define_struct(mb.types[], "Node"; brand = false)
    push!(node.fields, I.FieldType(I.NumType_i64; mutable = false))
    push!(node.fields, I.FieldType(I.RefType_def(node; nullable = true)))
    local bytes_t = W.define_array(mb.types[], "Bytes"; element_type = I.FieldType_i8())
    local sig = W.define_function(mb.types[], I.ValueType[I.RefType_any(nullable = true)], I.ValueType[I.NumType_i64])
    local f = W.define(mb.functions[], sig)
    local b = W.body(f)
    local x = W.locals(f)[1]
    W.local_get(b, x); W.ref_cast(b, I.RefType_def(node; nullable = false))
    W.i64_const(b, 7); W.ref_null(b, I.HeapType_none); W.struct_new(b, node)
    W.struct_set(b, node, 1)
    W.i32_const(b, 3); W.array_new_default(b, bytes_t); W.array_len(b); W.drop(b)
    W.local_get(b, x); W.ref_cast(b, I.RefType_def(node; nullable = false)); W.struct_get(b, node, 0)
    W.var"end"(b)
    W.var"export"(mb.exports, "f", f)
    return mb
end

# a tag and try_table, a table with an active and a declarative element segment, call_indirect,
# br_table, select, a memory with an active data segment, i31, packed struct and array fields
function broad_module()
    local mb = W.ModuleBuilder("m", nothing)
    local i32, i64 = I.NumType_i32, I.NumType_i64
    local pair = W.define_struct(mb.types[], "Pair"; fields = [I.FieldType_i8(), I.FieldType(i32; mutable = false)], brand = false)
    local ints = W.define_array(mb.types[], "Ints"; element_type = I.FieldType_i16())
    local unop = W.define_function(mb.types[], I.ValueType[i32], I.ValueType[i32])
    local exn = W.define_function(mb.types[], I.ValueType[i32], I.ValueType[])
    local tag = W.define(mb.tags[], exn)
    local tab = W.define(mb.tables[], I.RefType_func(nullable = true), 2)
    local mem = W.define(mb.memories[], false, 1)
    W.define(mb.data_segments, UInt8[0x2a, 0x00, 0x00, 0x00], mem, 16)
    local inc = W.define(mb.functions[], unop, "inc")
    local ib = W.body(inc)
    W.local_get(ib, W.locals(inc)[1]); W.i32_const(ib, 1); W.i32_add(ib); W.var"end"(ib)
    W.set_function_at(W.active_function_segment_builder_for(mb.elements[], tab), 0, inc)
    W.declare(mb.elements[].declarative_segment_builder, inc)
    local main = W.define(mb.functions[], W.define_function(mb.types[], I.ValueType[i32], I.ValueType[i64]), "main")
    local b = W.body(main)
    local x = W.locals(main)[1]
    local y = W.add_local(b, i32)
    local caught = W.block(b, I.ValueType[], I.ValueType[i32])
    W.try_table(b, W.TryTableCatch[W.Catch(tag, caught)])
    W.local_get(b, x); W.i32_eqz(b)
    W.if_(b)
    W.local_get(b, x); W.throw_(b, tag)
    W.var"end"(b)
    W.var"end"(b)
    W.i32_const(b, 0)
    W.var"end"(b)
    W.local_set(b, y)
    local outer = W.block(b)
    local inner = W.block(b)
    W.local_get(b, y); W.br_table(b, W.Label[inner, outer], outer)
    W.var"end"(b)
    W.var"end"(b)
    W.local_get(b, x); W.i32_const(b, 0); W.call_indirect(b, unop, tab)
    W.local_get(b, y); W.local_get(b, x); W.select(b, i32)
    W.i32_const(b, 0); W.i32_load(b, mem, 16); W.i32_add(b); W.local_set(b, y)
    W.i32_const(b, 4); W.local_get(b, y); W.i32_store(b, mem, 0)
    W.local_get(b, y); W.i31_new(b); W.i31_get_s(b)
    W.i32_const(b, 3); W.local_get(b, y); W.struct_new(b, pair); W.struct_get_u(b, pair, 0)
    W.i32_add(b)
    W.i32_const(b, 7); W.i32_const(b, 8); W.array_new_fixed(b, ints, 2); W.i32_const(b, 1); W.array_get_s(b, ints)
    W.i32_add(b)
    W.ref_func(b, inc); W.drop(b)
    W.i64_extend_i32_s(b)
    W.var"end"(b)
    W.var"export"(mb.exports, "main", main)
    return mb
end

@testset "wasm_builder's builders build modules byte-identical with wasm-tools" begin
    # (module $m
    #   (type (func (param i32) (result i32)))
    #   (type (func (param i32)))
    #   (import "env" "log" (func (type 1)))
    #   (global (mut i32) (i32.const 0))
    #   (export "sum" (func 1))
    #   (func (type 0) (param i32) (result i32) (local i32)
    #     block
    #       loop
    #         local.get 0  i32.eqz  br_if 1
    #         local.get 1  local.get 0  i32.add  local.set 1
    #         local.get 0  i32.const 1  i32.sub  local.set 0
    #         global.get 0  i32.const 1  i32.add  global.set 0
    #         br 0
    #       end
    #     end
    #     local.get 1  call 0
    #     local.get 1  i32.const 10  i32.gt_s
    #     if (result i32)  i32.const 1  else  i32.const 0  end))
    @test bytes2hex(module_bytes(sum_module())) == "0061736d01000000010a0260017f017f60017f00020b0103656e76036c6f670001030201000606017f0141000b0707010373756d00010a39013701017f024003402000450d01200120006a2101200041016b2100230041016a24000c000b0b200110002001410a4a047f41010541000b0b0009046e616d650002016d"

    # (module $m
    #   (type $Node (struct (field i64) (field (mut (ref null $Node)))))
    #   (type $Bytes (array (mut i8)))
    #   (type (func (param anyref) (result i64)))
    #   (export "f" (func 0))
    #   (func (type 2) (param anyref) (result i64)
    #     local.get 0  ref.cast (ref $Node)
    #     i64.const 7  ref.null none  struct.new $Node
    #     struct.set $Node 1
    #     i32.const 3  array.new_default $Bytes  array.len  drop
    #     local.get 0  ref.cast (ref $Node)  struct.get $Node 0))
    @test bytes2hex(module_bytes(gc_module())) == "0061736d010000000110035f027e006300015e780160016e017e03020102070501016600000a250123002000fb16004207d071fb0000fb0500014103fb0701fb0f1a2000fb1600fb0200000b0019046e616d650002016d040e0200044e6f646501054279746573"

    # (module $m
    #   (type $Pair (struct (field (mut i8)) (field i32)))
    #   (type $Ints (array (mut i16)))
    #   (type (func (param i32) (result i32)))
    #   (type (func (param i32)))
    #   (type (func (param i32) (result i64)))
    #   (table 2 funcref)
    #   (memory 1)
    #   (tag (type 3))
    #   (export "main" (func 1))
    #   (elem (i32.const 0) func 0)
    #   (elem declare func 0)
    #   (func $inc (type 2) (param i32) (result i32)  local.get 0  i32.const 1  i32.add)
    #   (func $main (type 4) (param i32) (result i64) (local i32)
    #     block (result i32)
    #       try_table (catch 0 0)
    #         local.get 0  i32.eqz
    #         if  local.get 0  throw 0  end
    #       end
    #       i32.const 0
    #     end
    #     local.set 1
    #     block  block  local.get 1  br_table 0 1 1  end  end
    #     local.get 0  i32.const 0  call_indirect (type 2)
    #     local.get 1  local.get 0  select
    #     i32.const 0  i32.load offset=16  i32.add  local.set 1
    #     i32.const 4  local.get 1  i32.store
    #     local.get 1  ref.i31  i31.get_s
    #     i32.const 3  local.get 1  struct.new $Pair  struct.get_u $Pair 0
    #     i32.add
    #     i32.const 7  i32.const 8  array.new_fixed $Ints 2  i32.const 1  array.get_s $Ints
    #     i32.add
    #     ref.func $inc  drop
    #     i64.extend_i32_s)
    #   (data (i32.const 16) "\2a\00\00\00"))
    # dart writes a data count section whenever the module has data segments (sections.dart:652),
    # where wasm-tools writes one only when bulk memory needs it: the golden is wasm-tools' bytes with
    # the section `0c 01 01` before the code section.
    @test bytes2hex(module_bytes(broad_module())) == "0061736d010000000118055f0278017f005e770160017f017f60017f0060017f017e030302020404040170000205030100010d03010003070801046d61696e0001090b020041000b0100030001000c01010a72020700200041016a0b6801017f027f1f40010000002000450440200008000b0b41000b21010240024020010e020001010b0b20004100110200200120001b41002802106a2101410420013602002001fb1cfb1d41032001fb0000fb0400006a41074108fb0801024101fb0c016ad2001aac0b0b0a010041100b042a0000000026046e616d650002016d010c020003696e6301046d61696e040d020004506169720104496e7473"

    @testset "a misuse rejects at the emitting call" begin
        local mb = W.ModuleBuilder("m", nothing)
        local i32 = I.NumType_i32
        local f = W.define(mb.functions[], W.define_function(mb.types[], I.ValueType[], I.ValueType[i32]))
        local b = W.body(f)
        @test rejects(() -> W.i32_add(b))                      # i32.add on an empty stack
        W.i64_const(b, 1)
        @test rejects(() -> W.i32_eqz(b))                      # i32.eqz on an i64
        local gb = W.body(W.define(mb.functions[], W.define_function(mb.types[], I.ValueType[], I.ValueType[i32])))
        W.i64_const(gb, 1)
        @test rejects(() -> W.var"end"(gb))                    # `end` with the wrong result
        local h = W.define(mb.functions[], W.define_function(mb.types[], I.ValueType[], I.ValueType[]))
        local hb = W.body(h)
        local l = W.add_local(hb, I.RefType_any(nullable = false))
        @test rejects(() -> W.local_get(hb, l))                # a non-defaultable local read before it is set
        @test rejects(() -> W.else_(hb))                       # `else` outside an `if`
        local gl = W.define(mb.globals[], I.GlobalType(i32))
        W.i32_const(gl.initializer, 1)
        W.i32_const(gl.initializer, 2)
        @test rejects(() -> W.i32_add(gl.initializer))         # i32.add in a global's initializer
    end
end

end # module BuilderModulesTest
