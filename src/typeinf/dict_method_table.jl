# DictMethodTable + WasmInterpreter — Pure Julia method table replacement
#
# This file replaces the C runtime method table (ccall(:jl_matching_methods))
# with a pure Julia Dict-based lookup, enabling Core.Compiler.typeinf to run
# entirely in Wasm without any C calls.
#
# Architecture:
#   Build time: populate_method_table() uses Julia's native method lookup
#               to fill a Dict{Type, MethodLookupResult} with all needed signatures.
#   Runtime:    DictMethodTable.findall() does a pure Dict lookup.
#               WasmInterpreter routes typeinf through this Dict instead of C.
#
# This file is STANDALONE and independently testable:
#   julia +1.12 --project=. -e 'include("src/typeinf/dict_method_table.jl"); println("OK")'

using Core.Compiler: AbstractInterpreter, MethodTableView, MethodLookupResult,
                     InferenceParams, OptimizationParams, InferenceResult,
                     CachedMethodTable, WorldRange, InferenceState,
                     NativeInterpreter

# ─── DictMethodTable ────────────────────────────────────────────────────────────
# Pure Julia replacement for InternalMethodTable.
# Instead of ccall(:jl_matching_methods), does a Dict lookup.

struct DictMethodTable <: MethodTableView
    methods::Dict{Any, MethodLookupResult}
    world::UInt64
    intersections::Dict{Tuple{Any,Any}, Any}           # (a, b) → typeintersect(a, b)
    intersections_with_env::Dict{Tuple{Any,Any}, Any}   # (a, b) → SimpleVector[result, env]
end

function DictMethodTable(world::UInt64)
    DictMethodTable(Dict{Any, MethodLookupResult}(), world,
                    Dict{Tuple{Any,Any}, Any}(),
                    Dict{Tuple{Any,Any}, Any}())
end

function Core.Compiler.findall(sig::Type, table::DictMethodTable; limit::Int=Int(typemax(Int32)))
    return get(table.methods, sig, nothing)
end

# Required MethodTableView interface — DictMethodTable is NOT an overlay
Core.Compiler.isoverlayed(::DictMethodTable) = false

# findsup: find the unique most-specific method covering sig (used for invoke dispatch).
# Falls back to native lookup since the Dict is populated from native method tables.
function Core.Compiler.findsup(sig::Type, table::DictMethodTable)
    return Core.Compiler._findsup(sig, nothing, table.world)
end

# ─── PreDecompressedCodeInfo ────────────────────────────────────────────────────
# Replaces ccall(:jl_uncompress_ir) — stores pre-decompressed CodeInfo at build time.

struct PreDecompressedCodeInfo
    cache::Dict{Core.MethodInstance, Core.CodeInfo}
end

PreDecompressedCodeInfo() = PreDecompressedCodeInfo(Dict{Core.MethodInstance, Core.CodeInfo}())

function get_code_info(pd::PreDecompressedCodeInfo, mi::Core.MethodInstance)
    return get(pd.cache, mi, nothing)
end

# ─── WasmInterpreter ───────────────────────────────────────────────────────────
# Custom AbstractInterpreter that uses DictMethodTable instead of C method tables.
# Disables optimization (Binaryen handles that).

struct WasmInterpreter <: AbstractInterpreter
    world::UInt64
    method_table::CachedMethodTable{DictMethodTable}
    inf_cache::Vector{InferenceResult}
    inf_params::InferenceParams
    opt_params::OptimizationParams
    code_info_cache::PreDecompressedCodeInfo
end

function WasmInterpreter(world::UInt64, dict_table::DictMethodTable;
                         inf_params::InferenceParams=InferenceParams(),
                         opt_params::OptimizationParams=OptimizationParams(; inlining=false))
    cached_table = CachedMethodTable(dict_table)
    inf_cache = Vector{InferenceResult}()
    code_cache = PreDecompressedCodeInfo()
    return WasmInterpreter(world, cached_table, inf_cache, inf_params, opt_params, code_cache)
end

# ─── AbstractInterpreter interface overrides ────────────────────────────────────

Core.Compiler.method_table(interp::WasmInterpreter) = interp.method_table
# Use a unique symbol as cache owner to avoid polluting the global native cache.
# When cache_owner returns `nothing`, CodeInstances are stored in the global cache
# and can interfere with other interpreters (e.g., _TracingInterpreter sees stale
# results from a previous WasmInterpreter run).
Core.Compiler.cache_owner(interp::WasmInterpreter) = :WasmInterpreter
Core.Compiler.get_inference_world(interp::WasmInterpreter) = interp.world
Core.Compiler.get_inference_cache(interp::WasmInterpreter) = interp.inf_cache
Core.Compiler.InferenceParams(interp::WasmInterpreter) = interp.inf_params
Core.Compiler.OptimizationParams(interp::WasmInterpreter) = interp.opt_params

# Disable optimization — Binaryen.js handles that on the Wasm side
Core.Compiler.may_optimize(interp::WasmInterpreter) = false
Core.Compiler.may_compress(interp::WasmInterpreter) = false
Core.Compiler.may_discard_trees(interp::WasmInterpreter) = false

# ─── Build-time population ──────────────────────────────────────────────────────
# These functions run at BUILD TIME (native Julia) to populate the DictMethodTable
# with all method signatures needed for the playground.

function populate_method_table(signatures::Vector; world::UInt64=Base.get_world_counter())
    table = DictMethodTable(world)
    native_mt = Core.Compiler.InternalMethodTable(world)
    for sig in signatures
        result = Core.Compiler.findall(sig, native_mt; limit=3)
        if result !== nothing
            table.methods[sig] = result
        end
    end
    return table
end

function predecompress_methods!(code_cache::PreDecompressedCodeInfo,
                                table::DictMethodTable;
                                world::UInt64=table.world)
    for (sig, result) in table.methods
        for match in result.matches
            mi = Core.Compiler.specialize_method(match)
            ci = Core.Compiler.retrieve_code_info(mi, world)
            if ci !== nothing
                code_cache.cache[mi] = ci
            end
        end
    end
    return code_cache
end

# ─── Transitive population ──────────────────────────────────────────────────────
# Discovers ALL method lookups that typeinf makes by tracing a first pass
# with InternalMethodTable, then populating DictMethodTable with the results.

struct _TracingTable <: MethodTableView
    inner::Core.Compiler.InternalMethodTable
    lookups::Dict{Any, MethodLookupResult}
    intersections::Dict{Tuple{Any,Any}, Any}           # traced typeintersect calls
    intersections_with_env::Dict{Tuple{Any,Any}, Any}   # traced intersection_with_env calls
end

function Core.Compiler.findall(sig::Type, table::_TracingTable; limit::Int=Int(typemax(Int32)))
    result = Core.Compiler.findall(sig, table.inner; limit=limit)
    if result !== nothing
        table.lookups[sig] = result
    end
    return result
end
Core.Compiler.isoverlayed(::_TracingTable) = false
Core.Compiler.findsup(sig::Type, table::_TracingTable) = Core.Compiler.findsup(sig, table.inner)

struct _TracingInterpreter <: AbstractInterpreter
    world::UInt64
    method_table::CachedMethodTable{_TracingTable}
    inf_cache::Vector{InferenceResult}
    inf_params::InferenceParams
    opt_params::OptimizationParams
end

Core.Compiler.method_table(interp::_TracingInterpreter) = interp.method_table
Core.Compiler.cache_owner(interp::_TracingInterpreter) = :_TracingInterpreter
Core.Compiler.get_inference_world(interp::_TracingInterpreter) = interp.world
Core.Compiler.get_inference_cache(interp::_TracingInterpreter) = interp.inf_cache
Core.Compiler.InferenceParams(interp::_TracingInterpreter) = interp.inf_params
Core.Compiler.OptimizationParams(interp::_TracingInterpreter) = interp.opt_params
Core.Compiler.may_optimize(interp::_TracingInterpreter) = false
Core.Compiler.may_compress(interp::_TracingInterpreter) = false
Core.Compiler.may_discard_trees(interp::_TracingInterpreter) = false

# ─── Intersection tracing globals ─────────────────────────────────────────────
# When non-nothing, typeintersect calls are recorded into these Dicts.
# Activated during populate_transitive(), deactivated after.

const _TRACING_INTERSECTIONS = Ref{Union{Nothing, Dict{Tuple{Any,Any}, Any}}}(nothing)
const _TRACING_INTERSECTIONS_WITH_ENV = Ref{Union{Nothing, Dict{Tuple{Any,Any}, Any}}}(nothing)

# ─── Pre-computed intersection lookup ─────────────────────────────────────────
# At Wasm runtime, typeintersect does a Dict lookup instead of ccall.
# At tracing time, it calls the real ccall AND records the result.
# At normal native time (tracing off, no WASM_INTERSECTIONS), it uses the ccall.

const _WASM_INTERSECTIONS = Ref{Union{Nothing, Dict{Tuple{Any,Any}, Any}}}(nothing)
const _WASM_INTERSECTIONS_WITH_ENV = Ref{Union{Nothing, Dict{Tuple{Any,Any}, Any}}}(nothing)

# Override typeintersect to trace and/or use pre-computed results
function Base.typeintersect(@nospecialize(a::Type), @nospecialize(b::Type))
    # Check pre-computed Dict first (Wasm runtime path)
    wasm_dict = _WASM_INTERSECTIONS[]
    if wasm_dict !== nothing
        key = (a, b)
        result = get(wasm_dict, key, nothing)
        if result !== nothing
            return result
        end
        # Also try (b, a) since intersection is commutative
        result = get(wasm_dict, (b, a), nothing)
        if result !== nothing
            return result
        end
        # Fallback: compute natively (shouldn't happen if Dict is complete)
    end

    # Compute using real ccall
    result = ccall(:jl_type_intersection, Any, (Any, Any), a, b)

    # If tracing, record the result
    tracing = _TRACING_INTERSECTIONS[]
    if tracing !== nothing
        tracing[(a, b)] = result
    end

    return result
end

# Pure Julia replacement for ccall(:jl_type_intersection_with_env, ...)
# Returns a SimpleVector [intersection_result, type_env_bindings]
# Used inline in abstract_call_method, abstract_call_opaque_closure, normalize_typevars
function _type_intersection_with_env(@nospecialize(a::Type), @nospecialize(b::Type))
    # Check pre-computed Dict first (Wasm runtime path)
    wasm_dict = _WASM_INTERSECTIONS_WITH_ENV[]
    if wasm_dict !== nothing
        key = (a, b)
        result = get(wasm_dict, key, nothing)
        if result !== nothing
            return result
        end
    end

    # Compute using real ccall
    result = ccall(:jl_type_intersection_with_env, Any, (Any, Any), a, b)::Core.SimpleVector

    # If tracing, record the result
    tracing = _TRACING_INTERSECTIONS_WITH_ENV[]
    if tracing !== nothing
        tracing[(a, b)] = result
    end

    return result
end

# Override normalize_typevars to use pure Julia intersection_with_env
function Base.normalize_typevars(method::Method, @nospecialize(atype), sparams::Core.SimpleVector)
    at2 = Base.subst_trivial_bounds(atype)
    if at2 !== atype && at2 == atype
        atype = at2
        sp_ = _type_intersection_with_env(at2, method.sig)
        sparams = sp_[2]::Core.SimpleVector
    end
    return Pair{Any,Core.SimpleVector}(atype, sparams)
end

function populate_transitive(signatures::Vector; world::UInt64=Base.get_world_counter())
    native_mt = Core.Compiler.InternalMethodTable(world)
    tracing = _TracingTable(native_mt, Dict{Any, MethodLookupResult}(),
                            Dict{Tuple{Any,Any}, Any}(),
                            Dict{Tuple{Any,Any}, Any}())
    cached = CachedMethodTable(tracing)
    interp = _TracingInterpreter(world, cached,
        Vector{InferenceResult}(), InferenceParams(),
        OptimizationParams(; inlining=false))

    # Enable intersection tracing during typeinf pass
    _TRACING_INTERSECTIONS[] = tracing.intersections
    _TRACING_INTERSECTIONS_WITH_ENV[] = tracing.intersections_with_env

    for sig in signatures
        lookup = Core.Compiler.findall(sig, native_mt; limit=3)
        lookup === nothing && continue
        mi = Core.Compiler.specialize_method(first(lookup.matches))
        src = Core.Compiler.retrieve_code_info(mi, world)
        src === nothing && continue
        result = InferenceResult(mi)
        frame = InferenceState(result, src, :no, interp)
        try
            Core.Compiler.typeinf(interp, frame)
        catch
            # Some methods may fail — that's OK, we still collect partial lookups
        end
    end

    # Disable intersection tracing
    _TRACING_INTERSECTIONS[] = nothing
    _TRACING_INTERSECTIONS_WITH_ENV[] = nothing

    # Build DictMethodTable from traced lookups + original signatures
    table = DictMethodTable(world)
    for (sig, result) in tracing.lookups
        table.methods[sig] = result
    end
    # Ensure the original signatures are also included
    for sig in signatures
        if !haskey(table.methods, sig)
            result = Core.Compiler.findall(sig, native_mt; limit=3)
            if result !== nothing
                table.methods[sig] = result
            end
        end
    end
    # Copy traced intersections to the DictMethodTable
    for (key, val) in tracing.intersections
        table.intersections[key] = val
    end
    for (key, val) in tracing.intersections_with_env
        table.intersections_with_env[key] = val
    end
    return table
end

# ─── Convenience: build a complete WasmInterpreter for given signatures ─────────

function build_wasm_interpreter(signatures::Vector; world::UInt64=Base.get_world_counter(),
                                 transitive::Bool=true)
    table = if transitive
        populate_transitive(signatures; world=world)
    else
        populate_method_table(signatures; world=world)
    end
    interp = WasmInterpreter(world, table)
    predecompress_methods!(interp.code_info_cache, table; world=world)
    return interp
end

# ─── Verification: compare Dict typeinf vs native typeinf ───────────────────────

function verify_typeinf(f, argtypes::Tuple;
                        world::UInt64=Base.get_world_counter(),
                        verbose::Bool=false)
    # Step 1: Get native result via code_typed
    native_results = Base.code_typed(f, argtypes; optimize=false)
    if isempty(native_results)
        return (pass=false, reason="code_typed returned empty for $f$argtypes")
    end
    native_ci, native_rettype = first(native_results)

    # Step 2: Build WasmInterpreter with the method signature
    # For Type constructors (e.g., Int64(Bool)), typeof(Int64) == DataType, but the
    # correct signature is Tuple{Type{Int64}, Bool}. Use the native result's MI to
    # get the exact signature that code_typed matched.
    native_mi = native_ci.parent
    if native_mi !== nothing
        sig = native_mi.specTypes
    else
        sig = Tuple{typeof(f), argtypes...}
    end
    interp = build_wasm_interpreter([sig]; world=world)

    # Step 3: Run typeinf with WasmInterpreter
    # Use the same MethodInstance that code_typed used, to ensure we're comparing the same method
    mi = native_ci.parent
    src = Core.Compiler.retrieve_code_info(mi, world)
    if src === nothing
        return (pass=false, reason="retrieve_code_info returned nothing for $mi")
    end
    result = Core.Compiler.InferenceResult(mi)
    frame = InferenceState(result, src, #=cache_mode=# :no, interp)
    Core.Compiler.typeinf(interp, frame)

    # Step 4: Compare return types
    dict_rettype = result.result
    if verbose
        println("Native rettype: $native_rettype")
        println("Dict rettype:   $dict_rettype")
        println("Native CI stmts: $(length(native_ci.code))")
    end

    # Exact match
    types_match = native_rettype == dict_rettype
    # Also accept Core.Const refinements: Const(0) is more precise than Int64
    if !types_match && dict_rettype isa Core.Compiler.Const
        types_match = Core.Compiler.widenconst(dict_rettype) == native_rettype
    end
    # And accept InterConditional as refinement of Bool (common for ! operator)
    if !types_match && dict_rettype isa Core.Compiler.InterConditional
        types_match = native_rettype === Bool
    end
    return (pass=types_match, native_rettype=native_rettype, dict_rettype=dict_rettype,
            native_ci=native_ci, dict_result=result)
end
