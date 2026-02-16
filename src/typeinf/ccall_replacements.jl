# ccall_replacements.jl — Pure Julia replacements for Phase B1 + B2 ccalls
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
# Functions unblocked (B1): edge_matches_sv, maybe_validate_code, is_lattice_equal,
#                           issimplertype, tmerge, validate_code!
# Functions unblocked (B2): _limit_type_size, _fieldindex_nothrow, _getfield_tfunc,
#                           valid_as_lattice, is_undefref_fieldtype, abstract_eval_splatnew,
#                           abstract_eval_new, opaque_closure_tfunc, most_general_argtypes,
#                           rewrap_unionall, subst_trivial_bounds, get_staged, tmerge, push!
#
# Usage:
#   include("src/typeinf/ccall_stubs.jl")       # Phase A stubs first
#   include("src/typeinf/ccall_replacements.jl") # Phase B1 + B2 replacements
#
# This file is STANDALONE and independently testable:
#   julia +1.12 --project=. -e '
#     include("src/typeinf/ccall_stubs.jl")
#     include("src/typeinf/ccall_replacements.jl")
#     println("Phase B2 type ops loaded OK")'

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

    println("Phase B1+B2 replacements verification: $passed passed, $failed failed")
    return failed == 0
end
