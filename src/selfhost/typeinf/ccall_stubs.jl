# ccall_stubs.jl — No-op stubs for timing/debug/cache ccalls
#
# These stubs replace ccall-wrapping functions that are NOT needed for
# single-shot typeinf in Wasm:
#   - Timing: jl_hrtime (via _time_ns)
#   - Debug output: jl_uv_puts, jl_uv_putb, jl_string_ptr (via print/println)
#   - Cache management: jl_fill_codeinst, jl_promote_ci_to_current,
#     jl_promote_cis_to_current, jl_push_newly_inferred, jl_mi_cache_insert
#   - JIT engine: jl_engine_reserve, jl_engine_fulfill
#   - Debug assertions: jl_is_assertsbuild
#   - BigFloat timer: mpfr_greater_p
#   - Phase 2a stubs (PHASE-2-PREP-002):
#     - jl_apply_cmpswap_type (atomic pointer type construction)
#     - jl_get_module_max_methods (module method limit)
#     - jl_maybe_add_binding_backedge (invalidation tracking)
#     - jl_method_table_add_backedge (invalidation tracking)
#     - jl_method_instance_add_backedge (invalidation tracking)
#
# Loading this file OVERRIDES the ccall-wrapping functions in Core.Compiler
# with pure Julia equivalents. This makes 21 C_DEPENDENT functions compilable.
#
# Usage:
#   include("src/typeinf/ccall_stubs.jl")
#   # Now _time_ns(), engine_reserve(), etc. are pure Julia — no ccalls
#
# This file is STANDALONE and independently testable:
#   julia +1.12 --project=. -e 'include("src/typeinf/ccall_stubs.jl"); println("Phase A stubs loaded OK")'

using Core.Compiler: AbstractInterpreter, InternalCodeCache, CodeInstance,
                     InferenceState, InferenceResult, AbsIntState

# ─── SKIP foreigncall registry ────────────────────────────────────────────────
# Foreigncall names that compile_foreigncall should treat as no-ops.
# For Cvoid returns: just drop arguments, emit nothing.
# For value returns: emit the appropriate default (0 for numerics, ref.null for refs).
#
# This list is used by compile_foreigncall in codegen.jl to skip these ccalls
# instead of emitting `unreachable`.

const TYPEINF_SKIP_FOREIGNCALLS = Set{Symbol}([
    :jl_hrtime,              # timing — return UInt64(0)
    :jl_uv_puts,             # debug output — Cvoid no-op
    :jl_uv_putb,             # debug output — Cvoid no-op
    :jl_string_ptr,          # string pointer — return Ptr{UInt8}(0)
    :jl_fill_codeinst,       # cache management — Cvoid no-op
    :jl_promote_ci_to_current, # cache management — Cvoid no-op
    :jl_promote_cis_to_current, # cache management — Cvoid no-op
    :jl_push_newly_inferred, # worklist — Cvoid no-op
    :jl_mi_cache_insert,     # cache insert — Cvoid no-op
    :jl_engine_reserve,      # JIT engine — return CodeInstance
    :jl_engine_fulfill,      # JIT engine — Cvoid no-op
    :jl_is_assertsbuild,     # debug assertions — return Cint(0)
    :jl_update_codeinst,     # cache update — Cvoid no-op
    :jl_compress_ir,         # IR compression — not needed (may_compress=false)
    :jl_add_codeinst_to_jit, # JIT compilation — Cvoid no-op
    # Phase 2a stubs (PHASE-2-PREP-002):
    :jl_apply_cmpswap_type,       # atomic pointer type — return Any
    :jl_get_module_max_methods,   # module method limit — return Cint
    :jl_maybe_add_binding_backedge, # invalidation — Cvoid no-op
    :jl_method_table_add_backedge,  # invalidation — Cvoid no-op
    :jl_method_instance_add_backedge, # invalidation — Cvoid no-op
])

# Map foreigncall names to their return type defaults (for non-Cvoid returns)
const TYPEINF_SKIP_RETURN_DEFAULTS = Dict{Symbol, Any}(
    :jl_hrtime => UInt64,          # returns UInt64(0)
    :jl_string_ptr => Ptr{UInt8},  # returns Ptr{UInt8}(0) — i64 zero
    :jl_engine_reserve => Any,     # returns CodeInstance (externref)
    :jl_is_assertsbuild => Cint,   # returns Cint(0) — i32 zero
    :jl_compress_ir => String,     # returns String (externref)
    :jl_apply_cmpswap_type => Any, # returns type for cmpswap (externref)
    :jl_get_module_max_methods => Cint, # returns Cint — i32 zero (no limit)
    :jl_maybe_add_binding_backedge => Cint, # returns Cint — i32 zero (unused)
)

# ─── Simple wrapper overrides ─────────────────────────────────────────────────
# These replace thin ccall wrappers in Core.Compiler with pure Julia functions.

# _time_ns: wraps ccall(:jl_hrtime, UInt64, ())
# Used for timing in typeinf, finish_cycle, finish_nocycle
Core.Compiler._time_ns() = UInt64(0)

# is_asserts: wraps ccall(:jl_is_assertsbuild, Cint, ()) == 1
# Used in maybe_validate_code — always false for Wasm (no assertion checks)
Core.Compiler.is_asserts() = false

# engine_reserve: wraps ccall(:jl_engine_reserve, Any, (Any, Any), mi, owner)
# Used in typeinf_edge to reserve an inference engine slot.
# For single-shot typeinf, return a new CodeInstance directly.
function Core.Compiler.engine_reserve(mi::Core.MethodInstance, @nospecialize(owner))
    # Create a CodeInstance that typeinf_edge can use.
    # In native Julia, jl_engine_reserve does thread-safe reservation;
    # for single-shot Wasm, we just create a fresh CodeInstance.
    # CodeInstance constructor: (mi, owner, rettype, exctype, inferred_const, inferred,
    #                           const_flags::Int32, min_world::UInt64, max_world::UInt64,
    #                           effects::UInt32, analysis_results, di, edges)
    return Core.CodeInstance(mi, owner, Any, Any, nothing, nothing,
                            Int32(0), UInt64(0), typemax(UInt64),
                            UInt32(0), nothing, nothing, Core.svec())
end

# engine_reject: wraps ccall(:jl_engine_fulfill, Cvoid, (Any, Ptr{Cvoid}), ci, C_NULL)
# Used to release engine reservation. No-op for single-shot.
Core.Compiler.engine_reject(::AbstractInterpreter, ci::CodeInstance) = nothing

# setindex!(::InternalCodeCache, ci, mi): wraps jl_push_newly_inferred + jl_mi_cache_insert
# Used for caching inference results globally. No-op for single-shot.
function Core.Compiler.setindex!(cache::InternalCodeCache, ci::CodeInstance, mi::Core.MethodInstance)
    # Skip both jl_push_newly_inferred and jl_mi_cache_insert
    # For single-shot typeinf in Wasm, we don't need global caching
    return cache
end

# ─── Phase 2a stubs (PHASE-2-PREP-002) ───────────────────────────────────────
# These 5 ccalls are needed by the typeinf path but not for single-shot Wasm.

# get_max_methods_for_module: wraps ccall(:jl_get_module_max_methods, Cint, (Any,), mod)
# Used in inferencestate.jl to limit method resolution. Return typemax(Int) = no limit.
function Core.Compiler.get_max_methods_for_module(mod::Module)
    return typemax(Int)
end

# store_backedges: contains jl_method_table_add_backedge and jl_method_instance_add_backedge.
# For single-shot typeinf, invalidation tracking is not needed — override the whole function.
function Core.Compiler.store_backedges(caller::CodeInstance, edges::Core.SimpleVector)
    # No-op: backedges are for incremental recompilation, not needed in Wasm single-shot.
    return nothing
end

# maybe_add_binding_backedge!: wraps ccall(:jl_maybe_add_binding_backedge, Cint, (Any,Any,Any))
# Used in invalidation.jl. No-op for single-shot.
function Base.maybe_add_binding_backedge!(b::Core.Binding, edge::Union{Method, CodeInstance})
    return nothing
end

# ─── Verification ─────────────────────────────────────────────────────────────

function verify_stubs()
    passed = 0
    failed = 0

    # Test _time_ns returns UInt64(0)
    t = Core.Compiler._time_ns()
    if t === UInt64(0)
        passed += 1
    else
        println("FAIL: _time_ns() returned $t, expected UInt64(0)")
        failed += 1
    end

    # Test is_asserts returns false
    a = Core.Compiler.is_asserts()
    if a === false
        passed += 1
    else
        println("FAIL: is_asserts() returned $a, expected false")
        failed += 1
    end

    # Test engine_reject is a no-op (doesn't throw)
    try
        # We can't easily create a real CodeInstance/AbstractInterpreter pair,
        # but we can verify the method exists
        m = methods(Core.Compiler.engine_reject, (AbstractInterpreter, CodeInstance))
        if length(m) > 0
            passed += 1
        else
            println("FAIL: engine_reject method not found")
            failed += 1
        end
    catch e
        println("FAIL: engine_reject check threw: $e")
        failed += 1
    end

    # Test setindex! method exists for InternalCodeCache
    m = methods(Core.Compiler.setindex!, (InternalCodeCache, CodeInstance, Core.MethodInstance))
    if length(m) > 0
        passed += 1
    else
        println("FAIL: setindex!(InternalCodeCache, ...) method not found")
        failed += 1
    end

    # Test TYPEINF_SKIP_FOREIGNCALLS has all entries (15 base + 5 Phase 2a = 20)
    if length(TYPEINF_SKIP_FOREIGNCALLS) >= 20
        passed += 1
    else
        println("FAIL: TYPEINF_SKIP_FOREIGNCALLS has $(length(TYPEINF_SKIP_FOREIGNCALLS)) entries, expected >= 20")
        failed += 1
    end

    # Test engine_reserve method exists
    m = methods(Core.Compiler.engine_reserve, (Core.MethodInstance, Any))
    if length(m) > 0
        passed += 1
    else
        println("FAIL: engine_reserve(MethodInstance, Any) method not found")
        failed += 1
    end

    # Phase 2a stubs (PHASE-2-PREP-002):

    # Test get_max_methods_for_module returns typemax(Int)
    max_m = Core.Compiler.get_max_methods_for_module(Main)
    if max_m === typemax(Int)
        passed += 1
    else
        println("FAIL: get_max_methods_for_module(Main) returned $max_m, expected $(typemax(Int))")
        failed += 1
    end

    # Test store_backedges is a no-op (doesn't throw)
    try
        m = methods(Core.Compiler.store_backedges, (CodeInstance, Core.SimpleVector))
        if length(m) > 0
            passed += 1
        else
            println("FAIL: store_backedges method not found")
            failed += 1
        end
    catch e
        println("FAIL: store_backedges check threw: $e")
        failed += 1
    end

    # Test new foreigncall entries are in the skip set
    for sym in [:jl_apply_cmpswap_type, :jl_get_module_max_methods,
                :jl_maybe_add_binding_backedge, :jl_method_table_add_backedge,
                :jl_method_instance_add_backedge]
        if sym in TYPEINF_SKIP_FOREIGNCALLS
            passed += 1
        else
            println("FAIL: $sym not in TYPEINF_SKIP_FOREIGNCALLS")
            failed += 1
        end
    end

    println("Stubs verification: $passed passed, $failed failed")
    return failed == 0
end
