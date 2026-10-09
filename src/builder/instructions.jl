# WebAssembly Instructions and Opcodes
# Reference: https://webassembly.github.io/spec/core/binary/instructions.html

export Opcode, WasmModule, WasmImport, WasmTable, WasmMemory, WasmDataSegment, WasmTag, add_function!, add_import!, add_export!, add_struct_type!, add_array_type!, add_type_group!, add_table!, add_table_export!, add_elem_segment!, add_memory!, add_memory_export!, add_data_segment!, add_tag!, add_start_function!, define_function!, function_builder, fill_function!, define_global!, fill_global!, to_bytes

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

    # Exception handling instructions (legacy, the form dart2wasm emits)
    const TRY = 0x06           # try blocktype - legacy try block
    const CATCH_LEGACY = 0x07  # catch tag_idx - legacy catch of a tag
    const THROW = 0x08         # throw tag_idx - throw exception with tag

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
    const I32_STORE = 0x36

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

    # any/extern conversions (0xFB prefix)
    const ANY_CONVERT_EXTERN = 0x1A  # any.convert_extern
    const EXTERN_CONVERT_ANY = 0x1B  # extern.convert_any

# end parity-region
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:563 I32TruncSatF32S)
    # Saturating truncation (0xFC prefix, sub-ops 0x00–0x07): float → int, clamping
    # out-of-range / NaN to the int min/max/0 instead of trapping (the non-saturating
    # 0xA8–0xB1 family traps on overflow).
    const I64_TRUNC_SAT_F64_U = 0x07
# end parity-region
# parity-region(pkg/wasm_builder/lib/src/ir/instruction.dart:87 Instruction.deserialize)
    # the 0xFC prefix (saturating truncation)
    const FC_PREFIX = 0xFC
# end parity-region
end

# ============================================================================
# WasmModule - High-level module builder
# ============================================================================

"""
A function the module defines: its type, the name it is defined with (which the name section
gives it: every function has one, and an empty name, which the name section could not carry, is
refused at definition, L157), and its body once filled from a builder (fill_function!): the
locals the builder declared, its serialized instructions and their source mappings (byte offsets
into `body`). An unfilled function (`body === nothing`) is defined and not yet built; to_bytes
refuses a module holding one, as dart requires every body complete before serialization.
parity(pkg/wasm_builder/lib/src/ir/function.dart:77 DefinedFunction)
"""
struct WasmFunction
    type_idx::UInt32
    locals::Vector{WasmValType}
    body::Union{Nothing,Vector{UInt8}}
    mappings::Vector{SourceMapping}
    name::String
    function WasmFunction(type_idx::UInt32, locals::Vector{WasmValType}, body::Union{Nothing,Vector{UInt8}},
                          mappings::Vector{SourceMapping}, name::String)::WasmFunction
        isempty(name) && throw(ArgumentError("WasmFunction(type $type_idx; name=\"\"): a function is named where it is defined, and the name section drops an empty name"))
        return new(type_idx, locals, body, mappings, name)
    end
end

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
Represents an import entry, and for an imported function the name the name section gives it,
given where it is imported.
parity(pkg/wasm_builder/lib/src/ir/imports.dart:39 Import)
"""
struct WasmImport
    module_name::String
    field_name::String
    kind::UInt8  # 0=func, 1=table, 2=memory, 3=global
    type_idx::UInt32  # For functions, the type index
    # parity(pkg/wasm_builder/lib/src/ir/function.dart:37 BaseFunction.functionName): an imported function's name
    function_name::String
end

"""
    WasmGlobalDef

A global the module defines: its type, mutability, name, and initializer (define_global!).
parity(pkg/wasm_builder/lib/src/ir/global.dart:40 DefinedGlobal)
"""
struct WasmGlobalDef
    valtype::WasmValType     # Type of the global
    mutable_::Bool           # Whether the global is mutable
    # its initializer, serialized from its constant-expression builder once filled
    # (fill_global!); `nothing` while defined and not yet filled, which to_bytes refuses
    init::Union{Nothing,Vector{UInt8}}
    name::Union{Nothing,String}   # the name it was defined with (dart GlobalBuilder.globalName)
end

"""
    WasmGlobalImport

A global the module imports: its module and field, its type and mutability, and the name it is
found by (dart's Global.globalName).
parity(pkg/wasm_builder/lib/src/ir/global.dart:88 ImportedGlobal)
"""
struct WasmGlobalImport
    module_name::String
    field_name::String
    valtype::WasmValType
    mutable_::Bool
    name::Union{Nothing,String}
end

# a global of the module, imported or defined, in the one global index space: the imported
# globals first (add_global_import! refuses one after a definition), then the defined ones
# parity(pkg/wasm_builder/lib/src/ir/global.dart:10 Global)
const WasmModuleGlobal = Union{WasmGlobalImport, WasmGlobalDef}

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
    globals::Vector{WasmModuleGlobal}   # every global by its index: the imported ones, then the defined
    exports::Vector{WasmExport}
    elem_segments::Vector{WasmElemSegment}  # Element segments for table init
    data_segments::Vector{WasmDataSegment}  # Data segments for memory init
    tags::Vector{WasmTag}         # Exception tags for exception handling
    start_function::Union{Nothing, UInt32}  # Optional start function index
    # the URL a `sourceMappingURL` section names; set, every builder of this module records
    # its source mappings (dart ModuleBuilder.sourceMapUrl, module.dart:28)
    source_map_url::Union{Nothing, String}
    # the recursion groups add_type! and add_type_group! added, 0-based index ranges in section
    # order: the index their deduplication looks equal groups up in (dart computes its groups
    # once, after every type is defined, types.dart:77; the writer computes the section's and
    # refuses a complete record that disagrees)
    type_groups::Vector{UnitRange{Int}}
    # every builder of this module records its full emit log, which its errors carry (dart
    # InstructionsBuilder.traceEnabled, set from the ModuleBuilder's construction)
    builder_trace::Bool
end

# parity(pkg/wasm_builder/lib/src/builder/module.dart:48 ModuleBuilder): the source map URL and
# the trace are the module's from its construction
WasmModule(; source_map_url::Union{Nothing,String}=nothing, builder_trace::Bool=false)::WasmModule =
    WasmModule(CompositeType[], WasmImport[], WasmFunction[], WasmTable[], WasmMemory[],
               WasmModuleGlobal[], WasmExport[], WasmElemSegment[], WasmDataSegment[], WasmTag[],
               nothing, source_map_url, UnitRange{Int}[], builder_trace)

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

# the type index of function `idx`, imported or defined
# parity(pkg/wasm_builder/lib/src/ir/function.dart:36 BaseFunction.type)
function _function_type_idx(mod::WasmModule, idx::Integer)::UInt32
    0 <= idx < _function_count(mod) ||
        _module_invalid(:function_index, "function index $idx is out of bounds")
    idx < num_imported_funcs(mod) && return filter(x -> x.kind == 0x00, mod.imports)[idx + 1].type_idx
    return mod.functions[idx - num_imported_funcs(mod) + 1].type_idx
end

# parity(pkg/wasm_builder/lib/src/ir/function.dart:36 BaseFunction.type)
function _function_type(mod::WasmModule, idx::Integer)::FuncType
    ft = mod.types[Int(_function_type_idx(mod, idx)) + 1]
    ft isa FuncType || _module_invalid(:function_index, "function $idx has a non-function type")
    return ft
end

# A struct's supertype is declared before it, inside a recursion group too (the wasm rule), so
# every supertype chain ends. Checked for every type being added before any field or subtype
# check, which walks supertype chains (wasm_subtype).
# parity(pkg/wasm_builder/lib/src/ir/type.dart:712 DefType.superType)
function _check_supertype_declared_earlier(ct::CompositeType, own::Integer)::Nothing
    (ct isa StructType && ct.supertype_idx !== nothing) || return nothing
    local si = Int(ct.supertype_idx)
    0 <= si < own ||
        _module_invalid(:add_type, "struct supertype $si must be declared earlier than its subtype $own")
    return nothing
end

# parity(pkg/wasm_builder/lib/src/ir/type.dart:1136 StructType.isStructuralSubtypeOf)
function _validate_struct_subtype!(mod::WasmModule, st::StructType)::Nothing
    st.supertype_idx === nothing && return
    si = Int(st.supertype_idx)   # below the subtype's own index: _check_supertype_declared_earlier
    super = mod.types[si + 1]
    super isa StructType || _module_invalid(:add_type, "struct supertype $si is not a struct")
    length(st.fields) >= length(super.fields) ||
        _module_invalid(:add_type, "struct subtype has fewer fields than supertype $si")
    for (i, sf) in enumerate(super.fields)
        cf = st.fields[i]
        cf.mutable_ == sf.mutable_ ||
            _module_invalid(:add_type, "field $i changes mutability from supertype $si")
        # Mutable fields are invariant. Immutable fields are covariant.
        ok = sf.mutable_ ? cf.valtype == sf.valtype :
             (cf.valtype isa PackedType || sf.valtype isa PackedType) ? cf.valtype === sf.valtype :
             wasm_subtype(cf.valtype, sf.valtype, mod.types)
        ok || _module_invalid(:add_type, "field $i is not a valid subtype of supertype $si")
    end
end

"""
    add_type!(mod, composite_type) -> type_idx

Add a composite type (FuncType, StructType, or ArrayType) to the module and return its index:
an existing type with equal fields that is its own recursion group and refers to no type in it
is the same runtime type, and its index is returned (a recursion group's member is not, however
equal its fields read); otherwise a new index, its own group.
formal(dev/formal/TypeIdentity.tla): an index handed back is the runtime type requested.
parity(quarantine: WT's validator identifies a type by its index, so an addition structurally
identical to a type already defined returns that type's index, as wasm's iso-recursive
canonicalization identifies the two at run time; dart's defineStruct and defineArray define a
new type every time and deduplicate only function types, types.dart:406 _FunctionTypeKey; open
on dev/MARCH.md 13.7.)
"""
function add_type!(mod::WasmModule, ct::CompositeType)::UInt32
    _check_refs_defined(mod, ct, length(mod.types))
    _check_supertype_declared_earlier(ct, length(mod.types))
    ct isa StructType && _validate_struct_subtype!(mod, ct)
    # an existing type with equal fields that is its own recursion group, referring to no type
    # in it, is the same runtime type (a member of a recursion group is not, however equal its
    # fields read: wasm compares a group's inside references by position)
    for g in mod.type_groups
        length(g) == 1 || continue
        local existing = mod.types[first(g) + 1]
        types_equal(existing, ct) && !(UInt32(first(g)) in type_refs(existing)) && return UInt32(first(g))
    end
    push!(mod.types, ct)
    idx = UInt32(length(mod.types) - 1)
    push!(mod.type_groups, Int(idx):Int(idx))
    return idx
end

# parity(pkg/wasm_builder/lib/src/builder/types.dart:406 _FunctionTypeKey.==)
function types_equal(a::FuncType, b::FuncType)::Bool
    a.params == b.params && a.results == b.results
end

# parity(quarantine: the structural identity add_type! deduplicates by, above.)
function types_equal(a::StructType, b::StructType)::Bool
    # the supertype is part of a struct type's identity: the class hierarchy's {classId}
    # structs differ only by their parent, and (sub A (struct i32)) and (sub B (struct i32))
    # are distinct types
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
function add_array_type!(mod::WasmModule, elem_type::StorageType, mutable_::Bool=true)::UInt32
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
# parity(quarantine: WT numbers a type when it is added, a body serialized when its function is
# filled (dev/formal/RecGroup.tla), so each addition must refer only backward or within its group;
# dart numbers every type at the end, types.dart:240: eager numbering, open on dev/MARCH.md 13.7.)
function _check_refs_defined(mod::WasmModule, ct::CompositeType, limit::Integer)::Nothing
    for r in type_refs(ct)
        Int(r) < limit ||
            _module_invalid(:add_type, "type refers to type $r, which is not defined before it or in its recursion group")
    end
end

"""
    add_type_group!(mod, types) -> first index

Add types that refer to one another (a strongly connected component of the type graph) at
consecutive indices: each may refer to any of them and to every type defined before them. A
recursion group already in the section that is equal to them, member by member (a reference
inside the group by its position, one outside it by its index), is the same runtime type under
wasm's iso-recursive canonicalization, so its first index is returned and nothing is added: an
index is a runtime type, as add_type! keeps it for a single type.
formal(dev/formal/TypeIdentity.tla): two distinct indices are never one runtime type, and an
index handed back is the runtime type requested.
parity(pkg/wasm_builder/lib/src/builder/types.dart:350 TypesBuilder.defineStruct): the types
are defined, and their recursion group follows from the graph (recursion_groups). Returning an
equal group's index: parity(quarantine: WT numbers a type when it adds it, so an addition wasm
would canonicalize into an existing group must be that group's index; dart numbers its groups at
the end, a FinalizableIndex: the equal-group merge eager numbering forces, open on dev/MARCH.md
13.7.)
"""
function add_type_group!(mod::WasmModule, types::Vector{CompositeType})::UInt32
    local base = length(mod.types)
    for (k, ct) in enumerate(types)
        _check_supertype_declared_earlier(ct, base + k - 1)
        _check_refs_defined(mod, ct, base + length(types))
    end
    local n = length(types)
    # the members are one strongly connected component: each reaches every other through
    # references inside the group (one member refers to itself), as wasm's recursion groups
    # and the equality below assume
    local inside = [Int[Int(r) - base + 1 for r in type_refs(ct) if base <= r < base + n] for ct in types]
    local reach(a) = (seen = falses(n); stack = copy(inside[a]);
                      while !isempty(stack); x = pop!(stack); seen[x] && continue; seen[x] = true; append!(stack, inside[x]); end; seen)
    all(a -> all(reach(a)), 1:n) ||
        _module_invalid(:add_type_group, "the types of a recursion group must each reach every other through references inside it")
    for g in mod.type_groups
        length(g) == n || continue
        all(_group_member_equal(mod.types[first(g) + k + 1], first(g), types[k + 1], base, n)
            for k in 0:n-1) && return UInt32(first(g))
    end
    append!(mod.types, types)
    push!(mod.type_groups, base:base + n - 1)
    for ct in types
        ct isa StructType && _validate_struct_subtype!(mod, ct)
    end
    return UInt32(base)
end

"""
    _group_member_equal(a, abase, b, bbase, n) -> Bool

Whether member `a` of the recursion group at `abase` and member `b` of the group at `bbase`,
both `n` long, are the same type under wasm's iso-recursive canonicalization: the same kind,
mutability and value types, a reference inside its group matching only the one at the same
position inside the other, a reference outside it only the same index.
parity(quarantine: wasm's iso-recursive type equivalence, which WT must apply when it adds a
group (add_type_group!); dart's _areGroupsStructurallyEqual, types.dart:106, compares heap
types by identity, to decide which groups to brand.)
"""
function _group_member_equal(a::CompositeType, abase::Integer, b::CompositeType, bbase::Integer, n::Integer)::Bool
    local inside(r, base) = base <= r < base + n
    local idx_eq(ra, rb) = inside(ra, abase) ? (inside(rb, bbase) && ra - abase == rb - bbase) :
                                               (!inside(rb, bbase) && ra == rb)
    local vt_eq(x, y) = (x isa ConcreteRef && y isa ConcreteRef) ?
        (x.nullable == y.nullable && idx_eq(x.type_idx, y.type_idx)) :
        (!(x isa ConcreteRef) && !(y isa ConcreteRef) && x == y)
    local f_eq(x, y) = x.mutable_ == y.mutable_ && vt_eq(x.valtype, y.valtype)
    if a isa StructType && b isa StructType
        (a.supertype_idx === nothing) == (b.supertype_idx === nothing) || return false
        a.supertype_idx === nothing || idx_eq(a.supertype_idx, b.supertype_idx) || return false
        return length(a.fields) == length(b.fields) && all(f_eq(x, y) for (x, y) in zip(a.fields, b.fields))
    elseif a isa ArrayType && b isa ArrayType
        return f_eq(a.elem, b.elem)
    elseif a isa FuncType && b isa FuncType
        return length(a.params) == length(b.params) && length(a.results) == length(b.results) &&
               all(vt_eq(x, y) for (x, y) in zip(a.params, b.params)) &&
               all(vt_eq(x, y) for (x, y) in zip(a.results, b.results))
    end
    return false
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

Add an imported function to the module and return its function index, named
"<module>.<field> (import)", as dart2wasm names a host import (functions.dart:141).
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
    push!(mod.imports, WasmImport(module_name, field_name, 0x00, type_idx,
                                  _import_function_name(module_name, field_name)))
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
    push!(mod.imports, WasmImport(module_name, field_name, 0x00, type_idx,
                                  _import_function_name(module_name, field_name)))
    return UInt32(length(mod.imports) - 1)
end

# the name of a host import, "<module>.<field> (import)" (ImportName.toString, util.dart:94)
# parity(pkg/dart2wasm/lib/functions.dart:141 importName)
_import_function_name(module_name::String, field_name::String)::String =
    "$(module_name).$(field_name) (import)"

# parity(quarantine: a WT invention, open on dev/MARCH.md 13.7 (eager numbering) — WT numbers a function when
# it is defined, where dart's FinalizableIndex numbers it when the module is built
# (builder/util.dart:28), so a late import is refused instead of renumbered; no Julia necessity.)
_check_import_precedes_definitions(mod::WasmModule, module_name::String, field_name::String)::Nothing =
    isempty(mod.functions) ? nothing : _module_invalid(:add_import,
        "import $(module_name).$(field_name) after $(length(mod.functions)) defined function(s) " *
        "would renumber them: every import precedes the first definition")

# parity(quarantine: a WT invention, open on dev/MARCH.md 13.7 (eager numbering) — WT numbers a global when it
# is defined, where dart's FinalizableIndex numbers every global when the module is built, the
# imported ones first (builder/util.dart:28 finalizeImportsAndBuilders), so a late global import
# is refused instead of renumbered; no Julia necessity.)
function _check_global_import_precedes_definitions(mod::WasmModule, module_name::String, field_name::String)::Nothing
    local defined = findfirst(g -> g isa WasmGlobalDef, mod.globals)
    defined === nothing && return nothing
    _module_invalid(:add_global_import,
        "global import $(module_name).$(field_name) after the defined global $(defined - 1)" *
        (mod.globals[defined].name === nothing ? "" : " ($(mod.globals[defined].name))") *
        " would renumber it: every global import precedes the first defined global")
end

"""
    num_imported_funcs(mod) -> Int

Return the number of imported functions (affects function index space).
parity(pkg/wasm_builder/lib/src/builder/functions.dart:13 FunctionsBuilder._importedFunctions)
"""
function num_imported_funcs(mod::WasmModule)::Int
    count(imp -> imp.kind == 0x00, mod.imports)
end

"""
    define_function!(mod, params, results; name) -> func_idx

Define a function of type `params -> results` named `name`, with no body yet, and return its
index (imported functions come first in the index space). Its body is a builder of that type
(function_builder), filled in with fill_function!; to_bytes refuses a module with an unfilled
function. dart's `define(type, [name])` takes the name optionally, and dart2wasm names most of
its definitions (functions.dart:171 getFunctionName, each generator's own text) but not all (its
cross-module global getter and setter, globals.dart:52 and :79); WT requires it, a strengthening
of dart's practice, so no definition goes unnamed and a trap inside a function the compiler
generates names it by its construct (L157).
parity(pkg/wasm_builder/lib/src/builder/functions.dart:31 FunctionsBuilder.define)
"""
function define_function!(mod::WasmModule, params::Vector{<:WasmValType}, results::Vector{<:WasmValType};
                          name::String)::UInt32
    isempty(name) && throw(ArgumentError("define_function!(…; name=\"\"): a function is named where it is defined, and the name section drops an empty name"))
    local type_idx = add_type!(mod, FuncType(WasmValType[p for p in params], WasmValType[r for r in results]))
    push!(mod.functions, WasmFunction(type_idx, WasmValType[], nothing, SourceMapping[], name))
    return UInt32(num_imported_funcs(mod) + length(mod.functions) - 1)
end

# the defined function at `idx`, by its slot
# parity(pkg/wasm_builder/lib/src/builder/functions.dart:12 FunctionsBuilder._functionBuilders)
function _defined_function_slot(mod::WasmModule, idx::Integer, op::Symbol)::Int
    local slot = Int(idx) - num_imported_funcs(mod) + 1
    1 <= slot <= length(mod.functions) ||
        _module_invalid(op, "function $idx is not a function the module defines")
    return slot
end

"""
    add_export!(mod, name, kind, idx)

Add an export entry to the module.
- kind: 0=func, 1=table, 2=memory, 3=global, 4=tag
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

# a global's name, when given, names no other global (the name section names each by its own)
# parity(pkg/wasm_builder/lib/src/builder/globals.dart:29 GlobalsBuilder.define)
_check_global_name(mod::WasmModule, name::Union{Nothing,String}, op::Symbol)::Nothing =
    (name === nothing || !any(g -> g.name == name, mod.globals)) ? nothing :
        _module_invalid(op, "a global named $(repr(name)) is already defined")

"""
    add_global_import!(mod, module_name, field_name, valtype, mutable; name) -> global_idx

Import a global of type `valtype` (mutable or not) from `module_name.field_name` and return its
index; `name` names it in the name section. Imported globals come first in the
global index space, and WT numbers a global when it is defined (dart's FinalizableIndex numbers it
when the module is built), so an import after a defined global, which would renumber it under
the code already emitted, is refused, as add_import! refuses a function import after a defined
function (_check_import_precedes_definitions).
parity(pkg/wasm_builder/lib/src/builder/globals.dart:41 GlobalsBuilder.import)
"""
function add_global_import!(mod::WasmModule, module_name::String, field_name::String,
                            valtype::WasmValType, mutable_::Bool;
                            name::Union{Nothing,String}=nothing)::UInt32
    _check_global_import_precedes_definitions(mod, module_name, field_name)
    _check_global_name(mod, name, :add_global_import)
    valtype isa ConcreteRef && !(Int(valtype.type_idx) < length(mod.types)) &&
        _module_invalid(:add_global_import, "type $(valtype.type_idx) is not defined")
    push!(mod.globals, WasmGlobalImport(module_name, field_name, valtype, mutable_, name))
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
const SECTION_CUSTOM = 0x00   # a custom section (the name section, sourceMappingURL); parity(pkg/wasm_builder/lib/src/serialize/sections.dart:836 CustomSection.sectionId)
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
    # every body is complete before the module is written (dart: a body must be ended before
    # the module is serialized, functions.dart:28-30; a global's initializer is built with it)
    for (k, f) in enumerate(mod.functions)
        f.body === nothing && _module_invalid(:to_bytes,
            "function $(num_imported_funcs(mod) + k - 1) ($(f.name)) is defined and never filled (fill_function!)")
    end
    for (k, g) in enumerate(mod.globals)
        (g isa WasmGlobalDef && g.init === nothing) && _module_invalid(:to_bytes,
            "global $(k - 1)$(g.name === nothing ? "" : " ($(g.name))") is defined and never filled (fill_global!)")
    end
    w = WasmWriter()
    local module_mappings = SourceMapping[]

    # Magic number and version
    write_bytes!(w, WASM_MAGIC...)
    write_bytes!(w, WASM_VERSION...)

    # Type section
    if !isempty(mod.types)
        write_section!(w, SECTION_TYPE) do section
            local groups = recursion_groups(mod)
            # the groups the builder recorded as it added them are the section's (a module whose
            # types were pushed past add_type!/add_type_group! has no complete record to compare)
            sum(length, mod.type_groups; init=0) == length(mod.types) && groups != mod.type_groups &&
                _module_invalid(:type_section, "the recursion groups the builder recorded differ from the section's strongly connected components")
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

    # Import section: the functions, then the globals (dart Imports.all, imports.dart:18)
    local imported_globals = WasmGlobalImport[g for g in mod.globals if g isa WasmGlobalImport]
    if !isempty(mod.imports) || !isempty(imported_globals)
        write_section!(w, SECTION_IMPORT) do section
            write_u32!(section, length(mod.imports) + length(imported_globals))
            for imp in mod.imports
                write_name!(section, imp.module_name)
                write_name!(section, imp.field_name)
                write_byte!(section, imp.kind)
                write_u32!(section, imp.type_idx)
            end
            # an imported global: its names, kind 0x03, its global type (ImportedGlobal.serialize)
            for g in imported_globals
                write_name!(section, g.module_name)
                write_name!(section, g.field_name)
                write_byte!(section, 0x03)
                write_valtype!(section, g.valtype)
                write_byte!(section, g.mutable_ ? 0x01 : 0x00)
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

    # Global section: the defined globals, after the imported ones in the index space
    local defined_globals = WasmGlobalDef[g for g in mod.globals if g isa WasmGlobalDef]
    if !isempty(defined_globals)
        write_section!(w, SECTION_GLOBAL) do section
            write_u32!(section, length(defined_globals))
            for g in defined_globals
                # Global type: valtype + mutability
                write_valtype!(section, g.valtype)
                write_byte!(section, g.mutable_ ? 0x01 : 0x00)
                # its initializer, a complete constant expression (fill_global!)
                append!(section.buffer, something(g.init))
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
                append!(body_writer.buffer, something(func.body))

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

    # Name section (custom section): each function's own name, the one it was imported or
    # defined with, in index order; a function with none ("") is not named. An export's name
    # names no function (dart's NameSection reads `functions[i].functionName` only). Then each
    # global's name, imported or defined, in index order (subsection 7, `globals[i].globalName`)
    # parity(pkg/wasm_builder/lib/src/serialize/sections.dart:844 NameSection)
    func_names = Pair{UInt32, String}[]
    func_idx = UInt32(0)
    for imp in mod.imports
        imp.kind == 0x00 || continue  # a function import
        isempty(imp.function_name) || push!(func_names, func_idx => imp.function_name)
        func_idx += 1
    end
    for f in mod.functions
        push!(func_names, func_idx => f.name)   # never empty (WasmFunction refuses one)
        func_idx += 1
    end
    local global_names = Pair{UInt32,String}[UInt32(k - 1) => g.name
                                             for (k, g) in enumerate(mod.globals) if g.name !== nothing]
    if !isempty(func_names) || !isempty(global_names)
        write_section!(w, SECTION_CUSTOM) do custom_section
            write_name!(custom_section, "name")
            for (id, names) in ((0x01, func_names), (0x07, global_names))
                isempty(names) && continue
                subsection = WasmWriter()
                write_u32!(subsection, length(names))
                for (idx, name) in names
                    write_u32!(subsection, idx)
                    write_name!(subsection, name)
                end
                write_byte!(custom_section, id)
                write_u32!(custom_section, length(subsection.buffer))
                append!(custom_section.buffer, subsection.buffer)
            end
        end
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
    write_section!(w, SECTION_CUSTOM) do contents
        write_name!(contents, "sourceMappingURL")
        write_name!(contents, url)
    end
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
Write a field type (storage type + mutability).
parity(pkg/wasm_builder/lib/src/ir/type.dart:1296 _WithMutability.serialize)
"""
function write_field_type!(w::WasmWriter, ft::FieldType)::WasmWriter
    write_storage_type!(w, ft.valtype)
    write_byte!(w, ft.mutable_ ? 0x01 : 0x00)
end

"""
Write a value type (NumType or a reference type).
parity(pkg/wasm_builder/lib/src/ir/type.dart:121 NumType.serialize)
"""
function write_valtype!(w::WasmWriter, vt::NumType)::WasmWriter
    write_byte!(w, UInt8(vt))
end

# A nullable reference to an abstract heap type, written as dart writes it: an abstract heap
# type's default nullability is nullable, so the heap type's one byte is the whole value type
# (`anyref` is 0x6E, not 0x63 0x6E), and a non-null one is NonNullAbstractRef's 0x64 prefix.
# parity(pkg/wasm_builder/lib/src/ir/type.dart:249 RefType.serialize)
write_valtype!(w::WasmWriter, vt::RefType)::WasmWriter = write_byte!(w, UInt8(vt))

# a field's storage type: a packed type's one byte, or a value type as every value type is written
# parity(pkg/wasm_builder/lib/src/ir/type.dart:1399 PackedType.serialize)
write_storage_type!(w::WasmWriter, t::PackedType)::WasmWriter = write_byte!(w, UInt8(t))
# parity(pkg/wasm_builder/lib/src/ir/type.dart:1296 _WithMutability.serialize)
write_storage_type!(w::WasmWriter, t::WasmValType)::WasmWriter = write_valtype!(w, t)

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
