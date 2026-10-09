# Wasm Types - Value types, Reference types, and composite types
# Reference: https://webassembly.github.io/spec/core/binary/types.html

export NumType, RefType, ConcreteRef, NonNullAbstractRef, FuncType, StructType, ArrayType, FieldType, CompositeType, WasmValType, PackedType, StorageType

# ============================================================================
# Value Types (Section 5.3.1)
# ============================================================================

"""
    NumType

Numeric types in WebAssembly.
"""
@enum NumType::UInt8 begin
    I32 = 0x7F  # i32
    I64 = 0x7E  # i64
    F32 = 0x7D  # f32
    F64 = 0x7C  # f64
end

"""
    RefType

Reference types in WebAssembly (including WasmGC extensions).
"""
@enum RefType::UInt8 begin
    FuncRef = 0x70    # funcref
    ExternRef = 0x6F  # externref
    AnyRef = 0x6E     # anyref (WasmGC)
    EqRef = 0x6D      # eqref (WasmGC)
    I31Ref = 0x6C     # i31ref (WasmGC)
    StructRef = 0x6B  # structref (WasmGC)
    ArrayRef = 0x6A   # arrayref (WasmGC)
    ExnRef = 0x69     # exnref (exception handling)
end

"""
    ConcreteRef

A concrete reference type with a type index, e.g., `(ref null \$typeidx)`.
Used for locals and parameters that hold instances of specific struct/array types.
parity(pkg/wasm_builder/lib/src/ir/type.dart:164 RefType)
"""
struct ConcreteRef
    type_idx::UInt32
    nullable::Bool
end

# parity(pkg/wasm_builder/lib/src/ir/type.dart:164 RefType)
ConcreteRef(type_idx::UInt32)::ConcreteRef = ConcreteRef(type_idx, true)  # Default nullable

"""
    NonNullAbstractRef

A non-nullable reference to an abstract heap type, e.g., `(ref extern)` or `(ref func)`.
RefType values like ExternRef (0x6F) are always nullable shorthand; this type
expresses the non-null variant needed for some import signatures (e.g., JS String Builtins).
parity(pkg/wasm_builder/lib/src/ir/type.dart:164 RefType)
"""
struct NonNullAbstractRef
    heaptype_byte::UInt8  # Same byte as the RefType enum: 0x6F for extern, 0x70 for func, etc.
end

# parity(pkg/wasm_builder/lib/src/ir/type.dart:185 RefType.extern)
const NonNullExternRef = NonNullAbstractRef(UInt8(ExternRef))  # (ref extern)
# parity(pkg/wasm_builder/lib/src/ir/type.dart:195 RefType.func)
const NonNullFuncRef = NonNullAbstractRef(UInt8(FuncRef))      # (ref func)

"""
    WasmValType

A value type: numeric or reference (abstract or concrete). A packed i8/i16 is no value type: it
is a field's storage type only (PackedType).
parity(pkg/wasm_builder/lib/src/ir/type.dart:39 ValueType)
"""
const WasmValType = Union{NumType, RefType, ConcreteRef, NonNullAbstractRef}

"""
    PackedType

A packed storage type, i8 or i16, which exists only in memory: a struct field's or an array
element's type, read and written as its unpacked i32.
parity(pkg/wasm_builder/lib/src/ir/type.dart:1370 PackedType)
"""
@enum PackedType::UInt8 begin
    I8 = 0x78   # i8
    I16 = 0x77  # i16
end

"""
    StorageType

A field's type: a value type or a packed type (FieldType admits it; every other place holds a
value type).
parity(pkg/wasm_builder/lib/src/ir/type.dart:11 StorageType)
"""
const StorageType = Union{WasmValType, PackedType}

# the value type a storage type is read and written as: a packed type's i32, a value type itself
# parity(pkg/wasm_builder/lib/src/ir/type.dart:1382 PackedType.unpacked)
unpacked(::PackedType)::WasmValType = I32
# parity(pkg/wasm_builder/lib/src/ir/type.dart:43 ValueType.unpacked)
unpacked(t::WasmValType)::WasmValType = t

# ============================================================================
# Function Types (Section 5.3.6)
# ============================================================================

"""
    FuncType

A function type describing the signature of a WebAssembly function.
Supports both numeric types and reference types (for WasmGC).
parity(pkg/wasm_builder/lib/src/ir/type.dart:974 FunctionType)
"""
struct FuncType
    params::Vector{WasmValType}
    results::Vector{WasmValType}
end

# Convenience constructor for NumType-only signatures
# parity(pkg/wasm_builder/lib/src/ir/type.dart:974 FunctionType)
FuncType(params::Vector{NumType}, results::Vector{NumType})::FuncType =
    FuncType(WasmValType[p for p in params], WasmValType[r for r in results])

# ============================================================================
# WasmGC Types
# Reference: https://github.com/WebAssembly/gc/blob/main/proposals/gc/Overview.md
# ============================================================================

"""
    FieldType

A field in a WasmGC struct type.
parity(pkg/wasm_builder/lib/src/ir/type.dart:1338 FieldType)
"""
struct FieldType
    valtype::StorageType  # The field's storage type: a value type or a packed i8/i16
    mutable_::Bool        # Whether the field is mutable
end

# parity(pkg/wasm_builder/lib/src/ir/type.dart:1338 FieldType)
FieldType(valtype::StorageType)::FieldType = FieldType(valtype, true)  # Default to mutable

"""
    StructType

A WasmGC struct type with named fields.
parity(pkg/wasm_builder/lib/src/ir/type.dart:1119 StructType)
"""
struct StructType
    fields::Vector{FieldType}
    supertype_idx::Union{Nothing, UInt32}  # supertype index for subtyping (nothing = no supertype)
end

# Backward-compatible constructor (no supertype)
# parity(pkg/wasm_builder/lib/src/ir/type.dart:1119 StructType)
StructType(fields::Vector{FieldType})::StructType = StructType(fields, nothing)

"""
    ArrayType

A WasmGC array type with element type.
parity(pkg/wasm_builder/lib/src/ir/type.dart:1229 ArrayType)
"""
struct ArrayType
    elem::FieldType  # Element type with mutability
end

# parity(pkg/wasm_builder/lib/src/ir/type.dart:1229 ArrayType)
ArrayType(valtype::StorageType)::ArrayType = ArrayType(FieldType(valtype, true))

"""
    CompositeType

Union of all composite types in WasmGC.
parity(pkg/wasm_builder/lib/src/ir/type.dart:708 DefType)
"""
const CompositeType = Union{FuncType, StructType, ArrayType}

# ============================================================================
# Subtyping (the one relation every check asks: the builder's operand checks, its casts and
# codegen's conversions). WT's value types name a heap type by a byte (the abstract ones) or by
# a type index (a defined type), so the relation reads a defined type's kind and declared
# supertype from the module's type list, where dart's DefType holds them.
# ============================================================================

# is `t` a reference type?
# parity(pkg/wasm_builder/lib/src/ir/type.dart:164 RefType)
_wt_is_ref(t::StorageType)::Bool =
    t isa RefType || t isa ConcreteRef || t isa NonNullAbstractRef

# parity-region(pkg/wasm_builder/lib/src/ir/type.dart:170 RefType.nullable): one method per WT
# reference representation; an abstract RefType is the nullable shorthand.
_wt_ref_nullable(t::ConcreteRef)::Bool = t.nullable
_wt_ref_nullable(::NonNullAbstractRef)::Bool = false
_wt_ref_nullable(::RefType)::Bool = true
# end parity-region

# The reference type made non-null: a concrete one loses its null, the nullable shorthand becomes
# its non-null form; a numeric type is itself.
# parity-region(pkg/wasm_builder/lib/src/ir/type.dart:229 RefType.withNullability): one method per
# WT reference representation; a numeric type is ValueType.withNullability's (:56).
_wt_drop_nullable(t::ConcreteRef)::WasmValType = ConcreteRef(t.type_idx, false)
_wt_drop_nullable(t::RefType)::WasmValType = NonNullAbstractRef(UInt8(t))
_wt_drop_nullable(t::NonNullAbstractRef)::WasmValType = t
_wt_drop_nullable(t::NumType)::WasmValType = t
# end parity-region

"""
    _wt_heap_kind(t, types) -> Symbol

The heap type of a reference type, by kind: an abstract heap type (`:any`, `:eq`, `:struct`,
`:array`, `:i31`, `:extern`, `:func`, `:exn`), a defined type of the module (`:concrete_struct`,
`:concrete_array`, `:concrete_func`), or `:unknown` for a heap byte WT does not model. A type
index the module does not define is invalid, never guessed.
parity(pkg/wasm_builder/lib/src/ir/type.dart:166 RefType.heapType)
"""
function _wt_heap_kind(t::WasmValType, types::Vector{CompositeType})::Symbol
    if t isa ConcreteRef
        local ct = _wt_defined_type(t.type_idx, types)
        ct isa ArrayType && return :concrete_array
        ct isa FuncType && return :concrete_func
        return :concrete_struct
    elseif t isa NonNullAbstractRef
        return _wt_heap_kind_of_byte(t.heaptype_byte)
    elseif t isa RefType
        return _wt_heap_kind_of_byte(UInt8(t))
    end
    return :unknown
end

# the type the module defines at `idx`; an index it does not define is invalid
# parity(pkg/wasm_builder/lib/src/ir/type.dart:708 DefType)
function _wt_defined_type(idx::Integer, types::Vector{CompositeType})::CompositeType
    0 <= idx < length(types) || _module_invalid(:heap_type, "type $idx is not defined")
    return types[Int(idx) + 1]
end

# An abstract heap type's code (the RefType enum's byte) as its kind; a code WT does not model
# (none, noextern, nofunc, noexn) is :unknown.
# parity(pkg/wasm_builder/lib/src/ir/type.dart:361 HeapType.deserialize)
function _wt_heap_kind_of_byte(byte::UInt8)::Symbol
    byte == UInt8(AnyRef)    ? :any    :
    byte == UInt8(EqRef)     ? :eq     :
    byte == UInt8(StructRef) ? :struct :
    byte == UInt8(ArrayRef)  ? :array  :
    byte == UInt8(I31Ref)    ? :i31    :
    byte == UInt8(ExternRef) ? :extern :
    byte == UInt8(FuncRef)   ? :func   :
    byte == UInt8(ExnRef)    ? :exn    : :unknown
end

# The top of a heap kind's hierarchy: any (eq, struct, array, i31 and the defined structs and
# arrays), func (the defined function types), extern or exn; the four share no supertype.
# parity(pkg/wasm_builder/lib/src/ir/type.dart:348 HeapType.topType)
function _wt_hierarchy_top(kind::Symbol)::Symbol
    (kind === :func || kind === :concrete_func) ? :func :
    kind === :extern ? :extern :
    kind === :exn    ? :exn    :
    (kind === :any || kind === :eq || kind === :struct || kind === :array ||
     kind === :i31 || kind === :concrete_struct || kind === :concrete_array) ? :any :
    :unknown
end

# The nullable reference to the top of `t`'s hierarchy (dart `RefType(heapType.topType,
# nullable: true)`, the input a cast or a test takes), or nothing for a heap type WT does not
# model.
# parity(pkg/wasm_builder/lib/src/ir/type.dart:348 HeapType.topType)
function _wt_top_ref(t::WasmValType, types::Vector{CompositeType})::Union{Nothing,RefType}
    local top = _wt_hierarchy_top(_wt_heap_kind(t, types))
    top === :any ? AnyRef : top === :func ? FuncRef : top === :extern ? ExternRef :
    top === :exn ? ExnRef : nothing
end

"""
    _wt_same_hierarchy(a, b, types) -> Bool

Whether two reference types share a top (any, func, extern or exn), as a cast's operand and
target must: dart's `_verifyCast` takes the target's top type as the cast's input. It is not a
subtype check: a cast between two unrelated structs is valid and traps at run time.
parity(pkg/wasm_builder/lib/src/builder/instructions.dart:1927 InstructionsBuilder._verifyCast)
"""
function _wt_same_hierarchy(a::WasmValType, b::WasmValType, types::Vector{CompositeType})::Bool
    local ta = _wt_hierarchy_top(_wt_heap_kind(a, types))
    ta !== :unknown && ta === _wt_hierarchy_top(_wt_heap_kind(b, types))
end

# the declared supertype of the type at `idx`, or nothing: only a struct type declares one
# parity(pkg/wasm_builder/lib/src/ir/type.dart:712 DefType.superType)
function _wt_concrete_supertype_idx(idx::Integer, types::Vector{CompositeType})::Union{Nothing,UInt32}
    local ct = _wt_defined_type(idx, types)
    ct isa StructType ? ct.supertype_idx : nothing
end

# Does the type at `a_idx` reach the type at `b_idx` along its declared supertype chain? A struct's
# supertype is declared before it, inside a recursion group too (_check_supertype_declared_earlier
# checks every type add_type! or add_type_group! adds, before any check walks a chain), so the
# chain ends.
# parity(pkg/wasm_builder/lib/src/ir/type.dart:733 DefType.isSubtypeOf)
function _wt_concrete_chain_reaches(a_idx::Integer, b_idx::Integer, types::Vector{CompositeType})::Bool
    local cur::Union{Nothing,UInt32} = UInt32(a_idx)
    while cur !== nothing
        cur == b_idx && return true
        cur = _wt_concrete_supertype_idx(cur, types)
    end
    return false
end

"""
    wasm_subtype(a, b, types) -> Bool

Whether a value of type `a` may be used where `b` is expected, as dart's `isSubtypeOf` answers
it: a numeric type only as itself; a reference type when its nullability allows it (a nullable
one is never a subtype of a non-null one) and its heap type is a subtype of the other's. A
defined type walks its declared supertype chain, then its abstract super (struct, array or func),
so two distinct function types are unrelated, as are a function type and any type outside the
func hierarchy; any > eq > {struct, array, i31}; extern, func and exn each their own top.
`types` is the module's type list (WasmModule.types).
parity(pkg/wasm_builder/lib/src/ir/type.dart:236 RefType.isSubtypeOf)
"""
function wasm_subtype(a::WasmValType, b::WasmValType, types::Vector{CompositeType})::Bool
    a === b && return true
    (_wt_is_ref(a) && _wt_is_ref(b)) || return false
    (_wt_ref_nullable(a) && !_wt_ref_nullable(b)) && return false
    local ka = _wt_heap_kind(a, types)
    local kb = _wt_heap_kind(b, types)
    (ka === :unknown || kb === :unknown) && return false
    # a defined target: a defined type on the source's declared chain
    if kb === :concrete_struct || kb === :concrete_array || kb === :concrete_func
        (ka === :concrete_struct || ka === :concrete_array || ka === :concrete_func) || return false
        return _wt_concrete_chain_reaches(Int(a.type_idx), Int(b.type_idx), types)
    end
    # an abstract target: the source's abstract heap type (a defined type's abstract super)
    local ka_abs = ka === :concrete_struct ? :struct : ka === :concrete_array ? :array :
                   ka === :concrete_func ? :func : ka
    kb === :extern && return ka_abs === :extern
    kb === :func   && return ka_abs === :func
    kb === :exn    && return ka_abs === :exn
    kb === :any    && return _wt_hierarchy_top(ka_abs) === :any
    kb === :eq     && return ka_abs === :eq || ka_abs === :struct || ka_abs === :array || ka_abs === :i31
    kb === :struct && return ka_abs === :struct
    kb === :array  && return ka_abs === :array
    kb === :i31    && return ka_abs === :i31
    return false
end
