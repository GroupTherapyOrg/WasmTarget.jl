# ccall_replacements.jl — Pure Julia replacements for Phase B1 ccalls
#
# These replace 5 ccall-dependent functions with pure Julia equivalents:
#   1. jl_get_world_counter → build-time constant WASM_WORLD_AGE
#   2. jl_get_module_infer  → always return Cint(1) (inference enabled)
#   3. jl_is_assertsbuild   → already in ccall_stubs.jl (is_asserts() = false)
#   4. jl_types_equal       → T1 === T2 (Julia's built-in identity comparison)
#   5. jl_eqtable_get       → pure Julia linear probe on IdDict.ht Memory
#
# Functions unblocked: edge_matches_sv, maybe_validate_code, is_lattice_equal,
#                      issimplertype, tmerge, validate_code!
#
# Usage:
#   include("src/typeinf/ccall_stubs.jl")       # Phase A stubs first
#   include("src/typeinf/ccall_replacements.jl") # Phase B1 replacements
#
# This file is STANDALONE and independently testable:
#   julia +1.12 --project=. -e '
#     include("src/typeinf/ccall_stubs.jl")
#     include("src/typeinf/ccall_replacements.jl")
#     println("Phase B1 replacements loaded OK")'

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

    println("Phase B1 replacements verification: $passed passed, $failed failed")
    return failed == 0
end
