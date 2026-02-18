# Pure Julia reimplementation of ml_matches (gf.c)
# Phase 2d: Replaces C runtime method matching for WasmGC compilation
#
# This file implements:
#   - wasm_matching_methods: find all methods matching a call signature
#   - _extract_sparams: extract static parameter bindings from type matching
#   - _sort_by_specificity!: sort matches using precomputed interferences
#   - _method_morespecific: check if one method is more specific than another
#
# Dependencies:
#   - wasm_subtype (from subtype.jl) — for subtype checks
#   - wasm_type_intersection (from subtype.jl) — for intersection computation
#
# Verified against: Core.Compiler.findall with InternalMethodTable (PURE-4131)

# Load subtype.jl if not already loaded (for standalone inclusion)
if !@isdefined(SubtypeEnv)
    include(joinpath(@__DIR__, "subtype.jl"))
end

using Core.Compiler: MethodMatch, MethodLookupResult, WorldRange

# ─── Static parameter extraction ───

"""
    _extract_sparams(sig::Type, method_sig::Type) → Core.SimpleVector

Extract the static parameter (TypeVar) bindings that result from matching
`sig` against `method_sig`. This is the pure Julia equivalent of the
sparams extraction done by `jl_type_intersection_with_env`.

Algorithm: Walk the UnionAll chain of method_sig, run subtype check
with environment tracking, and read off the variable bindings.
"""
function _extract_sparams(@nospecialize(sig), @nospecialize(method_sig))::Core.SimpleVector
    # If method_sig has no TypeVars, sparams is empty
    method_sig isa UnionAll || return Core.svec()

    # Collect the TypeVars from the UnionAll chain
    tvars = TypeVar[]
    t = method_sig
    while t isa UnionAll
        push!(tvars, t.var)
        t = t.body
    end

    # Run subtype with environment to capture bindings
    env = SubtypeEnv()
    _subtype(sig, method_sig, env, 0)

    # The bindings are in the env after subtype check
    # But since _subtype pops vars on return, we need a different approach:
    # Run _subtype manually with the UnionAll chain
    env2 = SubtypeEnv()
    bindings = Any[]
    _extract_sparams_walk!(bindings, sig, method_sig, env2)

    return Core.svec(bindings...)
end

"""
Walk the UnionAll chain on the right side, push VarBindings, run subtype,
then collect the bindings.
"""
function _extract_sparams_walk!(bindings::Vector{Any}, @nospecialize(sig), @nospecialize(method_sig),
                                 env::SubtypeEnv)
    if method_sig isa UnionAll
        # Push binding for this TypeVar (right side = existential)
        vb = VarBinding(method_sig.var, true)
        push!(env.vars, vb)

        # Recurse into body
        _extract_sparams_walk!(bindings, sig, method_sig.body, env)

        # Read off the binding: lb is the inferred concrete type
        # For successful matches, lb should equal ub (= the concrete binding)
        binding = vb.lb
        if binding === Union{}
            # TypeVar wasn't constrained — use the TypeVar itself
            binding = method_sig.var
        end
        # Insert at the front since we're unwinding the stack
        # Actually, we need to insert in order: first UnionAll var = first sparam
        pushfirst!(bindings, binding)

        # Pop binding
        pop!(env.vars)
    else
        # Base case: no more UnionAll wrappers — run the actual subtype check
        _subtype(sig, method_sig, env, 0)
    end
end

# ─── Method iteration helpers ───

"""
    _get_all_methods(sig::Type) → Vector{Method}

Get all methods for the function referenced in the call signature.
The signature is expected to be a Tuple type where the first element
is `typeof(f)` for some function `f`.
"""
function _get_all_methods(@nospecialize(sig))::Vector{Method}
    unw = Base.unwrap_unionall(sig)
    unw isa DataType || return Method[]
    length(unw.parameters) >= 1 || return Method[]

    ft = unw.parameters[1]
    ft isa DataType || return Method[]

    # Case 1: Singleton function type (typeof(f) has an instance)
    if isdefined(ft, :instance)
        f = ft.instance
        return methods(f).ms
    end

    # Case 2: Type constructor — e.g., Type{Float64}
    # ft is like Type{Float64}, and we need methods(Float64)
    if ft <: Type && length(ft.parameters) >= 1
        T = ft.parameters[1]
        if T isa DataType || T isa UnionAll
            return methods(T).ms
        end
    end

    return Method[]
end

# ─── Specificity sorting ───

# Check if target is in source.interferences. Handles undefined Memory entries.
function _in_interferences(target::Method, source::Method)::Bool
    interf = source.interferences
    for i in 1:length(interf)
        if isassigned(interf, i) && interf[i] === target
            return true
        end
    end
    return false
end

function _method_morespecific(m1::Method, m2::Method)::Bool
    # From gf.c: m1 is more specific than m2 if:
    # m1 is in m2.interferences (m2 interferes with m1) AND
    # m2 is NOT in m1.interferences (m1 does not interfere with m2)
    return _in_interferences(m1, m2) && !_in_interferences(m2, m1)
end

"""
    _sort_by_specificity!(matches::Vector{MethodMatch})

Sort method matches by specificity, with most specific methods first.
Uses precomputed interferences from Julia 1.12.
"""
function _sort_by_specificity!(matches::Vector{Any})
    # Simple insertion sort — typically very few matches (1-5)
    n = length(matches)
    for i in 2:n
        j = i
        while j > 1
            m_j = matches[j]::MethodMatch
            m_prev = matches[j-1]::MethodMatch
            if _method_morespecific(m_j.method, m_prev.method)
                matches[j], matches[j-1] = matches[j-1], matches[j]
                j -= 1
            else
                break
            end
        end
    end
end

# ─── Ambiguity detection ───

"""
    _detect_ambiguity(matches::Vector{Any}) → Bool

Detect if there is any ambiguity among the matched methods.
Two methods are ambiguous if each is in the other's interferences set.
"""
function _detect_ambiguity(matches::Vector{Any})::Bool
    n = length(matches)
    n <= 1 && return false

    for i in 1:n
        mi = (matches[i]::MethodMatch).method
        for j in (i+1):n
            mj = (matches[j]::MethodMatch).method
            # Ambiguous if mutually in each other's interferences
            if _in_interferences(mi, mj) && _in_interferences(mj, mi)
                return true
            end
        end
    end
    return false
end

# ─── Main entry point ───

"""
    wasm_matching_methods(sig::Type; limit::Int=-1) → Union{MethodLookupResult, Nothing}

Find all methods matching the call signature `sig`.
Pure Julia reimplementation of `jl_matching_methods` / `ml_matches` from `src/gf.c`.

Returns a `MethodLookupResult` compatible with `Core.Compiler.findall`, or
`nothing` if the limit is exceeded.

Simplified from the C implementation:
- No world age filtering (single compile-time snapshot)
- No TypeMap trie traversal (linear scan over all methods)
- No caching (single-shot compilation)
- Uses precomputed `method.interferences` for specificity sorting
"""
function wasm_matching_methods(@nospecialize(sig); limit::Int=-1)::Union{MethodLookupResult, Nothing}
    # Get all methods for the function in the signature
    all_meths = _get_all_methods(sig)
    isempty(all_meths) && return MethodLookupResult(Any[], WorldRange(UInt(1), typemax(UInt)), false)

    # For dispatch tuples (concrete call signatures), the C code only includes
    # methods where the call type is a subtype of the method signature.
    # Non-subtype intersections are skipped (an important optimization from gf.c).
    unw = Base.unwrap_unionall(sig)
    is_dispatch = unw isa DataType && Base.isdispatchtuple(sig)

    # Phase 1: Collect all matching methods
    matches = Any[]
    for method in all_meths
        # Check if the call signature is a subtype of the method signature
        issubty = false
        try
            issubty = wasm_subtype(sig, method.sig)
        catch
            # Complex type patterns may trigger edge cases in subtype
        end

        # For dispatch tuples, skip non-subtype methods (matches C behavior)
        if is_dispatch && !issubty
            continue
        end

        # Check intersection (only needed if not a subtype)
        ti = Union{}
        if issubty
            ti = sig  # subtype implies non-empty intersection
        else
            try
                ti = wasm_type_intersection(sig, method.sig)
            catch
                # Complex type patterns may trigger edge cases in intersection
                continue
            end
        end

        if ti !== Union{}
            # Extract static parameters
            sparams = try
                _extract_sparams(sig, method.sig)
            catch
                Core.svec()  # fallback to empty sparams
            end

            # Use sig as spec_types if fully covering, otherwise the intersection
            spec_types = issubty ? sig : ti

            mm = MethodMatch(spec_types, sparams, method, issubty)
            push!(matches, mm)
        end
    end

    # Phase 2: Sort by specificity (most specific first)
    if length(matches) > 1
        _sort_by_specificity!(matches)
    end

    # Phase 3: Prune dominated methods (mirrors gf.c Phase 3)
    # Find minmax: the most specific fully-covering method
    if length(matches) > 1
        minmax_idx = 0
        for i in 1:length(matches)
            mm_i = matches[i]::MethodMatch
            if mm_i.fully_covers
                is_minmax = true
                for j in 1:length(matches)
                    i == j && continue
                    mm_j = matches[j]::MethodMatch
                    if mm_j.fully_covers
                        if !_method_morespecific(mm_i.method, mm_j.method)
                            is_minmax = false
                            break
                        end
                    end
                end
                if is_minmax
                    minmax_idx = i
                    break
                end
            end
        end

        # Remove dominated methods: if minmax is more specific than a method,
        # that method is dominated and can be removed
        if minmax_idx > 0
            minmax_method = (matches[minmax_idx]::MethodMatch).method
            pruned = Any[]
            for i in 1:length(matches)
                mm_i = matches[i]::MethodMatch
                if i == minmax_idx
                    push!(pruned, mm_i)
                elseif !mm_i.fully_covers
                    # Non-fully-covering: keep only if minmax does NOT dominate
                    if !_method_morespecific(minmax_method, mm_i.method)
                        push!(pruned, mm_i)
                    end
                else
                    # Other fully-covering but less specific: dominated, prune
                end
            end
            matches = pruned
        end
    end

    # Phase 4: Detect ambiguity
    ambig = _detect_ambiguity(matches)

    # Limit check (after pruning, not before)
    if limit >= 0 && length(matches) > limit
        return nothing
    end

    return MethodLookupResult(matches, WorldRange(UInt(1), typemax(UInt)), ambig)
end
