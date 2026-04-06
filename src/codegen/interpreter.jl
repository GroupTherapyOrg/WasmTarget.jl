# ============================================================================
# WasmTarget Custom AbstractInterpreter with Method Table Overlays
# ============================================================================
#
# Following the GPUCompiler.jl pattern: create a custom AbstractInterpreter
# with an OverlayMethodTable so Julia's own compiler resolves dispatch using
# WASM-friendly method replacements BEFORE WasmTarget's codegen sees the IR.
#
# This is the same infrastructure that CUDA.jl, AMDGPU.jl, and oneAPI.jl
# use for compiling Julia to non-native targets.

import Core.Compiler as CC
using Base.Experimental: @MethodTable, @overlay

# ─── Method Table ───────────────────────────────────────────────────────────

Base.Experimental.@MethodTable(WASM_METHOD_TABLE)

# ─── Overlays ───────────────────────────────────────────────────────────────

# sort! overlay: simple insertion sort producing flat IR.
# Base.sort! dispatches through InsertionSort/MergeSort/By/Lt/Order —
# deep dispatch chains that produce hundreds of IR statements with complex
# method resolution. This overlay replaces all of that with a simple loop.
#
# As WasmTarget's codegen improves, this overlay can be removed —
# the original Base.sort! would then compile directly.
@overlay WASM_METHOD_TABLE function Base.sort!(v::AbstractVector;
        lt=isless, by=identity, rev::Bool=false,
        alg::Base.Sort.Algorithm=Base.Sort.InsertionSort,
        order::Base.Order.Ordering=Base.Order.Forward)
    n = length(v)
    for i in 2:n
        key = v[i]
        j = i - 1
        while j >= 1
            # Compare: should v[j] shift right? (i.e., key should come before v[j])
            should_shift = rev ? lt(by(v[j]), by(key)) : lt(by(key), by(v[j]))
            !should_shift && break
            v[j + 1] = v[j]
            j -= 1
        end
        v[j + 1] = key
    end
    return v
end

# String comparison overlays: Base implementations use foreigncall :memcmp
# which can't run in WASM. Stub return values (0="equal") are semantically wrong
# and cause wasm-opt GUFA to eliminate live comparison branches.
# These replace memcmp-based paths with pure-Julia byte loops.
@overlay WASM_METHOD_TABLE function Base.startswith(a::String, b::String)
    al = ncodeunits(a)
    bl = ncodeunits(b)
    bl > al && return false
    i = 1
    while i <= bl
        codeunit(a, i) != codeunit(b, i) && return false
        i += 1
    end
    return true
end

@overlay WASM_METHOD_TABLE function Base.endswith(a::String, b::String)
    al = ncodeunits(a)
    bl = ncodeunits(b)
    bl > al && return false
    offset = al - bl
    i = 1
    while i <= bl
        codeunit(a, offset + i) != codeunit(b, i) && return false
        i += 1
    end
    return true
end

# cmp overlay: Base.cmp for strings uses foreigncall :memcmp which can't
# run in WASM. Replace with byte-by-byte comparison (pure Julia).
@overlay WASM_METHOD_TABLE function Base.cmp(a::String, b::String)
    al = ncodeunits(a)
    bl = ncodeunits(b)
    ml = al < bl ? al : bl
    i = 1
    while i <= ml
        ca = codeunit(a, i)
        cb = codeunit(b, i)
        if ca != cb
            return ca < cb ? -1 : 1
        end
        i += 1
    end
    return al < bl ? -1 : al > bl ? 1 : 0
end

# chop overlay: Base.chop calls #chop#418 which has complex kwarg dispatch.
# Uses WasmTarget str_* primitives for WasmGC string construction.
@overlay WASM_METHOD_TABLE function Base.chop(s::String; head::Int=0, tail::Int=1)
    n = str_len(s)
    new_len = n - Int32(head) - Int32(tail)
    new_len <= Int32(0) && return ""
    result = str_new(new_len)
    i = Int32(1)
    while i <= new_len
        str_setchar!(result, i, str_char(s, i + Int32(head)))
        i = i + Int32(1)
    end
    return Base.inferencebarrier(result)::String
end

# last(String, Int) overlay: Base.last uses SubString dispatch chains.
@overlay WASM_METHOD_TABLE function Base.last(s::String, n::Int)
    len = str_len(s)
    n32 = Int32(n)
    n32 >= len && return s
    result = str_new(n32)
    start = len - n32
    i = Int32(1)
    while i <= n32
        str_setchar!(result, i, str_char(s, start + i))
        i = i + Int32(1)
    end
    return Base.inferencebarrier(result)::String
end

# reverse(String) overlay: Base.reverse uses GC.@preserve + pointer ops.
@overlay WASM_METHOD_TABLE function Base.reverse(s::String)
    n = str_len(s)
    n <= Int32(1) && return s
    result = str_new(n)
    i = Int32(1)
    while i <= n
        str_setchar!(result, n - i + Int32(1), str_char(s, i))
        i = i + Int32(1)
    end
    return Base.inferencebarrier(result)::String
end

# titlecase overlay: Base.titlecase uses Unicode tables and complex dispatch.
# Simple ASCII version: uppercase first char of each word.
@overlay WASM_METHOD_TABLE function Base.titlecase(s::String; wordsep=nothing, strict::Bool=true)
    n = str_len(s)
    n == Int32(0) && return s
    result = str_new(n)
    prev_space = true
    i = Int32(1)
    while i <= n
        c = str_char(s, i)
        if c == Int32(' ') || c == Int32('\t') || c == Int32('\n')
            str_setchar!(result, i, c)
            prev_space = true
        elseif prev_space
            # Uppercase: if lowercase a-z, subtract 32
            if c >= _CHAR_A_LOWER && c <= _CHAR_Z_LOWER
                str_setchar!(result, i, c - _CHAR_CASE_DIFF)
            else
                str_setchar!(result, i, c)
            end
            prev_space = false
        elseif strict
            # Lowercase: if uppercase A-Z, add 32
            if c >= _CHAR_A_UPPER && c <= _CHAR_Z_UPPER
                str_setchar!(result, i, c + _CHAR_CASE_DIFF)
            else
                str_setchar!(result, i, c)
            end
        else
            str_setchar!(result, i, c)
        end
        i = i + Int32(1)
    end
    return Base.inferencebarrier(result)::String
end

# lowercasefirst overlay: Base version has complex SubString/GenericString dispatch.
@overlay WASM_METHOD_TABLE function Base.Unicode.lowercasefirst(s::String)
    n = str_len(s)
    n == Int32(0) && return s
    result = str_new(n)
    # First char: lowercase
    c = str_char(s, Int32(1))
    if c >= _CHAR_A_UPPER && c <= _CHAR_Z_UPPER
        str_setchar!(result, Int32(1), c + _CHAR_CASE_DIFF)
    else
        str_setchar!(result, Int32(1), c)
    end
    # Copy rest
    i = Int32(2)
    while i <= n
        str_setchar!(result, i, str_char(s, i))
        i = i + Int32(1)
    end
    return Base.inferencebarrier(result)::String
end

# uppercasefirst overlay: Same issue as lowercasefirst.
@overlay WASM_METHOD_TABLE function Base.Unicode.uppercasefirst(s::String)
    n = str_len(s)
    n == Int32(0) && return s
    result = str_new(n)
    # First char: uppercase
    c = str_char(s, Int32(1))
    if c >= _CHAR_A_LOWER && c <= _CHAR_Z_LOWER
        str_setchar!(result, Int32(1), c - _CHAR_CASE_DIFF)
    else
        str_setchar!(result, Int32(1), c)
    end
    # Copy rest
    i = Int32(2)
    while i <= n
        str_setchar!(result, i, str_char(s, i))
        i = i + Int32(1)
    end
    return Base.inferencebarrier(result)::String
end

# unique overlay: Base.unique dispatches through _unique! which uses Dict internally.
# The compiled function ends up calling itself (self-recursion) due to name collision
# in function discovery. Simple O(n²) implementation with `in` check avoids this.
@overlay WASM_METHOD_TABLE function Base.unique(A::AbstractVector)
    n = length(A)
    result = similar(A, 0)
    i = 1
    while i <= n
        val = A[i]
        found = false
        j = 1
        while j <= length(result)
            if result[j] == val
                found = true
                break
            end
            j += 1
        end
        if !found
            push!(result, val)
        end
        i += 1
    end
    return result
end

# ─── WasmInterpreter ───────────────────────────────────────────────────────

struct WasmInterpreter <: CC.AbstractInterpreter
    world::UInt
    method_table::CC.OverlayMethodTable
    inf_cache::Vector{CC.InferenceResult}
    inf_params::CC.InferenceParams
    opt_params::CC.OptimizationParams
end

function WasmInterpreter(; world::UInt=Base.get_world_counter())
    mt = CC.OverlayMethodTable(world, WASM_METHOD_TABLE)
    inf_params = CC.InferenceParams(;
        aggressive_constant_propagation=true,
    )
    opt_params = CC.OptimizationParams(;
        inline_cost_threshold=500,
        inline_nonleaf_penalty=100,
    )
    WasmInterpreter(world, mt, CC.InferenceResult[], inf_params, opt_params)
end

# Required AbstractInterpreter API
CC.InferenceParams(interp::WasmInterpreter) = interp.inf_params
CC.OptimizationParams(interp::WasmInterpreter) = interp.opt_params
CC.get_inference_world(interp::WasmInterpreter) = interp.world
CC.get_inference_cache(interp::WasmInterpreter) = interp.inf_cache
CC.cache_owner(::WasmInterpreter) = :wasm_target
CC.method_table(interp::WasmInterpreter) = interp.method_table

# Disable semi-concrete eval (broken with overlays — GPUCompiler pattern)
function CC.concrete_eval_eligible(interp::WasmInterpreter,
        @nospecialize(f), result::CC.MethodCallResult, arginfo::CC.ArgInfo,
        sv::Union{CC.InferenceState, CC.IRInterpretationState})
    ret = @invoke CC.concrete_eval_eligible(interp::CC.AbstractInterpreter,
        f::Any, result::CC.MethodCallResult, arginfo::CC.ArgInfo,
        sv::Union{CC.InferenceState, CC.IRInterpretationState})
    if ret === :semi_concrete_eval
        return :none
    end
    return ret
end

"""
    get_wasm_interpreter() -> WasmInterpreter

Create a WasmInterpreter with overlay method table for the current world age.
Must be called after all user functions are defined (so they're visible to inference).
"""
get_wasm_interpreter() = WasmInterpreter(; world=Base.get_world_counter())
