# Byte identity of wasm_builder's IR (dev/MARCH.md 1.B): every instruction, and modules assembled
# from IR parts the way ModuleBuilder.forceBuild initializes one, serialize to the bytes
# `wasm-tools parse` (1.244.0) gives the equivalent text. The goldens are those bytes: an instruction's
# are its bytes inside a function body, its text beside it; a module's text is beside its golden.
# dart names two instructions by their former text (`extern.externalize`, `i31.new`), which
# wasm-tools spells `extern.convert_any` and `ref.i31`; the bytes are the same.

module IRModulesTest

using Test
using WasmTarget

const W = WasmTarget.WasmBuilder
const I = W.IR

bytes_of(x) = (s = W.Serializer(); W.serialize(s, x); W.data(s))
fidx(i::Int) = (f = I.Finalizable{Int}(); W.set_value!(f, i); f)
code(locals, instructions) = I.Instructions(locals, WasmTarget.LinkedHashMap{Int,String}(), I.Instruction[instructions...], nothing, String[], nothing)

# A module assembled from IR parts, the way ModuleBuilder.forceBuild initializes one.
function ir_module(; types, imported_functions = I.ImportedFunction[], defined_functions = I.DefinedFunction[],
                   tables = I.DefinedTable[], memories = I.DefinedMemory[], globals = I.DefinedGlobal[],
                   exports = I.Export[], start = nothing, data = I.DataSegment[], m = I.Module_uninitialized(), name = "m")
    local functions = I.Functions(imported_functions, defined_functions)
    local imports = I.Imports(imported_functions, I.ImportedTag[], I.ImportedGlobal[], I.ImportedTable[], I.ImportedMemory[])
    W.initialize(m, name, functions, start, I.Tables(I.ImportedTable[], tables), I.Elements(I.ElementSegment[]),
                 I.Tags(I.ImportedTag[], I.DefinedTag[]), I.Memories(I.ImportedMemory[], memories), I.Exports(exports),
                 I.Globals(I.ImportedGlobal[], globals), types, I.DataSegments(data), imports, Int[], nothing,
                 W.ExtraCustomSection[])
    return m
end

# The parts the instructions' immediates name, at the indices the text names them by: types 0 to 4,
# function 0, tables 0 and 1, memories 0 and 1, globals 0 and 1, tags 0 and 1, data segment 1.
const M = I.Module_uninitialized()
const FT0 = I.FunctionType(I.ValueType[], I.ValueType[])
const ST = I.StructType(nothing; fields = [I.FieldType(I.NumType_i32), I.FieldType_i8(), I.FieldType(I.NumType_i64)])
const AT8 = I.ArrayType(nothing; element_type = I.FieldType_i8())
const AT32 = I.ArrayType(nothing; element_type = I.FieldType(I.NumType_i32))
const FT4 = I.FunctionType(I.ValueType[I.NumType_i32], I.ValueType[I.NumType_i64])
foreach(((k, t),) -> W.set_index!(t, k - 1), enumerate((FT0, ST, AT8, AT32, FT4)))
const F0 = I.ImportedFunction(M, "env", "f", fidx(0), FT0)
const T0 = I.DefinedTable(M, fidx(0), I.RefType_func(nullable = true), 2, nothing)
const T1 = I.DefinedTable(M, fidx(1), I.RefType_extern(nullable = true), 1, nothing)
const M0 = I.DefinedMemory(M, fidx(0), false, 1, nothing)
const M1 = I.DefinedMemory(M, fidx(1), false, 1, nothing)
const G0 = I.DefinedGlobal(M, code(I.Local[], []), fidx(0), I.GlobalType(I.NumType_i32))
const G1 = I.DefinedGlobal(M, code(I.Local[], []), fidx(1), I.GlobalType(I.NumType_i64))
const TG0 = I.DefinedTag(M, fidx(0), FT0)
const TG1 = I.DefinedTag(M, fidx(1), FT4)
const D1 = I.DataSegment(1, UInt8[0x63, 0x64], nothing, nothing)
const L0 = I.Local(0, I.NumType_i32)
const L3 = I.Local(3, I.NumType_i32)
moa(m, o, a) = I.MemoryOffsetAlign(m; offset = o, align = a)

# every instruction without an immediate: its struct, dart's name for it, its bytes
const FIELDLESS = [
    (I.ArrayLen, "array.len", "fb0f"),
    (I.BeginNoEffectBlock, "block", "0240"),
    (I.BeginNoEffectIf, "if", "0440"),
    (I.BeginNoEffectLoop, "loop", "0340"),
    (I.BeginNoEffectTry, "try", "0640"),
    (I.ExternExternalize, "extern.externalize", "fb1b"),
    (I.ExternInternalize, "any.convert_extern", "fb1a"),
    (I.I31GetS, "i31.get_s", "fb1d"),
    (I.I31GetU, "i31.get_u", "fb1e"),
    (I.I31New, "i31.new", "fb1c"),
    (I.I32TruncSatF32S, "i32.trunc_sat_f32_s", "fc00"),
    (I.I32TruncSatF32U, "i32.trunc_sat_f32_u", "fc01"),
    (I.I32TruncSatF64S, "i32.trunc_sat_f64_s", "fc02"),
    (I.I32TruncSatF64U, "i32.trunc_sat_f64_u", "fc03"),
    (I.I64TruncSatF32S, "i64.trunc_sat_f32_s", "fc04"),
    (I.I64TruncSatF32U, "i64.trunc_sat_f32_u", "fc05"),
    (I.I64TruncSatF64S, "i64.trunc_sat_f64_s", "fc06"),
    (I.I64TruncSatF64U, "i64.trunc_sat_f64_u", "fc07"),
    (I.Select, "select", "1b"),
    (I.CatchAllLegacy, "catch_all", "19"),
    (I.Drop, "drop", "1a"),
    (I.Else, "else", "05"),
    (I.End, "end", "0b"),
    (I.F32Abs, "f32.abs", "8b"),
    (I.F32Add, "f32.add", "92"),
    (I.F32Ceil, "f32.ceil", "8d"),
    (I.F32ConvertI32S, "f32.convert_i32_s", "b2"),
    (I.F32ConvertI32U, "f32.convert_i32_u", "b3"),
    (I.F32ConvertI64S, "f32.convert_i64_s", "b4"),
    (I.F32ConvertI64U, "f32.convert_i64_u", "b5"),
    (I.F32Copysign, "f32.copysign", "98"),
    (I.F32DemoteF64, "f32.demote_f64", "b6"),
    (I.F32Div, "f32.div", "95"),
    (I.F32Eq, "f32.eq", "5b"),
    (I.F32Floor, "f32.floor", "8e"),
    (I.F32Ge, "f32.ge", "60"),
    (I.F32Gt, "f32.gt", "5e"),
    (I.F32Le, "f32.le", "5f"),
    (I.F32Lt, "f32.lt", "5d"),
    (I.F32Max, "f32.max", "97"),
    (I.F32Min, "f32.min", "96"),
    (I.F32Mul, "f32.mul", "94"),
    (I.F32Ne, "f32.ne", "5c"),
    (I.F32Nearest, "f32.nearest", "90"),
    (I.F32Neg, "f32.neg", "8c"),
    (I.F32ReinterpretI32, "f32.reinterpret_i32", "be"),
    (I.F32Sqrt, "f32.sqrt", "91"),
    (I.F32Sub, "f32.sub", "93"),
    (I.F32Trunc, "f32.trunc", "8f"),
    (I.F64Abs, "f64.abs", "99"),
    (I.F64Add, "f64.add", "a0"),
    (I.F64Ceil, "f64.ceil", "9b"),
    (I.F64ConvertI32S, "f64.convert_i32_s", "b7"),
    (I.F64ConvertI32U, "f64.convert_i32_u", "b8"),
    (I.F64ConvertI64S, "f64.convert_i64_s", "b9"),
    (I.F64ConvertI64U, "f64.convert_i64_u", "ba"),
    (I.F64Copysign, "f64.copysign", "a6"),
    (I.F64Div, "f64.div", "a3"),
    (I.F64Eq, "f64.eq", "61"),
    (I.F64Floor, "f64.floor", "9c"),
    (I.F64Ge, "f64.ge", "66"),
    (I.F64Gt, "f64.gt", "64"),
    (I.F64Le, "f64.le", "65"),
    (I.F64Lt, "f64.lt", "63"),
    (I.F64Max, "f64.max", "a5"),
    (I.F64Min, "f64.min", "a4"),
    (I.F64Mul, "f64.mul", "a2"),
    (I.F64Ne, "f64.ne", "62"),
    (I.F64Nearest, "f64.nearest", "9e"),
    (I.F64Neg, "f64.neg", "9a"),
    (I.F64PromoteF32, "f64.promote_f32", "bb"),
    (I.F64ReinterpretI64, "f64.reinterpret_i64", "bf"),
    (I.F64Sqrt, "f64.sqrt", "9f"),
    (I.F64Sub, "f64.sub", "a1"),
    (I.F64Trunc, "f64.trunc", "9d"),
    (I.I32Add, "i32.add", "6a"),
    (I.I32And, "i32.and", "71"),
    (I.I32Clz, "i32.clz", "67"),
    (I.I32Ctz, "i32.ctz", "68"),
    (I.I32DivS, "i32.div_s", "6d"),
    (I.I32DivU, "i32.div_u", "6e"),
    (I.I32Eq, "i32.eq", "46"),
    (I.I32Eqz, "i32.eqz", "45"),
    (I.I32Extend16S, "i32.extend16_s", "c1"),
    (I.I32Extend8S, "i32.extend8_s", "c0"),
    (I.I32GeS, "i32.ge_s", "4e"),
    (I.I32GeU, "i32.ge_u", "4f"),
    (I.I32GtS, "i32.gt_s", "4a"),
    (I.I32GtU, "i32.gt_u", "4b"),
    (I.I32LeS, "i32.le_s", "4c"),
    (I.I32LeU, "i32.le_u", "4d"),
    (I.I32LtS, "i32.lt_s", "48"),
    (I.I32LtU, "i32.lt_u", "49"),
    (I.I32Mul, "i32.mul", "6c"),
    (I.I32Ne, "i32.ne", "47"),
    (I.I32Or, "i32.or", "72"),
    (I.I32Popcnt, "i32.popcnt", "69"),
    (I.I32ReinterpretF32, "i32.reinterpret_f32", "bc"),
    (I.I32RemS, "i32.rem_s", "6f"),
    (I.I32RemU, "i32.rem_u", "70"),
    (I.I32Rotl, "i32.rotl", "77"),
    (I.I32Rotr, "i32.rotr", "78"),
    (I.I32Shl, "i32.shl", "74"),
    (I.I32ShrS, "i32.shr_s", "75"),
    (I.I32ShrU, "i32.shr_u", "76"),
    (I.I32Sub, "i32.sub", "6b"),
    (I.I32TruncF32S, "i32.trunc_f32_s", "a8"),
    (I.I32TruncF32U, "i32.trunc_f32_u", "a9"),
    (I.I32TruncF64S, "i32.trunc_f64_s", "aa"),
    (I.I32TruncF64U, "i32.trunc_f64_u", "ab"),
    (I.I32WrapI64, "i32.wrap_i64", "a7"),
    (I.I32Xor, "i32.xor", "73"),
    (I.I64Add, "i64.add", "7c"),
    (I.I64And, "i64.and", "83"),
    (I.I64Clz, "i64.clz", "79"),
    (I.I64Ctz, "i64.ctz", "7a"),
    (I.I64DivS, "i64.div_s", "7f"),
    (I.I64DivU, "i64.div_u", "80"),
    (I.I64Eq, "i64.eq", "51"),
    (I.I64Eqz, "i64.eqz", "50"),
    (I.I64Extend16S, "i64.extend16_s", "c3"),
    (I.I64Extend32S, "i64.extend32_s", "c4"),
    (I.I64Extend8S, "i64.extend8_s", "c2"),
    (I.I64ExtendI32S, "i64.extend_i32_s", "ac"),
    (I.I64ExtendI32U, "i64.extend_i32_u", "ad"),
    (I.I64GeS, "i64.ge_s", "59"),
    (I.I64GeU, "i64.ge_u", "5a"),
    (I.I64GtS, "i64.gt_s", "55"),
    (I.I64GtU, "i64.gt_u", "56"),
    (I.I64LeS, "i64.le_s", "57"),
    (I.I64LeU, "i64.le_u", "58"),
    (I.I64LtS, "i64.lt_s", "53"),
    (I.I64LtU, "i64.lt_u", "54"),
    (I.I64Mul, "i64.mul", "7e"),
    (I.I64Ne, "i64.ne", "52"),
    (I.I64Or, "i64.or", "84"),
    (I.I64Popcnt, "i64.popcnt", "7b"),
    (I.I64ReinterpretF64, "i64.reinterpret_f64", "bd"),
    (I.I64RemS, "i64.rem_s", "81"),
    (I.I64RemU, "i64.rem_u", "82"),
    (I.I64Rotl, "i64.rotl", "89"),
    (I.I64Rotr, "i64.rotr", "8a"),
    (I.I64Shl, "i64.shl", "86"),
    (I.I64ShrS, "i64.shr_s", "87"),
    (I.I64ShrU, "i64.shr_u", "88"),
    (I.I64Sub, "i64.sub", "7d"),
    (I.I64TruncF32S, "i64.trunc_f32_s", "ae"),
    (I.I64TruncF32U, "i64.trunc_f32_u", "af"),
    (I.I64TruncF64S, "i64.trunc_f64_s", "b0"),
    (I.I64TruncF64U, "i64.trunc_f64_u", "b1"),
    (I.I64Xor, "i64.xor", "85"),
    (I.Nop, "nop", "01"),
    (I.RefAsNonNull, "ref.as_non_null", "d4"),
    (I.RefEq, "ref.eq", "d3"),
    (I.RefIsNull, "ref.is_null", "d1"),
    (I.Return, "return", "0f"),
    (I.Unreachable, "unreachable", "00"),
    (I.ThrowRef, "throw_ref", "0a"),
]

# the instructions with immediates: each built, its bytes, the text that encodes to them
const IMMEDIATE = [
    (() -> I.BeginOneOutputBlock(I.NumType_i32), "027f"),  # block (result i32) end
    (() -> I.BeginFunctionBlock(FT4), "0204"),  # block (type 4) end
    (() -> I.BeginOneOutputLoop(I.RefType_any(nullable=true)), "036e"),  # loop (result anyref) end
    (() -> I.BeginFunctionLoop(FT4), "0304"),  # loop (type 4) end
    (() -> I.BeginOneOutputIf(I.NumType_f64), "047c"),  # if (result f64) end
    (() -> I.BeginFunctionIf(FT4), "0404"),  # if (type 4) end
    (() -> I.BeginOneOutputTry(I.NumType_i64), "067e"),  # try (result i64) end
    (() -> I.BeginFunctionTry(FT4), "0604"),  # try (type 4) end
    (() -> I.CatchLegacy(TG1), "0701"),  # try catch 1 end
    (() -> I.Throw(TG1), "0801"),  # throw 1
    (() -> I.Rethrow(0), "0900"),  # try catch_all rethrow 0 end
    (() -> I.Br(2), "0c02"),  # br 2
    (() -> I.BrIf(130), "0d8201"),  # br_if 130
    (() -> I.BrTable([0, 1, 200], 3), "0e030001c80103"),  # br_table 0 1 200 3
    (() -> I.Call(F0), "1000"),  # call 0
    (() -> I.CallIndirect(FT4, T1), "110401"),  # call_indirect 1 (type 4)
    (() -> I.CallIndirect(FT4, nothing), "110400"),  # call_indirect (type 4)
    (() -> I.CallRef(FT4), "1404"),  # call_ref 4
    (() -> I.SelectWithType(I.NumType_i64), "1c017e"),  # select (result i64)
    (() -> I.LocalGet(L3), "2003"),  # local.get 3
    (() -> I.LocalSet(L0), "2100"),  # local.set 0
    (() -> I.LocalTee(L3), "2203"),  # local.tee 3
    (() -> I.GlobalGet(G1), "2301"),  # global.get 1
    (() -> I.GlobalSet(G0), "2400"),  # global.set 0
    (() -> I.TableGet(T1), "2501"),  # table.get 1
    (() -> I.TableSet(T0), "2600"),  # table.set 0
    (() -> I.TableSize(T1), "fc1001"),  # table.size 1
    (() -> I.TableFill(T1), "fc1101"),  # table.fill 1
    (() -> I.I32Load(moa(M0, 4, 2)), "280204"),  # i32.load offset=4 align=4
    (() -> I.I64Load(moa(M1, 8, 3)), "29430108"),  # i64.load 1 offset=8 align=8
    (() -> I.F32Load(moa(M0, 0, 2)), "2a0200"),  # f32.load
    (() -> I.F64Load(moa(M0, 300, 3)), "2b03ac02"),  # f64.load offset=300
    (() -> I.I32Load8S(moa(M0, 1, 0)), "2c0001"),  # i32.load8_s offset=1
    (() -> I.I32Load8U(moa(M0, 0, 0)), "2d0000"),  # i32.load8_u
    (() -> I.I32Load16S(moa(M0, 0, 1)), "2e0100"),  # i32.load16_s
    (() -> I.I32Load16U(moa(M0, 0, 0)), "2f0000"),  # i32.load16_u align=1
    (() -> I.I64Load8S(moa(M0, 0, 0)), "300000"),  # i64.load8_s
    (() -> I.I64Load8U(moa(M0, 0, 0)), "310000"),  # i64.load8_u
    (() -> I.I64Load16S(moa(M0, 0, 1)), "320100"),  # i64.load16_s
    (() -> I.I64Load16U(moa(M0, 0, 1)), "330100"),  # i64.load16_u
    (() -> I.I64Load32S(moa(M0, 0, 2)), "340200"),  # i64.load32_s
    (() -> I.I64Load32U(moa(M0, 0, 2)), "350200"),  # i64.load32_u
    (() -> I.I32Store(moa(M0, 0, 2)), "360200"),  # i32.store
    (() -> I.I64Store(moa(M1, 0, 3)), "37430100"),  # i64.store 1
    (() -> I.F32Store(moa(M0, 0, 2)), "380200"),  # f32.store
    (() -> I.F64Store(moa(M0, 0, 3)), "390300"),  # f64.store
    (() -> I.I32Store8(moa(M0, 0, 0)), "3a0000"),  # i32.store8
    (() -> I.I32Store16(moa(M0, 0, 1)), "3b0100"),  # i32.store16
    (() -> I.I64Store8(moa(M0, 0, 0)), "3c0000"),  # i64.store8
    (() -> I.I64Store16(moa(M0, 0, 1)), "3d0100"),  # i64.store16
    (() -> I.I64Store32(moa(M0, 0, 2)), "3e0200"),  # i64.store32
    (() -> I.MemorySize(M1), "3f01"),  # memory.size 1
    (() -> I.MemoryGrow(M0), "4000"),  # memory.grow 0
    (() -> I.MemoryFill(M1), "fc0b01"),  # memory.fill 1
    (() -> I.I32Const(-1), "417f"),  # i32.const -1
    (() -> I.I32Const(2147483647), "41ffffffff07"),  # i32.const 2147483647
    (() -> I.I64Const(-9223372036854775808), "428080808080808080807f"),  # i64.const -9223372036854775808
    (() -> I.F32Const(1.5f0), "430000c03f"),  # f32.const 1.5
    (() -> I.F64Const(-0.25), "44000000000000d0bf"),  # f64.const -0.25
    (() -> I.RefNull(I.HeapType_none), "d071"),  # ref.null none
    (() -> I.RefNull(I.HeapType_noextern), "d072"),  # ref.null noextern
    (() -> I.RefNull(ST), "d001"),  # ref.null 1
    (() -> I.RefFunc(F0), "d200"),  # ref.func 0
    (() -> I.StructNew(ST), "fb0001"),  # struct.new 1
    (() -> I.StructNewDefault(ST), "fb0101"),  # struct.new_default 1
    (() -> I.StructGet(ST, 2), "fb020102"),  # struct.get 1 2
    (() -> I.StructGetS(ST, 1), "fb030101"),  # struct.get_s 1 1
    (() -> I.StructGetU(ST, 1), "fb040101"),  # struct.get_u 1 1
    (() -> I.StructSet(ST, 0), "fb050100"),  # struct.set 1 0
    (() -> I.ArrayNew(AT32), "fb0603"),  # array.new 3
    (() -> I.ArrayNewDefault(AT8), "fb0702"),  # array.new_default 2
    (() -> I.ArrayNewFixed(AT32, 3), "fb080303"),  # array.new_fixed 3 3
    (() -> I.ArrayNewData(AT8, D1), "fb090201"),  # array.new_data 2 1
    (() -> I.ArrayGet(AT32), "fb0b03"),  # array.get 3
    (() -> I.ArrayGetS(AT8), "fb0c02"),  # array.get_s 2
    (() -> I.ArrayGetU(AT8), "fb0d02"),  # array.get_u 2
    (() -> I.ArraySet(AT32), "fb0e03"),  # array.set 3
    (() -> I.ArrayFill(AT8), "fb1002"),  # array.fill 2
    (() -> I.ArrayCopy(dest_array_type=AT8, source_array_type=AT8), "fb110202"),  # array.copy 2 2
    (() -> I.RefTest(I.RefType_struct(nullable=false)), "fb146b"),  # ref.test (ref struct)
    (() -> I.RefTest(I.RefType_def(ST; nullable=true)), "fb1501"),  # ref.test (ref null 1)
    (() -> I.RefCast(I.RefType_i31(nullable=false)), "fb166c"),  # ref.cast (ref i31)
    (() -> I.RefCast(I.RefType_def(AT8; nullable=true)), "fb1702"),  # ref.cast (ref null 2)
    (() -> I.BrOnNull(1), "d501"),  # br_on_null 1
    (() -> I.BrOnNonNull(0), "d600"),  # br_on_non_null 0
    (() -> I.BrOnCast(0, I.RefType_any(nullable=true), I.RefType_def(ST; nullable=false)), "fb1801006e01"),  # br_on_cast 0 anyref (ref 1)
    (() -> I.BrOnCast(1, I.RefType_any(nullable=true), I.RefType_def(ST; nullable=true)), "fb1803016e01"),  # br_on_cast 1 anyref (ref null 1)
    (() -> I.BrOnCastFail(0, I.RefType_eq(nullable=false), I.RefType_i31(nullable=false)), "fb1900006d6c"),  # br_on_cast_fail 0 (ref eq) (ref i31)
    (() -> I.BeginNoEffectTryTable(I.TryTableCatch[I.Catch(TG1, 0), I.CatchRef(TG0, 1), I.CatchAll(2), I.CatchAllRef(3)]), "1f400400010001000102020303"),  # try_table (catch 1 0) (catch_ref 0 1) (catch_all 2) (catch_all_ref 3) end
    (() -> I.BeginOneOutputTryTable(I.NumType_i32, I.TryTableCatch[I.CatchAll(0)]), "1f7f010200"),  # try_table (result i32) (catch_all 0) end
    (() -> I.BeginFunctionTryTable(FT4, I.TryTableCatch[]), "1f0400"),  # try_table (type 4) end
    (() -> I.V128Const(UInt8[1:16;]), "fd0c0102030405060708090a0b0c0d0e0f10"),  # v128.const i8x16 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16
    (() -> I.I8x16Shuffle([0:15;]), "fd0d000102030405060708090a0b0c0d0e0f"),  # i8x16.shuffle 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
    (() -> I.I8x16ExtractLaneS(15), "fd150f"),  # i8x16.extract_lane_s 15
    (() -> I.I8x16ExtractLaneU(1), "fd1601"),  # i8x16.extract_lane_u 1
    (() -> I.I8x16ReplaceLane(2), "fd1702"),  # i8x16.replace_lane 2
    (() -> I.I16x8ExtractLaneS(7), "fd1807"),  # i16x8.extract_lane_s 7
    (() -> I.I16x8ExtractLaneU(0), "fd1900"),  # i16x8.extract_lane_u 0
    (() -> I.I16x8ReplaceLane(3), "fd1a03"),  # i16x8.replace_lane 3
    (() -> I.I32x4ExtractLane(3), "fd1b03"),  # i32x4.extract_lane 3
    (() -> I.I32x4ReplaceLane(0), "fd1c00"),  # i32x4.replace_lane 0
    (() -> I.I64x2ExtractLane(1), "fd1d01"),  # i64x2.extract_lane 1
    (() -> I.I64x2ReplaceLane(0), "fd1e00"),  # i64x2.replace_lane 0
    (() -> I.F32x4ExtractLane(2), "fd1f02"),  # f32x4.extract_lane 2
    (() -> I.F32x4ReplaceLane(1), "fd2001"),  # f32x4.replace_lane 1
    (() -> I.F64x2ExtractLane(1), "fd2101"),  # f64x2.extract_lane 1
    (() -> I.F64x2ReplaceLane(0), "fd2200"),  # f64x2.replace_lane 0
    (() -> I.V128Instruction_f32x4_abs, "fde001"),  # f32x4.abs
    (() -> I.V128Instruction_f32x4_add, "fde401"),  # f32x4.add
    (() -> I.V128Instruction_f32x4_ceil, "fd67"),  # f32x4.ceil
    (() -> I.V128Instruction_f32x4_div, "fde701"),  # f32x4.div
    (() -> I.V128Instruction_f32x4_eq, "fd41"),  # f32x4.eq
    (() -> I.V128Instruction_f32x4_floor, "fd68"),  # f32x4.floor
    (() -> I.V128Instruction_f32x4_ge, "fd46"),  # f32x4.ge
    (() -> I.V128Instruction_f32x4_gt, "fd44"),  # f32x4.gt
    (() -> I.V128Instruction_f32x4_le, "fd45"),  # f32x4.le
    (() -> I.V128Instruction_f32x4_lt, "fd43"),  # f32x4.lt
    (() -> I.V128Instruction_f32x4_max, "fde901"),  # f32x4.max
    (() -> I.V128Instruction_f32x4_min, "fde801"),  # f32x4.min
    (() -> I.V128Instruction_f32x4_mul, "fde601"),  # f32x4.mul
    (() -> I.V128Instruction_f32x4_ne, "fd42"),  # f32x4.ne
    (() -> I.V128Instruction_f32x4_nearest, "fd6a"),  # f32x4.nearest
    (() -> I.V128Instruction_f32x4_neg, "fde101"),  # f32x4.neg
    (() -> I.V128Instruction_f32x4_p_max, "fdeb01"),  # f32x4.pmax
    (() -> I.V128Instruction_f32x4_p_min, "fdea01"),  # f32x4.pmin
    (() -> I.V128Instruction_f32x4_splat, "fd13"),  # f32x4.splat
    (() -> I.V128Instruction_f32x4_sqrt, "fde301"),  # f32x4.sqrt
    (() -> I.V128Instruction_f32x4_sub, "fde501"),  # f32x4.sub
    (() -> I.V128Instruction_f32x4_trunc, "fd69"),  # f32x4.trunc
    (() -> I.V128Instruction_f64x2_abs, "fdec01"),  # f64x2.abs
    (() -> I.V128Instruction_f64x2_add, "fdf001"),  # f64x2.add
    (() -> I.V128Instruction_f64x2_ceil, "fd74"),  # f64x2.ceil
    (() -> I.V128Instruction_f64x2_div, "fdf301"),  # f64x2.div
    (() -> I.V128Instruction_f64x2_eq, "fd47"),  # f64x2.eq
    (() -> I.V128Instruction_f64x2_floor, "fd75"),  # f64x2.floor
    (() -> I.V128Instruction_f64x2_ge, "fd4c"),  # f64x2.ge
    (() -> I.V128Instruction_f64x2_gt, "fd4a"),  # f64x2.gt
    (() -> I.V128Instruction_f64x2_le, "fd4b"),  # f64x2.le
    (() -> I.V128Instruction_f64x2_lt, "fd49"),  # f64x2.lt
    (() -> I.V128Instruction_f64x2_max, "fdf501"),  # f64x2.max
    (() -> I.V128Instruction_f64x2_min, "fdf401"),  # f64x2.min
    (() -> I.V128Instruction_f64x2_mul, "fdf201"),  # f64x2.mul
    (() -> I.V128Instruction_f64x2_ne, "fd48"),  # f64x2.ne
    (() -> I.V128Instruction_f64x2_nearest, "fd9401"),  # f64x2.nearest
    (() -> I.V128Instruction_f64x2_neg, "fded01"),  # f64x2.neg
    (() -> I.V128Instruction_f64x2_p_max, "fdf701"),  # f64x2.pmax
    (() -> I.V128Instruction_f64x2_p_min, "fdf601"),  # f64x2.pmin
    (() -> I.V128Instruction_f64x2_splat, "fd14"),  # f64x2.splat
    (() -> I.V128Instruction_f64x2_sqrt, "fdef01"),  # f64x2.sqrt
    (() -> I.V128Instruction_f64x2_sub, "fdf101"),  # f64x2.sub
    (() -> I.V128Instruction_f64x2_trunc, "fd7a"),  # f64x2.trunc
    (() -> I.V128Instruction_i16x8_add, "fd8e01"),  # i16x8.add
    (() -> I.V128Instruction_i16x8_all_true, "fd8301"),  # i16x8.all_true
    (() -> I.V128Instruction_i16x8_bitmask, "fd8401"),  # i16x8.bitmask
    (() -> I.V128Instruction_i16x8_eq, "fd2d"),  # i16x8.eq
    (() -> I.V128Instruction_i16x8_mul, "fd9501"),  # i16x8.mul
    (() -> I.V128Instruction_i16x8_neg, "fd8101"),  # i16x8.neg
    (() -> I.V128Instruction_i16x8_splat, "fd10"),  # i16x8.splat
    (() -> I.V128Instruction_i16x8_sub, "fd9101"),  # i16x8.sub
    (() -> I.V128Instruction_i32x4_add, "fdae01"),  # i32x4.add
    (() -> I.V128Instruction_i32x4_all_true, "fda301"),  # i32x4.all_true
    (() -> I.V128Instruction_i32x4_bitmask, "fda401"),  # i32x4.bitmask
    (() -> I.V128Instruction_i32x4_dot_i16x8, "fdba01"),  # i32x4.dot_i16x8_s
    (() -> I.V128Instruction_i32x4_eq, "fd37"),  # i32x4.eq
    (() -> I.V128Instruction_i32x4_mul, "fdb501"),  # i32x4.mul
    (() -> I.V128Instruction_i32x4_neg, "fda101"),  # i32x4.neg
    (() -> I.V128Instruction_i32x4_splat, "fd11"),  # i32x4.splat
    (() -> I.V128Instruction_i32x4_sub, "fdb101"),  # i32x4.sub
    (() -> I.V128Instruction_i64x2_add, "fdce01"),  # i64x2.add
    (() -> I.V128Instruction_i64x2_all_true, "fdc301"),  # i64x2.all_true
    (() -> I.V128Instruction_i64x2_bitmask, "fdc401"),  # i64x2.bitmask
    (() -> I.V128Instruction_i64x2_eq, "fdd601"),  # i64x2.eq
    (() -> I.V128Instruction_i64x2_mul, "fdd501"),  # i64x2.mul
    (() -> I.V128Instruction_i64x2_neg, "fdc101"),  # i64x2.neg
    (() -> I.V128Instruction_i64x2_splat, "fd12"),  # i64x2.splat
    (() -> I.V128Instruction_i64x2_sub, "fdd101"),  # i64x2.sub
    (() -> I.V128Instruction_i8x16_add, "fd6e"),  # i8x16.add
    (() -> I.V128Instruction_i8x16_all_true, "fd63"),  # i8x16.all_true
    (() -> I.V128Instruction_i8x16_bitmask, "fd64"),  # i8x16.bitmask
    (() -> I.V128Instruction_i8x16_eq, "fd23"),  # i8x16.eq
    (() -> I.V128Instruction_i8x16_neg, "fd61"),  # i8x16.neg
    (() -> I.V128Instruction_i8x16_splat, "fd0f"),  # i8x16.splat
    (() -> I.V128Instruction_i8x16_sub, "fd71"),  # i8x16.sub
    (() -> I.V128Instruction_v128_and, "fd4e"),  # v128.and
    (() -> I.V128Instruction_v128_and_not, "fd4f"),  # v128.andnot
    (() -> I.V128Instruction_v128_any_true, "fd53"),  # v128.any_true
    (() -> I.V128Instruction_v128_bit_select, "fd52"),  # v128.bitselect
    (() -> I.V128Instruction_v128_not, "fd4d"),  # v128.not
    (() -> I.V128Instruction_v128_or, "fd50"),  # v128.or
    (() -> I.V128Instruction_v128_xor, "fd51"),  # v128.xor
]

@testset "wasm_builder's IR is byte-identical with wasm-tools" begin
    @testset "every instruction without an immediate" begin
        for (T, name, hex) in FIELDLESS
            @test (T, W.name(T())) == (T, name)
            @test (T, bytes2hex(bytes_of(T()))) == (T, hex)
        end
    end
    @testset "the instructions with immediates" begin
        for (make, hex) in IMMEDIATE
            local x = make()
            @test (x, bytes2hex(bytes_of(x))) == (x, hex)
        end
    end
    @testset "an empty module" begin
        # (module $m): dart's NameSection writes the module-name subsection's id even without a
        # name (sections.dart:936); with a name it is the subsection wasm-tools writes for `$m`
        @test bytes2hex(bytes_of(ir_module(types = I.Types(Vector{I.DefType}[])))) == "0061736d010000000009046e616d650002016d"
    end
    @testset "types, an import, a function, a memory, a table, a global, exports" begin
        local m = I.Module_uninitialized()
        local add = I.FunctionType(I.ValueType[I.NumType_i32, I.NumType_i32], I.ValueType[I.NumType_i32])
        local log = I.FunctionType(I.ValueType[I.NumType_i64], I.ValueType[])
        local point = I.StructType("Point"; fields = [I.FieldType(I.NumType_i32), I.FieldType(I.NumType_f64; mutable = false)])
        local imp = I.ImportedFunction(m, "env", "log", fidx(0), log)
        local mem = I.DefinedMemory(m, fidx(0), false, 1, 2)
        local tab = I.DefinedTable(m, fidx(0), I.RefType_func(nullable = true), 4, nothing)
        local g = I.DefinedGlobal(m, code(I.Local[], [I.I32Const(42), I.End()]), fidx(0), I.GlobalType(I.NumType_i32))
        local p0, p1, t = I.Local(0, I.NumType_i32), I.Local(1, I.NumType_i32), I.Local(2, I.NumType_i64)
        local f = I.DefinedFunction(m, code(I.Local[p0, p1, t], [
                I.LocalGet(p0), I.LocalGet(p1), I.I32Add(),
                I.I64Const(-7), I.LocalTee(t), I.Call(imp),
                I.GlobalGet(g), I.I32Add(),
                I.I32Const(8), I.I32Load(moa(mem, 4, 2)), I.I32Add(),
                I.End()]), fidx(1), add)
        ir_module(; types = I.Types([I.DefType[add], I.DefType[log], I.DefType[point]]), imported_functions = [imp],
                  defined_functions = [f], tables = [tab], memories = [mem], globals = [g],
                  exports = I.Export[I.FunctionExport("add", f), I.MemoryExport("mem", mem)], m)
        # (module $m
        #   (type (func (param i32 i32) (result i32)))
        #   (type (func (param i64)))
        #   (type $Point (struct (field (mut i32)) (field f64)))
        #   (import "env" "log" (func (type 1)))
        #   (table 4 funcref)
        #   (memory 1 2)
        #   (global (mut i32) (i32.const 42))
        #   (export "add" (func 1))
        #   (export "mem" (memory 0))
        #   (func (type 0) (param i32 i32) (result i32) (local i64)
        #     local.get 0  local.get 1  i32.add  i64.const -7  local.tee 2  call 0
        #     global.get 0  i32.add  i32.const 8  i32.load offset=4 align=4  i32.add))
        @test bytes2hex(bytes_of(m)) == "0061736d0100000001110360027f7f017f60017e005f027f017c00020b0103656e76036c6f670001030201000404017000040504010101020606017f01412a0b070d02036164640001036d656d02000a1a011801017e200020016a42792202100023006a41082802046a0b0013046e616d650002016d0408010205506f696e74"
    end
    # a part's debugging name numbers it within its module, from 0 on its first read (Indexable's
    # `_id = _globalId++`, the counter the enclosing module holds, A42S4)
    @testset "each module numbers its own parts" begin
        local ms = (I.Module_uninitialized(), I.Module_uninitialized())
        local names = [W.name(I.DefinedTable(m, fidx(k), I.RefType_func(nullable = true), 1, nothing)) for m in ms for k in 0:1]
        @test names == ["0", "1", "0", "1"]
    end
    # Serializer.write takes each class dart's Serializable names (A42S5): the load checks it, and a
    # write that takes Serializable's subtypes alone misses the implementors Julia cannot place there
    @testset "Serializer.write takes every Serializable implementor" begin
        local sdk = WasmTarget._pin_sdk()
        @test sdk !== nothing
        if sdk !== nothing
            @test WasmTarget.check_serializable_writable(W.serialize, Base.write, W.Serializer, sdk) == 0
            narrow(s::W.Serializer, o::W.Serializable) = nothing
            local why = try
                WasmTarget.check_serializable_writable(W.serialize, narrow, W.Serializer, sdk); ""
            catch e
                e isa WasmTarget.ConstructionViolation ? e.what : rethrow()
            end
            @test occursin("DefinedFunction implements Serializable", why)
            @test occursin("ActiveFunctionElementSegment implements Serializable", why)
            @test !occursin("Catch", why)      # dart's TryTableCatch serializes but is not Serializable
        end
    end
end

end # module IRModulesTest
