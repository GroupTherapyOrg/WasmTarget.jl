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
# carry only Base-typed fields so this submodule has zero parent dependencies.
#
# The InstrBuilder produces a `Vector{WasmInstr}` (the ir/ layer); `builder_code`
# serializes it (the serialize/ layer). One representation, no parallel byte path.

module InstrIR

abstract type WasmInstr end

# ── numeric / const ──────────────────────────────────────────────────────────────
struct I32Const <: WasmInstr; value::Int64; end
struct I64Const <: WasmInstr; value::Int64; end
struct F32Const <: WasmInstr; value::Float32; end
struct F64Const <: WasmInstr; value::Float64; end
struct NumOp    <: WasmInstr; op::UInt8; end   # generic no-immediate numeric/cmp/conv op

# ── parametric ───────────────────────────────────────────────────────────────────
struct Drop   <: WasmInstr; end
struct Select <: WasmInstr; end
# Typed select (0x1C): carries the on-wire bytes of the single result valtype
# (dart2wasm SelectWithType writes 0x1C, vec-len 1, then `write(type)`). The caller
# already has the valtype bytes (e.g. 0x63 + signed-LEB type_idx), so carry them
# verbatim — keeps this submodule dependency-free of the type-encoding layer.
struct SelectWithType <: WasmInstr; type_bytes::Vector{UInt8}; end

# ── variable ─────────────────────────────────────────────────────────────────────
struct LocalGet  <: WasmInstr; idx::UInt32; end
struct LocalSet  <: WasmInstr; idx::UInt32; end
struct LocalTee  <: WasmInstr; idx::UInt32; end
struct GlobalGet <: WasmInstr; idx::UInt32; end
struct GlobalSet <: WasmInstr; idx::UInt32; end

# ── control flow ─────────────────────────────────────────────────────────────────
struct Unreachable <: WasmInstr; end
struct Nop         <: WasmInstr; end
struct Block <: WasmInstr; blocktype::Any; end   # blocktype: 0x40 byte or a WasmValType
struct Loop  <: WasmInstr; blocktype::Any; end
struct If    <: WasmInstr; blocktype::Any; end
struct Else  <: WasmInstr; end
struct End   <: WasmInstr; end
struct Br    <: WasmInstr; depth::UInt32; end
struct BrIf  <: WasmInstr; depth::UInt32; end
struct BrTable <: WasmInstr; targets::Vector{UInt32}; default::UInt32; end
struct Return  <: WasmInstr; end
struct Call    <: WasmInstr; idx::UInt32; end
struct CallIndirect <: WasmInstr; type_idx::UInt32; table_idx::UInt32; end
# call_ref (Wasm GC, 0x14): a typed call through a (ref $type) on the stack.
# dart2wasm CallRef.serialize writes 0x14 + writeTypeIndex(type) (unsigned LEB type idx).
struct CallRef <: WasmInstr; type_idx::UInt32; end
# br_on_null (0xD5) / br_on_non_null (0xD6): branch on the nullability of the top ref.
struct BrOnNull    <: WasmInstr; depth::UInt32; end
struct BrOnNonNull <: WasmInstr; depth::UInt32; end

# ── exception handling (Wasm 3.0) ──────────────────────────────────────────────────
# A try_table catch clause (dart2wasm TryTableCatch): a kind byte + immediates.
#   kind 0x00 catch          tag_idx label_idx   (pushes tag.inputs)
#   kind 0x01 catch_ref      tag_idx label_idx   (pushes tag.inputs ++ exnref)
#   kind 0x02 catch_all      label_idx           (pushes nothing)
#   kind 0x03 catch_all_ref  label_idx           (pushes exnref)
# `tag` is unused (and `0xffffffff`) for the *_all kinds.
struct TryCatch
    kind::UInt8
    tag::UInt32
    label::UInt32
end
# try_table: a block opener (blocktype: 0x40 byte or a WasmValType) plus the catch vec.
struct TryTable <: WasmInstr; blocktype::Any; catches::Vector{TryCatch}; end
struct Throw    <: WasmInstr; tag::UInt32; end
struct ThrowRef <: WasmInstr; end
struct Rethrow  <: WasmInstr; depth::UInt32; end

# ── reference ────────────────────────────────────────────────────────────────────
# ref.null with an abstract heaptype: heaptype_byte is the raw on-wire byte (e.g. 0x6E any).
struct RefNullAbstract <: WasmInstr; heaptype_byte::UInt8; end
# ref.null with a concrete type index: encoded as a signed-LEB heaptype.
struct RefNullConcrete <: WasmInstr; heaptype::Int64; end
struct RefFunc      <: WasmInstr; idx::UInt32; end
struct RefIsNull    <: WasmInstr; end
struct RefAsNonNull <: WasmInstr; end

# ── GC ───────────────────────────────────────────────────────────────────────────
struct StructNew        <: WasmInstr; idx::UInt32; end
struct StructNewDefault <: WasmInstr; idx::UInt32; end
struct StructGet <: WasmInstr; idx::UInt32; field::UInt32; op::UInt8; end  # op = STRUCT_GET/_S/_U
struct StructSet <: WasmInstr; idx::UInt32; field::UInt32; end
struct ArrayNew        <: WasmInstr; idx::UInt32; end
struct ArrayNewDefault <: WasmInstr; idx::UInt32; end
struct ArrayNewFixed   <: WasmInstr; idx::UInt32; n::UInt32; end
struct ArrayNewData    <: WasmInstr; idx::UInt32; seg::UInt32; end
struct ArrayGet <: WasmInstr; idx::UInt32; op::UInt8; end   # op = ARRAY_GET/_S/_U
struct ArraySet <: WasmInstr; idx::UInt32; end
struct ArrayLen  <: WasmInstr; end
struct ArrayCopy <: WasmInstr; dst::UInt32; src::UInt32; end
struct ArrayFill <: WasmInstr; idx::UInt32; end
# ref.cast to a concrete type index (signed-LEB heaptype) vs an abstract heaptype byte.
struct RefCastConcrete <: WasmInstr; idx::Int64; nullable::Bool; end
struct RefCastAbstract <: WasmInstr; heaptype_byte::UInt8; nullable::Bool; end
struct RefTest <: WasmInstr; idx::Int64; nullable::Bool; end
# br_on_cast (0xFB 0x18) / br_on_cast_fail (0xFB 0x19): a cast that branches on
# success/failure. dart2wasm BrOnCast(.serialize): GC_PREFIX, op, flags byte
# (bit0 = src nullable, bit1 = dst nullable), unsigned label, then the SOURCE heaptype
# and the TARGET heaptype, each written as `s.write(heapType)` — a single on-wire byte for
# an abstract heaptype or a signed-LEB s33 for a concrete type index. The caller already
# has those heaptype bytes (exactly as for ref.cast / ref.null), so carry them verbatim.
struct BrOnCast     <: WasmInstr; flags::UInt8; depth::UInt32; src_heap::Vector{UInt8}; dst_heap::Vector{UInt8}; end
struct BrOnCastFail <: WasmInstr; flags::UInt8; depth::UInt32; src_heap::Vector{UInt8}; dst_heap::Vector{UInt8}; end
struct AnyConvertExtern <: WasmInstr; end
struct ExternConvertAny <: WasmInstr; end
struct RefI31  <: WasmInstr; end
struct I31GetS <: WasmInstr; end
struct I31GetU <: WasmInstr; end

# ── table ──────────────────────────────────────────────────────────────────────────
# dart2wasm Table{Get,Set,Size,Grow,Fill}.serialize. get/set are unprefixed (0x25/0x26);
# size/grow/fill are FC-prefixed (0xFC 0x10/0x0F/0x11). All write an unsigned table index.
struct TableGet  <: WasmInstr; idx::UInt32; end
struct TableSet  <: WasmInstr; idx::UInt32; end
struct TableSize <: WasmInstr; idx::UInt32; end
struct TableGrow <: WasmInstr; idx::UInt32; end
struct TableFill <: WasmInstr; idx::UInt32; end

# ── bulk memory (0xFC prefix) ────────────────────────────────────────────────────────
# dart2wasm Memory{Init,Copy,Fill}/DataDrop.serialize: FC_PREFIX, then an UNSIGNED sub-op
# (note: dart2wasm writes the sub-op via writeUnsigned, single-byte LEB == the raw byte for
# these small values), then the immediates. memory.init writes seg then mem; data.drop seg;
# memory.copy dst-mem then src-mem; memory.fill mem.
struct MemoryInit <: WasmInstr; seg::UInt32; mem::UInt32; end
struct DataDrop   <: WasmInstr; seg::UInt32; end
struct MemoryCopy <: WasmInstr; dst_mem::UInt32; src_mem::UInt32; end
struct MemoryFill <: WasmInstr; mem::UInt32; end
# array.new_elem (0xFB 0x0A): [offset:i32 length:i32] -> [(ref $type)] from an elem segment.
struct ArrayNewElem <: WasmInstr; idx::UInt32; seg::UInt32; end

# ── transitional bridge (deleted when every emitter is migrated) ──────────────────
# Pre-encoded bytes spliced from an un-migrated callee (compile_value, etc.). A real
# instruction in the stream that just carries already-serialized bytes.
struct RawBytes <: WasmInstr; bytes::Vector{UInt8}; end

end # module InstrIR

# ── serialize layer (dart2wasm serialize/) + printTo, by multiple dispatch ─────────
import .InstrIR: WasmInstr,
    I32Const, I64Const, F32Const, F64Const, NumOp, Drop, Select, SelectWithType,
    LocalGet, LocalSet, LocalTee, GlobalGet, GlobalSet,
    Unreachable, Nop, Block, Loop, If, Else, End, Br, BrIf, BrTable, Return, Call, CallIndirect,
    CallRef, BrOnNull, BrOnNonNull,
    TryCatch, TryTable, Throw, ThrowRef, Rethrow,
    RefNullAbstract, RefNullConcrete, RefFunc, RefIsNull, RefAsNonNull,
    StructNew, StructNewDefault, StructGet, StructSet,
    ArrayNew, ArrayNewDefault, ArrayNewFixed, ArrayNewData, ArrayNewElem, ArrayGet, ArraySet, ArrayLen, ArrayCopy, ArrayFill,
    RefCastConcrete, RefCastAbstract, RefTest, BrOnCast, BrOnCastFail, AnyConvertExtern, ExternConvertAny,
    RefI31, I31GetS, I31GetU,
    TableGet, TableSet, TableSize, TableGrow, TableFill,
    MemoryInit, DataDrop, MemoryCopy, MemoryFill, RawBytes

# encode!(code, instr): append this instruction's exact on-wire bytes (dart2wasm `serialize`).
@inline _u!(code, n) = append!(code, encode_leb128_unsigned(n))
@inline _s!(code, n) = append!(code, encode_leb128_signed(n))

encode!(c::Vector{UInt8}, i::I32Const) = (push!(c, Opcode.I32_CONST); _s!(c, i.value))
encode!(c::Vector{UInt8}, i::I64Const) = (push!(c, Opcode.I64_CONST); _s!(c, i.value))
encode!(c::Vector{UInt8}, i::F32Const) = (push!(c, Opcode.F32_CONST); append!(c, reinterpret(UInt8, [i.value])))
encode!(c::Vector{UInt8}, i::F64Const) = (push!(c, Opcode.F64_CONST); append!(c, reinterpret(UInt8, [i.value])))
encode!(c::Vector{UInt8}, i::NumOp)    = push!(c, i.op)
encode!(c::Vector{UInt8}, ::Drop)      = push!(c, Opcode.DROP)
encode!(c::Vector{UInt8}, ::Select)    = push!(c, Opcode.SELECT)
# select (typed): 0x1C, vec-len 1, then the result valtype bytes (dart2wasm SelectWithType).
encode!(c::Vector{UInt8}, i::SelectWithType) = (push!(c, Opcode.SELECT_T); _u!(c, 1); append!(c, i.type_bytes))
encode!(c::Vector{UInt8}, i::LocalGet)  = (push!(c, Opcode.LOCAL_GET);  _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::LocalSet)  = (push!(c, Opcode.LOCAL_SET);  _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::LocalTee)  = (push!(c, Opcode.LOCAL_TEE);  _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::GlobalGet) = (push!(c, Opcode.GLOBAL_GET); _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::GlobalSet) = (push!(c, Opcode.GLOBAL_SET); _u!(c, i.idx))
encode!(c::Vector{UInt8}, ::Unreachable) = push!(c, Opcode.UNREACHABLE)
encode!(c::Vector{UInt8}, ::Nop)         = push!(c, Opcode.NOP)
encode!(c::Vector{UInt8}, i::Block) = (push!(c, Opcode.BLOCK); append!(c, encode_block_type(i.blocktype)))
encode!(c::Vector{UInt8}, i::Loop)  = (push!(c, Opcode.LOOP);  append!(c, encode_block_type(i.blocktype)))
encode!(c::Vector{UInt8}, i::If)    = (push!(c, Opcode.IF);    append!(c, encode_block_type(i.blocktype)))
encode!(c::Vector{UInt8}, ::Else)   = push!(c, Opcode.ELSE)
encode!(c::Vector{UInt8}, ::End)    = push!(c, Opcode.END)
encode!(c::Vector{UInt8}, i::Br)    = (push!(c, Opcode.BR);    _u!(c, i.depth))
encode!(c::Vector{UInt8}, i::BrIf)  = (push!(c, Opcode.BR_IF); _u!(c, i.depth))
function encode!(c::Vector{UInt8}, i::BrTable)
    push!(c, Opcode.BR_TABLE); _u!(c, length(i.targets))
    for t in i.targets; _u!(c, t); end
    _u!(c, i.default)
end
encode!(c::Vector{UInt8}, ::Return) = push!(c, Opcode.RETURN)
encode!(c::Vector{UInt8}, i::Call)  = (push!(c, Opcode.CALL); _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::CallIndirect) = (push!(c, Opcode.CALL_INDIRECT); _u!(c, i.type_idx); _u!(c, i.table_idx))
encode!(c::Vector{UInt8}, i::CallRef)     = (push!(c, Opcode.CALL_REF); _u!(c, i.type_idx))
encode!(c::Vector{UInt8}, i::BrOnNull)    = (push!(c, Opcode.BR_ON_NULL);     _u!(c, i.depth))
encode!(c::Vector{UInt8}, i::BrOnNonNull) = (push!(c, Opcode.BR_ON_NON_NULL); _u!(c, i.depth))
# try_table: 0x1F, blocktype, vec(catch). Each catch = kind byte + immediates (dart2wasm
# TryTableCatch.serialize): catch/catch_ref write tag then label; the *_all kinds write only label.
function _encode_catch!(c::Vector{UInt8}, k::TryCatch)
    push!(c, k.kind)
    if k.kind == Opcode.CATCH || k.kind == Opcode.CATCH_REF
        _u!(c, k.tag)
    end
    _u!(c, k.label)
end
function encode!(c::Vector{UInt8}, i::TryTable)
    push!(c, Opcode.TRY_TABLE)
    append!(c, encode_block_type(i.blocktype))
    _u!(c, length(i.catches))
    for k in i.catches; _encode_catch!(c, k); end
end
encode!(c::Vector{UInt8}, i::Throw)   = (push!(c, Opcode.THROW); _u!(c, i.tag))
encode!(c::Vector{UInt8}, ::ThrowRef) = push!(c, Opcode.THROW_REF)
encode!(c::Vector{UInt8}, i::Rethrow) = (push!(c, Opcode.RETHROW); _u!(c, i.depth))
encode!(c::Vector{UInt8}, i::RefNullAbstract) = (push!(c, Opcode.REF_NULL); push!(c, i.heaptype_byte))
encode!(c::Vector{UInt8}, i::RefNullConcrete) = (push!(c, Opcode.REF_NULL); _s!(c, i.heaptype))
encode!(c::Vector{UInt8}, i::RefFunc)   = (push!(c, Opcode.REF_FUNC); _u!(c, i.idx))
encode!(c::Vector{UInt8}, ::RefIsNull)    = push!(c, Opcode.REF_IS_NULL)
encode!(c::Vector{UInt8}, ::RefAsNonNull) = push!(c, Opcode.REF_AS_NON_NULL)
encode!(c::Vector{UInt8}, i::StructNew)        = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.STRUCT_NEW); _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::StructNewDefault) = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.STRUCT_NEW_DEFAULT); _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::StructGet) = (push!(c, Opcode.GC_PREFIX); push!(c, i.op); _u!(c, i.idx); _u!(c, i.field))
encode!(c::Vector{UInt8}, i::StructSet) = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.STRUCT_SET); _u!(c, i.idx); _u!(c, i.field))
encode!(c::Vector{UInt8}, i::ArrayNew)        = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.ARRAY_NEW); _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::ArrayNewDefault) = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.ARRAY_NEW_DEFAULT); _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::ArrayNewFixed)   = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.ARRAY_NEW_FIXED); _u!(c, i.idx); _u!(c, i.n))
encode!(c::Vector{UInt8}, i::ArrayNewData)    = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.ARRAY_NEW_DATA); _u!(c, i.idx); _u!(c, i.seg))
encode!(c::Vector{UInt8}, i::ArrayNewElem)    = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.ARRAY_NEW_ELEM); _u!(c, i.idx); _u!(c, i.seg))
encode!(c::Vector{UInt8}, i::ArrayGet) = (push!(c, Opcode.GC_PREFIX); push!(c, i.op); _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::ArraySet) = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.ARRAY_SET); _u!(c, i.idx))
encode!(c::Vector{UInt8}, ::ArrayLen)  = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.ARRAY_LEN))
encode!(c::Vector{UInt8}, i::ArrayCopy) = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.ARRAY_COPY); _u!(c, i.dst); _u!(c, i.src))
encode!(c::Vector{UInt8}, i::ArrayFill) = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.ARRAY_FILL); _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::RefCastConcrete) = (push!(c, Opcode.GC_PREFIX); push!(c, i.nullable ? Opcode.REF_CAST_NULL : Opcode.REF_CAST); _s!(c, i.idx))
encode!(c::Vector{UInt8}, i::RefCastAbstract) = (push!(c, Opcode.GC_PREFIX); push!(c, i.nullable ? Opcode.REF_CAST_NULL : Opcode.REF_CAST); push!(c, i.heaptype_byte))
encode!(c::Vector{UInt8}, i::RefTest) = (push!(c, Opcode.GC_PREFIX); push!(c, i.nullable ? Opcode.REF_TEST_NULL : Opcode.REF_TEST); _s!(c, i.idx))
# br_on_cast / br_on_cast_fail: GC_PREFIX, op, flags byte, unsigned label, src heaptype bytes,
# dst heaptype bytes (dart2wasm BrOnCast.serialize). Heaptype bytes are caller-supplied verbatim.
encode!(c::Vector{UInt8}, i::BrOnCast)     = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.BR_ON_CAST);      push!(c, i.flags); _u!(c, i.depth); append!(c, i.src_heap); append!(c, i.dst_heap))
encode!(c::Vector{UInt8}, i::BrOnCastFail) = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.BR_ON_CAST_FAIL); push!(c, i.flags); _u!(c, i.depth); append!(c, i.src_heap); append!(c, i.dst_heap))
encode!(c::Vector{UInt8}, ::AnyConvertExtern) = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.ANY_CONVERT_EXTERN))
encode!(c::Vector{UInt8}, ::ExternConvertAny) = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.EXTERN_CONVERT_ANY))
encode!(c::Vector{UInt8}, ::RefI31)  = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.REF_I31))
encode!(c::Vector{UInt8}, ::I31GetS) = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.I31_GET_S))
encode!(c::Vector{UInt8}, ::I31GetU) = (push!(c, Opcode.GC_PREFIX); push!(c, Opcode.I31_GET_U))
# table: get/set unprefixed; size/grow/fill FC-prefixed. All write an unsigned table index.
encode!(c::Vector{UInt8}, i::TableGet)  = (push!(c, Opcode.TABLE_GET); _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::TableSet)  = (push!(c, Opcode.TABLE_SET); _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::TableSize) = (push!(c, Opcode.FC_PREFIX); _u!(c, UInt32(Opcode.TABLE_SIZE)); _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::TableGrow) = (push!(c, Opcode.FC_PREFIX); _u!(c, UInt32(Opcode.TABLE_GROW)); _u!(c, i.idx))
encode!(c::Vector{UInt8}, i::TableFill) = (push!(c, Opcode.FC_PREFIX); _u!(c, UInt32(Opcode.TABLE_FILL)); _u!(c, i.idx))
# bulk memory: FC_PREFIX, unsigned sub-op, then immediates (dart2wasm writes the sub-op via
# writeUnsigned — single-byte LEB == the raw byte for these values).
encode!(c::Vector{UInt8}, i::MemoryInit) = (push!(c, Opcode.FC_PREFIX); _u!(c, UInt32(Opcode.MEMORY_INIT)); _u!(c, i.seg); _u!(c, i.mem))
encode!(c::Vector{UInt8}, i::DataDrop)   = (push!(c, Opcode.FC_PREFIX); _u!(c, UInt32(Opcode.DATA_DROP));   _u!(c, i.seg))
encode!(c::Vector{UInt8}, i::MemoryCopy) = (push!(c, Opcode.FC_PREFIX); _u!(c, UInt32(Opcode.MEMORY_COPY)); _u!(c, i.dst_mem); _u!(c, i.src_mem))
encode!(c::Vector{UInt8}, i::MemoryFill) = (push!(c, Opcode.FC_PREFIX); _u!(c, UInt32(Opcode.MEMORY_FILL)); _u!(c, i.mem))
encode!(c::Vector{UInt8}, i::RawBytes) = append!(c, i.bytes)

# mnemonic(instr): symbolic WAT-ish text (dart2wasm `printTo`) — for builder_diagnose /
# WT_BUILDER_TRACE disassembly. Clarity for tracking codegen bugs without a hex round-trip.
mnemonic(i::I32Const) = "i32.const $(i.value)"
mnemonic(i::I64Const) = "i64.const $(i.value)"
mnemonic(i::F32Const) = "f32.const $(i.value)"
mnemonic(i::F64Const) = "f64.const $(i.value)"
mnemonic(i::NumOp)    = "num 0x$(string(i.op, base=16))"
mnemonic(::Drop)   = "drop"
mnemonic(::Select) = "select"
mnemonic(i::SelectWithType) = "select (result <$(length(i.type_bytes))B>)"
mnemonic(i::LocalGet)  = "local.get $(i.idx)"
mnemonic(i::LocalSet)  = "local.set $(i.idx)"
mnemonic(i::LocalTee)  = "local.tee $(i.idx)"
mnemonic(i::GlobalGet) = "global.get $(i.idx)"
mnemonic(i::GlobalSet) = "global.set $(i.idx)"
mnemonic(::Unreachable) = "unreachable"
mnemonic(::Nop)         = "nop"
mnemonic(i::Block) = "block $(i.blocktype)"
mnemonic(i::Loop)  = "loop $(i.blocktype)"
mnemonic(i::If)    = "if $(i.blocktype)"
mnemonic(::Else)   = "else"
mnemonic(::End)    = "end"
mnemonic(i::Br)    = "br $(i.depth)"
mnemonic(i::BrIf)  = "br_if $(i.depth)"
mnemonic(i::BrTable) = "br_table $(i.targets) $(i.default)"
mnemonic(::Return) = "return"
mnemonic(i::Call)  = "call $(i.idx)"
mnemonic(i::CallIndirect) = "call_indirect (type $(i.type_idx)) (table $(i.table_idx))"
mnemonic(i::CallRef)     = "call_ref \$$(i.type_idx)"
mnemonic(i::BrOnNull)    = "br_on_null $(i.depth)"
mnemonic(i::BrOnNonNull) = "br_on_non_null $(i.depth)"
_catch_mnemonic(k::TryCatch) =
    k.kind == Opcode.CATCH         ? "catch $(k.tag) $(k.label)" :
    k.kind == Opcode.CATCH_REF     ? "catch_ref $(k.tag) $(k.label)" :
    k.kind == Opcode.CATCH_ALL     ? "catch_all $(k.label)" :
    k.kind == Opcode.CATCH_ALL_REF ? "catch_all_ref $(k.label)" :
                                     "catch?0x$(string(k.kind, base=16)) $(k.label)"
mnemonic(i::TryTable) = "try_table $(i.blocktype) [" * join((_catch_mnemonic(k) for k in i.catches), ", ") * "]"
mnemonic(i::Throw)   = "throw $(i.tag)"
mnemonic(::ThrowRef) = "throw_ref"
mnemonic(i::Rethrow) = "rethrow $(i.depth)"
mnemonic(i::RefNullAbstract) = "ref.null 0x$(string(i.heaptype_byte, base=16))"
mnemonic(i::RefNullConcrete) = "ref.null \$$(i.heaptype)"
mnemonic(i::RefFunc)   = "ref.func $(i.idx)"
mnemonic(::RefIsNull)    = "ref.is_null"
mnemonic(::RefAsNonNull) = "ref.as_non_null"
mnemonic(i::StructNew)        = "struct.new \$$(i.idx)"
mnemonic(i::StructNewDefault) = "struct.new_default \$$(i.idx)"
mnemonic(i::StructGet) = "struct.get \$$(i.idx) $(i.field)"
mnemonic(i::StructSet) = "struct.set \$$(i.idx) $(i.field)"
mnemonic(i::ArrayNew)        = "array.new \$$(i.idx)"
mnemonic(i::ArrayNewDefault) = "array.new_default \$$(i.idx)"
mnemonic(i::ArrayNewFixed)   = "array.new_fixed \$$(i.idx) $(i.n)"
mnemonic(i::ArrayNewData)    = "array.new_data \$$(i.idx) $(i.seg)"
mnemonic(i::ArrayNewElem)    = "array.new_elem \$$(i.idx) $(i.seg)"
mnemonic(i::ArrayGet) = "array.get \$$(i.idx)"
mnemonic(i::ArraySet) = "array.set \$$(i.idx)"
mnemonic(::ArrayLen)  = "array.len"
mnemonic(i::ArrayCopy) = "array.copy \$$(i.dst) \$$(i.src)"
mnemonic(i::ArrayFill) = "array.fill \$$(i.idx)"
mnemonic(i::RefCastConcrete) = "ref.cast$(i.nullable ? " null" : "") \$$(i.idx)"
mnemonic(i::RefCastAbstract) = "ref.cast$(i.nullable ? " null" : "") 0x$(string(i.heaptype_byte, base=16))"
mnemonic(i::RefTest) = "ref.test$(i.nullable ? " null" : "") \$$(i.idx)"
mnemonic(i::BrOnCast)     = "br_on_cast $(i.depth) (flags 0x$(string(i.flags, base=16)))"
mnemonic(i::BrOnCastFail) = "br_on_cast_fail $(i.depth) (flags 0x$(string(i.flags, base=16)))"
mnemonic(::AnyConvertExtern) = "any.convert_extern"
mnemonic(::ExternConvertAny) = "extern.convert_any"
mnemonic(::RefI31)  = "ref.i31"
mnemonic(::I31GetS) = "i31.get_s"
mnemonic(::I31GetU) = "i31.get_u"
mnemonic(i::TableGet)  = "table.get $(i.idx)"
mnemonic(i::TableSet)  = "table.set $(i.idx)"
mnemonic(i::TableSize) = "table.size $(i.idx)"
mnemonic(i::TableGrow) = "table.grow $(i.idx)"
mnemonic(i::TableFill) = "table.fill $(i.idx)"
mnemonic(i::MemoryInit) = "memory.init $(i.seg) $(i.mem)"
mnemonic(i::DataDrop)   = "data.drop $(i.seg)"
mnemonic(i::MemoryCopy) = "memory.copy $(i.dst_mem) $(i.src_mem)"
mnemonic(i::MemoryFill) = "memory.fill $(i.mem)"
mnemonic(i::RawBytes) = "<raw $(length(i.bytes))B>"
