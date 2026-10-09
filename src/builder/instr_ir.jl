# Instruction IR — the dart2wasm `ir/instructions.dart` layer, 1:1.
#
# dart2wasm models every wasm instruction as a subclass of an abstract `Instruction`,
# each overriding `serialize(Serializer)` (writes its own bytes) and `printTo(IrPrinter)`
# (symbolic WAT). This is that, natively: a sealed `WasmInstr` hierarchy, one immutable
# struct per instruction, with per-class `encode!` (= serialize) and `mnemonic` (= printTo)
# defined by multiple dispatch in the parent module.
#
# Why native dispatch, not Moshi @data/@match: dart2wasm uses per-class virtual methods,
# whose 1:1 Julia map is per-type dispatch — `encode!(code, ::I32Const)` — NOT a giant
# match. It's also dependency-free (matters for the freeze/notarize story). The structs
# carry Base-typed fields, and a block's type is the builder's value-type union (the one
# parent binding this submodule reads, as dart's instruction carries a typed w.BlockType).
#
# The InstrBuilder produces a `Vector{WasmInstr}` (the ir/ layer); `builder_code`
# serializes it (the serialize/ layer). One representation, no parallel byte path.

module InstrIR

using ..WasmTarget: WasmValType

# The void block type: a frame with no inputs and no outputs (encoded 0x40).
# parity(pkg/wasm_builder/lib/src/ir/instruction.dart:642 BeginNoEffectBlock)
struct VoidBlock end
# parity(pkg/wasm_builder/lib/src/ir/instruction.dart:642 BeginNoEffectBlock)
const VOID_BLOCK = VoidBlock()
# A block's type: void, the one output's value type, or a function-type index for a multi-value
# frame (an Int, encoded s33).
# parity(pkg/wasm_builder/lib/src/ir/instruction.dart:642 BeginNoEffectBlock): the typed blocktype
const BlockTypeArg = Union{VoidBlock, WasmValType, Int}

# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:11 Instruction)
abstract type WasmInstr end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:11 Instruction)

# ── numeric / const ──────────────────────────────────────────────────────────────
struct I32Const <: WasmInstr; value::Int64; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:3053 I32Const)
struct I64Const <: WasmInstr; value::Int64; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:3075 I64Const)
struct F32Const <: WasmInstr; value::Float32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:3097 F32Const)
struct F64Const <: WasmInstr; value::Float64; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:3119 F64Const)
# end parity-region
# parity(pkg/wasm_builder/lib/src/ir/instruction.dart:615 SingleByteInstruction)
struct NumOp    <: WasmInstr; op::UInt8; end   # generic no-immediate numeric/cmp/conv op
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:11 Instruction)

# ── parametric ───────────────────────────────────────────────────────────────────
struct Drop   <: WasmInstr; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:1291 Drop)
struct Select <: WasmInstr; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:1300 Select)
# Typed select (0x1C): its one result value type, written as every value type is (dart
# SelectWithType writes 0x1C, vec-len 1, then `write(type)`).
struct SelectWithType <: WasmInstr; type::WasmValType; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:1319 SelectWithType)

# ── variable ─────────────────────────────────────────────────────────────────────
struct LocalGet  <: WasmInstr; idx::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:1350 LocalGet)
struct LocalSet  <: WasmInstr; idx::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:1376 LocalSet)
struct LocalTee  <: WasmInstr; idx::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:1402 LocalTee)
struct GlobalGet <: WasmInstr; idx::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:1428 GlobalGet)
struct GlobalSet <: WasmInstr; idx::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:1457 GlobalSet)

# ── control flow ─────────────────────────────────────────────────────────────────
struct Unreachable <: WasmInstr; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:624 Unreachable)
struct Nop         <: WasmInstr; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:633 Nop)
struct Block <: WasmInstr; blocktype::BlockTypeArg; end   # blocktype: void, a WasmValType, or a type index; parity(pkg/wasm_builder/lib/src/ir/instruction.dart:642 BeginNoEffectBlock)
struct Loop  <: WasmInstr; blocktype::BlockTypeArg; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:733 BeginNoEffectLoop)
struct If    <: WasmInstr; blocktype::BlockTypeArg; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:821 BeginNoEffectIf)
struct Else  <: WasmInstr; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:899 Else)
struct End   <: WasmInstr; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:1096 End)
struct Br    <: WasmInstr; depth::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:1110 Br)
struct BrIf  <: WasmInstr; depth::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:1134 BrIf)
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:11 Instruction)
struct Return  <: WasmInstr; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:1193 Return)
struct Call    <: WasmInstr; idx::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:1202 Call)
struct CallIndirect <: WasmInstr; type_idx::UInt32; table_idx::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:1228 CallIndirect)
# call_ref (Wasm GC, 0x14): a typed call through a (ref $type) on the stack.
# dart2wasm CallRef.serialize writes 0x14 + writeTypeIndex(type) (unsigned LEB type idx).
struct CallRef <: WasmInstr; type_idx::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:1262 CallRef)
# end parity-region
# br_on_null (0xD5) / br_on_non_null (0xD6): branch on the nullability of the top ref.
# parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2195 BrOnNull)
struct BrOnNull    <: WasmInstr; depth::UInt32; end
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:11 Instruction)
struct BrOnNonNull <: WasmInstr; depth::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2228 BrOnNonNull)

# ── exception handling (legacy, the form dart2wasm emits) ─────────────────────────
# a legacy try: a block opener whose type is a block's (void, one value type or a function-type
# index), as dart's BeginNoEffectTry, BeginOneOutputTry and BeginFunctionTry are one opener each
struct BeginTry <: WasmInstr; blocktype::BlockTypeArg; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:908 BeginNoEffectTry)
struct CatchLegacy <: WasmInstr; tag::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:997 CatchLegacy)
struct Throw    <: WasmInstr; tag::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:1032 Throw)
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:11 Instruction)

# ── reference ────────────────────────────────────────────────────────────────────
# ref.null with an abstract heaptype: heaptype_byte is the raw on-wire byte (e.g. 0x6E any).
struct RefNullAbstract <: WasmInstr; heaptype_byte::UInt8; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2111 RefNull)
# ref.null with a concrete type index: encoded as a signed-LEB heaptype.
struct RefNullConcrete <: WasmInstr; heaptype::Int64; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2111 RefNull)
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:11 Instruction)
struct RefIsNull    <: WasmInstr; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2146 RefIsNull)
struct RefAsNonNull <: WasmInstr; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2186 RefAsNonNull)
struct RefEq        <: WasmInstr; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2219 RefEq)
struct RefFunc      <: WasmInstr; idx::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2155 RefFunc)

# ── GC ───────────────────────────────────────────────────────────────────────────
struct StructNew        <: WasmInstr; idx::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2393 StructNew)
struct StructNewDefault <: WasmInstr; idx::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2426 StructNewDefault)
struct StructGet <: WasmInstr; idx::UInt32; field::UInt32; op::UInt8; end  # op = STRUCT_GET/_S/_U; parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2253 StructGet)
struct StructSet <: WasmInstr; idx::UInt32; field::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2358 StructSet)
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:11 Instruction)
struct ArrayNewDefault <: WasmInstr; idx::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2666 ArrayNewDefault)
struct ArrayNewFixed   <: WasmInstr; idx::UInt32; n::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2594 ArrayNewFixed)
struct ArrayNewData    <: WasmInstr; idx::UInt32; seg::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2699 ArrayNewData)
struct ArrayGet <: WasmInstr; idx::UInt32; op::UInt8; end   # op = ARRAY_GET/_S/_U; parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2459 ArrayGet)
struct ArraySet <: WasmInstr; idx::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2549 ArraySet)
struct ArrayLen  <: WasmInstr; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2579 ArrayLen)
struct ArrayCopy <: WasmInstr; dst::UInt32; src::UInt32; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2739 ArrayCopy)
# end parity-region
# parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2776 ArrayFill)
struct ArrayFill <: WasmInstr; idx::UInt32; end
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:11 Instruction)
# ref.cast to a concrete type index (signed-LEB heaptype) vs an abstract heaptype byte.
struct RefCastConcrete <: WasmInstr; idx::Int64; nullable::Bool; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2883 RefCast)
struct RefCastAbstract <: WasmInstr; heaptype_byte::UInt8; nullable::Bool; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2883 RefCast)
struct RefTest <: WasmInstr; idx::Int64; nullable::Bool; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2854 RefTest)
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:11 Instruction)
struct AnyConvertExtern <: WasmInstr; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:3013 ExternInternalize)
struct ExternConvertAny <: WasmInstr; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:3033 ExternExternalize)
# end parity-region

# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:11 Instruction)

# ── saturating truncation (0xFC prefix, sub-op 0x00–0x07) ────────────────────────
# float → int, clamping out-of-range/NaN instead of trapping. `sub_op` is the FC sub-op.
struct TruncSat <: WasmInstr; sub_op::UInt8; end  # parity(pkg/wasm_builder/lib/src/ir/instruction.dart:4321 I32TruncSatF32S)

# end parity-region

# May the instruction appear in a constant expression (a global's initializer)? The constants,
# global.get, ref.null, ref.func, the allocations of a struct or an array of given elements,
# the extern conversions and end; every other instruction is not.
# parity(pkg/wasm_builder/lib/src/ir/instruction.dart:29 Instruction.isConstant)
is_constant(::WasmInstr)::Bool = false
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:29 Instruction.isConstant): each
# class dart marks `isConstant => true` (End :1100, GlobalGet :1438, RefNull :2127, RefFunc :2167,
# StructNew :2406, StructNewDefault :2439, ArrayNewFixed :2611, ArrayNewDefault :2679,
# ExternInternalize :3027, ExternExternalize :3047, the four consts :3063-:3129)
is_constant(::Union{End, GlobalGet, RefNullAbstract, RefNullConcrete, RefFunc, StructNew,
                    StructNewDefault, ArrayNewFixed, ArrayNewDefault, AnyConvertExtern,
                    ExternConvertAny, I32Const, I64Const, F32Const, F64Const})::Bool = true
# end parity-region

end # module InstrIR

# ── serialize layer (dart2wasm serialize/) + printTo, by multiple dispatch ─────────
import .InstrIR: I32Const, I64Const, F32Const, F64Const, NumOp, Drop, Select, SelectWithType,
    LocalGet, LocalSet, LocalTee, GlobalGet, GlobalSet,
    Unreachable, Nop, Block, Loop, If, Else, End, Br, BrIf, Return, Call, CallIndirect,
    CallRef, BrOnNull, BrOnNonNull,
    BeginTry, CatchLegacy, Throw,
    RefNullAbstract, RefNullConcrete, RefIsNull, RefAsNonNull, RefEq, RefFunc,
    StructNew, StructNewDefault, StructGet, StructSet,
    ArrayNewDefault, ArrayNewFixed, ArrayNewData, ArrayGet, ArraySet, ArrayLen, ArrayCopy, ArrayFill,
    RefCastConcrete, RefCastAbstract, RefTest, AnyConvertExtern, ExternConvertAny,
    TruncSat

# encode!(code, instr): append this instruction's exact on-wire bytes (dart2wasm `serialize`).
# parity(pkg/wasm_builder/lib/src/serialize/serializer.dart:69 Serializer.writeUnsigned)
@inline _u!(code::Vector{UInt8}, n::Integer)::Vector{UInt8} = append!(code, encode_leb128_unsigned(n))
# parity(pkg/wasm_builder/lib/src/serialize/serializer.dart:61 Serializer.writeSigned)
@inline _s!(code::Vector{UInt8}, n::Integer)::Vector{UInt8} = append!(code, encode_leb128_signed(n))

# parity(pkg/wasm_builder/lib/src/serialize/serializer.dart:12 Serializable.serialize)
# parity-region(pkg/wasm_builder/lib/src/serialize/serializer.dart:12 Serializable.serialize)
encode!(c::Vector{UInt8}, i::I32Const)::Vector{UInt8} = (push!(c, Opcode.I32_CONST); _s!(c, i.value))
encode!(c::Vector{UInt8}, i::I64Const)::Vector{UInt8} = (push!(c, Opcode.I64_CONST); _s!(c, i.value))
encode!(c::Vector{UInt8}, i::F32Const)::Vector{UInt8} = (push!(c, Opcode.F32_CONST); append!(c, reinterpret(UInt8, [i.value])))
encode!(c::Vector{UInt8}, i::F64Const)::Vector{UInt8} = (push!(c, Opcode.F64_CONST); append!(c, reinterpret(UInt8, [i.value])))
# end parity-region
# parity(pkg/wasm_builder/lib/src/ir/instruction.dart:621 SingleByteInstruction.serialize)
encode!(c::Vector{UInt8}, i::NumOp)::Vector{UInt8}    = push!(c, i.op)
# parity-region(pkg/wasm_builder/lib/src/serialize/serializer.dart:12 Serializable.serialize)
encode!(c::Vector{UInt8}, ::Drop)::Vector{UInt8}      = push!(c, Opcode.DROP)
encode!(c::Vector{UInt8}, ::Select)::Vector{UInt8}    = push!(c, Opcode.SELECT)
# select (typed): 0x1C, vec-len 1, then the result valtype bytes (dart2wasm SelectWithType).
encode!(c::Vector{UInt8}, i::SelectWithType)::Vector{UInt8} = (push!(c, Opcode.SELECT_T); _u!(c, 1); write_valtype!(WasmWriter(c), i.type); c)
encode!(c::Vector{UInt8}, i::LocalGet)::Vector{UInt8}  = (push!(c, Opcode.LOCAL_GET);  _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::LocalSet)::Vector{UInt8}  = (push!(c, Opcode.LOCAL_SET);  _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::LocalTee)::Vector{UInt8}  = (push!(c, Opcode.LOCAL_TEE);  _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::GlobalGet)::Vector{UInt8} = (push!(c, Opcode.GLOBAL_GET); _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::GlobalSet)::Vector{UInt8} = (push!(c, Opcode.GLOBAL_SET); _u!(c, i.idx))
encode!(c::Vector{UInt8}, ::Unreachable)::Vector{UInt8} = push!(c, Opcode.UNREACHABLE)
encode!(c::Vector{UInt8}, ::Nop)::Vector{UInt8}         = push!(c, Opcode.NOP)
# A block type's bytes: void 0x40, the one output's value type written as every value type is
# (write_valtype!), or a function type's index as a signed LEB128 (dart's BeginNoEffect-,
# BeginOneOutput- and BeginFunctionBlock).
# parity(pkg/wasm_builder/lib/src/ir/instruction.dart:667 BeginOneOutputBlock)
function _block_type_bytes!(c::Vector{UInt8}, bt::InstrIR.BlockTypeArg)::Vector{UInt8}
    bt isa InstrIR.VoidBlock && return push!(c, 0x40)
    bt isa Int && return append!(c, encode_leb128_signed(Int64(bt)))
    write_valtype!(WasmWriter(c), bt)
    return c
end
encode!(c::Vector{UInt8}, i::Block)::Vector{UInt8} = (push!(c, Opcode.BLOCK); _block_type_bytes!(c, i.blocktype))
encode!(c::Vector{UInt8}, i::Loop)::Vector{UInt8}  = (push!(c, Opcode.LOOP);  _block_type_bytes!(c, i.blocktype))
encode!(c::Vector{UInt8}, i::If)::Vector{UInt8}    = (push!(c, Opcode.IF);    _block_type_bytes!(c, i.blocktype))
encode!(c::Vector{UInt8}, ::Else)::Vector{UInt8}   = push!(c, Opcode.ELSE)
encode!(c::Vector{UInt8}, ::End)::Vector{UInt8}    = push!(c, Opcode.END)
encode!(c::Vector{UInt8}, i::Br)::Vector{UInt8}    = (push!(c, Opcode.BR);    _u!(c, i.depth))
encode!(c::Vector{UInt8}, i::BrIf)::Vector{UInt8}  = (push!(c, Opcode.BR_IF); _u!(c, i.depth))
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/serialize/serializer.dart:12 Serializable.serialize)
encode!(c::Vector{UInt8}, ::Return)::Vector{UInt8} = push!(c, Opcode.RETURN)
encode!(c::Vector{UInt8}, i::Call)::Vector{UInt8}  = (push!(c, Opcode.CALL); _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::CallIndirect)::Vector{UInt8} = (push!(c, Opcode.CALL_INDIRECT); _u!(c, i.type_idx); _u!(c, i.table_idx))
encode!(c::Vector{UInt8}, i::CallRef)::Vector{UInt8}     = (push!(c, Opcode.CALL_REF); _u!(c, i.type_idx))
# end parity-region
# parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2203 BrOnNull.serialize)
encode!(c::Vector{UInt8}, i::BrOnNull)::Vector{UInt8}    = (push!(c, Opcode.BR_ON_NULL);     _u!(c, i.depth))
# parity-region(pkg/wasm_builder/lib/src/serialize/serializer.dart:12 Serializable.serialize)
encode!(c::Vector{UInt8}, i::BrOnNonNull)::Vector{UInt8} = (push!(c, Opcode.BR_ON_NON_NULL); _u!(c, i.depth))
# try: 0x06 then its block type (dart: `s.writeByte(0x06); s.write(type)`)
# parity(pkg/wasm_builder/lib/src/ir/instruction.dart:948 BeginOneOutputTry.serialize)
encode!(c::Vector{UInt8}, i::BeginTry)::Vector{UInt8} = (push!(c, Opcode.TRY); _block_type_bytes!(c, i.blocktype))
# catch: 0x07 then the tag's index (dart: `s.writeByte(0x07); s.writeUnsigned(tag.index)`)
# parity(pkg/wasm_builder/lib/src/ir/instruction.dart:1007 CatchLegacy.serialize)
encode!(c::Vector{UInt8}, i::CatchLegacy)::Vector{UInt8} = (push!(c, Opcode.CATCH_LEGACY); _u!(c, i.tag))
encode!(c::Vector{UInt8}, i::Throw)::Vector{UInt8}   = (push!(c, Opcode.THROW); _u!(c, i.tag))
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/serialize/serializer.dart:12 Serializable.serialize)
encode!(c::Vector{UInt8}, i::RefNullAbstract)::Vector{UInt8} = (push!(c, Opcode.REF_NULL); push!(c, i.heaptype_byte))
encode!(c::Vector{UInt8}, i::RefNullConcrete)::Vector{UInt8} = (push!(c, Opcode.REF_NULL); _s!(c, i.heaptype))
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/serialize/serializer.dart:12 Serializable.serialize)
encode!(c::Vector{UInt8}, ::RefIsNull)::Vector{UInt8}    = push!(c, Opcode.REF_IS_NULL)
encode!(c::Vector{UInt8}, ::RefAsNonNull)::Vector{UInt8} = push!(c, Opcode.REF_AS_NON_NULL)
encode!(c::Vector{UInt8}, ::RefEq)::Vector{UInt8}        = push!(c, Opcode.REF_EQ)
encode!(c::Vector{UInt8}, i::RefFunc)::Vector{UInt8}     = (push!(c, Opcode.REF_FUNC); _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::StructNew)::Vector{UInt8}        = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.STRUCT_NEW); _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::StructNewDefault)::Vector{UInt8} = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.STRUCT_NEW_DEFAULT); _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::StructGet)::Vector{UInt8} = (push!(c, Opcode.GC_PREFIX); push!(c, i.op); _u!(c, i.idx); _u!(c, i.field))
encode!(c::Vector{UInt8}, i::StructSet)::Vector{UInt8} = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.STRUCT_SET); _u!(c, i.idx); _u!(c, i.field))
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/serialize/serializer.dart:12 Serializable.serialize)
encode!(c::Vector{UInt8}, i::ArrayNewDefault)::Vector{UInt8} = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.ARRAY_NEW_DEFAULT); _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::ArrayNewFixed)::Vector{UInt8}   = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.ARRAY_NEW_FIXED); _u!(c, i.idx); _u!(c, i.n))
encode!(c::Vector{UInt8}, i::ArrayNewData)::Vector{UInt8}    = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.ARRAY_NEW_DATA); _u!(c, i.idx); _u!(c, i.seg))
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/serialize/serializer.dart:12 Serializable.serialize)
encode!(c::Vector{UInt8}, i::ArrayGet)::Vector{UInt8} = (push!(c, Opcode.GC_PREFIX); push!(c, i.op); _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::ArraySet)::Vector{UInt8} = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.ARRAY_SET); _u!(c, i.idx))
encode!(c::Vector{UInt8}, ::ArrayLen)::Vector{UInt8}  = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.ARRAY_LEN))
encode!(c::Vector{UInt8}, i::ArrayCopy)::Vector{UInt8} = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.ARRAY_COPY); _u!(c, i.dst); _u!(c, i.src))
# end parity-region
# parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2789 ArrayFill.serialize)
encode!(c::Vector{UInt8}, i::ArrayFill)::Vector{UInt8} = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.ARRAY_FILL); _u!(c, i.idx))
# parity-region(pkg/wasm_builder/lib/src/serialize/serializer.dart:12 Serializable.serialize)
encode!(c::Vector{UInt8}, i::RefCastConcrete)::Vector{UInt8} = (push!(c, Opcode.GC_PREFIX); push!(c, i.nullable ? Opcode.REF_CAST_NULL : Opcode.REF_CAST); _s!(c, i.idx))
encode!(c::Vector{UInt8}, i::RefCastAbstract)::Vector{UInt8} = (push!(c, Opcode.GC_PREFIX); push!(c, i.nullable ? Opcode.REF_CAST_NULL : Opcode.REF_CAST); push!(c, i.heaptype_byte))
encode!(c::Vector{UInt8}, i::RefTest)::Vector{UInt8} = (push!(c, Opcode.GC_PREFIX); push!(c, i.nullable ? Opcode.REF_TEST_NULL : Opcode.REF_TEST); _s!(c, i.idx))
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/serialize/serializer.dart:12 Serializable.serialize)
encode!(c::Vector{UInt8}, ::AnyConvertExtern)::Vector{UInt8} = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.ANY_CONVERT_EXTERN))
encode!(c::Vector{UInt8}, ::ExternConvertAny)::Vector{UInt8} = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.EXTERN_CONVERT_ANY))
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/serialize/serializer.dart:12 Serializable.serialize)
encode!(c::Vector{UInt8}, i::TruncSat)::Vector{UInt8} = (push!(c, Opcode.FC_PREFIX); _u!(c, UInt32(i.sub_op)))
# end parity-region

# mnemonic(instr): symbolic WAT-ish text (dart2wasm `printTo`) — for builder_disasm and the
# WT_BUILDER_TRACE disassembly. Clarity for tracking codegen bugs without a hex round-trip.
# parity(pkg/wasm_builder/lib/src/ir/instruction.dart:37 Instruction.printTo)
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:37 Instruction.printTo)
mnemonic(i::I32Const)::String = "i32.const $(i.value)"
mnemonic(i::I64Const)::String = "i64.const $(i.value)"
mnemonic(i::F32Const)::String = "f32.const $(i.value)"
mnemonic(i::F64Const)::String = "f64.const $(i.value)"
# end parity-region
# parity(pkg/wasm_builder/lib/src/ir/instruction.dart:37 Instruction.printTo)
mnemonic(i::NumOp)::String    = "num 0x$(string(i.op, base=16))"
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:37 Instruction.printTo)
mnemonic(::Drop)::String   = "drop"
mnemonic(::Select)::String = "select"
mnemonic(i::SelectWithType)::String = "select (result $(i.type))"
mnemonic(i::LocalGet)::String  = "local.get $(i.idx)"
mnemonic(i::LocalSet)::String  = "local.set $(i.idx)"
mnemonic(i::LocalTee)::String  = "local.tee $(i.idx)"
mnemonic(i::GlobalGet)::String = "global.get $(i.idx)"
mnemonic(i::GlobalSet)::String = "global.set $(i.idx)"
mnemonic(::Unreachable)::String = "unreachable"
mnemonic(::Nop)::String         = "nop"
mnemonic(i::Block)::String = "block $(i.blocktype)"
mnemonic(i::Loop)::String  = "loop $(i.blocktype)"
mnemonic(i::If)::String    = "if $(i.blocktype)"
mnemonic(::Else)::String   = "else"
mnemonic(::End)::String    = "end"
mnemonic(i::Br)::String    = "br $(i.depth)"
mnemonic(i::BrIf)::String  = "br_if $(i.depth)"
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:37 Instruction.printTo)
mnemonic(::Return)::String = "return"
mnemonic(i::Call)::String  = "call $(i.idx)"
mnemonic(i::CallIndirect)::String = "call_indirect (type $(i.type_idx)) (table $(i.table_idx))"
mnemonic(i::CallRef)::String     = "call_ref \$$(i.type_idx)"
# end parity-region
# parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2212 BrOnNull.printTo)
mnemonic(i::BrOnNull)::String    = "br_on_null $(i.depth)"
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:37 Instruction.printTo)
mnemonic(i::BrOnNonNull)::String = "br_on_non_null $(i.depth)"
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:37 Instruction.printTo)
mnemonic(i::BeginTry)::String = "try $(i.blocktype)"
mnemonic(i::CatchLegacy)::String = "catch $(i.tag)"
mnemonic(i::Throw)::String   = "throw $(i.tag)"
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:37 Instruction.printTo)
mnemonic(i::RefNullAbstract)::String = "ref.null 0x$(string(i.heaptype_byte, base=16))"
mnemonic(i::RefNullConcrete)::String = "ref.null \$$(i.heaptype)"
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:37 Instruction.printTo)
mnemonic(::RefIsNull)::String    = "ref.is_null"
mnemonic(::RefAsNonNull)::String = "ref.as_non_null"
mnemonic(::RefEq)::String        = "ref.eq"
mnemonic(i::RefFunc)::String     = "ref.func $(i.idx)"
mnemonic(i::StructNew)::String        = "struct.new \$$(i.idx)"
mnemonic(i::StructNewDefault)::String = "struct.new_default \$$(i.idx)"
mnemonic(i::StructGet)::String = "struct.get \$$(i.idx) $(i.field)"
mnemonic(i::StructSet)::String = "struct.set \$$(i.idx) $(i.field)"
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:37 Instruction.printTo)
mnemonic(i::ArrayNewDefault)::String = "array.new_default \$$(i.idx)"
mnemonic(i::ArrayNewFixed)::String   = "array.new_fixed \$$(i.idx) $(i.n)"
mnemonic(i::ArrayNewData)::String    = "array.new_data \$$(i.idx) $(i.seg)"
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:37 Instruction.printTo)
mnemonic(i::ArrayGet)::String = "array.get \$$(i.idx)"
mnemonic(i::ArraySet)::String = "array.set \$$(i.idx)"
mnemonic(::ArrayLen)::String  = "array.len"
mnemonic(i::ArrayCopy)::String = "array.copy \$$(i.dst) \$$(i.src)"
# end parity-region
# parity(pkg/wasm_builder/lib/src/ir/instruction.dart:2799 ArrayFill.printTo)
mnemonic(i::ArrayFill)::String = "array.fill \$$(i.idx)"
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:37 Instruction.printTo)
mnemonic(i::RefCastConcrete)::String = "ref.cast$(i.nullable ? " null" : "") \$$(i.idx)"
mnemonic(i::RefCastAbstract)::String = "ref.cast$(i.nullable ? " null" : "") 0x$(string(i.heaptype_byte, base=16))"
mnemonic(i::RefTest)::String = "ref.test$(i.nullable ? " null" : "") \$$(i.idx)"
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:37 Instruction.printTo)
mnemonic(::AnyConvertExtern)::String = "any.convert_extern"
mnemonic(::ExternConvertAny)::String = "extern.convert_any"
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:37 Instruction.printTo)
mnemonic(i::TruncSat)::String = "trunc_sat 0x$(string(i.sub_op, base=16))"
# end parity-region
