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
# Always copies to avoid codegen null-ref phi bug on `return s`.
@overlay WASM_METHOD_TABLE function Base.last(s::String, n::Int)
    len = str_len(s)
    n32 = Int32(n)
    take = n32 >= len ? len : n32
    result = str_new(take)
    start = len - take
    i = Int32(1)
    while i <= take
        str_setchar!(result, i, str_char(s, start + i))
        i = i + Int32(1)
    end
    return Base.inferencebarrier(result)::String
end

# reverse(String) overlay: Base.reverse uses GC.@preserve + pointer ops.
# Always copies to avoid codegen null-ref phi bug on `return s`.
@overlay WASM_METHOD_TABLE function Base.reverse(s::String)
    n = str_len(s)
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
# Uses flat if-then pattern (not nested if/elseif) to avoid codegen phi node bugs.
@overlay WASM_METHOD_TABLE function Base.titlecase(s::String; wordsep=nothing, strict::Bool=true)
    n = str_len(s)
    n == Int32(0) && return s
    result = str_new(n)
    prev_space = Int32(1)
    i = Int32(1)
    while i <= n
        c = str_char(s, i)
        new_c = c
        new_prev = prev_space

        is_ws = c == Int32(32) # space (simplified whitespace check)

        if is_ws
            new_prev = Int32(1)
        else
            new_prev = Int32(0)
        end

        # Uppercase if prev was space and char is lowercase a-z
        if prev_space == Int32(1) && !is_ws && c >= _CHAR_A_LOWER && c <= _CHAR_Z_LOWER
            new_c = c - _CHAR_CASE_DIFF
        end

        # Lowercase if prev was not space and char is uppercase A-Z (strict mode)
        if strict && prev_space == Int32(0) && !is_ws && c >= _CHAR_A_UPPER && c <= _CHAR_Z_UPPER
            new_c = c + _CHAR_CASE_DIFF
        end

        str_setchar!(result, i, new_c)
        prev_space = new_prev
        i = i + Int32(1)
    end
    return Base.inferencebarrier(result)::String
end

# lowercasefirst overlay: Base version has complex SubString/GenericString dispatch.
# Uses flat if-then pattern to avoid codegen phi node bugs with if/else before loops.
@overlay WASM_METHOD_TABLE function Base.Unicode.lowercasefirst(s::String)
    n = str_len(s)
    n == Int32(0) && return s
    result = str_new(n)
    # First char: lowercase if uppercase, else keep as-is
    c = str_char(s, Int32(1))
    new_c = c
    if c >= _CHAR_A_UPPER && c <= _CHAR_Z_UPPER
        new_c = c + _CHAR_CASE_DIFF
    end
    str_setchar!(result, Int32(1), new_c)
    # Copy rest
    i = Int32(2)
    while i <= n
        str_setchar!(result, i, str_char(s, i))
        i = i + Int32(1)
    end
    return Base.inferencebarrier(result)::String
end

# uppercasefirst overlay: Same pattern as lowercasefirst.
@overlay WASM_METHOD_TABLE function Base.Unicode.uppercasefirst(s::String)
    n = str_len(s)
    n == Int32(0) && return s
    result = str_new(n)
    # First char: uppercase if lowercase, else keep as-is
    c = str_char(s, Int32(1))
    new_c = c
    if c >= _CHAR_A_LOWER && c <= _CHAR_Z_LOWER
        new_c = c - _CHAR_CASE_DIFF
    end
    str_setchar!(result, Int32(1), new_c)
    # Copy rest
    i = Int32(2)
    while i <= n
        str_setchar!(result, i, str_char(s, i))
        i = i + Int32(1)
    end
    return Base.inferencebarrier(result)::String
end

# length(String) overlay: Base.length(::String) uses Core.sizeof which returns byte
# count. For WasmGC strings (i32 arrays), sizeof returns n*4 not n. This overlay
# uses str_len which maps directly to array.len in WASM.
@overlay WASM_METHOD_TABLE function Base.length(s::String)
    return Int(str_len(s))
end

# getindex(String, Int) overlay: Base version uses jl_string_ptr foreigncall +
# pointerref for byte access, which doesn't work reliably in WasmGC.
# Uses str_char (array.get_u on byte array) + Char construction.
# NOTE: str_getchar would create a circular dependency (its fallback calls getindex).
@overlay WASM_METHOD_TABLE function Base.getindex(s::String, i::Int)
    b = codeunit(s, i)
    return Char(UInt32(b))
end

# strip/lstrip/rstrip overlays: Base versions return SubString which causes WasmGC
# type mismatch (SubString ref vs String ref). These return new String via str_* ops.
@overlay WASM_METHOD_TABLE function Base.strip(s::String)
    return str_trim(s)
end

@overlay WASM_METHOD_TABLE function Base.lstrip(s::String)
    n = str_len(s)
    n == Int32(0) && return s
    start = Int32(1)
    while start <= n && _is_whitespace(str_char(s, start))
        start += Int32(1)
    end
    start > n && return ""
    return str_substr(s, start, n - start + Int32(1))
end

@overlay WASM_METHOD_TABLE function Base.rstrip(s::String)
    n = str_len(s)
    n == Int32(0) && return s
    stop = n
    while stop >= Int32(1) && _is_whitespace(str_char(s, stop))
        stop -= Int32(1)
    end
    stop < Int32(1) && return ""
    return str_substr(s, Int32(1), stop)
end

# replace overlay: Base.replace uses SubString + Pair matching internally.
# Two-pass approach: count matches first, then build result.
# IMPORTANT: No early `return s` — codegen emits ref.null for string literals
# in phi nodes on early-return paths, causing null pointer at runtime.
# Instead, always build a copy (when count==0, out_len==slen, copies original).
@overlay WASM_METHOD_TABLE function Base.replace(s::String, pair::Pair{String,String})
    pattern = pair.first
    replacement = pair.second
    slen = str_len(s)
    plen = str_len(pattern)
    rlen = plen > Int32(0) ? str_len(replacement) : Int32(0)

    # Pass 1: count matches
    count = Int32(0)
    i = Int32(1)
    while i <= slen - plen + Int32(1) && plen > Int32(0)
        found = true
        j = Int32(1)
        while j <= plen
            if str_char(s, i + j - Int32(1)) != str_char(pattern, j)
                found = false
                j = plen + Int32(1)  # break
            else
                j += Int32(1)
            end
        end
        if found
            count += Int32(1)
            i += plen  # skip past match
        else
            i += Int32(1)
        end
    end

    # Pass 2: build result char by char (copies original when count==0)
    out_len = slen - count * plen + count * rlen
    result = str_new(out_len)
    ri = Int32(1)
    i = Int32(1)
    while i <= slen
        # Check for pattern match at position i
        matched = plen > Int32(0) && i <= slen - plen + Int32(1)
        j = Int32(1)
        while j <= plen && matched
            if str_char(s, i + j - Int32(1)) != str_char(pattern, j)
                matched = false
            end
            j += Int32(1)
        end
        if matched
            # Copy replacement
            k = Int32(1)
            while k <= rlen
                str_setchar!(result, ri, str_char(replacement, k))
                ri += Int32(1)
                k += Int32(1)
            end
            i += plen
        else
            str_setchar!(result, ri, str_char(s, i))
            ri += Int32(1)
            i += Int32(1)
        end
    end
    return Base.inferencebarrier(result)::String
end

# split overlay: Base.split returns Vector{SubString} which WasmTarget can't handle.
# This returns Vector{String} with actual string copies.
@overlay WASM_METHOD_TABLE function Base.split(s::String, delim::String;
        limit::Int=0, keepempty::Bool=true)
    result = String[]
    n = str_len(s)
    dlen = str_len(delim)
    count = 0
    start = Int32(1)

    while start <= n
        # Check limit (0 = no limit)
        if limit > 0 && count >= limit - 1
            # Last piece: take everything remaining
            push!(result, String(str_substr(s, start, n - start + Int32(1))))
            count += 1
            start = n + Int32(1)
            break
        end
        pos = str_find(str_substr(s, start, n - start + Int32(1)), delim)
        if pos == Int32(0)
            break
        end
        # pos is relative to start
        abs_pos = start + pos - Int32(1)
        piece_len = abs_pos - start
        if piece_len > Int32(0) || keepempty
            if piece_len > Int32(0)
                push!(result, String(str_substr(s, start, piece_len)))
            else
                push!(result, "")
            end
            count += 1
        end
        start = abs_pos + dlen
    end
    # Remaining piece (or empty string if nothing was processed)
    if start <= n
        push!(result, String(str_substr(s, start, n - start + Int32(1))))
    elseif length(result) == 0 && keepempty
        # Empty input with keepempty → return [""]
        push!(result, "")
    end
    return result
end

# join overlay: Base.join uses IOBuffer which is a deep dependency.
# Simple concatenation with delimiter.
@overlay WASM_METHOD_TABLE function Base.join(strings, delim::String)
    result = ""
    first = true
    for s in strings
        if !first
            result = str_concat(result, delim)
        end
        result = str_concat(result, String(s))
        first = false
    end
    return Base.inferencebarrier(result)::String
end

@overlay WASM_METHOD_TABLE function Base.join(strings)
    result = ""
    for s in strings
        result = str_concat(result, String(s))
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

# Disable concrete eval entirely (GPUCompiler pattern).
# Without this, the compiler constant-folds calls like getindex("hello", 1)
# using the Base implementation, bypassing overlays. This matters because
# overlay-produced strings use WasmGC arrays, not the pointer-based Base layout.
function CC.concrete_eval_eligible(interp::WasmInterpreter,
        @nospecialize(f), result::CC.MethodCallResult, arginfo::CC.ArgInfo,
        sv::Union{CC.InferenceState, CC.IRInterpretationState})
    return :none
end

"""
    get_wasm_interpreter() -> WasmInterpreter

Create a WasmInterpreter with overlay method table for the current world age.
Must be called after all user functions are defined (so they're visible to inference).
"""
get_wasm_interpreter() = WasmInterpreter(; world=Base.get_world_counter())
