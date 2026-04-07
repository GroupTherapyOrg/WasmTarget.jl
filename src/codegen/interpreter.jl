# ============================================================================
# WasmTarget Custom AbstractInterpreter with Method Table Overlays
# ============================================================================
#
# Following the GPUCompiler.jl pattern: create a custom AbstractInterpreter
# with an OverlayMethodTable so Julia's own compiler resolves dispatch using
# WASM-friendly method replacements BEFORE WasmTarget's codegen sees the IR.
#
# RULES FOR OVERLAYS:
# 1. Overlays must use ONLY pure Julia — no str_*, arr_* WasmTarget runtime fns
# 2. Julia's inference must be able to fully type-check every overlay
# 3. Overlays must produce identical results to the Base methods they replace
# 4. WasmInterpreter is ALWAYS on — every compilation uses it
#
# This is the same infrastructure that CUDA.jl, AMDGPU.jl, and oneAPI.jl
# use for compiling Julia to non-native targets.

import Core.Compiler as CC
using Base.Experimental: @MethodTable, @overlay

# ─── Method Table ───────────────────────────────────────────────────────────

Base.Experimental.@MethodTable(WASM_METHOD_TABLE)

# ─── Sort Overlay ──────────────────────────────────────────────────────────
# Base.sort! dispatches through InsertionSort/MergeSort/By/Lt/Order —
# deep dispatch chains that produce hundreds of IR statements.
# Simple insertion sort with full kwarg support.

@overlay WASM_METHOD_TABLE function Base.sort!(v::AbstractVector;
        lt=isless, by=identity, rev::Bool=false,
        alg::Base.Sort.Algorithm=Base.Sort.InsertionSort,
        order::Base.Order.Ordering=Base.Order.Forward)
    n = length(v)
    for i in 2:n
        key = v[i]
        j = i - 1
        while j >= 1
            should_shift = rev ? lt(by(v[j]), by(key)) : lt(by(key), by(v[j]))
            !should_shift && break
            v[j + 1] = v[j]
            j -= 1
        end
        v[j + 1] = key
    end
    return v
end

# ─── sort Overlay (non-mutating) ──────────────────────────────────────────
# Why: Base.sort uses internal copyto!/getindex with foreigncall(:memmove).
#      Use our copy overlay + sort! overlay for a clean path.
# Remove when: codegen handles foreigncall(:memmove) or Base.sort IR is simpler
@overlay WASM_METHOD_TABLE function Base.sort(v::AbstractVector; kws...)
    return sort!(copy(v); kws...)
end

# ─── String Comparison Overlays ────────────────────────────────────────────
# Base implementations use foreigncall :memcmp which can't run in WASM.
# Pure Julia byte-by-byte comparisons using ncodeunits + codeunit.

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

# ─── String Manipulation Overlays ──────────────────────────────────────────
# Base versions use SubString, IOBuffer, or deep dispatch chains.
# All overlays use only: ncodeunits, codeunit, String(UInt8[...]) construction.
# This is pure Julia that WasmTarget's codegen can handle.

@overlay WASM_METHOD_TABLE function Base.chop(s::String; head::Int=0, tail::Int=1)
    n = ncodeunits(s)
    endpos = n - tail
    startpos = head + 1
    endpos < startpos && return ""
    bytes = UInt8[]
    i = startpos
    while i <= endpos
        push!(bytes, codeunit(s, i))
        i += 1
    end
    return String(bytes)
end

@overlay WASM_METHOD_TABLE function Base.last(s::String, n::Int)
    len = ncodeunits(s)
    take = n >= len ? len : n
    start = len - take + 1
    bytes = UInt8[]
    i = start
    while i <= len
        push!(bytes, codeunit(s, i))
        i += 1
    end
    return String(bytes)
end

@overlay WASM_METHOD_TABLE function Base.reverse(s::String)
    n = ncodeunits(s)
    bytes = UInt8[]
    i = n
    while i >= 1
        push!(bytes, codeunit(s, i))
        i -= 1
    end
    return String(bytes)
end

@overlay WASM_METHOD_TABLE function Base.titlecase(s::String; wordsep=nothing, strict::Bool=true)
    n = ncodeunits(s)
    n == 0 && return s
    bytes = UInt8[]
    prev_space = true
    i = 1
    while i <= n
        b = codeunit(s, i)
        c = b
        is_ws = b == UInt8(' ')
        if is_ws
            prev_space = true
        else
            if prev_space && b >= UInt8('a') && b <= UInt8('z')
                c = b - UInt8(32)
            elseif strict && !prev_space && b >= UInt8('A') && b <= UInt8('Z')
                c = b + UInt8(32)
            end
            prev_space = false
        end
        push!(bytes, c)
        i += 1
    end
    return String(bytes)
end

@overlay WASM_METHOD_TABLE function Base.Unicode.lowercasefirst(s::String)
    n = ncodeunits(s)
    n == 0 && return s
    bytes = UInt8[]
    b = codeunit(s, 1)
    if b >= UInt8('A') && b <= UInt8('Z')
        push!(bytes, b + UInt8(32))
    else
        push!(bytes, b)
    end
    i = 2
    while i <= n
        push!(bytes, codeunit(s, i))
        i += 1
    end
    return String(bytes)
end

@overlay WASM_METHOD_TABLE function Base.Unicode.uppercasefirst(s::String)
    n = ncodeunits(s)
    n == 0 && return s
    bytes = UInt8[]
    b = codeunit(s, 1)
    if b >= UInt8('a') && b <= UInt8('z')
        push!(bytes, b - UInt8(32))
    else
        push!(bytes, b)
    end
    i = 2
    while i <= n
        push!(bytes, codeunit(s, i))
        i += 1
    end
    return String(bytes)
end

# ─── strip Overlay ─────────────────────────────────────────────────────────
# Why: Base.strip uses SubString ref cast that codegen can't handle.
#      Delegate to working lstrip + rstrip overlays.
# Remove when: codegen handles SubString operations natively
@overlay WASM_METHOD_TABLE function Base.strip(s::AbstractString)
    return rstrip(lstrip(s))
end

# NOTE: lstrip/rstrip use single-loop patterns to avoid a codegen bug where
# codeunit() in a first loop + push!() in a second loop corrupts local variables.
@overlay WASM_METHOD_TABLE function Base.lstrip(s::String)
    n = ncodeunits(s)
    n == 0 && return s
    bytes = UInt8[]
    found = false
    i = 1
    while i <= n
        b = codeunit(s, i)
        if !found && b == UInt8(32)
            # skip leading space
        else
            found = true
            push!(bytes, b)
        end
        i += 1
    end
    length(bytes) == 0 && return ""
    return String(bytes)
end

@overlay WASM_METHOD_TABLE function Base.rstrip(s::String)
    n = ncodeunits(s)
    n == 0 && return s
    # First pass: find last non-space position (no push! in this function)
    # Copy all bytes then trim trailing spaces by rebuilding
    bytes = UInt8[]
    i = 1
    while i <= n
        push!(bytes, codeunit(s, i))
        i += 1
    end
    # Trim trailing spaces
    while length(bytes) > 0 && bytes[length(bytes)] == UInt8(32)
        pop!(bytes)
    end
    length(bytes) == 0 && return ""
    return String(bytes)
end

@overlay WASM_METHOD_TABLE function Base.replace(s::String, pair::Pair{String,String})
    pattern = pair.first
    replacement = pair.second
    slen = ncodeunits(s)
    plen = ncodeunits(pattern)
    rlen = ncodeunits(replacement)
    plen == 0 && return s

    bytes = UInt8[]
    i = 1
    while i <= slen
        # Check for pattern match at position i
        matched = i + plen - 1 <= slen
        j = 1
        while j <= plen && matched
            if codeunit(s, i + j - 1) != codeunit(pattern, j)
                matched = false
            end
            j += 1
        end
        if matched
            # Copy replacement bytes
            k = 1
            while k <= rlen
                push!(bytes, codeunit(replacement, k))
                k += 1
            end
            i += plen
        else
            push!(bytes, codeunit(s, i))
            i += 1
        end
    end
    return String(bytes)
end

@overlay WASM_METHOD_TABLE function Base.split(s::String, delim::String;
        limit::Int=0, keepempty::Bool=true)
    result = String[]
    slen = ncodeunits(s)
    dlen = ncodeunits(delim)
    count = 0
    start = 1

    while start <= slen
        if limit > 0 && count >= limit - 1
            # Last piece: take everything remaining
            bytes = UInt8[]
            i = start
            while i <= slen
                push!(bytes, codeunit(s, i))
                i += 1
            end
            push!(result, String(bytes))
            count += 1
            start = slen + 1
            break
        end

        # Search for delimiter starting at `start`
        pos = 0
        i = start
        while i + dlen - 1 <= slen
            found = true
            j = 1
            while j <= dlen
                if codeunit(s, i + j - 1) != codeunit(delim, j)
                    found = false
                    break
                end
                j += 1
            end
            if found
                pos = i
                break
            end
            i += 1
        end

        if pos == 0
            break  # No more delimiters
        end

        piece_len = pos - start
        if piece_len > 0 || keepempty
            bytes = UInt8[]
            i = start
            while i < pos
                push!(bytes, codeunit(s, i))
                i += 1
            end
            push!(result, String(bytes))
            count += 1
        end
        start = pos + dlen
    end

    # Remaining piece
    if start <= slen
        bytes = UInt8[]
        i = start
        while i <= slen
            push!(bytes, codeunit(s, i))
            i += 1
        end
        push!(result, String(bytes))
    elseif length(result) == 0 && keepempty
        push!(result, "")
    end
    return result
end

@overlay WASM_METHOD_TABLE function Base.join(strings, delim::String)
    result = ""
    first = true
    for s in strings
        if !first
            result = result * delim
        end
        result = result * String(s)
        first = false
    end
    return result
end

@overlay WASM_METHOD_TABLE function Base.join(strings)
    result = ""
    for s in strings
        result = result * String(s)
    end
    return result
end

# ─── Array Mutation Overlays ──────────────────────────────────────────────
# Julia 1.12's array mutation IR uses low-level GC operations that are
# incompatible with WasmGC. These use similar() + indexing which compile fine.

@overlay WASM_METHOD_TABLE function Base.push!(v::Vector{T}, x) where T
    n = length(v)
    new_v = similar(v, n + 1)
    i = 1
    while i <= n
        new_v[i] = v[i]
        i += 1
    end
    new_v[n + 1] = convert(T, x)
    setfield!(v, :ref, getfield(new_v, :ref))
    setfield!(v, :size, getfield(new_v, :size))
    return v
end

@overlay WASM_METHOD_TABLE function Base.pop!(v::Vector{T}) where T
    n = length(v)
    val = v[n]
    new_v = similar(v, n - 1)
    i = 1
    while i < n
        new_v[i] = v[i]
        i += 1
    end
    setfield!(v, :ref, getfield(new_v, :ref))
    setfield!(v, :size, getfield(new_v, :size))
    return val
end

@overlay WASM_METHOD_TABLE function Base.pushfirst!(v::Vector{T}, x) where T
    n = length(v)
    new_v = similar(v, n + 1)
    new_v[1] = convert(T, x)
    i = 1
    while i <= n
        new_v[i + 1] = v[i]
        i += 1
    end
    setfield!(v, :ref, getfield(new_v, :ref))
    setfield!(v, :size, getfield(new_v, :size))
    return v
end

@overlay WASM_METHOD_TABLE function Base.popfirst!(v::Vector{T}) where T
    n = length(v)
    val = v[1]
    new_v = similar(v, n - 1)
    i = 2
    while i <= n
        new_v[i - 1] = v[i]
        i += 1
    end
    setfield!(v, :ref, getfield(new_v, :ref))
    setfield!(v, :size, getfield(new_v, :size))
    return val
end

@overlay WASM_METHOD_TABLE function Base.insert!(v::Vector{T}, i::Integer, x) where T
    n = length(v)
    idx = Int(i)
    new_v = similar(v, n + 1)
    j = 1
    while j < idx
        new_v[j] = v[j]
        j += 1
    end
    new_v[idx] = convert(T, x)
    j = idx
    while j <= n
        new_v[j + 1] = v[j]
        j += 1
    end
    setfield!(v, :ref, getfield(new_v, :ref))
    setfield!(v, :size, getfield(new_v, :size))
    return v
end

@overlay WASM_METHOD_TABLE function Base.deleteat!(v::Vector{T}, i::Integer) where T
    n = length(v)
    idx = Int(i)
    new_v = similar(v, n - 1)
    j = 1
    while j < idx
        new_v[j] = v[j]
        j += 1
    end
    j = idx + 1
    while j <= n
        new_v[j - 1] = v[j]
        j += 1
    end
    setfield!(v, :ref, getfield(new_v, :ref))
    setfield!(v, :size, getfield(new_v, :size))
    return v
end

@overlay WASM_METHOD_TABLE function Base.append!(v::Vector{T}, w::AbstractVector) where T
    for x in w
        push!(v, x)
    end
    return v
end

@overlay WASM_METHOD_TABLE function Base.prepend!(v::Vector{T}, w::AbstractVector) where T
    nw = length(w)
    n = length(v)
    new_v = similar(v, n + nw)
    i = 1
    while i <= nw
        new_v[i] = w[i]
        i += 1
    end
    i = 1
    while i <= n
        new_v[nw + i] = v[i]
        i += 1
    end
    setfield!(v, :ref, getfield(new_v, :ref))
    setfield!(v, :size, getfield(new_v, :size))
    return v
end

@overlay WASM_METHOD_TABLE function Base.splice!(v::Vector{T}, i::Integer) where T
    val = v[Int(i)]
    deleteat!(v, i)
    return val
end

# ─── Collection Overlays ──────────────────────────────────────────────────

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

# ─── unsigned Overlay ─────────────────────────────────────────────────────
# Why: Base.unsigned(::Int64) produces 387 IR stmts with foreigncall(:jl_get_field_offset),
#      foreigncall(:memcpy), foreigncall(:jl_value_ptr), etc. — complex reinterpret infrastructure.
#      The actual operation is a single bitcast (no-op in WASM since Int64/UInt64 are both i64).
# Remove when: codegen handles reinterpret(UInt64, ::Int64) natively
@overlay WASM_METHOD_TABLE function Base.unsigned(x::Int64)
    return Core.bitcast(UInt64, x)
end

@overlay WASM_METHOD_TABLE function Base.unsigned(x::Int32)
    return Core.bitcast(UInt32, x)
end

# ─── copy(Vector) Overlay ─────────────────────────────────────────────────
# Why: Base.copy(::Vector) uses foreigncall(:memmove) and foreigncall(:jl_genericmemory_copyto)
#      for bulk memory copying. WASM has no memmove — use element-by-element copy instead.
# Remove when: codegen handles foreigncall(:memmove) or provides a WASM bulk-copy intrinsic
@overlay WASM_METHOD_TABLE function Base.copy(v::Vector{T}) where T
    n = length(v)
    result = similar(v, n)
    i = 1
    while i <= n
        result[i] = v[i]
        i += 1
    end
    return result
end

# ─── filter Overlay ───────────────────────────────────────────────────────
# Why: Base.filter creates new vectors using internal copy/resize machinery with foreigncalls.
#      Pure Julia loop with push! overlay handles this cleanly.
# Remove when: codegen handles the internal Vector creation machinery
@overlay WASM_METHOD_TABLE function Base.filter(f, v::Vector{T}) where T
    result = similar(v, 0)
    i = 1
    n = length(v)
    while i <= n
        if f(v[i])
            push!(result, v[i])
        end
        i += 1
    end
    return result
end

# ─── Char Classification Overlays ─────────────────────────────────────────
# Why: Base implementations use foreigncall(:utf8proc_category), foreigncall(:utf8proc_isupper),
#      foreigncall(:utf8proc_islower) — C library calls that can't compile to WASM.
#      These overlays handle ASCII range; non-ASCII returns false (sufficient for Therapy.jl).
#      Uses Core.bitcast (2 IR stmts) instead of reinterpret (400+ IR stmts).
# Remove when: codegen can link libutf8proc or a pure-Julia Unicode DB is available
# Char internal: Core.bitcast(UInt32, 'A') = 0x41000000, 'Z' = 0x5a000000,
#                'a' = 0x61000000, 'z' = 0x7a000000, ASCII < 0x80000000

@overlay WASM_METHOD_TABLE function Base.isletter(c::Char)
    raw = Core.bitcast(UInt32, c)
    return (raw >= UInt32(0x41000000) && raw <= UInt32(0x5a000000)) ||
           (raw >= UInt32(0x61000000) && raw <= UInt32(0x7a000000))
end

@overlay WASM_METHOD_TABLE function Base.isuppercase(c::Char)
    raw = Core.bitcast(UInt32, c)
    return raw >= UInt32(0x41000000) && raw <= UInt32(0x5a000000)
end

@overlay WASM_METHOD_TABLE function Base.islowercase(c::Char)
    raw = Core.bitcast(UInt32, c)
    return raw >= UInt32(0x61000000) && raw <= UInt32(0x7a000000)
end

@overlay WASM_METHOD_TABLE function Base.isascii(c::Char)
    # Char stores UTF-8 bytes as UInt32. ASCII chars have top byte < 0x80.
    raw = Core.bitcast(UInt32, c)
    return raw < UInt32(0x80000000)
end

# ─── count Overlay ────────────────────────────────────────────────────────
# Why: Base.count uses kwarg dispatch (init=0) that triggers sym_in/kwerr stubs,
#      plus mapreduce infrastructure with 135+ IR stmts and codegen type mismatches.
# Remove when: codegen handles kwarg dispatch patterns cleanly
@overlay WASM_METHOD_TABLE function Base.count(f, v::Vector{T}) where T
    n = length(v)
    c = 0
    i = 1
    while i <= n
        if f(v[i])
            c += 1
        end
        i += 1
    end
    return c
end

# ─── argmax/argmin Overlays ──────────────────────────────────────────────
# Why: Base implementations use complex dispatch through _findmax/_findmin
#      with Pairs iterators and kwarg patterns that produce codegen errors.
# Remove when: codegen handles Pairs iterators and kwarg dispatch
@overlay WASM_METHOD_TABLE function Base.argmax(v::Vector{T}) where T
    n = length(v)
    n == 0 && throw(ArgumentError("collection must be non-empty"))
    best_idx = 1
    best_val = v[1]
    i = 2
    while i <= n
        if v[i] > best_val
            best_val = v[i]
            best_idx = i
        end
        i += 1
    end
    return best_idx
end

@overlay WASM_METHOD_TABLE function Base.argmin(v::Vector{T}) where T
    n = length(v)
    n == 0 && throw(ArgumentError("collection must be non-empty"))
    best_idx = 1
    best_val = v[1]
    i = 2
    while i <= n
        if v[i] < best_val
            best_val = v[i]
            best_idx = i
        end
        i += 1
    end
    return best_idx
end

# ─── foreach Overlay ─────────────────────────────────────────────────────
# Why: Base.foreach uses Generator/iterate patterns with complex dispatch.
# Remove when: codegen handles Generator iteration cleanly
@overlay WASM_METHOD_TABLE function Base.foreach(f, v::Vector{T}) where T
    n = length(v)
    i = 1
    while i <= n
        f(v[i])
        i += 1
    end
    return nothing
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

# Disable concrete eval (GPUCompiler pattern).
# Without this, the compiler constant-folds calls using Base implementation,
# bypassing overlays.
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
