# The instruction builder refuses invalid wasm at the emitting call (dev/LEDGER.md D10): one case
# per check of wasm_builder's InstructionsBuilder, each an InvalidModule rejection whose text names
# the fault, beside the valid sequence the same check accepts. dart makes these checks inside
# asserts; the port makes every one on every emission. wasm-tools is not consulted here.

module BuilderRefusalsTest

using Test
using WasmTarget

const W = WasmTarget.WasmBuilder
const I = W.IR
const i32, i64 = I.NumType_i32, I.NumType_i64

# the text of the InvalidModule rejection `f` raises, or "" when it raises none
function refusal(f)::String
    try
        f()
        return ""
    catch e
        e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.InvalidModule || rethrow()
        return e.rejection.site
    end
end
# the text of any rejection `f` raises (a module part dart refuses with an assert or a throw)
function rejection(f)::String
    try
        f()
        return ""
    catch e
        e isa WasmTarget.RejectionError || rethrow()
        return sprint(showerror, e)
    end
end
module_bytes(mb) = (s = W.Serializer(); W.serialize(s, W.build(mb)); W.data(s))
accepts(f) = (f(); true)

new_module() = W.ModuleBuilder("m", nothing)
# the body of a fresh function of `mb` taking `inputs` and returning `outputs`
function body_of(mb, inputs = I.ValueType[], outputs = I.ValueType[])
    local f = W.define(mb.functions[], W.define_function(mb.types[], inputs, outputs))
    return W.body(f), f
end

@testset "the instruction builder refuses invalid wasm where it is emitted" begin
    @testset "operand stack" begin
        local b, _ = body_of(new_module())
        @test occursin("Underflowing base stack", refusal(() -> W.i32_add(b)))      # nothing on the stack
        local b2, _ = body_of(new_module())
        W.i64_const(b2, 1)
        @test occursin("Expected [i32], but stack contained [i64]", refusal(() -> W.i32_eqz(b2)))
        local ok, _ = body_of(new_module())
        @test accepts(() -> (W.i32_const(ok, 1); W.i32_eqz(ok); W.drop(ok)))
        local b3, _ = body_of(new_module())
        W.i32_const(b3, 1)
        W.block(b3)                                    # the block's base hides the outer i32
        @test occursin("Underflowing base stack of innermost block", refusal(() -> W.i32_eqz(b3)))
        local b4, _ = body_of(new_module())
        W.i32_const(b4, 1); W.i64_const(b4, 2); W.i32_const(b4, 0)
        @test occursin("Expected [i32, i32, i32]", refusal(() -> W.select(b4, i32)))
    end

    @testset "block results and the function's end" begin
        local b, _ = body_of(new_module())
        W.block(b)
        W.i32_const(b, 1)
        @test occursin("Incorrect stack height at end of block (expected 0, actual 1)", refusal(() -> W.var"end"(b)))
        local b2, _ = body_of(new_module(), I.ValueType[], I.ValueType[i32])
        W.i64_const(b2, 1)
        @test occursin("Expected [i32], but stack contained [i64]", refusal(() -> W.var"end"(b2)))
        local ok, _ = body_of(new_module(), I.ValueType[], I.ValueType[i32])
        @test accepts(() -> (W.i32_const(ok, 1); W.var"end"(ok)))
        @test W.is_complete(ok)
        @test occursin("Label stack underflow", refusal(() -> W.var"end"(ok)))   # an end past the function's
    end

    @testset "branches and labels" begin
        local b, _ = body_of(new_module())
        local l = W.block(b, I.ValueType[], I.ValueType[i32])
        @test occursin("Underflowing base stack of target label", refusal(() -> W.br(b, l)))
        W.i64_const(b, 1)
        @test occursin("Expected [i32], but stack contained [i64]", refusal(() -> W.br(b, l)))
        local b2, _ = body_of(new_module())
        local gone = W.block(b2)
        W.var"end"(b2)
        @test occursin("is not on the label stack", refusal(() -> W.br(b2, gone)))   # a closed block's label
        local ok, _ = body_of(new_module())
        local lo = W.block(ok)
        @test accepts(() -> (W.br(ok, lo); W.var"end"(ok); W.var"end"(ok)))
    end

    @testset "if, else, try, catch, throw and rethrow" begin
        local mb = new_module()
        local b, _ = body_of(mb)
        @test occursin("Unexpected 'else' (not in 'if' block)", refusal(() -> W.else_(b)))
        W.i32_const(b, 1)
        W.if_(b)
        W.else_(b)
        @test occursin("Duplicate 'else' in 'if' block", refusal(() -> W.else_(b)))
        local tag = W.define(mb.tags[], W.define_function(mb.types[], I.ValueType[], I.ValueType[]))
        local b2, _ = body_of(mb)
        @test occursin("Unexpected 'catch' (not in 'try' block)", refusal(() -> W.catch_legacy(b2, tag)))
        local blk = W.block(b2)
        @test occursin("not a 'try' block with a 'catch'", refusal(() -> W.rethrow_(b2, blk)))
        local other = new_module()
        local foreign = W.define(other.tags[], W.define_function(other.types[], I.ValueType[], I.ValueType[]))
        local b3, _ = body_of(mb)
        @test occursin("of another module in 'throw'", refusal(() -> W.throw_(b3, foreign)))
        local ok, _ = body_of(mb)
        @test accepts(() -> (W.throw_(ok, tag); W.var"end"(ok)))
    end

    @testset "calls, locals and globals" begin
        local mb, other = new_module(), new_module()
        local b, _ = body_of(mb)
        local _, g = body_of(other)
        @test occursin("of another module", refusal(() -> W.call(b, g)))
        local _, f2 = body_of(mb, I.ValueType[i32])
        local b2, _ = body_of(mb)
        @test occursin("is not this function's", refusal(() -> W.local_get(b2, W.locals(f2)[1])))
        local l = W.add_local(b2, I.RefType_any(nullable = false))
        @test occursin("Uninitialized local with non-defaultable type", refusal(() -> W.local_get(b2, l)))
        local fixed = W.define(mb.globals[], I.GlobalType(i32; mutable = false))
        local b3, _ = body_of(mb)
        W.i32_const(b3, 1)
        @test occursin("'global.set' of the immutable global", refusal(() -> W.global_set(b3, fixed)))
        local foreign = W.define(other.globals[], I.GlobalType(i32))
        @test occursin("of another module", refusal(() -> W.global_get(b3, foreign)))
        local var = W.define(mb.globals[], I.GlobalType(i32))
        @test accepts(() -> W.global_set(b3, var))
        local fn_type = W.define_function(mb.types[], I.ValueType[], I.ValueType[])
        local tab = W.define(other.tables[], I.RefType_func(nullable = true), 1)
        local b4, _ = body_of(mb)
        W.i32_const(b4, 0)
        @test occursin("Table of another module in 'call_indirect'", refusal(() -> W.call_indirect(b4, fn_type, tab)))
    end

    @testset "tables and memories" begin
        local mb, other = new_module(), new_module()
        local tab = W.define(other.tables[], I.RefType_func(nullable = true), 1)
        local b, _ = body_of(mb)
        W.i32_const(b, 0)
        @test occursin("table of another module", refusal(() -> W.table_get(b, tab)))
        local mem = W.define(mb.memories[], false, 1)
        local b2, _ = body_of(mb)
        W.i32_const(b2, 0)
        @test occursin("alignment 3 outside 0..2", refusal(() -> W.i32_load(b2, mem, 0, 3)))
        @test accepts(() -> (W.i32_load(b2, mem, 0, 2); W.drop(b2)))
        local foreign = W.define(other.memories[], false, 1)
        W.i32_const(b2, 0)
        @test occursin("another module", refusal(() -> W.i32_load(b2, foreign, 0)))
    end

    @testset "structs, arrays, casts" begin
        local mb = new_module()
        local s = W.define_struct(mb.types[], "S"; fields = [I.FieldType_i8(), I.FieldType(i32)], brand = false)
        local a8 = W.define_array(mb.types[], "A8"; element_type = I.FieldType_i8())
        local a32 = W.define_array(mb.types[], "A32"; element_type = I.FieldType(I.RefType_any(nullable = true)))
        local b, _ = body_of(mb)
        W.ref_null(b, I.HeapType_none)
        @test occursin("'struct.get' of the packed field 0", refusal(() -> W.struct_get(b, s, 0)))
        @test occursin("'struct.get_s' of the unpacked field 1", refusal(() -> W.struct_get_s(b, s, 1)))
        @test occursin("'struct.get' of the field 2, not one of the 2 fields", refusal(() -> W.struct_get(b, s, 2)))
        @test accepts(() -> (W.struct_get_s(b, s, 0); W.drop(b)))
        local b2, _ = body_of(mb)
        W.ref_null(b2, I.HeapType_none); W.i32_const(b2, 0)
        @test occursin("'array.get' of the packed array", refusal(() -> W.array_get(b2, a8)))
        @test occursin("'array.get_u' of the unpacked array", refusal(() -> W.array_get_u(b2, a32)))
        local seg = W.define(mb.data_segments, UInt8[1, 2])
        local b3, _ = body_of(mb)
        W.i32_const(b3, 0); W.i32_const(b3, 1)
        @test occursin("'array.new_data' of the reference array", refusal(() -> W.array_new_data(b3, a32, seg)))
        local b4, f4 = body_of(mb, I.ValueType[I.RefType_func(nullable = true)])
        W.local_get(b4, W.locals(f4)[1])
        local l = W.block(b4, I.ValueType[I.RefType_func(nullable = true)], I.ValueType[I.RefType_func(nullable = true)])
        @test occursin("not a subtype of input type", refusal(() ->
            W.br_on_cast(b4, l, I.RefType_func(nullable = true), I.RefType_def(s; nullable = true))))
    end

    @testset "constants and constant expressions" begin
        local mb = new_module()
        local b, _ = body_of(mb)
        @test occursin("outside the signed 32-bit range", refusal(() -> W.i32_const(b, 2^31)))
        local ok, _ = body_of(mb)
        @test accepts(() -> (W.i32_const(ok, -2^31); W.drop(ok)))
        local v, _ = body_of(mb)
        @test occursin("v128.const with 15 bytes, not 16", refusal(() -> W.v128_const(v, zeros(UInt8, 15))))
        W.v128_const(v, zeros(UInt8, 16)); W.v128_const(v, zeros(UInt8, 16))
        @test occursin("with 15 lanes, not 16", refusal(() -> W.i8x16_shuffle(v, collect(0:14))))
        local g = W.define(mb.globals[], I.GlobalType(i32))
        W.i32_const(g.initializer, 1)
        W.i32_const(g.initializer, 2)
        @test occursin("Non-constant instruction i32.add added to constant expression", refusal(() -> W.i32_add(g.initializer)))
    end

    @testset "the module's parts refuse when they are defined or built" begin
        # a declared supertype that is not a structural supertype: the type section refuses it
        local mb = new_module()
        local sup = W.define_struct(mb.types[], "Sup"; fields = [I.FieldType(i64)], brand = false)
        local sub = W.define_struct(mb.types[], "Sub"; fields = [I.FieldType(i32)], super_type = sup, brand = false)
        local b, _ = body_of(mb, I.ValueType[I.RefType_def(sub; nullable = true)])
        W.var"end"(b)
        @test occursin("is not a structural subtype of its declared supertype", rejection(() -> module_bytes(mb)))
        local ok = new_module()
        local sup2 = W.define_struct(ok.types[], "Sup"; fields = [I.FieldType(i64; mutable = false)], brand = false)
        local sub2 = W.define_struct(ok.types[], "Sub"; fields = [I.FieldType(i64; mutable = false), I.FieldType(i32)], super_type = sup2, brand = false)
        local b2, _ = body_of(ok, I.ValueType[I.RefType_def(sub2; nullable = true)])
        W.var"end"(b2)
        @test !isempty(module_bytes(ok))
        # a custom section under a name the serializer writes itself
        @test occursin("is reserved", rejection(() -> W.add_custom_section(new_module(), "name", UInt8[])))
        # a data segment with a memory and no offset, and one past its memory's pages
        local m3 = new_module()
        local mem = W.define(m3.memories[], false, 1)
        @test occursin("a memory without an offset", rejection(() -> W.define(m3.data_segments, UInt8[1], mem, nothing)))
        @test occursin("overflow the memory", rejection(() -> W.define(m3.data_segments, UInt8[1, 2], mem, 65535)))
        # a function table entry past the table's maximum, and a function table of non-function references
        local m4 = new_module()
        local ftab = W.define(m4.tables[], I.RefType_func(nullable = true), 1, 2)
        local _, f = body_of(m4)
        local seg = W.active_function_segment_builder_for(m4.elements[], ftab)
        @test occursin("greater than max table size", rejection(() -> W.set_function_at(seg, 2, f)))
        local xtab = W.define(m4.tables[], I.RefType_extern(nullable = true), 1)
        @test occursin("holds no function references", rejection(() -> W.active_function_segment_builder_for(m4.elements[], xtab)))
        # two exports under one name
        local m5 = new_module()
        local _, g = body_of(m5)
        W.var"export"(m5.exports, "f", g)
        @test occursin("a second export named 'f'", rejection(() -> W.var"export"(m5.exports, "f", g)))
    end
end

end # module BuilderRefusalsTest
