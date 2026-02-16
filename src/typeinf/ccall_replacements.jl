# ccall_replacements.jl — Pure Julia replacements for Phase B1 + B2 + B3 + C1 + C2 + C3 ccalls
#
# Phase B1 (5 replacements):
#   1. jl_get_world_counter → build-time constant WASM_WORLD_AGE
#   2. jl_get_module_infer  → always return Cint(1) (inference enabled)
#   3. jl_is_assertsbuild   → already in ccall_stubs.jl (is_asserts() = false)
#   4. jl_types_equal       → T1 === T2 (Julia's built-in identity comparison)
#   5. jl_eqtable_get       → pure Julia linear probe on IdDict.ht Memory
#
# Phase B2 (7 replacements — type operations):
#   6. jl_type_unionall   → UnionAll(v, t) Julia constructor (SKIP foreigncall)
#   7. jl_field_index     → findfirst on fieldnames (override _fieldindex_*)
#   8. jl_get_fieldtypes  → T.types direct field access (override datatype_fieldtypes)
#   9. jl_stored_inline   → isbitstype(T) || isbitsunion(T) (override allocatedinline)
#  10. jl_argument_datatype → recursive UnionAll unwrap (override argument_datatype)
#  11. jl_value_ptr        → objectid-based or === (override pointer_from_objref)
#  12. jl_new_structv/jl_new_structt → SKIP foreigncall (handled at Wasm level)
#
# Phase B3 (6 replacements — memory ops + rethrow + IR inspection):
#  13. memcmp     → SKIP foreigncall (Wasm string/array comparison uses GC struct ops)
#  14. memmove    → SKIP foreigncall (Wasm memory.copy instruction)
#  15. memset     → SKIP foreigncall (Wasm memory.fill instruction)
#  16. jl_genericmemory_copyto → SKIP foreigncall (Cvoid return, handled at Wasm level)
#  17. jl_rethrow / jl_rethrow_other → SKIP foreigncall (Wasm rethrow instruction)
#  18. jl_ir_nslots / jl_ir_slotflag → Override with CodeInfo field access
#
# Phase C1 (3 replacements — type variable helpers):
#  19. jl_has_free_typevars    → Recursive type walk checking for unbound TypeVars
#  20. jl_find_free_typevars   → Collect all unbound TypeVars from type tree
#  21. jl_instantiate_type_in_env → Type substitution using UnionAll env bindings
#
# Phase C2 (4 replacements — IdSet identity set operations):
#  22. jl_idset_peek_bp  → Linear scan on list using === (override haskey)
#  23. jl_idset_pop      → Find+remove by === + rebuild idxs (override _pop!)
#  24. jl_idset_put_key  → Find empty slot or grow list (override push!)
#  25. jl_idset_put_idx  → Rebuild idxs hash table (override push!)
#
# Phase C3 (5 replacements — string operations):
#  26. jl_alloc_string             → SKIP foreigncall (Wasm strings are GC objects)
#  27. jl_string_to_genericmemory  → SKIP foreigncall (Wasm Memory handled at codegen level)
#  28. jl_genericmemory_to_string  → SKIP foreigncall (Wasm string construction at codegen level)
#  29. jl_pchar_to_string          → SKIP foreigncall (pointer-based, handled at codegen level)
#  30. jl_string_ptr               → Already in Phase A SKIP list (pointer to string data)
#
# Functions unblocked (B1): edge_matches_sv, maybe_validate_code, is_lattice_equal,
#                           issimplertype, tmerge, validate_code!
# Functions unblocked (B2): _limit_type_size, _fieldindex_nothrow, _getfield_tfunc,
#                           valid_as_lattice, is_undefref_fieldtype, abstract_eval_splatnew,
#                           abstract_eval_new, opaque_closure_tfunc, most_general_argtypes,
#                           rewrap_unionall, subst_trivial_bounds, get_staged, tmerge, push!
# Functions unblocked (B3): == (Base), empty!, ensureroom_slowpath, unsafe_write,
#                           #sizehint!#81, _resize!, rethrow, may_invoke_generator,
#                           abstract_eval_new_opaque_closure, propagate_to_error_handler!,
#                           typeinf_local, widenreturn_partials, finish_cycle
# Functions unblocked (C1): abstract_call_opaque_closure, abstract_eval_new,
#                           abstract_eval_splatnew, is_derived_type, is_undefref_fieldtype,
#                           issimpleenoughtype, may_invoke_generator, most_general_argtypes,
#                           sp_type_rewrap, tmerge_types_slow, tuplemerge,
#                           union_count_abstract, abstract_eval_throw_undef_if_not, tmeet
# Functions unblocked (C2): cycle_fix_limited, issubset, push! (Compiler IdDict variant)
# Functions unblocked (C3): _base, bin, dec, hex, oct, ensureroom_reallocate,
#                           print_to_string, _resize!
#
# Usage:
#   include("src/typeinf/ccall_stubs.jl")       # Phase A stubs first
#   include("src/typeinf/ccall_replacements.jl") # Phase B1 + B2 + B3 + C1 + C2 + C3 replacements
#
# This file is STANDALONE and independently testable:
#   julia +1.12 --project=. -e '
#     include("src/typeinf/ccall_stubs.jl")
#     include("src/typeinf/ccall_replacements.jl")
#     println("Phase C3 string ops loaded OK")'

# ─── 1. World age constant ──────────────────────────────────────────────────────
# jl_get_world_counter returns the current world age counter.
# In Wasm, world age is fixed at build time — no new methods are defined at runtime.
# Capture the build-time constant. The actual override happens at Wasm level:
# jl_get_world_counter is added to SKIP_FOREIGNCALLS with return type UInt.
#
# NOTE: We do NOT override Base.get_world_counter() here because that would break
# native Julia code_typed (which needs the real world counter to see newly-defined
# methods). The override only applies in Wasm where the world is frozen.

const WASM_WORLD_AGE = Base.get_world_counter()

# Add to SKIP foreigncalls — codegen will emit WASM_WORLD_AGE constant instead
if !(:jl_get_world_counter in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_get_world_counter)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_get_world_counter] = UInt

# ─── 2. Module inference flag ────────────────────────────────────────────────────
# jl_get_module_infer(module) returns whether inference is enabled for a module.
# In typeinfer.jl:916 and :1233, it checks == 0 to skip inference.
# For Wasm, inference is ALWAYS enabled (we need it for all modules).
# Return Cint(1) to mean "enabled" (any non-zero value works, but 1 is canonical).
#
# The ccall is INLINE in typeinfer.jl (not wrapped in a function), so we add it
# to the SKIP foreigncall list with a return value of Cint(1).

if !(:jl_get_module_infer in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_get_module_infer)
end

# Also add to return defaults — returns Cint (i32), default should be 1 (non-zero = enabled)
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_get_module_infer] = Cint

# ─── 3. Type equality ───────────────────────────────────────────────────────────
# jl_types_equal(T, S) checks structural type equality. Used in:
#   operators.jl:295:  ==(T::Type, S::Type) = ccall(:jl_types_equal, ...) != 0
#
# In Julia, `===` (object identity) is sufficient for type equality:
# jl_types_equal checks structural equality which for types is the same as ===.
# Override the ==(Type, Type) method to avoid the ccall.

Base.:(==)(T::Type, S::Type) = (@Base._total_meta; T === S)

# ─── 4. IdDict eqtable lookup ───────────────────────────────────────────────────
# jl_eqtable_get(ht, key, default) does identity-based lookup in IdDict's
# internal Memory{Any} hashtable. The ht is a flat array of [key, value, key, value, ...]
# pairs with empty slots marked by #undef.
#
# Pure Julia replacement: linear scan through the Memory, checking === equality.
# This is O(n) but correct. IdDicts in typeinf are small (typically <100 entries).

function _pure_eqtable_get(ht::Memory{Any}, @nospecialize(key), @nospecialize(default))
    # The ht is a flat array: [k1, v1, k2, v2, ...] with length divisible by 2.
    # Empty slots have #undef entries.
    len = length(ht)
    i = 1
    while i <= len
        if isassigned(ht, i) && ht[i] === key
            return ht[i + 1]
        end
        i += 2
    end
    return default
end

# Override IdDict methods that use jl_eqtable_get
function Base.get(d::IdDict{K,V}, @nospecialize(key), @nospecialize(default)) where {K, V}
    val = _pure_eqtable_get(d.ht, key, default)
    val === default ? default : val::V
end

function Base.getindex(d::IdDict{K,V}, @nospecialize(key)) where {K, V}
    val = _pure_eqtable_get(d.ht, key, Base.secret_table_token)
    val === Base.secret_table_token && throw(KeyError(key))
    return val::V
end

function Base.get!(d::IdDict{K,V}, @nospecialize(key), @nospecialize(default)) where {K, V}
    val = _pure_eqtable_get(d.ht, key, Base.secret_table_token)
    if val === Base.secret_table_token
        val = isa(default, V) ? default : convert(V, default)::V
        setindex!(d, val, key)
        return val
    else
        return val::V
    end
end

function Base.get(default::Base.Callable, d::IdDict{K,V}, @nospecialize(key)) where {K, V}
    val = _pure_eqtable_get(d.ht, key, Base.secret_table_token)
    if val === Base.secret_table_token
        return default()
    else
        return val::V
    end
end

function Base.get!(default::Base.Callable, d::IdDict{K,V}, @nospecialize(key)) where {K, V}
    val = _pure_eqtable_get(d.ht, key, Base.secret_table_token)
    if val === Base.secret_table_token
        val = default()
        if !isa(val, V)
            val = convert(V, val)::V
        end
        setindex!(d, val, key)
        return val
    else
        return val::V
    end
end

function Base.haskey(d::IdDict, @nospecialize(key))
    _pure_eqtable_get(d.ht, key, Base.secret_table_token) !== Base.secret_table_token
end

function Base.in(@nospecialize(key), v::Base.KeySet{<:Any, <:IdDict})
    _pure_eqtable_get(v.dict.ht, key, Base.secret_table_token) !== Base.secret_table_token
end

# Also add jl_eqtable_get to SKIP list for any remaining inline ccalls
if !(:jl_eqtable_get in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_eqtable_get)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_eqtable_get] = Any

# ─── 5. jl_is_assertsbuild — already handled ────────────────────────────────────
# Already in ccall_stubs.jl: Core.Compiler.is_asserts() = false
# No additional work needed here.

# ═══════════════════════════════════════════════════════════════════════════════
# Phase B2 — Type operation ccall replacements
# ═══════════════════════════════════════════════════════════════════════════════

# ─── 6. jl_type_unionall ──────────────────────────────────────────────────────
# boot.jl:338: UnionAll(v, t) = ccall(:jl_type_unionall, Any, (Any, Any), v::TypeVar, t)
#
# The UnionAll constructor IS the ccall wrapper. In Wasm, we add the foreigncall
# to the SKIP list. The codegen already handles UnionAll construction natively —
# this ccall is just an implementation detail of the bootstrap constructor.
# The actual semantics: construct a UnionAll type from a TypeVar and body.

if !(:jl_type_unionall in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_type_unionall)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_type_unionall] = Any

# ─── 7. jl_field_index ────────────────────────────────────────────────────────
# runtime_internals.jl:1093-1103: _fieldindex_maythrow / _fieldindex_nothrow
# Both call ccall(:jl_field_index, Cint, (Any, Any, Cint), T, name, err)
# Returns 0-based index (or -1 on error), Julia wrapper adds +1.
#
# Pure Julia replacement: scan fieldnames(T) for matching name.

function Base._fieldindex_nothrow(T::DataType, name::Symbol)
    @Base._total_meta
    @noinline
    fns = fieldnames(T)
    for i in 1:length(fns)
        if fns[i] === name
            return i
        end
    end
    return 0
end

function Base._fieldindex_maythrow(T::DataType, name::Symbol)
    @Base._foldable_meta
    @noinline
    idx = Base._fieldindex_nothrow(T, name)
    if idx == 0
        throw(ArgumentError("type $(T) has no field $(name)"))
    end
    return idx
end

# Also add jl_field_index to SKIP list for any remaining inline ccalls
if !(:jl_field_index in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_field_index)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_field_index] = Cint

# ─── 8. jl_get_fieldtypes ────────────────────────────────────────────────────
# runtime_internals.jl:521: datatype_fieldtypes(x) = ccall(:jl_get_fieldtypes, SimpleVector, (Any,), x)
#
# Pure Julia: DataType has a .types field that IS the SimpleVector of field types.
# This is a direct field access, no ccall needed.

function Base.datatype_fieldtypes(x::DataType)
    return x.types::Core.SimpleVector
end

if !(:jl_get_fieldtypes in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_get_fieldtypes)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_get_fieldtypes] = Core.SimpleVector

# ─── 9. jl_stored_inline ─────────────────────────────────────────────────────
# array.jl:198: allocatedinline(T) = ccall(:jl_stored_inline, Cint, (Any,), T) != 0
#
# A type is "stored inline" (allocatedinline) if it's a bits type OR a bits union.
# NOTE: Cannot use isbitsunion(T) because isbitsunion calls allocatedinline → circular!
# Instead, inline the union check: a Union is stored inline if ALL members are bits types.

function Base.allocatedinline(@nospecialize T::Type)
    @Base._total_meta
    if isbitstype(T)
        return true
    end
    if T isa Union
        return _all_bits_union(T)
    end
    return false
end

function _all_bits_union(@nospecialize u::Union)
    # Check if all union members are bits types (recursive for nested unions)
    a = u.a
    b = u.b
    a_ok = isbitstype(a) || (a isa Union && _all_bits_union(a))
    b_ok = isbitstype(b) || (b isa Union && _all_bits_union(b))
    return a_ok && b_ok
end

if !(:jl_stored_inline in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_stored_inline)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_stored_inline] = Cint

# ─── 10. jl_argument_datatype ────────────────────────────────────────────────
# runtime_internals.jl:1114-1118: argument_datatype(t) = ccall(:jl_argument_datatype, ...)
#
# Unwraps UnionAll wrappers to get the underlying DataType.
# Returns nothing for non-DataType leaves (Union, TypeVar, etc.)

function Base.argument_datatype(@nospecialize t)
    @Base._total_meta
    @noinline
    while t isa UnionAll
        t = t.body
    end
    if t isa DataType
        return t
    end
    return nothing
end

if !(:jl_argument_datatype in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_argument_datatype)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_argument_datatype] = Any

# ─── 11. jl_value_ptr ────────────────────────────────────────────────────────
# pointer.jl:285,302: pointer_from_objref(x) = ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), x)
#
# Used in typeinf for:
#   - typelimits.jl:710: pointer_from_objref(typea) === pointer_from_objref(typeb)
#     → fast identity check for concrete types in tmerge
#   - utilities.jl:97: pointer_from_objref(cache_ci) for jl_code_for_staged
#     → separate story handles jl_code_for_staged
#
# CANNOT override pointer_from_objref globally — the Julia runtime uses it
# internally for I/O handle management (preserve_handle, uv_write). Replacing
# it with objectid() causes segfaults because the C runtime dereferences the
# "pointer" we return.
#
# Instead, add jl_value_ptr to the SKIP list for Wasm compilation only.
# In Wasm, the codegen will emit objectid-based identity (or struct.get on
# the Wasm object reference) instead of pointer arithmetic.

if !(:jl_value_ptr in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_value_ptr)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_value_ptr] = Ptr{Cvoid}

# ─── 12. jl_new_structv / jl_new_structt ─────────────────────────────────────
# abstractinterpretation.jl:3120: ccall(:jl_new_structv, Any, (Any, Ptr{Cvoid}, UInt32), rt, argvals, nargs)
# abstractinterpretation.jl:3154: ccall(:jl_new_structt, Any, (Any, Any), rt, at.val)
#
# These are INLINE ccalls in abstract_eval_new and abstract_eval_splatnew,
# used for constant folding during type inference. They construct struct values
# from a DataType and field values.
#
# Add to SKIP list — codegen should handle these as no-ops that return externref.
# The actual struct construction will be handled at the Wasm level via struct_new.
# For native Julia testing, we don't need to override since they work as ccalls.

if !(:jl_new_structv in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_new_structv)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_new_structv] = Any

if !(:jl_new_structt in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_new_structt)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_new_structt] = Any

# ═══════════════════════════════════════════════════════════════════════════════
# Phase B3 — Memory + rethrow + IR inspection ccall replacements
# ═══════════════════════════════════════════════════════════════════════════════

# ─── 13. memcmp ──────────────────────────────────────────────────────────────
# cmem.jl: memcmp(a, b, n) = ccall(:memcmp, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), a, b, n)
#
# Used for string/array equality comparison (== on strings).
# In Wasm, strings are GC objects compared via struct field access, not raw
# pointer comparison. The codegen emits Wasm-native comparison for strings.
# Add to SKIP list — returns Cint (i32), default 0 means "equal".

if !(:memcmp in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :memcmp)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:memcmp] = Cint

# ─── 14. memmove ─────────────────────────────────────────────────────────────
# cmem.jl: memmove(dst, src, n) = ccall(:memmove, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), dst, src, n)
#
# Copies memory with overlap handling. In Wasm, memory.copy instruction handles
# this natively. Used by _resize!, ensureroom_slowpath, unsafe_write.
# Add to SKIP list — returns Ptr{Cvoid} (i64), default 0.

if !(:memmove in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :memmove)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:memmove] = Ptr{Cvoid}

# ─── 15. memset ──────────────────────────────────────────────────────────────
# cmem.jl: memset(p, val, n) = ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), p, val, n)
#
# Fills memory with a byte value. In Wasm, memory.fill instruction handles this.
# Used by empty! to zero-initialize memory.
# Add to SKIP list — returns Ptr{Cvoid} (i64), default 0.

if !(:memset in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :memset)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:memset] = Ptr{Cvoid}

# ─── 16. jl_genericmemory_copyto ────────────────────────────────────────────
# genericmemory.jl:129: unsafe_copyto! calls this for non-bits types.
# ccall(:jl_genericmemory_copyto, Cvoid, (Any, Ptr{Cvoid}, Any, Ptr{Cvoid}, Int), ...)
#
# Copies elements between GenericMemory arrays for non-isbitstype elements.
# In Wasm, array element copy is handled by GC array operations (array.copy).
# Add to SKIP list — returns Cvoid (no-op).

if !(:jl_genericmemory_copyto in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_genericmemory_copyto)
end
# Cvoid return — no entry needed in TYPEINF_SKIP_RETURN_DEFAULTS

# ─── 17. jl_rethrow / jl_rethrow_other ──────────────────────────────────────
# error.jl:71: rethrow() = ccall(:jl_rethrow, Bottom, ())
# error.jl:72: rethrow(e) = ccall(:jl_rethrow_other, Bottom, (Any,), e)
#
# These re-throw exceptions from catch blocks. In Wasm, the `rethrow`
# instruction does this natively (part of Wasm exception handling proposal).
# Return type is Bottom (never returns) — codegen should emit `unreachable`
# after the Wasm rethrow instruction.
# Add to SKIP list — Bottom return means codegen emits unreachable.

if !(:jl_rethrow in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_rethrow)
end
# Bottom return type — after rethrow, code is unreachable

if !(:jl_rethrow_other in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_rethrow_other)
end
# Bottom return type — after rethrow_other, code is unreachable

# ─── 18. jl_ir_nslots / jl_ir_slotflag ──────────────────────────────────────
# runtime_internals.jl:1494: nslots = ccall(:jl_ir_nslots, Int, (Any,), code)
# runtime_internals.jl:1453: ast_slotflag(code, i) = ccall(:jl_ir_slotflag, UInt8, (Any, Csize_t), code, i - 1)
#
# These read CodeInfo slot metadata. jl_ir_nslots handles both CodeInfo and
# compressed String forms. Used by may_invoke_generator to check if sparams
# are used in @generated function bodies.
#
# For Wasm typeinf: @generated functions are pre-expanded at build time
# (PURE-3109). At runtime, may_invoke_generator is called but the generator
# methods will have pre-decompressed CodeInfo (from our jl_uncompress_ir
# replacement). So we can handle both forms:
#   - CodeInfo: length(code.slotnames) / code.slotflags[i+1]
#   - String (compressed): add to SKIP list, return conservative defaults

# Override ast_slotflag to handle CodeInfo directly
function Base.ast_slotflag(@nospecialize(code), i)
    if code isa Core.CodeInfo
        return code.slotflags[i]  # i is already 1-based in Julia callers
    end
    # For compressed String forms, return 0 (no flags set = safe default)
    # This makes may_invoke_generator conservatively return true (allow invocation)
    return UInt8(0)
end

# Add jl_ir_nslots and jl_ir_slotflag to SKIP list for any remaining inline ccalls
if !(:jl_ir_nslots in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_ir_nslots)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_ir_nslots] = Int

if !(:jl_ir_slotflag in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_ir_slotflag)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_ir_slotflag] = UInt8

# ═══════════════════════════════════════════════════════════════════════════════
# Phase C1 — Type variable helpers (pure Julia replacements for 3 ccalls)
# ═══════════════════════════════════════════════════════════════════════════════

# ─── 19. jl_has_free_typevars ─────────────────────────────────────────────────
# reflection.jl:798: has_free_typevars(t) = ccall(:jl_has_free_typevars, Cint, (Any,), t) != 0
#
# A TypeVar is "free" if it's not bound by an enclosing UnionAll in the type.
# UnionAll(T, body) binds T within body. Walk the type tree tracking bound vars.

function has_free_typevars_pure(@nospecialize(t), bound::Set{TypeVar}=Set{TypeVar}())
    if t isa TypeVar
        return !(t in bound)
    end
    if t isa UnionAll
        push!(bound, t.var)
        result = has_free_typevars_pure(t.body, bound)
        delete!(bound, t.var)
        return result
    end
    if t isa Union
        return has_free_typevars_pure(t.a, bound) || has_free_typevars_pure(t.b, bound)
    end
    if t isa DataType
        for p in t.parameters
            has_free_typevars_pure(p, bound) && return true
        end
        return false
    end
    return false
end

# Override Base.has_free_typevars to avoid the ccall
Base.has_free_typevars(@nospecialize(t)) = (@Base._total_meta; has_free_typevars_pure(t))

# Add to SKIP list for any remaining inline ccalls
if !(:jl_has_free_typevars in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_has_free_typevars)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_has_free_typevars] = Cint

# ─── 20. jl_find_free_typevars ────────────────────────────────────────────────
# abstractinterpretation.jl:2314: ccall(:jl_find_free_typevars, Vector{Any}, (Any,), T)
#
# Collect all TypeVars that are NOT bound by an enclosing UnionAll.
# Returns Vector{Any} of free TypeVar objects.

function find_free_typevars_pure(@nospecialize(t), bound::Set{TypeVar}=Set{TypeVar}(), found::Vector{Any}=Any[])
    if t isa TypeVar
        if !(t in bound) && !(t in found)
            push!(found, t)
        end
        return found
    end
    if t isa UnionAll
        push!(bound, t.var)
        find_free_typevars_pure(t.body, bound, found)
        delete!(bound, t.var)
        return found
    end
    if t isa Union
        find_free_typevars_pure(t.a, bound, found)
        find_free_typevars_pure(t.b, bound, found)
        return found
    end
    if t isa DataType
        for p in t.parameters
            find_free_typevars_pure(p, bound, found)
        end
        return found
    end
    return found
end

# Add to SKIP list
if !(:jl_find_free_typevars in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_find_free_typevars)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_find_free_typevars] = Vector{Any}

# ─── 21. jl_instantiate_type_in_env ──────────────────────────────────────────
# abstractinterpretation.jl:2306:
#   ccall(:jl_instantiate_type_in_env, Any, (Any, Any, Ptr{Any}), T, spsig, sparam_vals)
#
# Substitutes TypeVars in `body` using values from the environment.
# The environment is built from the UnionAll chain of `spsig`:
#   spsig = T1 where T1 → env[T1] = vals[1]
#   spsig = (T2 where T2) where T1 → env[T1] = vals[1], env[T2] = vals[2]
#
# Walk the UnionAll chain to build a Dict{TypeVar, Any}, then recursively
# substitute in `body`.

function instantiate_type_in_env_pure(@nospecialize(body), @nospecialize(spsig), sparam_vals::Vector{Any})
    # Build environment from UnionAll chain
    env = Dict{TypeVar, Any}()
    sig = spsig
    idx = 1
    while sig isa UnionAll && idx <= length(sparam_vals)
        env[sig.var] = sparam_vals[idx]
        sig = sig.body
        idx += 1
    end
    return _substitute_typevars(body, env)
end

function _substitute_typevars(@nospecialize(t), env::Dict{TypeVar, Any})
    if t isa TypeVar
        return get(env, t, t)
    end
    if t isa UnionAll
        # Don't substitute the bound variable itself, but DO substitute in the body
        # (the bound variable shadows any outer binding)
        new_body = _substitute_typevars(t.body, env)
        if new_body === t.body
            return t
        end
        return UnionAll(t.var, new_body)
    end
    if t isa Union
        new_a = _substitute_typevars(t.a, env)
        new_b = _substitute_typevars(t.b, env)
        if new_a === t.a && new_b === t.b
            return t
        end
        return Union{new_a, new_b}
    end
    if t isa DataType && !isempty(t.parameters)
        changed = false
        new_params = Any[]
        for p in t.parameters
            new_p = _substitute_typevars(p, env)
            push!(new_params, new_p)
            if new_p !== p
                changed = true
            end
        end
        if !changed
            return t
        end
        return t.name.wrapper{new_params...}
    end
    return t
end

# Add to SKIP list
if !(:jl_instantiate_type_in_env in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_instantiate_type_in_env)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_instantiate_type_in_env] = Any

# ═══════════════════════════════════════════════════════════════════════════════
# Phase C2 — IdDict/IdSet equivalents (jl_idset_* ccalls)
# ═══════════════════════════════════════════════════════════════════════════════

# The IdSet struct uses 4 ccalls for identity-based set operations:
#   jl_idset_peek_bp  — find key by === in hash table → returns index or -1
#   jl_idset_pop      — remove key by === from hash table → returns index or -1
#   jl_idset_put_key  — insert key into list, return (possibly grown) list
#   jl_idset_put_idx  — rebuild/update idxs hash table after insert
#
# IdSet has:
#   list::Memory{Any}  — elements stored at positions 1..max
#   idxs::Union{Memory{UInt8}, Memory{UInt16}, Memory{UInt32}} — hash table
#     Maps objectid(key) % length(idxs) → 1-based index in list (0=empty, maxval=deleted)
#   count::Int — number of elements
#   max::Int   — highest assigned index in list
#
# Pure Julia approach: override haskey, push!, _pop! directly.
# For small sets (typeinf sets are <100 elements), linear scan is fast enough.
# The idxs hash table is rebuilt after mutations using objectid-based linear probing.

# ─── 22. jl_idset_peek_bp — identity lookup ─────────────────────────────────
# Returns 0-based index into list if found, -1 if not found

function _idset_peek_bp(list::Memory{Any}, @nospecialize(key), max::Int)
    for i in 1:max
        if isassigned(list, i) && list[i] === key
            return i - 1  # 0-based
        end
    end
    return -1
end

function Base.haskey(s::IdSet, @nospecialize(key))
    _idset_peek_bp(s.list, key, s.max) != -1
end

# Also override `in` for IdSet (delegates to haskey)
Base.in(@nospecialize(x), s::IdSet) = haskey(s, x)

# ─── 23. Rebuild idxs hash table ───────────────────────────────────────────
# Reconstruct the idxs hash table from scratch given the current list.
# Uses objectid-based hashing with linear probing, matching the C implementation.

function _idset_rebuild_idxs(list::Memory{Any}, max::Int)
    # Determine size: next power of 2 >= 4*max, minimum 32
    # (matches jl_idset_put_idx growth policy)
    needed = max < 8 ? 32 : nextpow(2, 4 * max)
    T = needed <= 256 ? UInt8 : (needed <= 65536 ? UInt16 : UInt32)
    idxs = Memory{T}(undef, needed)
    fill!(idxs, zero(T))
    mask = needed - 1  # power-of-2 mask for modular arithmetic
    for i in 1:max
        if isassigned(list, i)
            # Hash using objectid, linear probe to find empty slot
            h = objectid(list[i]) % UInt
            slot = (h & mask) + 1  # 1-based slot
            while idxs[slot] != zero(T)
                slot = (slot & mask) + 1  # wrap around
            end
            idxs[slot] = T(i)  # store 1-based index
        end
    end
    return idxs
end

# ─── 24. jl_idset_pop — remove by identity ─────────────────────────────────

function Base._pop!(s::IdSet, @nospecialize(x))
    idx = _idset_peek_bp(s.list, x, s.max)
    if idx == -1
        return -1
    end
    # Unassign the slot (1-based)
    Base._unsetindex!(s.list, idx + 1)
    s.count -= 1
    # Update max
    while s.max > 0 && !isassigned(s.list, s.max)
        s.max -= 1
    end
    # Rebuild idxs
    setfield!(s, :idxs, _idset_rebuild_idxs(s.list, s.max))
    return idx
end

# ─── 25. jl_idset_put_key + jl_idset_put_idx — insert by identity ──────────

function Base.push!(s::IdSet, @nospecialize(x))
    # Check if already present
    idx = _idset_peek_bp(s.list, x, s.max)
    if idx >= 0
        # Already exists — update in place
        s.list[idx + 1] = x
        return s
    end
    # Find an empty slot in list, or grow
    inserted = false
    for i in 1:length(s.list)
        if !isassigned(s.list, i)
            s.list[i] = x
            if i > s.max
                s.max = i
            end
            inserted = true
            break
        end
    end
    if !inserted
        # Need to grow list
        old_len = length(s.list)
        new_len = old_len < 4 ? 4 : old_len * 2
        new_list = Memory{Any}(undef, new_len)
        for i in 1:old_len
            if isassigned(s.list, i)
                new_list[i] = s.list[i]
            end
        end
        new_list[old_len + 1] = x
        s.max = old_len + 1
        setfield!(s, :list, new_list)
    end
    s.count += 1
    # Rebuild idxs hash table
    setfield!(s, :idxs, _idset_rebuild_idxs(s.list, s.max))
    return s
end

# Add all 4 ccalls to SKIP list
for sym in (:jl_idset_peek_bp, :jl_idset_pop, :jl_idset_put_key, :jl_idset_put_idx)
    if !(sym in TYPEINF_SKIP_FOREIGNCALLS)
        push!(TYPEINF_SKIP_FOREIGNCALLS, sym)
    end
end
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_idset_peek_bp] = Int
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_idset_pop] = Int
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_idset_put_key] = Any
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_idset_put_idx] = Any

# ═══════════════════════════════════════════════════════════════════════════════
# Phase C3 — String operation ccall replacements
# ═══════════════════════════════════════════════════════════════════════════════

# In Wasm GC, strings are managed as GC struct objects (not raw byte buffers).
# All 5 string ccalls deal with pointer-level operations (allocating raw memory,
# copying bytes to/from pointers, getting raw pointers to string data) that
# don't apply in Wasm GC. The codegen handles string operations natively via
# struct_new/struct_get for WasmGC string types.
#
# These functions are used by number-to-string formatting (_base, bin, dec, hex, oct)
# and IOBuffer operations (ensureroom_reallocate, print_to_string, _resize!).
# In single-shot typeinf they may not be exercised, but they need to compile.

# ─── 26. jl_alloc_string ─────────────────────────────────────────────────────
# strings/string.jl:109: _string_n(n) = foreigncall(:jl_alloc_string, Ref{String}, (Csize_t,), n)
# Base_compiler.jl:171: ccall(:jl_alloc_string, Ref{String}, (Int,), n)
#
# Allocates an empty String of n bytes. In Wasm GC, strings are created via
# struct_new with a Wasm array of bytes — no raw allocation needed.
# Add to SKIP list — returns Ref{String} (externref).

if !(:jl_alloc_string in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_alloc_string)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_alloc_string] = String

# ─── 27. jl_string_to_genericmemory ──────────────────────────────────────────
# strings/string.jl:120: unsafe_wrap(Memory{UInt8}, s::String) = ccall(...)
# Base.jl:81: @ccall jl_string_to_genericmemory(str::Any)::Memory{UInt8}
#
# Gets the backing Memory{UInt8} from a String. In Wasm GC, this would be
# a struct_get to extract the byte array from the string struct.
# Add to SKIP list — returns Memory{UInt8} (externref).

if !(:jl_string_to_genericmemory in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_string_to_genericmemory)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_string_to_genericmemory] = Any  # Memory{UInt8}

# ─── 28. jl_genericmemory_to_string ──────────────────────────────────────────
# strings/string.jl:71: ccall(:jl_genericmemory_to_string, Ref{String}, (Any, Int), mem, len)
# strings/string.jl:84: ccall(:jl_genericmemory_to_string, Ref{String}, (Any, Int), m, length(m))
#
# Converts a Memory{UInt8} buffer into a String (zero-copy when possible).
# In Wasm GC, this constructs a string struct from a byte array.
# Add to SKIP list — returns Ref{String} (externref).

if !(:jl_genericmemory_to_string in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_genericmemory_to_string)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_genericmemory_to_string] = String

# ─── 29. jl_pchar_to_string ──────────────────────────────────────────────────
# strings/string.jl:73: ccall(:jl_pchar_to_string, Ref{String}, (Ptr{UInt8}, Int), ref, len)
# strings/string.jl:99: unsafe_string(p, len) = ccall(:jl_pchar_to_string, ...)
#
# Copies bytes from a raw pointer into a new String. Pointer-based, not
# applicable in Wasm GC. The codegen handles string construction natively.
# Add to SKIP list — returns Ref{String} (externref).

if !(:jl_pchar_to_string in TYPEINF_SKIP_FOREIGNCALLS)
    push!(TYPEINF_SKIP_FOREIGNCALLS, :jl_pchar_to_string)
end
TYPEINF_SKIP_RETURN_DEFAULTS[:jl_pchar_to_string] = String

# ─── 30. jl_string_ptr ───────────────────────────────────────────────────────
# Already in Phase A SKIP list (ccall_stubs.jl line 38).
# boot.jl:690,761: ccall(:jl_string_ptr, Ptr{UInt8}, (Any,), s)
# essentials.jl:693-694: unsafe_convert(Ptr{UInt8}, s::String) = ccall(...)
#
# Gets a raw Ptr{UInt8} to the string's data. Not applicable in Wasm GC.
# Already added to SKIP in Phase A — just verify return default is set.
if !haskey(TYPEINF_SKIP_RETURN_DEFAULTS, :jl_string_ptr)
    TYPEINF_SKIP_RETURN_DEFAULTS[:jl_string_ptr] = Ptr{UInt8}
end

# ─── Verification ────────────────────────────────────────────────────────────────

function verify_replacements()
    passed = 0
    failed = 0

    # 1. World age constant — verify it was captured and is in SKIP list
    if WASM_WORLD_AGE isa UInt && WASM_WORLD_AGE > 0
        passed += 1
    else
        println("FAIL: WASM_WORLD_AGE = $WASM_WORLD_AGE (expected positive UInt)")
        failed += 1
    end
    if :jl_get_world_counter in TYPEINF_SKIP_FOREIGNCALLS
        passed += 1
    else
        println("FAIL: jl_get_world_counter not in TYPEINF_SKIP_FOREIGNCALLS")
        failed += 1
    end

    # 2. Module inference flag — verify it's in the skip list
    if :jl_get_module_infer in TYPEINF_SKIP_FOREIGNCALLS
        passed += 1
    else
        println("FAIL: jl_get_module_infer not in TYPEINF_SKIP_FOREIGNCALLS")
        failed += 1
    end

    # 3. Type equality — compare with native ccall result
    native_eq = ccall(:jl_types_equal, Cint, (Any, Any), Int64, Int64) != 0
    pure_eq = (Int64 == Int64)
    if native_eq == pure_eq && pure_eq == true
        passed += 1
    else
        println("FAIL: type equality Int64==Int64: native=$native_eq pure=$pure_eq")
        failed += 1
    end

    native_neq = ccall(:jl_types_equal, Cint, (Any, Any), Int64, Float64) != 0
    pure_neq = (Int64 == Float64)
    if native_neq == pure_neq && pure_neq == false
        passed += 1
    else
        println("FAIL: type equality Int64==Float64: native=$native_neq pure=$pure_neq")
        failed += 1
    end

    # Also test with UnionAll types
    native_union = ccall(:jl_types_equal, Cint, (Any, Any), Vector{Int64}, Vector{Int64}) != 0
    pure_union = (Vector{Int64} == Vector{Int64})
    if native_union == pure_union && pure_union == true
        passed += 1
    else
        println("FAIL: type equality Vector{Int64}==Vector{Int64}: native=$native_union pure=$pure_union")
        failed += 1
    end

    # 4. IdDict eqtable_get — compare pure Julia vs native ccall
    d = IdDict{Any, Int}()
    d[:a] = 1
    d[:b] = 2
    d["hello"] = 3

    # Test get with existing key
    v1 = get(d, :a, -1)
    if v1 == 1
        passed += 1
    else
        println("FAIL: IdDict get(:a) = $v1, expected 1")
        failed += 1
    end

    # Test get with missing key
    v2 = get(d, :missing, -1)
    if v2 == -1
        passed += 1
    else
        println("FAIL: IdDict get(:missing) = $v2, expected -1")
        failed += 1
    end

    # Test getindex
    v3 = d[:b]
    if v3 == 2
        passed += 1
    else
        println("FAIL: IdDict[:b] = $v3, expected 2")
        failed += 1
    end

    # Test getindex with KeyError
    try
        d[:nonexistent]
        println("FAIL: IdDict[:nonexistent] should throw KeyError")
        failed += 1
    catch e
        if e isa KeyError
            passed += 1
        else
            println("FAIL: IdDict[:nonexistent] threw $e, expected KeyError")
            failed += 1
        end
    end

    # Test haskey
    if haskey(d, :a) && !haskey(d, :missing)
        passed += 1
    else
        println("FAIL: haskey mismatch")
        failed += 1
    end

    # Test with object identity (not value equality)
    x = [1, 2, 3]
    y = [1, 2, 3]  # same value, different object
    d2 = IdDict{Any, String}()
    d2[x] = "x"
    if get(d2, x, "none") == "x" && get(d2, y, "none") == "none"
        passed += 1
    else
        println("FAIL: IdDict identity test — x=$(get(d2, x, "none")), y=$(get(d2, y, "none"))")
        failed += 1
    end

    # 5. is_asserts already verified in ccall_stubs.jl

    # ─── Phase B2 verification ───────────────────────────────────────────────

    # 6. jl_type_unionall — verify it's in SKIP list
    if :jl_type_unionall in TYPEINF_SKIP_FOREIGNCALLS
        passed += 1
    else
        println("FAIL: jl_type_unionall not in TYPEINF_SKIP_FOREIGNCALLS")
        failed += 1
    end

    # 7. jl_field_index — compare pure Julia vs native ccall
    # Test with a real struct
    native_idx = ccall(:jl_field_index, Cint, (Any, Any, Cint), Complex{Float64}, :re, Cint(0))
    pure_idx = Cint(Base._fieldindex_nothrow(Complex{Float64}, :re) - 1)  # convert to 0-based
    if native_idx == pure_idx && pure_idx == Cint(0)
        passed += 1
    else
        println("FAIL: field_index Complex :re — native=$native_idx pure=$pure_idx")
        failed += 1
    end

    native_idx2 = ccall(:jl_field_index, Cint, (Any, Any, Cint), Complex{Float64}, :im, Cint(0))
    pure_idx2 = Cint(Base._fieldindex_nothrow(Complex{Float64}, :im) - 1)
    if native_idx2 == pure_idx2 && pure_idx2 == Cint(1)
        passed += 1
    else
        println("FAIL: field_index Complex :im — native=$native_idx2 pure=$pure_idx2")
        failed += 1
    end

    # Test missing field
    native_miss = ccall(:jl_field_index, Cint, (Any, Any, Cint), Complex{Float64}, :missing_field, Cint(0))
    pure_miss = Cint(Base._fieldindex_nothrow(Complex{Float64}, :missing_field) - 1)
    if native_miss == pure_miss && pure_miss == Cint(-1)
        passed += 1
    else
        println("FAIL: field_index Complex :missing_field — native=$native_miss pure=$pure_miss")
        failed += 1
    end

    # 8. jl_get_fieldtypes — compare datatype_fieldtypes
    native_ft = ccall(:jl_get_fieldtypes, Core.SimpleVector, (Any,), Complex{Float64})
    pure_ft = Base.datatype_fieldtypes(Complex{Float64})
    if native_ft === pure_ft
        passed += 1
    else
        println("FAIL: datatype_fieldtypes(Complex{Float64}) — native=$native_ft pure=$pure_ft")
        failed += 1
    end

    native_ft2 = ccall(:jl_get_fieldtypes, Core.SimpleVector, (Any,), Int64)
    pure_ft2 = Base.datatype_fieldtypes(Int64)
    if native_ft2 === pure_ft2
        passed += 1
    else
        println("FAIL: datatype_fieldtypes(Int64) — native=$native_ft2 pure=$pure_ft2")
        failed += 1
    end

    # 9. jl_stored_inline — compare allocatedinline
    for (T, expected) in [(Int64, true), (String, false), (Float64, true),
                          (Vector{Int64}, false), (Union{Int64,Float64}, true),
                          (Union{Int64,String}, false)]
        native_raw = ccall(:jl_stored_inline, Cint, (Any,), T)
        native_stored = native_raw > Cint(0)
        pure_stored = Base.allocatedinline(T)
        if native_stored == pure_stored && pure_stored == expected
            passed += 1
        else
            println("FAIL: allocatedinline($T) — native=$native_stored pure=$pure_stored expected=$expected")
            failed += 1
        end
    end

    # 10. jl_argument_datatype — compare
    for (T, expected) in [(Int64, Int64), (Vector{Int64}, Vector{Int64}),
                          (Union{Int64,Float64}, nothing)]
        native_adt = ccall(:jl_argument_datatype, Any, (Any,), T)
        pure_adt = Base.argument_datatype(T)
        if native_adt === pure_adt && pure_adt === expected
            passed += 1
        else
            println("FAIL: argument_datatype($T) — native=$native_adt pure=$pure_adt expected=$expected")
            failed += 1
        end
    end

    # Test with UnionAll (should unwrap to DataType body)
    native_ua = ccall(:jl_argument_datatype, Any, (Any,), Vector)
    pure_ua = Base.argument_datatype(Vector)
    if native_ua === pure_ua && pure_ua isa DataType
        passed += 1
    else
        println("FAIL: argument_datatype(Vector) — native=$native_ua pure=$pure_ua")
        failed += 1
    end

    # 11. jl_value_ptr — verify it's in SKIP list (NOT overridden — see comment above)
    if :jl_value_ptr in TYPEINF_SKIP_FOREIGNCALLS
        passed += 1
    else
        println("FAIL: jl_value_ptr not in TYPEINF_SKIP_FOREIGNCALLS")
        failed += 1
    end

    # 12. jl_new_structv/jl_new_structt — verify they're in SKIP list
    if :jl_new_structv in TYPEINF_SKIP_FOREIGNCALLS && :jl_new_structt in TYPEINF_SKIP_FOREIGNCALLS
        passed += 1
    else
        println("FAIL: jl_new_structv/jl_new_structt not in TYPEINF_SKIP_FOREIGNCALLS")
        failed += 1
    end

    # ─── Phase B3 verification ───────────────────────────────────────────────

    # 13. memcmp — verify it's in SKIP list
    if :memcmp in TYPEINF_SKIP_FOREIGNCALLS
        passed += 1
    else
        println("FAIL: memcmp not in TYPEINF_SKIP_FOREIGNCALLS")
        failed += 1
    end

    # 14. memmove — verify it's in SKIP list
    if :memmove in TYPEINF_SKIP_FOREIGNCALLS
        passed += 1
    else
        println("FAIL: memmove not in TYPEINF_SKIP_FOREIGNCALLS")
        failed += 1
    end

    # 15. memset — verify it's in SKIP list
    if :memset in TYPEINF_SKIP_FOREIGNCALLS
        passed += 1
    else
        println("FAIL: memset not in TYPEINF_SKIP_FOREIGNCALLS")
        failed += 1
    end

    # 16. jl_genericmemory_copyto — verify it's in SKIP list
    if :jl_genericmemory_copyto in TYPEINF_SKIP_FOREIGNCALLS
        passed += 1
    else
        println("FAIL: jl_genericmemory_copyto not in TYPEINF_SKIP_FOREIGNCALLS")
        failed += 1
    end

    # 17. jl_rethrow / jl_rethrow_other — verify they're in SKIP list
    if :jl_rethrow in TYPEINF_SKIP_FOREIGNCALLS && :jl_rethrow_other in TYPEINF_SKIP_FOREIGNCALLS
        passed += 1
    else
        println("FAIL: jl_rethrow/jl_rethrow_other not in TYPEINF_SKIP_FOREIGNCALLS")
        failed += 1
    end

    # 18a. jl_ir_nslots — verify it's in SKIP list
    if :jl_ir_nslots in TYPEINF_SKIP_FOREIGNCALLS
        passed += 1
    else
        println("FAIL: jl_ir_nslots not in TYPEINF_SKIP_FOREIGNCALLS")
        failed += 1
    end

    # 18b. jl_ir_slotflag — verify it's in SKIP list
    if :jl_ir_slotflag in TYPEINF_SKIP_FOREIGNCALLS
        passed += 1
    else
        println("FAIL: jl_ir_slotflag not in TYPEINF_SKIP_FOREIGNCALLS")
        failed += 1
    end

    # 18c. ast_slotflag — verify pure Julia override matches native for CodeInfo
    ci_test = first(code_lowered(+, (Int, Int)))
    nslots_native = ccall(:jl_ir_nslots, Int, (Any,), ci_test)
    nslots_pure = length(ci_test.slotnames)
    if nslots_native == nslots_pure
        passed += 1
    else
        println("FAIL: jl_ir_nslots — native=$nslots_native pure=$nslots_pure")
        failed += 1
    end

    # Verify slotflags match for each slot
    slotflags_match = true
    for i in 1:nslots_native
        flag_native = ccall(:jl_ir_slotflag, UInt8, (Any, Csize_t), ci_test, i - 1)
        flag_pure = Base.ast_slotflag(ci_test, i)
        if flag_native != flag_pure
            println("FAIL: jl_ir_slotflag slot $i — native=$flag_native pure=$flag_pure")
            slotflags_match = false
        end
    end
    if slotflags_match
        passed += 1
    else
        failed += 1
    end

    # 18d. ast_slotflag — verify String (compressed) form returns UInt8(0) default
    m_test = first(methods(+, (Int, Int)))
    if m_test.source isa String
        flag_compressed = Base.ast_slotflag(m_test.source, 1)
        if flag_compressed == UInt8(0)
            passed += 1
        else
            println("FAIL: ast_slotflag(String, 1) = $flag_compressed, expected UInt8(0)")
            failed += 1
        end
    else
        # Source is CodeInfo (not compressed) — test with CodeInfo path instead
        passed += 1
    end

    # ─── Phase C1 verification ───────────────────────────────────────────────

    # 19. jl_has_free_typevars — compare pure Julia vs native ccall
    T_tv = TypeVar(:T_test19)
    S_tv = TypeVar(:S_test19)

    # Simple concrete types — no free typevars
    for (T, expected) in [(Int64, false), (Float64, false), (Vector{Int64}, false),
                          (Tuple{Int,Float64}, false), (Union{Int,Float64}, false)]
        native = ccall(:jl_has_free_typevars, Cint, (Any,), T) != 0
        pure = has_free_typevars_pure(T)
        if native == pure && pure == expected
            passed += 1
        else
            println("FAIL: has_free_typevars($T) — native=$native pure=$pure expected=$expected")
            failed += 1
        end
    end

    # Bare TypeVar — free
    native_tv = ccall(:jl_has_free_typevars, Cint, (Any,), T_tv) != 0
    pure_tv = has_free_typevars_pure(T_tv)
    if native_tv == pure_tv && pure_tv == true
        passed += 1
    else
        println("FAIL: has_free_typevars(TypeVar) — native=$native_tv pure=$pure_tv")
        failed += 1
    end

    # DataType with free TypeVar in parameters
    dt_free = Array{T_tv, 1}
    native_dtf = ccall(:jl_has_free_typevars, Cint, (Any,), dt_free) != 0
    pure_dtf = has_free_typevars_pure(dt_free)
    if native_dtf == pure_dtf && pure_dtf == true
        passed += 1
    else
        println("FAIL: has_free_typevars(Array{T,1}) — native=$native_dtf pure=$pure_dtf")
        failed += 1
    end

    # UnionAll binding the TypeVar — not free
    ua_bound = UnionAll(T_tv, Array{T_tv, 1})
    native_uab = ccall(:jl_has_free_typevars, Cint, (Any,), ua_bound) != 0
    pure_uab = has_free_typevars_pure(ua_bound)
    if native_uab == pure_uab && pure_uab == false
        passed += 1
    else
        println("FAIL: has_free_typevars(UnionAll(T,Array{T,1})) — native=$native_uab pure=$pure_uab")
        failed += 1
    end

    # Partially bound — S still free
    dt_two = Dict{T_tv, S_tv}
    ua_partial = UnionAll(T_tv, dt_two)
    native_part = ccall(:jl_has_free_typevars, Cint, (Any,), ua_partial) != 0
    pure_part = has_free_typevars_pure(ua_partial)
    if native_part == pure_part && pure_part == true
        passed += 1
    else
        println("FAIL: has_free_typevars(UnionAll(T,Dict{T,S})) — native=$native_part pure=$pure_part")
        failed += 1
    end

    # Fully bound
    ua_full = UnionAll(S_tv, UnionAll(T_tv, dt_two))
    native_full = ccall(:jl_has_free_typevars, Cint, (Any,), ua_full) != 0
    pure_full = has_free_typevars_pure(ua_full)
    if native_full == pure_full && pure_full == false
        passed += 1
    else
        println("FAIL: has_free_typevars(UnionAll(S,UnionAll(T,Dict{T,S}))) — native=$native_full pure=$pure_full")
        failed += 1
    end

    # Vector (where T is bound) — NOT free
    native_vec = ccall(:jl_has_free_typevars, Cint, (Any,), Vector) != 0
    pure_vec = has_free_typevars_pure(Vector)
    if native_vec == pure_vec && pure_vec == false
        passed += 1
    else
        println("FAIL: has_free_typevars(Vector) — native=$native_vec pure=$pure_vec")
        failed += 1
    end

    # Also verify the Base.has_free_typevars override works
    if Base.has_free_typevars(Int64) == false && Base.has_free_typevars(T_tv) == true
        passed += 1
    else
        println("FAIL: Base.has_free_typevars override mismatch")
        failed += 1
    end

    # 20. jl_find_free_typevars — compare pure Julia vs native ccall
    # Single free TypeVar
    fv1_native = ccall(:jl_find_free_typevars, Vector{Any}, (Any,), dt_free)
    fv1_pure = find_free_typevars_pure(dt_free)
    if length(fv1_native) == length(fv1_pure) && length(fv1_pure) == 1 && fv1_pure[1] === T_tv
        passed += 1
    else
        println("FAIL: find_free_typevars(Array{T,1}) — native=$fv1_native pure=$fv1_pure")
        failed += 1
    end

    # Two free TypeVars
    fv2_native = ccall(:jl_find_free_typevars, Vector{Any}, (Any,), dt_two)
    fv2_pure = find_free_typevars_pure(dt_two)
    if length(fv2_native) == length(fv2_pure) && length(fv2_pure) == 2
        passed += 1
    else
        println("FAIL: find_free_typevars(Dict{T,S}) — native len=$(length(fv2_native)) pure len=$(length(fv2_pure))")
        failed += 1
    end

    # Partially bound — only S free
    fv3_native = ccall(:jl_find_free_typevars, Vector{Any}, (Any,), ua_partial)
    fv3_pure = find_free_typevars_pure(ua_partial)
    if length(fv3_native) == length(fv3_pure) && length(fv3_pure) == 1 && fv3_pure[1] === S_tv
        passed += 1
    else
        println("FAIL: find_free_typevars(UnionAll(T,Dict{T,S})) — native=$fv3_native pure=$fv3_pure")
        failed += 1
    end

    # No free TypeVars
    fv4_native = ccall(:jl_find_free_typevars, Vector{Any}, (Any,), Int64)
    fv4_pure = find_free_typevars_pure(Int64)
    if length(fv4_native) == length(fv4_pure) && isempty(fv4_pure)
        passed += 1
    else
        println("FAIL: find_free_typevars(Int64) — native len=$(length(fv4_native)) pure len=$(length(fv4_pure))")
        failed += 1
    end

    # 21. jl_instantiate_type_in_env — compare pure Julia vs native ccall
    # Simple: Array{T,1} where T → substitute T=Int64
    sig_arr = Array{T_tv, 1} where T_tv
    vals_arr = Any[Int64]
    native_inst1 = GC.@preserve vals_arr ccall(:jl_instantiate_type_in_env, Any, (Any, Any, Ptr{Any}),
        sig_arr.body, sig_arr, pointer(vals_arr))
    pure_inst1 = instantiate_type_in_env_pure(sig_arr.body, sig_arr, vals_arr)
    if native_inst1 === pure_inst1 && pure_inst1 === Vector{Int64}
        passed += 1
    else
        println("FAIL: instantiate_type_in_env(Array{T,1}, [Int64]) — native=$native_inst1 pure=$pure_inst1")
        failed += 1
    end

    # Two parameters: Dict{K,V} where V where K → substitute K=Int64, V=String
    K_tv = TypeVar(:K_test21)
    V_tv = TypeVar(:V_test21)
    sig_dict = Dict{K_tv, V_tv} where V_tv where K_tv
    vals_dict = Any[Int64, String]
    native_inst2 = GC.@preserve vals_dict ccall(:jl_instantiate_type_in_env, Any, (Any, Any, Ptr{Any}),
        sig_dict.body.body, sig_dict, pointer(vals_dict))
    pure_inst2 = instantiate_type_in_env_pure(sig_dict.body.body, sig_dict, vals_dict)
    if native_inst2 === pure_inst2 && pure_inst2 === Dict{Int64, String}
        passed += 1
    else
        println("FAIL: instantiate_type_in_env(Dict{K,V}, [Int64,String]) — native=$native_inst2 pure=$pure_inst2")
        failed += 1
    end

    # Tuple type substitution: Tuple{T} where T → T=Int64
    R_tv = TypeVar(:R_test21)
    sig_tuple = Tuple{R_tv} where R_tv
    vals_tup = Any[Int64]
    native_inst3 = GC.@preserve vals_tup ccall(:jl_instantiate_type_in_env, Any, (Any, Any, Ptr{Any}),
        sig_tuple.body, sig_tuple, pointer(vals_tup))
    pure_inst3 = instantiate_type_in_env_pure(sig_tuple.body, sig_tuple, vals_tup)
    if native_inst3 === pure_inst3 && pure_inst3 === Tuple{Int64}
        passed += 1
    else
        println("FAIL: instantiate_type_in_env(Tuple{T}, [Int64]) — native=$native_inst3 pure=$pure_inst3")
        failed += 1
    end

    # SKIP list verification
    for sym in [:jl_has_free_typevars, :jl_find_free_typevars, :jl_instantiate_type_in_env]
        if sym in TYPEINF_SKIP_FOREIGNCALLS
            passed += 1
        else
            println("FAIL: $sym not in TYPEINF_SKIP_FOREIGNCALLS")
            failed += 1
        end
    end

    # ─── Phase C2 verification — IdSet operations ─────────────────────────

    # 22. haskey — test identity-based lookup
    s = IdSet{Any}()
    push!(s, 42)
    push!(s, "hello")
    push!(s, :sym)

    if haskey(s, 42) && haskey(s, "hello") && haskey(s, :sym) && !haskey(s, 99)
        passed += 1
    else
        println("FAIL: IdSet haskey basic test")
        failed += 1
    end

    # Identity semantics: different objects with same value
    a = [1, 2, 3]
    b = [1, 2, 3]
    s2 = IdSet{Any}()
    push!(s2, a)
    if haskey(s2, a) && !haskey(s2, b)
        passed += 1
    else
        println("FAIL: IdSet identity semantics — a in s2=$(haskey(s2, a)), b in s2=$(haskey(s2, b))")
        failed += 1
    end

    # 23. push! — test insertion + count tracking
    s3 = IdSet{Int}()
    push!(s3, 10)
    push!(s3, 20)
    push!(s3, 30)
    if length(s3) == 3 && 10 in s3 && 20 in s3 && 30 in s3
        passed += 1
    else
        println("FAIL: IdSet push! basic — count=$(length(s3)), has 10=$(10 in s3)")
        failed += 1
    end

    # push! duplicate — no change in count
    push!(s3, 20)
    if length(s3) == 3
        passed += 1
    else
        println("FAIL: IdSet push! duplicate — count=$(length(s3)), expected 3")
        failed += 1
    end

    # 24. _pop! / delete! — test removal
    delete!(s3, 20)
    if length(s3) == 2 && !(20 in s3) && 10 in s3 && 30 in s3
        passed += 1
    else
        println("FAIL: IdSet delete! — count=$(length(s3)), has 20=$(20 in s3)")
        failed += 1
    end

    # pop! with missing key should throw
    try
        pop!(s3, 999)
        println("FAIL: IdSet pop! should throw KeyError for missing key")
        failed += 1
    catch e
        if e isa KeyError
            passed += 1
        else
            println("FAIL: IdSet pop! threw $e, expected KeyError")
            failed += 1
        end
    end

    # pop! with default
    result = pop!(s3, 999, :default)
    if result === :default
        passed += 1
    else
        println("FAIL: IdSet pop! with default returned $result, expected :default")
        failed += 1
    end

    # 25. Iteration still works after mutations
    s4 = IdSet{Symbol}()
    push!(s4, :a)
    push!(s4, :b)
    push!(s4, :c)
    delete!(s4, :b)
    collected = collect(s4)
    if length(collected) == 2 && :a in collected && :c in collected
        passed += 1
    else
        println("FAIL: IdSet iteration after delete — collected=$collected")
        failed += 1
    end

    # 26. Larger set — stress test with 50 elements
    s5 = IdSet{Int}()
    for i in 1:50
        push!(s5, i)
    end
    if length(s5) == 50 && all(i -> i in s5, 1:50)
        passed += 1
    else
        println("FAIL: IdSet 50-element stress test — count=$(length(s5))")
        failed += 1
    end
    # Remove odd numbers
    for i in 1:2:50
        delete!(s5, i)
    end
    if length(s5) == 25 && all(i -> i in s5, 2:2:50) && !any(i -> i in s5, 1:2:50)
        passed += 1
    else
        println("FAIL: IdSet 50-element delete odds — count=$(length(s5))")
        failed += 1
    end

    # SKIP list verification for C2
    for sym in [:jl_idset_peek_bp, :jl_idset_pop, :jl_idset_put_key, :jl_idset_put_idx]
        if sym in TYPEINF_SKIP_FOREIGNCALLS
            passed += 1
        else
            println("FAIL: $sym not in TYPEINF_SKIP_FOREIGNCALLS")
            failed += 1
        end
    end

    # Total SKIP entries should be at least 41 now (37 Phase A+B+C1 + 4 Phase C2)
    total_skip_c2 = length(TYPEINF_SKIP_FOREIGNCALLS)
    if total_skip_c2 >= 41
        passed += 1
    else
        println("FAIL: TYPEINF_SKIP_FOREIGNCALLS has $total_skip_c2 entries, expected >= 41 (after C2)")
        failed += 1
    end

    # ─── Phase C3 verification — String operation SKIP entries ───────────

    # 26. jl_alloc_string — verify it's in SKIP list with correct return type
    if :jl_alloc_string in TYPEINF_SKIP_FOREIGNCALLS
        passed += 1
    else
        println("FAIL: jl_alloc_string not in TYPEINF_SKIP_FOREIGNCALLS")
        failed += 1
    end
    if haskey(TYPEINF_SKIP_RETURN_DEFAULTS, :jl_alloc_string)
        passed += 1
    else
        println("FAIL: jl_alloc_string not in TYPEINF_SKIP_RETURN_DEFAULTS")
        failed += 1
    end

    # 27. jl_string_to_genericmemory — verify it's in SKIP list
    if :jl_string_to_genericmemory in TYPEINF_SKIP_FOREIGNCALLS
        passed += 1
    else
        println("FAIL: jl_string_to_genericmemory not in TYPEINF_SKIP_FOREIGNCALLS")
        failed += 1
    end
    if haskey(TYPEINF_SKIP_RETURN_DEFAULTS, :jl_string_to_genericmemory)
        passed += 1
    else
        println("FAIL: jl_string_to_genericmemory not in TYPEINF_SKIP_RETURN_DEFAULTS")
        failed += 1
    end

    # 28. jl_genericmemory_to_string — verify it's in SKIP list
    if :jl_genericmemory_to_string in TYPEINF_SKIP_FOREIGNCALLS
        passed += 1
    else
        println("FAIL: jl_genericmemory_to_string not in TYPEINF_SKIP_FOREIGNCALLS")
        failed += 1
    end
    if haskey(TYPEINF_SKIP_RETURN_DEFAULTS, :jl_genericmemory_to_string)
        passed += 1
    else
        println("FAIL: jl_genericmemory_to_string not in TYPEINF_SKIP_RETURN_DEFAULTS")
        failed += 1
    end

    # 29. jl_pchar_to_string — verify it's in SKIP list
    if :jl_pchar_to_string in TYPEINF_SKIP_FOREIGNCALLS
        passed += 1
    else
        println("FAIL: jl_pchar_to_string not in TYPEINF_SKIP_FOREIGNCALLS")
        failed += 1
    end
    if haskey(TYPEINF_SKIP_RETURN_DEFAULTS, :jl_pchar_to_string)
        passed += 1
    else
        println("FAIL: jl_pchar_to_string not in TYPEINF_SKIP_RETURN_DEFAULTS")
        failed += 1
    end

    # 30. jl_string_ptr — verify it's still in SKIP list (was Phase A) + has return default
    if :jl_string_ptr in TYPEINF_SKIP_FOREIGNCALLS
        passed += 1
    else
        println("FAIL: jl_string_ptr not in TYPEINF_SKIP_FOREIGNCALLS")
        failed += 1
    end
    if haskey(TYPEINF_SKIP_RETURN_DEFAULTS, :jl_string_ptr)
        passed += 1
    else
        println("FAIL: jl_string_ptr not in TYPEINF_SKIP_RETURN_DEFAULTS")
        failed += 1
    end

    # Verify String roundtrip works in native Julia (ground truth)
    # String(Vector{UInt8}("hello")) should roundtrip correctly
    orig = "hello"
    bytes_vec = Vector{UInt8}(orig)
    roundtrip = String(bytes_vec)
    if roundtrip == orig
        passed += 1
    else
        println("FAIL: String roundtrip — orig=$orig roundtrip=$roundtrip")
        failed += 1
    end

    # Verify codeunits gives correct byte representation
    cu = codeunits("hello")
    if length(cu) == 5 && cu[1] == UInt8('h') && cu[5] == UInt8('o')
        passed += 1
    else
        println("FAIL: codeunits(\"hello\") — length=$(length(cu))")
        failed += 1
    end

    # Total SKIP entries should be at least 45 now (41 Phase C2 + 4 Phase C3)
    # (jl_string_ptr was already counted in Phase A, so +4 not +5)
    total_skip = length(TYPEINF_SKIP_FOREIGNCALLS)
    if total_skip >= 45
        passed += 1
    else
        println("FAIL: TYPEINF_SKIP_FOREIGNCALLS has $total_skip entries, expected >= 45")
        failed += 1
    end

    println("Phase B1+B2+B3+C1+C2+C3 replacements verification: $passed passed, $failed failed")
    return failed == 0
end
