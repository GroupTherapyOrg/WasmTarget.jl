# WebAssembly Instructions and Opcodes
# Reference: https://webassembly.github.io/spec/core/binary/instructions.html

export Opcode, WasmModule, WasmImport, WasmTable, WasmMemory, WasmDataSegment, WasmTag, add_function!, add_import!, add_export!, add_struct_type!, add_array_type!, add_type_group!, add_table!, add_table_export!, add_elem_segment!, add_memory!, add_memory_export!, add_data_segment!, add_tag!, add_start_function!, add_global_ref!, to_bytes

# ============================================================================
# Opcodes (Section 5.4)
# ============================================================================

module Opcode
    # Control instructions
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:87 Instruction.deserialize)
    const UNREACHABLE = 0x00
    const NOP = 0x01
    const BLOCK = 0x02
    const LOOP = 0x03
    const IF = 0x04
    const ELSE = 0x05
    const END = 0x0B
    const BR = 0x0C
    const BR_IF = 0x0D
    const BR_TABLE = 0x0E
    const RETURN = 0x0F
    const CALL = 0x10
    const CALL_INDIRECT = 0x11
    const CALL_REF = 0x14        # call_ref type_idx - typed function-reference call (Wasm GC)
    const BR_ON_NULL = 0xD5      # br_on_null label - branch if ref is null
    const BR_ON_NON_NULL = 0xD6  # br_on_non_null label - branch if ref is non-null

    # Reference-typed table access
    const TABLE_GET = 0x25       # table.get table_idx
    const TABLE_SET = 0x26       # table.set table_idx

    # Exception handling instructions (Wasm 3.0)
    const THROW = 0x08         # throw tag_idx - throw exception with tag
    const RETHROW = 0x09       # rethrow label_idx - re-throw caught exception (legacy)
    const THROW_REF = 0x0A     # throw_ref - rethrow exception from exnref
    const TRY_TABLE = 0x1F     # try_table blocktype catch* - structured exception handler

# end parity-region
    # Catch clause types for try_table
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:4937 TryTableCatch.deserialize)
    const CATCH = 0x00         # catch tag_idx label_idx
    const CATCH_REF = 0x01     # catch_ref tag_idx label_idx (pushes exnref)
    const CATCH_ALL = 0x02     # catch_all label_idx
    const CATCH_ALL_REF = 0x03 # catch_all_ref label_idx (pushes exnref)
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:87 Instruction.deserialize)

    # Parametric instructions
    const DROP = 0x1A
    const SELECT = 0x1B
    const SELECT_T = 0x1C  # Typed select (followed by type count and types)

    # Variable instructions
    const LOCAL_GET = 0x20
    const LOCAL_SET = 0x21
    const LOCAL_TEE = 0x22
    const GLOBAL_GET = 0x23
    const GLOBAL_SET = 0x24

    # Memory instructions
    const I32_LOAD = 0x28
    const I64_LOAD = 0x29
    const F32_LOAD = 0x2A
    const F64_LOAD = 0x2B
    const I32_STORE = 0x36
    const I64_STORE = 0x37
    const F32_STORE = 0x38
    const F64_STORE = 0x39
    const MEMORY_SIZE = 0x3F
    const MEMORY_GROW = 0x40

    # Numeric instructions - Constants
    const I32_CONST = 0x41
    const I64_CONST = 0x42
    const F32_CONST = 0x43
    const F64_CONST = 0x44

    # Numeric instructions - i32 operations
    const I32_EQZ = 0x45
    const I32_EQ = 0x46
    const I32_NE = 0x47
    const I32_LT_S = 0x48
    const I32_LT_U = 0x49
    const I32_GT_S = 0x4A
    const I32_GT_U = 0x4B
    const I32_LE_S = 0x4C
    const I32_LE_U = 0x4D
    const I32_GE_S = 0x4E
    const I32_GE_U = 0x4F

    # Numeric instructions - i64 comparisons
    const I64_EQZ = 0x50
    const I64_EQ = 0x51
    const I64_NE = 0x52
    const I64_LT_S = 0x53
    const I64_LT_U = 0x54
    const I64_GT_S = 0x55
    const I64_GT_U = 0x56
    const I64_LE_S = 0x57
    const I64_LE_U = 0x58
    const I64_GE_S = 0x59
    const I64_GE_U = 0x5A

    # Numeric instructions - f32 comparisons
    const F32_EQ = 0x5B
    const F32_NE = 0x5C
    const F32_LT = 0x5D
    const F32_GT = 0x5E
    const F32_LE = 0x5F
    const F32_GE = 0x60

    # Numeric instructions - f64 comparisons
    const F64_EQ = 0x61
    const F64_NE = 0x62
    const F64_LT = 0x63
    const F64_GT = 0x64
    const F64_LE = 0x65
    const F64_GE = 0x66

    # Numeric instructions - i32 arithmetic
    const I32_CLZ = 0x67
    const I32_CTZ = 0x68
    const I32_POPCNT = 0x69
    const I32_ADD = 0x6A
    const I32_SUB = 0x6B
    const I32_MUL = 0x6C
    const I32_DIV_S = 0x6D
    const I32_DIV_U = 0x6E
    const I32_REM_S = 0x6F
    const I32_REM_U = 0x70
    const I32_AND = 0x71
    const I32_OR = 0x72
    const I32_XOR = 0x73
    const I32_SHL = 0x74
    const I32_SHR_S = 0x75
    const I32_SHR_U = 0x76
    const I32_ROTL = 0x77
    const I32_ROTR = 0x78

    # Numeric instructions - i64 arithmetic
    const I64_CLZ = 0x79
    const I64_CTZ = 0x7A
    const I64_POPCNT = 0x7B
    const I64_ADD = 0x7C
    const I64_SUB = 0x7D
    const I64_MUL = 0x7E
    const I64_DIV_S = 0x7F
    const I64_DIV_U = 0x80
    const I64_REM_S = 0x81
    const I64_REM_U = 0x82
    const I64_AND = 0x83
    const I64_OR = 0x84
    const I64_XOR = 0x85
    const I64_SHL = 0x86
    const I64_SHR_S = 0x87
    const I64_SHR_U = 0x88
    const I64_ROTL = 0x89
    const I64_ROTR = 0x8A

    # Numeric instructions - f32 operations
    const F32_ABS = 0x8B
    const F32_NEG = 0x8C
    const F32_CEIL = 0x8D
    const F32_FLOOR = 0x8E
    const F32_TRUNC = 0x8F
    const F32_NEAREST = 0x90
    const F32_SQRT = 0x91
    const F32_ADD = 0x92
    const F32_SUB = 0x93
    const F32_MUL = 0x94
    const F32_DIV = 0x95
    const F32_MIN = 0x96
    const F32_MAX = 0x97
    const F32_COPYSIGN = 0x98

    # Numeric instructions - f64 operations
    const F64_ABS = 0x99
    const F64_NEG = 0x9A
    const F64_CEIL = 0x9B
    const F64_FLOOR = 0x9C
    const F64_TRUNC = 0x9D
    const F64_NEAREST = 0x9E
    const F64_SQRT = 0x9F
    const F64_ADD = 0xA0
    const F64_SUB = 0xA1
    const F64_MUL = 0xA2
    const F64_DIV = 0xA3
    const F64_MIN = 0xA4
    const F64_MAX = 0xA5
    const F64_COPYSIGN = 0xA6

    # Conversion operations
    const I32_WRAP_I64 = 0xA7
    const I64_EXTEND_I32_S = 0xAC
    const I64_EXTEND_I32_U = 0xAD
    # Sign-extension operators (--enable-sign-ext): in-register narrow normalisation
    const I32_EXTEND8_S = 0xC0
    const I32_EXTEND16_S = 0xC1
    const F32_CONVERT_I32_S = 0xB2
    const F32_CONVERT_I32_U = 0xB3
    const F32_CONVERT_I64_S = 0xB4
    const F32_CONVERT_I64_U = 0xB5
    const F64_CONVERT_I32_S = 0xB7
    const F64_CONVERT_I32_U = 0xB8
    const F64_CONVERT_I64_S = 0xB9
    const F64_CONVERT_I64_U = 0xBA

    # Float-to-float conversions
    const F32_DEMOTE_F64 = 0xB6
    const F64_PROMOTE_F32 = 0xBB

    # Float to int conversions
    const I32_TRUNC_F32_S = 0xA8
    const I32_TRUNC_F32_U = 0xA9
    const I32_TRUNC_F64_S = 0xAA
    const I32_TRUNC_F64_U = 0xAB
    const I64_TRUNC_F32_S = 0xAE
    const I64_TRUNC_F32_U = 0xAF
    const I64_TRUNC_F64_S = 0xB0
    const I64_TRUNC_F64_U = 0xB1

    # Reinterpret operations
    const I32_REINTERPRET_F32 = 0xBC
    const I64_REINTERPRET_F64 = 0xBD
    const F32_REINTERPRET_I32 = 0xBE
    const F64_REINTERPRET_I64 = 0xBF

    # ========================================================================
    # WasmGC Instructions (0xFB prefix)
    # Reference: https://github.com/WebAssembly/gc/blob/main/proposals/gc/Overview.md
    # ========================================================================
    const GC_PREFIX = 0xFB

    # Struct operations
    const STRUCT_NEW = 0x00       # struct.new $t : [field types] -> [(ref $t)]
    const STRUCT_NEW_DEFAULT = 0x01  # struct.new_default $t : [] -> [(ref $t)]
    const STRUCT_GET = 0x02       # struct.get $t $i : [(ref null $t)] -> [field type]
    const STRUCT_GET_S = 0x03     # struct.get_s $t $i (packed signed)
    const STRUCT_GET_U = 0x04     # struct.get_u $t $i (packed unsigned)
    const STRUCT_SET = 0x05       # struct.set $t $i : [(ref null $t) value] -> []

    # Array operations
    const ARRAY_NEW = 0x06        # array.new $t : [elem init, len] -> [(ref $t)]
    const ARRAY_NEW_DEFAULT = 0x07  # array.new_default $t : [len] -> [(ref $t)]
    const ARRAY_NEW_FIXED = 0x08  # array.new_fixed $t $n : [elem...] -> [(ref $t)]
    const ARRAY_NEW_DATA = 0x09   # array.new_data $t $d : [offset, len] -> [(ref $t)]
    const ARRAY_GET = 0x0B        # array.get $t : [(ref null $t) i32] -> [elem type]
    const ARRAY_GET_S = 0x0C      # array.get_s (packed signed)
    const ARRAY_GET_U = 0x0D      # array.get_u (packed unsigned)
    const ARRAY_SET = 0x0E        # array.set $t : [(ref null $t) i32 value] -> []
    const ARRAY_LEN = 0x0F        # array.len : [(ref null array)] -> [i32]
    const ARRAY_FILL = 0x10       # array.fill $t : [(ref null $t) i32 value i32] -> []
    const ARRAY_COPY = 0x11       # array.copy $t1 $t2

    # Reference type operations
    const REF_NULL = 0xD0         # ref.null $t : [] -> [(ref null $t)]
    const REF_IS_NULL = 0xD1      # ref.is_null : [(ref null $t)] -> [i32]
    const REF_FUNC = 0xD2         # ref.func $f : [] -> [(ref $f)]
    const REF_EQ = 0xD3           # ref.eq : [(eqref) (eqref)] -> [i32]
    const REF_AS_NON_NULL = 0xD4  # ref.as_non_null : [(ref null $t)] -> [(ref $t)]

    # GC casting operations (0xFB prefix)
    const REF_TEST = 0x14         # ref.test (ref $t) : [(ref null? $ht)] -> [i32]
    const REF_TEST_NULL = 0x15    # ref.test null (ref null $t) : [(ref null? $ht)] -> [i32]
    const REF_CAST = 0x16         # ref.cast (ref $t) : [(ref null? $ht)] -> [(ref $t)]
    const REF_CAST_NULL = 0x17    # ref.cast null (ref null $t) : [(ref null? $ht)] -> [(ref null $t)]
    const BR_ON_CAST = 0x18       # br_on_cast
    const BR_ON_CAST_FAIL = 0x19  # br_on_cast_fail

    # i31 operations (0xFB prefix)
    const REF_I31 = 0x1C          # ref.i31 : [i32] -> [(ref i31)]
    const I31_GET_S = 0x1D        # i31.get_s : [(ref null i31)] -> [i32]
    const I31_GET_U = 0x1E        # i31.get_u : [(ref null i31)] -> [i32]

    # any/extern conversions (0xFB prefix)
    const ANY_CONVERT_EXTERN = 0x1A  # any.convert_extern
    const EXTERN_CONVERT_ANY = 0x1B  # extern.convert_any

# end parity-region
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:563 I32TruncSatF32S)
    # Saturating truncation (0xFC prefix, sub-ops 0x00–0x07): float → int, clamping
    # out-of-range / NaN to the int min/max/0 instead of trapping (the non-saturating
    # 0xA8–0xB1 family traps on overflow).
    const I32_TRUNC_SAT_F32_S = 0x00
    const I32_TRUNC_SAT_F32_U = 0x01
    const I32_TRUNC_SAT_F64_S = 0x02
    const I32_TRUNC_SAT_F64_U = 0x03
    const I64_TRUNC_SAT_F32_S = 0x04
    const I64_TRUNC_SAT_F32_U = 0x05
    const I64_TRUNC_SAT_F64_S = 0x06
    const I64_TRUNC_SAT_F64_U = 0x07
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:87 Instruction.deserialize)
    # Bulk memory and table operations (0xFC prefix)
    const FC_PREFIX = 0xFC
    const MEMORY_FILL = 0x0B    # memory.fill mem_idx
    const TABLE_SIZE = 0x10     # table.size table_idx
    const TABLE_FILL = 0x11     # table.fill table_idx
# end parity-region
end

# ============================================================================
# WasmModule - High-level module builder
# ============================================================================

"""
Represents a WebAssembly function definition: its type, locals, body bytes, and the body's
source mappings (byte offsets into `body`; empty for a compiler-generated function that no
statement emitted).
parity(pkg/wasm_builder/lib/src/ir/function.dart:77 DefinedFunction)
"""
struct WasmFunction
    type_idx::UInt32
    locals::Vector{WasmValType}
    body::Vector{UInt8}
    mappings::Vector{SourceMapping}
end
# parity(pkg/wasm_builder/lib/src/ir/function.dart:77 DefinedFunction): a body with no source mappings.
WasmFunction(type_idx::Integer, locals::Vector, body::Vector{UInt8})::WasmFunction =
    WasmFunction(UInt32(type_idx), WasmValType[l for l in locals], body, SourceMapping[])

"""
Represents an export entry.
parity(pkg/wasm_builder/lib/src/ir/exports.dart:23 Export)
"""
struct WasmExport
    name::String
    kind::UInt8  # 0=func, 1=table, 2=memory, 3=global
    idx::UInt32
end

"""
Represents an import entry.
parity(pkg/wasm_builder/lib/src/ir/imports.dart:39 Import)
"""
struct WasmImport
    module_name::String
    field_name::String
    kind::UInt8  # 0=func, 1=table, 2=memory, 3=global
    type_idx::UInt32  # For functions, the type index
end

"""
    WasmGlobalDef

Internal representation of a WebAssembly global variable definition.
parity(pkg/wasm_builder/lib/src/ir/global.dart:40 DefinedGlobal)
"""
struct WasmGlobalDef
    valtype::WasmValType     # Type of the global
    mutable_::Bool           # Whether the global is mutable
    init::Vector{UInt8}      # Initialization expression (bytecode)
end

"""
    WasmTable

A WebAssembly table for holding references (funcref, externref).
parity(pkg/wasm_builder/lib/src/ir/table.dart:48 DefinedTable)
"""
struct WasmTable
    reftype::RefType         # funcref (0x70) or externref (0x6F)
    min::UInt32              # Minimum size
    max::Union{UInt32, Nothing}  # Maximum size (nothing = no max)
end

"""
    WasmElemSegment

An element segment for initializing tables with function references.
parity(pkg/wasm_builder/lib/src/ir/element.dart:20 ActiveFunctionElementSegment)
"""
struct WasmElemSegment
    table_idx::UInt32        # Which table to initialize
    offset::UInt32           # Offset in table (constant)
    func_indices::Vector{UInt32}  # Function indices to place in table
    declared::Bool           # flags=3 declarative segment (ref.func in const exprs)
end
# parity(pkg/wasm_builder/lib/src/ir/element.dart:20 ActiveFunctionElementSegment)
WasmElemSegment(t::UInt32, o::UInt32, f::Vector{UInt32})::WasmElemSegment = WasmElemSegment(t, o, f, false)

"""
    WasmMemory

A WebAssembly linear memory (in pages of 64KB).
parity(pkg/wasm_builder/lib/src/ir/memory.dart:65 DefinedMemory)
"""
struct WasmMemory
    min::UInt32              # Minimum size in pages
    max::Union{UInt32, Nothing}  # Maximum size in pages (nothing = no max)
end

"""
    WasmDataSegment

A data segment for initializing linear memory with constant data,
or a passive data segment for use with array.new_data / memory.init.
parity(pkg/wasm_builder/lib/src/ir/data_segment.dart:25 DataSegment)
"""
struct WasmDataSegment
    memory_idx::UInt32       # Which memory to initialize (ignored for passive)
    offset::UInt32           # Offset in memory (ignored for passive)
    data::Vector{UInt8}      # The data bytes
    passive::Bool            # If true, this is a passive data segment (mode 0x01)
end

# parity(pkg/wasm_builder/lib/src/ir/data_segment.dart:25 DataSegment)
WasmDataSegment(memory_idx, offset, data)::WasmDataSegment = WasmDataSegment(memory_idx, offset, data, false)

"""
    WasmTag

An exception tag for WebAssembly exception handling.
Tags identify exception types and have an associated type signature.
parity(pkg/wasm_builder/lib/src/ir/tags.dart:45 DefinedTag)
"""
struct WasmTag
    type_idx::UInt32         # Index of FuncType (params define exception payload)
end

"""
    WasmModule

A WebAssembly module builder. Use this to construct modules programmatically.
parity(pkg/wasm_builder/lib/src/builder/module.dart:24 ModuleBuilder)
"""
mutable struct WasmModule
    types::Vector{CompositeType}  # Can contain FuncType, StructType, ArrayType; recursion groups are computed (recursion_groups)
    imports::Vector{WasmImport}   # Imported functions/tables/etc
    functions::Vector{WasmFunction}
    tables::Vector{WasmTable}     # Tables for funcref/externref
    memories::Vector{WasmMemory}  # Linear memories
    globals::Vector{WasmGlobalDef}   # Global variables
    exports::Vector{WasmExport}
    elem_segments::Vector{WasmElemSegment}  # Element segments for table init
    data_segments::Vector{WasmDataSegment}  # Data segments for memory init
    tags::Vector{WasmTag}         # Exception tags for exception handling
    start_function::Union{Nothing, UInt32}  # Optional start function index
    # the URL a `sourceMappingURL` section names; set, every builder of this module records
    # its source mappings (dart ModuleBuilder.sourceMapUrl, module.dart:28)
    source_map_url::Union{Nothing, String}
    # the function whose statements report their values to the host (a traced compile, for
    # locating a wrong value at its first divergent statement); nothing otherwise
    trace_func_idx::Union{Nothing, UInt32}
    trace_code::Union{Nothing, Core.CodeInfo}   # that function's typed CodeInfo, as compiled
    trace_stmts::Vector{Int}                    # the statements its probes report, as emitted
end

# parity(pkg/wasm_builder/lib/src/builder/module.dart:48 ModuleBuilder)
WasmModule()::WasmModule = WasmModule(CompositeType[], WasmImport[], WasmFunction[], WasmTable[], WasmMemory[], WasmGlobalDef[], WasmExport[], WasmElemSegment[], WasmDataSegment[], WasmTag[], nothing, nothing, nothing, nothing, Int[])

# ============================================================================
# Module Building API
# ============================================================================

"""
Raised at a module-builder chokepoint when an addition would make the module invalid.
parity(quarantine: dart's module builders check their invariants with `assert`, in debug
builds only; WT checks every addition in every build and rejects it where it is made, as
dev/CHARTER.md C7 requires.)
"""
struct ModuleValidationError <: Exception
    operation::Symbol
    detail::String
end
# parity(quarantine: the message of ModuleValidationError, above.)
Base.showerror(io::IO, e::ModuleValidationError) =
    print(io, "invalid WebAssembly module at ", e.operation, ": ", e.detail)

# parity(quarantine: the one raise of ModuleValidationError, above.)
@noinline _module_invalid(op::Symbol, detail::AbstractString)::Union{} =
    throw(ModuleValidationError(op, String(detail)))

# parity(pkg/wasm_builder/lib/src/builder/functions.dart:10 FunctionsBuilder)
@inline _function_count(mod::WasmModule)::Int64 = num_imported_funcs(mod) + length(mod.functions)

# parity(pkg/wasm_builder/lib/src/ir/function.dart:36 BaseFunction.type)
function _function_type(mod::WasmModule, idx::Integer)::FuncType
    0 <= idx < _function_count(mod) ||
        _module_invalid(:function_index, "function index $idx is out of bounds")
    if idx < num_imported_funcs(mod)
        imp = filter(x -> x.kind == 0x00, mod.imports)[idx + 1]
        ft = mod.types[Int(imp.type_idx) + 1]
    else
        fn = mod.functions[idx - num_imported_funcs(mod) + 1]
        ft = mod.types[Int(fn.type_idx) + 1]
    end
    ft isa FuncType || _module_invalid(:function_index, "function $idx has a non-function type")
    return ft
end

# parity(pkg/wasm_builder/lib/src/ir/type.dart:1136 StructType.isStructuralSubtypeOf)
function _validate_struct_subtype!(mod::WasmModule, st::StructType)::Nothing
    st.supertype_idx === nothing && return
    si = Int(st.supertype_idx)
    0 <= si < length(mod.types) ||
        _module_invalid(:add_type, "struct supertype $si must be declared earlier")
    super = mod.types[si + 1]
    super isa StructType || _module_invalid(:add_type, "struct supertype $si is not a struct")
    length(st.fields) >= length(super.fields) ||
        _module_invalid(:add_type, "struct subtype has fewer fields than supertype $si")
    for (i, sf) in enumerate(super.fields)
        cf = st.fields[i]
        cf.mutable_ == sf.mutable_ ||
            _module_invalid(:add_type, "field $i changes mutability from supertype $si")
        # Mutable fields are invariant. Immutable fields are covariant.
        ok = sf.mutable_ ? cf.valtype == sf.valtype : wasm_subtype(cf.valtype, sf.valtype, mod)
        ok || _module_invalid(:add_type, "field $i is not a valid subtype of supertype $si")
    end
end

"""
    add_type!(mod, composite_type) -> type_idx

Add a composite type (FuncType, StructType, or ArrayType) to the module and return its index.
parity(quarantine: WT's validator identifies a type by its index, so an addition structurally
identical to a type already defined returns that type's index, as wasm's iso-recursive
canonicalization identifies the two at run time; dart's defineStruct and defineArray define a
new type every time and deduplicate only function types, types.dart:406 _FunctionTypeKey.)
"""
function add_type!(mod::WasmModule, ct::CompositeType)::UInt32
    _check_refs_defined(mod, ct, length(mod.types))
    ct isa StructType && _validate_struct_subtype!(mod, ct)
    # Check if type already exists (structural deduplication)
    for (i, existing) in enumerate(mod.types)
        if types_equal(existing, ct)
            return UInt32(i - 1)
        end
    end
    push!(mod.types, ct)
    idx = UInt32(length(mod.types) - 1)
    return idx
end

# parity(pkg/wasm_builder/lib/src/builder/types.dart:406 _FunctionTypeKey.==)
function types_equal(a::FuncType, b::FuncType)::Bool
    a.params == b.params && a.results == b.results
end

# parity(quarantine: the structural identity add_type! deduplicates by, above.)
function types_equal(a::StructType, b::StructType)::Bool
    # step5: the SUPERTYPE is part of a struct type's identity — the class-DAG's
    # synthetic {classId} structs differ ONLY by their parent (dedup collapsed the
    # whole hierarchy into $JlBase otherwise). Matches wasm's nominal-ish subtyping:
    # (sub A (struct i32)) and (sub B (struct i32)) are distinct types.
    a.supertype_idx == b.supertype_idx &&
    length(a.fields) == length(b.fields) &&
    all(fields_equal(af, bf) for (af, bf) in zip(a.fields, b.fields))
end

# parity(quarantine: the structural identity add_type! deduplicates by, above.)
function types_equal(a::ArrayType, b::ArrayType)::Bool
    fields_equal(a.elem, b.elem)
end

# parity(quarantine: the structural identity add_type! deduplicates by, above.)
types_equal(a::CompositeType, b::CompositeType)::Bool = false  # Different types

# parity(quarantine: the structural identity add_type! deduplicates by, above.)
function fields_equal(a::FieldType, b::FieldType)::Bool
    a.valtype == b.valtype && a.mutable_ == b.mutable_
end

"""
    add_struct_type!(mod, fields) -> type_idx

Add a struct type to the module and return its index.
parity(pkg/wasm_builder/lib/src/builder/types.dart:350 TypesBuilder.defineStruct)
"""
function add_struct_type!(mod::WasmModule, fields::Vector{FieldType})::UInt32
    return add_type!(mod, StructType(fields))
end

"""
    add_array_type!(mod, elem_type, mutable_=true) -> type_idx

Add an array type to the module and return its index.
parity(pkg/wasm_builder/lib/src/builder/types.dart:368 TypesBuilder.defineArray)
"""
function add_array_type!(mod::WasmModule, elem_type::WasmValType, mutable_::Bool=true)::UInt32
    add_type!(mod, ArrayType(FieldType(elem_type, mutable_)))
end

"""
    type_refs(ct) -> Vector{UInt32}

The type indices a composite type refers to: its concrete reference types and its supertype
(dart's edges of the type graph).
parity(pkg/wasm_builder/lib/src/builder/types.dart:85 _RecGroupBuilder._edgesforType)
"""
function type_refs(ct::CompositeType)::Vector{UInt32}
    local refs = UInt32[]
    local add(vt) = vt isa ConcreteRef && push!(refs, vt.type_idx)
    if ct isa FuncType
        foreach(add, ct.params); foreach(add, ct.results)
    elseif ct isa StructType
        foreach(f -> add(f.valtype), ct.fields)
        ct.supertype_idx === nothing || push!(refs, ct.supertype_idx)
    else
        add(ct.elem.valtype)
    end
    return refs
end

# every type index `ct` refers to is below `limit`: a type is added after what it refers to,
# or with it in one group (add_type_group!)
# parity(quarantine: WT numbers a type when it is added, since function bodies are bytes by the
# time the module is written (dev/formal/RecGroup.tla), so each addition must refer only
# backward or within its group; dart numbers every type at the end, types.dart:240.)
function _check_refs_defined(mod::WasmModule, ct::CompositeType, limit::Integer)::Nothing
    for r in type_refs(ct)
        Int(r) < limit ||
            _module_invalid(:add_type, "type refers to type $r, which is not defined before it or in its recursion group")
    end
end

"""
    add_type_group!(mod, types) -> first index

Add types that refer to one another (a strongly connected component of the type graph) at
consecutive indices, without structural deduplication: each may refer to any of them and to
every type defined before them.
parity(pkg/wasm_builder/lib/src/builder/types.dart:350 TypesBuilder.defineStruct): the types
are defined, and their recursion group follows from the graph (recursion_groups).
"""
function add_type_group!(mod::WasmModule, types::Vector{CompositeType})::UInt32
    local base = length(mod.types)
    for ct in types
        _check_refs_defined(mod, ct, base + length(types))
    end
    append!(mod.types, types)
    for ct in types
        ct isa StructType && _validate_struct_subtype!(mod, ct)
    end
    return UInt32(base)
end

"""
    recursion_groups(mod) -> Vector{UnitRange{Int}}

The type section's recursion groups, 0-based index ranges in section order: the strongly
connected components of the type graph. Each must be a contiguous run of indices, and every
reference out of a group must point to an earlier one; otherwise the section is invalid and
this refuses it.
parity(pkg/wasm_builder/lib/src/builder/types.dart:240 _RecGroupBuilder._createAllRecursiveGroups)
"""
function recursion_groups(mod::WasmModule)::Vector{UnitRange{Int}}
    local n = length(mod.types)
    local refs = [Int[Int(r) for r in type_refs(ct)] for ct in mod.types]
    for (i, rs) in enumerate(refs), r in rs
        0 <= r < n || _module_invalid(:type_section, "type $(i - 1) refers to undefined type $r")
    end
    # Tarjan's strongly connected components, iterative (a type section can be deep)
    local num = zeros(Int, n); local low = zeros(Int, n); local onstack = falses(n)
    local stack = Int[]; local counter = 0
    local comp = zeros(Int, n)   # component root (0-based) per type
    for root in 0:n-1
        num[root + 1] == 0 || continue
        local work = Tuple{Int,Int}[(root, 1)]
        while !isempty(work)
            v, k = work[end]
            if k == 1
                counter += 1; num[v + 1] = low[v + 1] = counter
                push!(stack, v); onstack[v + 1] = true
            end
            if k <= length(refs[v + 1])
                work[end] = (v, k + 1)
                local w = refs[v + 1][k]
                if num[w + 1] == 0
                    push!(work, (w, 1))
                elseif onstack[w + 1]
                    low[v + 1] = min(low[v + 1], num[w + 1])
                end
                continue
            end
            pop!(work)
            if low[v + 1] == num[v + 1]
                while true
                    local w = pop!(stack); onstack[w + 1] = false; comp[w + 1] = v
                    w == v && break
                end
            end
            isempty(work) || (low[work[end][1] + 1] = min(low[work[end][1] + 1], low[v + 1]))
        end
    end
    local size = Dict{Int,Int}()
    for c in comp
        size[c] = get(size, c, 0) + 1
    end
    local groups = UnitRange{Int}[]
    local i = 0
    while i < n
        local j = i
        while j + 1 < n && comp[j + 2] == comp[i + 1]
            j += 1
        end
        size[comp[i + 1]] == j - i + 1 ||
            _module_invalid(:type_section, "the recursion group of type $i is not a contiguous run of indices")
        for t in i:j, r in refs[t + 1]
            (r < i || r <= j) ||
                _module_invalid(:type_section, "type $t refers forward to type $r outside its recursion group")
        end
        push!(groups, i:j)
        i = j + 1
    end
    return groups
end

"""
    add_import!(mod, module_name, field_name, params, results) -> func_idx

Add an imported function to the module and return its function index.
Imported functions come before local functions in the function index space, and WT numbers a
function when it is defined (dart finalizes every index when the module is built, a
FinalizableIndex): an import after a definition would renumber every defined function under
the calls already emitted to it, so it is refused.
parity(pkg/wasm_builder/lib/src/builder/functions.dart:43 FunctionsBuilder.import)
"""
function add_import!(mod::WasmModule,
                     module_name::String,
                     field_name::String,
                     params::Vector{NumType},
                     results::Vector{NumType})::UInt32
    _check_import_precedes_definitions(mod, module_name, field_name)
    ft = FuncType(params, results)
    type_idx = add_type!(mod, ft)
    push!(mod.imports, WasmImport(module_name, field_name, 0x00, type_idx))
    return UInt32(length(mod.imports) - 1)  # Import function indices
end

# Overload for WasmValType (supports RefType, externref, etc.)
# parity(pkg/wasm_builder/lib/src/builder/functions.dart:43 FunctionsBuilder.import)
function add_import!(mod::WasmModule,
                     module_name::String,
                     field_name::String,
                     params::Vector{<:WasmValType},
                     results::Vector{<:WasmValType})::UInt32
    _check_import_precedes_definitions(mod, module_name, field_name)
    # Convert to WasmValType vectors
    param_vec = WasmValType[p for p in params]
    result_vec = WasmValType[r for r in results]
    ft = FuncType(param_vec, result_vec)
    type_idx = add_type!(mod, ft)
    push!(mod.imports, WasmImport(module_name, field_name, 0x00, type_idx))
    return UInt32(length(mod.imports) - 1)
end

# parity(quarantine: WT numbers a function when it is defined, where dart's FinalizableIndex
# numbers it when the module is built, so a late import is refused instead of renumbered.)
_check_import_precedes_definitions(mod::WasmModule, module_name::String, field_name::String)::Nothing =
    isempty(mod.functions) ? nothing : _module_invalid(:add_import,
        "import $(module_name).$(field_name) after $(length(mod.functions)) defined function(s) " *
        "would renumber them: every import precedes the first definition")

"""
    num_imported_funcs(mod) -> Int

Return the number of imported functions (affects function index space).
parity(pkg/wasm_builder/lib/src/builder/functions.dart:13 FunctionsBuilder._importedFunctions)
"""
function num_imported_funcs(mod::WasmModule)::Int
    count(imp -> imp.kind == 0x00, mod.imports)
end

"""
    add_function!(mod, params, results, locals, body) -> func_idx

Add a function to the module and return its index.
Note: Local function indices start after imported functions.
Params and results can be NumType or WasmValType vectors.
parity(pkg/wasm_builder/lib/src/builder/functions.dart:31 FunctionsBuilder.define)
"""
function add_function!(mod::WasmModule,
                       params::Vector{<:WasmValType},
                       results::Vector{<:WasmValType},
                       locals::Vector{<:WasmValType},
                       body::Vector{UInt8})::UInt32
    ft = FuncType(WasmValType[p for p in params], WasmValType[r for r in results])
    type_idx = add_type!(mod, ft)
    push!(mod.functions, WasmFunction(type_idx, WasmValType[l for l in locals], body))
    # Function index = number of imported functions + local function index
    return UInt32(num_imported_funcs(mod) + length(mod.functions) - 1)
end

"""
    add_export!(mod, name, kind, idx)

Add an export entry to the module.
- kind: 0=func, 1=table, 2=memory, 3=global
parity(pkg/wasm_builder/lib/src/builder/exports.dart:14 ExportsBuilder.export)
"""
function add_export!(mod::WasmModule, name::String, kind::Integer, idx::Integer)::WasmModule
    0 <= kind <= 4 || _module_invalid(:add_export, "unknown export kind $kind")
    limit = kind == 0 ? _function_count(mod) :
            kind == 1 ? length(mod.tables) :
            kind == 2 ? length(mod.memories) :
            kind == 3 ? length(mod.globals) : length(mod.tags)
    0 <= idx < limit || _module_invalid(:add_export, "index $idx is out of bounds for kind $kind")
    any(e -> e.name == name, mod.exports) &&
        _module_invalid(:add_export, "duplicate export name $(repr(name))")
    push!(mod.exports, WasmExport(name, UInt8(kind), UInt32(idx)))
    return mod
end

"""
    add_global!(mod, valtype, mutable, init_value) -> global_idx

Add a global variable to the module and return its index.
The init_value should be a constant of the appropriate type.
parity(pkg/wasm_builder/lib/src/builder/globals.dart:29 GlobalsBuilder.define)
"""
function add_global!(mod::WasmModule, valtype::WasmValType, mutable_::Bool, init_value)::UInt32
    # Generate initialization expression
    init = UInt8[]
    if valtype == I32
        push!(init, Opcode.I32_CONST)
        append!(init, encode_leb128_signed(Int32(init_value)))
    elseif valtype == I64
        push!(init, Opcode.I64_CONST)
        append!(init, encode_leb128_signed(Int64(init_value)))
    elseif valtype == F32
        push!(init, Opcode.F32_CONST)
        append!(init, reinterpret(UInt8, [Float32(init_value)]))
    elseif valtype == F64
        push!(init, Opcode.F64_CONST)
        append!(init, reinterpret(UInt8, [Float64(init_value)]))
    elseif valtype == ExternRef
        # externref initialized to null
        push!(init, Opcode.REF_NULL)
        push!(init, 0x6F)  # externref heap type
    else
        error("Unsupported global type: $valtype")
    end
    push!(init, Opcode.END)

    push!(mod.globals, WasmGlobalDef(valtype, mutable_, init))
    return UInt32(length(mod.globals) - 1)
end

"""
    add_global_ref!(mod, type_idx, mutable, init_expr) -> global_idx

Add a global variable with a WasmGC reference type to the module.
parity(pkg/wasm_builder/lib/src/builder/globals.dart:29 GlobalsBuilder.define)
The init_expr should be the bytecode for the initialization expression
(e.g., struct.new instructions) WITHOUT the trailing END byte.

# Arguments
- `mod`: The WasmModule to add the global to
- `type_idx`: The type index of the WasmGC struct/array type
- `mutable_`: Whether the global is mutable
- `init_expr`: The initialization bytecode (without END byte)
- `nullable`: Whether the reference is nullable (default: true)

# Example
```julia
# Create a global holding a struct instance
struct_type_idx = add_struct_type!(mod, [...])
init_bytes = [Opcode.GC_PREFIX, Opcode.STRUCT_NEW_DEFAULT, ...type_idx_leb...]
global_idx = add_global_ref!(mod, struct_type_idx, true, init_bytes)
```
"""
function add_global_ref!(mod::WasmModule, type_idx::Integer, mutable_::Bool, init_expr::Vector{UInt8}; nullable::Bool=true)::UInt32
    # Reference type to the struct (ConcreteRef: type_idx first, then nullable)
    valtype = ConcreteRef(UInt32(type_idx), nullable)

    # Add END byte to init expression
    init = copy(init_expr)
    push!(init, Opcode.END)

    push!(mod.globals, WasmGlobalDef(valtype, mutable_, init))
    return UInt32(length(mod.globals) - 1)
end

"""
    add_global_export!(mod, name, global_idx)

Export a global variable.
parity(pkg/wasm_builder/lib/src/builder/exports.dart:14 ExportsBuilder.export)
"""
function add_global_export!(mod::WasmModule, name::String, global_idx::Integer)::WasmModule
    add_export!(mod, name, 3, global_idx)  # kind 3 = global
end

"""
    add_table!(mod, reftype, min, max=nothing) -> table_idx

Add a table to the module. Tables hold references (funcref or externref).
parity(pkg/wasm_builder/lib/src/builder/tables.dart:18 TablesBuilder.define)
"""
function add_table!(mod::WasmModule, reftype::RefType, min::Integer, max::Union{Integer, Nothing}=nothing)::UInt32
    min >= 0 || _module_invalid(:add_table, "minimum must be nonnegative")
    max !== nothing && max < min && _module_invalid(:add_table, "maximum $max is below minimum $min")
    max_val = max === nothing ? nothing : UInt32(max)
    push!(mod.tables, WasmTable(reftype, UInt32(min), max_val))
    return UInt32(length(mod.tables) - 1)
end

"""
    add_table_export!(mod, name, table_idx)

Export a table.
parity(pkg/wasm_builder/lib/src/builder/exports.dart:14 ExportsBuilder.export)
"""
function add_table_export!(mod::WasmModule, name::String, table_idx::Integer)::WasmModule
    add_export!(mod, name, 1, table_idx)  # kind 1 = table
end

"""
    add_elem_segment!(mod, table_idx, offset, func_indices)

Add an element segment to initialize a table with function references.
parity(pkg/wasm_builder/lib/src/builder/elements.dart:84 ActiveFunctionSegmentBuilder.setFunctionAt)
"""
function add_elem_segment!(mod::WasmModule, table_idx::Integer, offset::Integer, func_indices::Vector{<:Integer})::WasmModule
    0 <= table_idx < length(mod.tables) || _module_invalid(:add_elem_segment, "unknown table $table_idx")
    offset >= 0 || _module_invalid(:add_elem_segment, "offset must be nonnegative")
    all(i -> 0 <= i < _function_count(mod), func_indices) ||
        _module_invalid(:add_elem_segment, "segment contains an unknown function")
    push!(mod.elem_segments, WasmElemSegment(UInt32(table_idx), UInt32(offset), UInt32[f for f in func_indices]))
    return mod
end


"""
    declare_funcs!(mod, func_indices)

A DECLARATIVE element segment (flags=3) — makes the functions legal
`ref.func` targets in constant expressions (the vtable-global initializers).
parity(pkg/wasm_builder/lib/src/builder/elements.dart:68 DeclarativeSegmentBuilder.declare)
"""
function declare_funcs!(mod::WasmModule, func_indices::Vector{UInt32})::Nothing
    isempty(func_indices) && return
    all(i -> Int(i) < _function_count(mod), func_indices) ||
        _module_invalid(:declare_funcs, "declaration contains an unknown function")
    push!(mod.elem_segments, WasmElemSegment(UInt32(0), UInt32(0), func_indices, true))
    return
end

"""
    add_memory!(mod, min, max=nothing) -> memory_idx

Add a linear memory to the module. Size is in pages (64KB each).
parity(pkg/wasm_builder/lib/src/builder/memories.dart:18 MemoriesBuilder.define)
"""
function add_memory!(mod::WasmModule, min::Integer, max::Union{Integer, Nothing}=nothing)::UInt32
    min >= 0 || _module_invalid(:add_memory, "minimum must be nonnegative")
    max !== nothing && max < min && _module_invalid(:add_memory, "maximum $max is below minimum $min")
    max_val = max === nothing ? nothing : UInt32(max)
    push!(mod.memories, WasmMemory(UInt32(min), max_val))
    return UInt32(length(mod.memories) - 1)
end

"""
    add_memory_export!(mod, name, memory_idx)

Export a memory.
parity(pkg/wasm_builder/lib/src/builder/exports.dart:14 ExportsBuilder.export)
"""
function add_memory_export!(mod::WasmModule, name::String, memory_idx::Integer)::WasmModule
    add_export!(mod, name, 2, memory_idx)  # kind 2 = memory
end

"""
    add_data_segment!(mod, memory_idx, offset, data)

Add a data segment to initialize linear memory with constant data.
Data can be a Vector{UInt8} or a String.
parity(pkg/wasm_builder/lib/src/builder/data_segments.dart:24 DataSegmentsBuilder.define)
"""
function add_data_segment!(mod::WasmModule, memory_idx::Integer, offset::Integer, data::Vector{UInt8})::WasmModule
    0 <= memory_idx < length(mod.memories) || _module_invalid(:add_data_segment, "unknown memory $memory_idx")
    offset >= 0 || _module_invalid(:add_data_segment, "offset must be nonnegative")
    push!(mod.data_segments, WasmDataSegment(UInt32(memory_idx), UInt32(offset), data))
    return mod
end

# parity(pkg/wasm_builder/lib/src/builder/data_segments.dart:24 DataSegmentsBuilder.define)
function add_data_segment!(mod::WasmModule, memory_idx::Integer, offset::Integer, data::String)::WasmModule
    add_data_segment!(mod, memory_idx, offset, Vector{UInt8}(codeunits(data)))
end

"""
    add_passive_data_segment!(mod, data) -> segment_index

Add a passive data segment (used with array.new_data or memory.init).
Returns the 0-based index of the data segment.
parity(quarantine: WT emits a string's bytes from more than one site (its interned constant
global and a long string's lazy initializer), so a passive segment with the same content
returns the existing one; dart's DataSegmentsBuilder.define, data_segments.dart:24, defines a
new segment every time, its constants being interned once each.)
"""
function add_passive_data_segment!(mod::WasmModule, data::Vector{UInt8})::UInt32
    # Passive segments are
    # read-only sources for array.new_data, so CONTENT-equal segments are
    # semantically identical — dedup by content. Repeated string/symbol
    # constants stop minting fresh segments.
    for (i, seg) in enumerate(mod.data_segments)
        if seg.passive && seg.data == data
            return UInt32(i - 1)
        end
    end
    idx = UInt32(length(mod.data_segments))
    push!(mod.data_segments, WasmDataSegment(UInt32(0), UInt32(0), data, true))
    return idx
end

"""
    add_tag!(mod, type_idx) -> tag_idx

Add an exception tag to the module and return its index.
The type_idx refers to a FuncType whose params define the exception payload.
parity(pkg/wasm_builder/lib/src/builder/tags.dart:27 TagsBuilder.define)
"""
function add_tag!(mod::WasmModule, type_idx::Integer)::UInt32
    0 <= type_idx < length(mod.types) || _module_invalid(:add_tag, "unknown type $type_idx")
    ft = mod.types[type_idx + 1]
    ft isa FuncType || _module_invalid(:add_tag, "tag type $type_idx is not a function type")
    isempty(ft.results) || _module_invalid(:add_tag, "tag type must have no results")
    push!(mod.tags, WasmTag(UInt32(type_idx)))
    return UInt32(length(mod.tags) - 1)
end

"""
    add_start_function!(mod, func_idx)

Set the start function for the module. This function is called automatically
on module instantiation. The function must take no parameters and return nothing.
parity(pkg/wasm_builder/lib/src/builder/module.dart:79 ModuleBuilder.startFunction)
"""
function add_start_function!(mod::WasmModule, func_idx::Integer)::WasmModule
    ft = _function_type(mod, func_idx)
    (isempty(ft.params) && isempty(ft.results)) ||
        _module_invalid(:add_start_function, "start function must have type [] -> []")
    mod.start_function = UInt32(func_idx)
    return mod
end

# ============================================================================
# Binary Serialization
# ============================================================================

# parity-region(pkg/wasm_builder/lib/src/ir/module.dart:98 Module.serialize)
const WASM_MAGIC = UInt8[0x00, 0x61, 0x73, 0x6D]  # \0asm; parity(pkg/wasm_builder/lib/src/ir/module.dart:98 Module.serialize)
const WASM_VERSION = UInt8[0x01, 0x00, 0x00, 0x00]  # version 1; parity(pkg/wasm_builder/lib/src/ir/module.dart:98 Module.serialize)
# end parity-region

# Section IDs
# parity-region(pkg/wasm_builder/lib/src/serialize/sections.dart:41 Section.id)
const SECTION_TYPE = 0x01  # parity(pkg/wasm_builder/lib/src/serialize/sections.dart:47 TypeSection.sectionId)
const SECTION_IMPORT = 0x02  # parity(pkg/wasm_builder/lib/src/serialize/sections.dart:145 ImportSection.sectionId)
const SECTION_FUNCTION = 0x03  # parity(pkg/wasm_builder/lib/src/serialize/sections.dart:276 FunctionSection.sectionId)
const SECTION_TABLE = 0x04  # parity(pkg/wasm_builder/lib/src/serialize/sections.dart:322 TableSection.sectionId)
const SECTION_MEMORY = 0x05  # parity(pkg/wasm_builder/lib/src/serialize/sections.dart:367 MemorySection.sectionId)
const SECTION_GLOBAL = 0x06  # parity(pkg/wasm_builder/lib/src/serialize/sections.dart:457 GlobalSection.sectionId)
const SECTION_EXPORT = 0x07  # parity(pkg/wasm_builder/lib/src/serialize/sections.dart:508 ExportSection.sectionId)
const SECTION_ELEMENT = 0x09  # parity(pkg/wasm_builder/lib/src/serialize/sections.dart:582 ElementSection.sectionId)
const SECTION_CODE = 0x0A  # parity(pkg/wasm_builder/lib/src/serialize/sections.dart:682 CodeSection.sectionId)
const SECTION_DATA = 0x0B  # parity(pkg/wasm_builder/lib/src/serialize/sections.dart:760 DataSection.sectionId)
const SECTION_START = 0x08    # Start function (section 8); parity(pkg/wasm_builder/lib/src/serialize/sections.dart:557 StartSection.sectionId)
const SECTION_DATACOUNT = 0x0C  # Data count (section 12); parity(pkg/wasm_builder/lib/src/serialize/sections.dart:653 DataCountSection.sectionId)
const SECTION_TAG = 0x0D      # Exception tags (section 13); parity(pkg/wasm_builder/lib/src/serialize/sections.dart:413 TagSection.sectionId)
# end parity-region

"""
    to_bytes(mod::WasmModule) -> Vector{UInt8}

Serialize a WasmModule to binary format.
parity(pkg/wasm_builder/lib/src/ir/module.dart:98 Module.serialize)
"""
to_bytes(mod::WasmModule)::Vector{UInt8} = first(to_bytes_mapped(mod))

"""
    to_bytes_with_source_map(mod) -> (bytes, source_map_json)

Serialize `mod` — which records source maps (`mod.source_map_url`) — with its
`sourceMappingURL` section, and the Source Map v3 JSON of its functions' mappings at their
module byte offsets.
parity(pkg/wasm_builder/lib/source_map.dart:94 SourceMapSerializer.serializeAsJson)
"""
function to_bytes_with_source_map(mod::WasmModule)::Tuple{Vector{UInt8},String}
    mod.source_map_url === nothing &&
        throw(ArgumentError("the module records no source maps (it has no source_map_url)"))
    local bytes, mappings = to_bytes_mapped(mod)
    return bytes, source_map_json(mappings)
end

"""
    to_bytes_mapped(mod) -> (bytes, mappings)

Serialize `mod`, and each function's source mappings at their module byte offsets: a body's
offsets move by where the body lands in the code section's contents, then by where those
contents land in the module (dart: function.dart:123 and sections.dart:33 copyMappings). A
module with a `source_map_url` gets the `sourceMappingURL` section after the name section.
parity(pkg/wasm_builder/lib/src/ir/module.dart:98 Module.serialize)
"""
function to_bytes_mapped(mod::WasmModule)::Tuple{Vector{UInt8},Vector{SourceMapping}}
    w = WasmWriter()
    local module_mappings = SourceMapping[]

    # Magic number and version
    write_bytes!(w, WASM_MAGIC...)
    write_bytes!(w, WASM_VERSION...)

    # Type section
    if !isempty(mod.types)
        write_section!(w, SECTION_TYPE) do section
            local groups = recursion_groups(mod)
            # the types some struct declares as its supertype (dart's hasAnySubtypes)
            local subtyped = Set{UInt32}(ct.supertype_idx for ct in mod.types
                                         if ct isa StructType && ct.supertype_idx !== nothing)
            write_u32!(section, length(groups))
            for g in groups
                if length(g) > 1
                    write_byte!(section, REC_BYTE)  # 0x4E = rec
                    write_u32!(section, length(g))
                end
                for ti in g
                    write_type_definition!(section, mod.types[ti + 1], UInt32(ti) in subtyped)
                end
            end
        end
    end

    # Import section
    if !isempty(mod.imports)
        write_section!(w, SECTION_IMPORT) do section
            write_u32!(section, length(mod.imports))
            for imp in mod.imports
                write_name!(section, imp.module_name)
                write_name!(section, imp.field_name)
                write_byte!(section, imp.kind)
                write_u32!(section, imp.type_idx)
            end
        end
    end

    # Function section (type indices)
    if !isempty(mod.functions)
        write_section!(w, SECTION_FUNCTION) do section
            write_u32!(section, length(mod.functions))
            for func in mod.functions
                write_u32!(section, func.type_idx)
            end
        end
    end

    # Table section
    if !isempty(mod.tables)
        write_section!(w, SECTION_TABLE) do section
            write_u32!(section, length(mod.tables))
            for table in mod.tables
                write_valtype!(section, table.reftype)
                # Limits: 0x00 = min only, 0x01 = min and max
                if table.max === nothing
                    write_byte!(section, 0x00)
                    write_u32!(section, table.min)
                else
                    write_byte!(section, 0x01)
                    write_u32!(section, table.min)
                    write_u32!(section, table.max)
                end
            end
        end
    end

    # Memory section
    if !isempty(mod.memories)
        write_section!(w, SECTION_MEMORY) do section
            write_u32!(section, length(mod.memories))
            for mem in mod.memories
                # Limits: 0x00 = min only, 0x01 = min and max
                if mem.max === nothing
                    write_byte!(section, 0x00)
                    write_u32!(section, mem.min)
                else
                    write_byte!(section, 0x01)
                    write_u32!(section, mem.min)
                    write_u32!(section, mem.max)
                end
            end
        end
    end

    # Tag section (exception handling)
    if !isempty(mod.tags)
        write_section!(w, SECTION_TAG) do section
            write_u32!(section, length(mod.tags))
            for tag in mod.tags
                # Tag format: attribute (0x00 = exception) + type_idx
                write_byte!(section, 0x00)  # exception attribute
                write_u32!(section, tag.type_idx)
            end
        end
    end

    # Global section
    if !isempty(mod.globals)
        write_section!(w, SECTION_GLOBAL) do section
            write_u32!(section, length(mod.globals))
            for g in mod.globals
                # Global type: valtype + mutability
                write_valtype!(section, g.valtype)
                write_byte!(section, g.mutable_ ? 0x01 : 0x00)
                # Init expression (already includes END byte)
                append!(section.buffer, g.init)
            end
        end
    end

    # Export section
    if !isempty(mod.exports)
        write_section!(w, SECTION_EXPORT) do section
            write_u32!(section, length(mod.exports))
            for exp in mod.exports
                write_name!(section, exp.name)
                write_byte!(section, exp.kind)
                write_u32!(section, exp.idx)
            end
        end
    end

    # Start section
    if mod.start_function !== nothing
        write_section!(w, SECTION_START) do section
            write_u32!(section, mod.start_function)
        end
    end

    # Element section
    if !isempty(mod.elem_segments)
        write_section!(w, SECTION_ELEMENT) do section
            write_u32!(section, length(mod.elem_segments))
            for elem in mod.elem_segments
                if elem.declared
                    # Declarative — elemkind + vec(funcidx), no table/offset
                    write_byte!(section, 0x03)
                    write_byte!(section, 0x00)  # elemkind: funcref
                elseif elem.table_idx == UInt32(0)
                    # Element segment kind 0: active, table index 0, funcref
                    # Binary format: flags (0) + offset expr + vec(funcidx)
                    write_byte!(section, 0x00)  # flags: active segment, table 0
                else
                    # Element segment kind 2: active, explicit table index, funcref
                    # Binary format: flags (2) + table_idx + offset expr + elemkind + vec(funcidx)
                    write_byte!(section, 0x02)  # flags: active segment, explicit table index
                    write_u32!(section, elem.table_idx)
                end
                if !elem.declared
                    # Offset expression (i32.const offset)
                    push!(section.buffer, Opcode.I32_CONST)
                    append!(section.buffer, encode_leb128_signed(Int32(elem.offset)))
                    push!(section.buffer, Opcode.END)
                end
                if !elem.declared && elem.table_idx != UInt32(0)
                    # elemkind for flags=2: 0x00 = funcref
                    write_byte!(section, 0x00)
                end
                # Vector of function indices
                write_u32!(section, length(elem.func_indices))
                for func_idx in elem.func_indices
                    write_u32!(section, func_idx)
                end
            end
        end
    end

    # Data count section (required by some runtimes when bulk memory ops are used)
    if !isempty(mod.data_segments)
        write_section!(w, SECTION_DATACOUNT) do section
            write_u32!(section, length(mod.data_segments))
        end
    end

    # Code section
    if !isempty(mod.functions)
        local code_mappings = SourceMapping[]   # offsets into the code section's contents
        local code_length = 0
        write_section!(w, SECTION_CODE) do section
            write_u32!(section, length(mod.functions))
            for func in mod.functions
                # Write function body with locals
                body_writer = WasmWriter()

                # Locals count (compressed format)
                if isempty(func.locals)
                    write_u32!(body_writer, 0)
                else
                    # Group consecutive locals of same type
                    local_groups = group_locals(func.locals)
                    write_u32!(body_writer, length(local_groups))
                    for (count, valtype) in local_groups
                        write_u32!(body_writer, count)
                        write_valtype!(body_writer, valtype)
                    end
                end

                # Body instructions
                local body_start = length(body_writer.buffer)
                append!(body_writer.buffer, func.body)

                # Write body size then body
                write_u32!(section, length(body_writer.buffer))
                local entry_start = length(section.buffer)
                for m in func.mappings
                    push!(code_mappings, shift_by(m, entry_start + body_start))
                end
                append!(section.buffer, body_writer.buffer)
            end
            code_length = length(section.buffer)
        end
        # the contents end the module so far: they start `code_length` bytes before its end
        local contents_start = length(w.buffer) - code_length
        for m in code_mappings
            push!(module_mappings, shift_by(m, contents_start))
        end
    end

    # Data section
    if !isempty(mod.data_segments)
        write_section!(w, SECTION_DATA) do section
            write_u32!(section, length(mod.data_segments))
            for data in mod.data_segments
                if data.passive
                    # Passive data segment (mode 1): no memory association
                    # Used with array.new_data and memory.init
                    write_byte!(section, 0x01)
                    # Data bytes
                    write_u32!(section, length(data.data))
                    append!(section.buffer, data.data)
                else
                    # Active data segment (mode 0): memory index 0
                    write_byte!(section, 0x00)
                    # Offset expression (i32.const offset)
                    push!(section.buffer, Opcode.I32_CONST)
                    append!(section.buffer, encode_leb128_signed(Int32(data.offset)))
                    push!(section.buffer, Opcode.END)
                    # Data bytes
                    write_u32!(section, length(data.data))
                    append!(section.buffer, data.data)
                end
            end
        end
    end

    # Name section (custom section) for stack trace readability
    # Includes function names from exports so stack traces show meaningful names
    func_names = Dict{UInt32, String}()
    # Collect names from imports
    func_idx = UInt32(0)
    for imp in mod.imports
        if imp.kind == 0x00  # function import
            func_names[func_idx] = "$(imp.module_name).$(imp.field_name)"
            func_idx += 1
        end
    end
    # Collect names from exports (overrides import names if both exist)
    for exp in mod.exports
        if exp.kind == 0x00  # function export
            func_names[exp.idx] = exp.name
        end
    end
    if !isempty(func_names)
        # Custom section (section id 0)
        write_byte!(w, 0x00)
        custom_section = WasmWriter()
        # Section name: "name"
        write_name!(custom_section, "name")
        # Subsection 1: function names
        subsection = WasmWriter()
        sorted_names = sort(collect(func_names), by=first)
        write_u32!(subsection, length(sorted_names))
        for (idx, name) in sorted_names
            write_u32!(subsection, idx)
            write_name!(subsection, name)
        end
        # Write subsection (id=1, then size, then content)
        write_byte!(custom_section, 0x01)  # subsection id: function names
        write_u32!(custom_section, length(subsection.buffer))
        append!(custom_section.buffer, subsection.buffer)
        # Write custom section size then content
        write_u32!(w, length(custom_section.buffer))
        append!(w.buffer, custom_section.buffer)
    end

    mod.source_map_url === nothing || write_source_mapping_url_section!(w, mod.source_map_url)
    return bytes(w), module_mappings
end

"""
    write_source_mapping_url_section!(w, url)

The `sourceMappingURL` custom section: its name, then the URL of the module's source map.
parity(pkg/wasm_builder/lib/src/serialize/sections.dart:1085 SourceMapSection)
"""
function write_source_mapping_url_section!(w::WasmWriter, url::String)::WasmWriter
    local contents = WasmWriter()
    write_name!(contents, "sourceMappingURL")
    write_name!(contents, url)
    write_byte!(w, 0x00)
    write_u32!(w, length(contents.buffer))
    append!(w.buffer, contents.buffer)
    return w
end

"""
Write a section with automatic size calculation.
parity(pkg/wasm_builder/lib/src/serialize/sections.dart:26 Section.serialize)
"""
function write_section!(f::Function, w::WasmWriter, section_id::UInt8)::Vector{UInt8}
    section = WasmWriter()
    f(section)

    write_byte!(w, section_id)
    write_u32!(w, length(section.buffer))
    append!(w.buffer, section.buffer)
end

"""
Group consecutive locals of the same type.
parity(pkg/wasm_builder/lib/src/ir/function.dart:101 DefinedFunction.serialize)
"""
function group_locals(locals::Vector{<:WasmValType})::Vector{Tuple{Int64, WasmValType}}
    isempty(locals) && return Tuple{Int, WasmValType}[]

    groups = Tuple{Int, WasmValType}[]
    current_type = locals[1]
    count = 1

    for i in 2:length(locals)
        if locals[i] == current_type
            count += 1
        else
            push!(groups, (count, current_type))
            current_type = locals[i]
            count = 1
        end
    end
    push!(groups, (count, current_type))

    return groups
end

# ============================================================================
# Composite Type Serialization (WasmGC)
# ============================================================================

# Type constructors for binary encoding
# parity(pkg/wasm_builder/lib/src/ir/type.dart:1022 FunctionType.serializeDefinitionInner)
const FUNCTYPE_BYTE = 0x60
# parity(pkg/wasm_builder/lib/src/ir/type.dart:1167 StructType.serializeDefinitionInner)
const STRUCTTYPE_BYTE = 0x5F
# parity(pkg/wasm_builder/lib/src/ir/type.dart:1255 ArrayType.serializeDefinitionInner)
const ARRAYTYPE_BYTE = 0x5E

# WasmGC subtype opcodes (required for GC types)
# parity(pkg/wasm_builder/lib/src/ir/type.dart:747 DefType.serializeDefinition)
const SUB_BYTE = 0x50       # sub (non-final subtype)
# parity(pkg/wasm_builder/lib/src/ir/type.dart:747 DefType.serializeDefinition)
const SUB_FINAL_BYTE = 0x4F # sub final (final subtype, no further subtyping)
# parity(pkg/wasm_builder/lib/src/serialize/sections.dart:59 TypeSection.serializeContents)
const REC_BYTE = 0x4E       # rec (recursive type group)

"""
    write_type_definition!(w, ct, has_subtypes)

A type-section entry: the subtyping prefix, then the composite type. A type with a supertype
is `sub final` when nothing subtypes it and `sub` when something does; a type without one is
`sub` (with no supertypes) only when something subtypes it, and has no prefix otherwise — a
final type, as dart writes every class no other class extends.
parity(pkg/wasm_builder/lib/src/ir/type.dart:747 DefType.serializeDefinition)
"""
function write_type_definition!(w::WasmWriter, ct::CompositeType, has_subtypes::Bool)::Nothing
    sup = ct isa StructType ? ct.supertype_idx : nothing
    if sup !== nothing
        write_byte!(w, has_subtypes ? SUB_BYTE : SUB_FINAL_BYTE)
        write_u32!(w, 1)
        write_u32!(w, sup)
    elseif has_subtypes
        write_byte!(w, SUB_BYTE)
        write_u32!(w, 0)
    end
    write_composite_type!(w, ct)
    return nothing
end

"""
Write a function type's definition (after its subtyping prefix, write_type_definition!).
parity(pkg/wasm_builder/lib/src/ir/type.dart:1022 FunctionType.serializeDefinitionInner)
"""
function write_composite_type!(w::WasmWriter, ft::FuncType)::Nothing
    write_byte!(w, FUNCTYPE_BYTE)
    # Write params as a vector of valtypes
    write_u32!(w, length(ft.params))
    for p in ft.params
        write_valtype!(w, p)
    end
    # Write results as a vector of valtypes
    write_u32!(w, length(ft.results))
    for r in ft.results
        write_valtype!(w, r)
    end
end

# parity(pkg/wasm_builder/lib/src/ir/type.dart:1167 StructType.serializeDefinitionInner)
function write_composite_type!(w::WasmWriter, st::StructType)::Nothing
    write_byte!(w, STRUCTTYPE_BYTE)
    write_u32!(w, length(st.fields))
    for field in st.fields
        write_field_type!(w, field)
    end
end

# parity(pkg/wasm_builder/lib/src/ir/type.dart:1255 ArrayType.serializeDefinitionInner)
function write_composite_type!(w::WasmWriter, at::ArrayType)::WasmWriter
    write_byte!(w, ARRAYTYPE_BYTE)
    write_field_type!(w, at.elem)
end

"""
Write a field type (valtype + mutability).
parity(pkg/wasm_builder/lib/src/ir/type.dart:1296 _WithMutability.serialize)
"""
function write_field_type!(w::WasmWriter, ft::FieldType)::WasmWriter
    write_valtype!(w, ft.valtype)
    write_byte!(w, ft.mutable_ ? 0x01 : 0x00)
end

"""
Write a value type (NumType, RefType, or packed type).
parity(pkg/wasm_builder/lib/src/ir/type.dart:121 NumType.serialize)
"""
function write_valtype!(w::WasmWriter, vt::NumType)::WasmWriter
    write_byte!(w, UInt8(vt))
end

# parity(pkg/wasm_builder/lib/src/ir/type.dart:249 RefType.serialize)
function write_valtype!(w::WasmWriter, vt::RefType)::WasmWriter
    # FuncRef (0x70) and ExternRef (0x6F) are nullable shorthand forms
    # Abstract GC heap types (StructRef, ArrayRef, etc.) need nullable wrapper
    # when used as locals/params: (ref null struct) = 0x63 + heaptype
    if vt == StructRef || vt == ArrayRef || vt == EqRef || vt == AnyRef || vt == I31Ref
        write_byte!(w, 0x63)  # ref null prefix
        write_byte!(w, UInt8(vt))
    else
        # FuncRef, ExternRef are already nullable shorthand
        write_byte!(w, UInt8(vt))
    end
end

# parity(pkg/wasm_builder/lib/src/ir/type.dart:1399 PackedType.serialize)
function write_valtype!(w::WasmWriter, vt::UInt8)::WasmWriter
    write_byte!(w, vt)
end

# parity(pkg/wasm_builder/lib/src/ir/type.dart:249 RefType.serialize)
function write_valtype!(w::WasmWriter, vt::NonNullAbstractRef)::WasmWriter
    # Non-nullable reference to an abstract heap type: (ref extern), (ref func), etc.
    # Binary: 0x64 (non-null ref prefix) + heap type byte
    write_byte!(w, 0x64)  # ref (non-null)
    write_byte!(w, vt.heaptype_byte)
end

# parity(pkg/wasm_builder/lib/src/ir/type.dart:249 RefType.serialize)
function write_valtype!(w::WasmWriter, vt::ConcreteRef)::WasmWriter
    # Concrete reference type: (ref null $typeidx) or (ref $typeidx)
    # Binary format: 0x63 (nullable) or 0x64 (non-nullable) followed by heap type index
    if vt.nullable
        write_byte!(w, 0x63)  # ref null
    else
        write_byte!(w, 0x64)  # ref
    end
    # Heap type index is a signed LEB128 (s33)
    write_i32!(w, Int32(vt.type_idx))
end
