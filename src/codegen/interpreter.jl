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
using Base.Experimental: @overlay

# ─── Method Table ───────────────────────────────────────────────────────────

Base.Experimental.@MethodTable(WASM_METHOD_TABLE)

"""Flat source-level type for runtime-length function composition."""
struct _RuntimeComposition{V<:AbstractVector} <: Function
    fs::V
end

@noinline function _runtime_composition_apply(fs::AbstractVector, i::Int, x)
    i == 0 && return x
    return _runtime_composition_apply(fs, i - 1, fs[i](x))
end

@noinline function (c::_RuntimeComposition)(x)
    isempty(c.fs) && throw(MethodError(∘, ()))
    return _runtime_composition_apply(c.fs, length(c.fs), x)
end

# ─── Dict literal-constructor Overlay ───────────────────────────────────────
# Why: Dict{K,V}(::Tuple{Pair...}) (the `Dict(k=>v, …)` literal) is mis-compiled as
#      a fieldwise struct.new from the tuple argument (Dict is a hash table, not a
#      simple struct) → emits invalid wasm (ref where i64 expected). Empty
#      Dict{K,V}() + setindex! IS supported, so build the Dict via that path.
# Remove when: codegen compiles the real Dict tuple-constructor body.
@overlay WASM_METHOD_TABLE function (::Type{Dict{K,V}})(kv::Tuple) where {K,V}
    d = Dict{K,V}()
    for p in kv
        d[p.first] = p.second
    end
    return d
end

# ─── hvcat Overlay (Tuple-element matrices) ─────────────────────────────────
# A 2-D matrix literal of TUPLE elements — e.g. WasmMakie's RGBA image data
# `[(r,g,b,a) (r,g,b,a); …]` — lowers to `Base.hvcat((nc,nc,…), tup, tup, …)`,
# which routes through `Base._typed_hvncat_dims` (1000+ stmts). WT stubs that to
# `unreachable` (and whitelisting it sends discovery into a recursive-type
# StackOverflow), so the matrix traps at runtime (gap a9bf645b1003, WASMMAKIE
# W-005). The known-working path is `Matrix{T}(undef, m, n)` + element stores;
# this overlay reconstructs the rectangular matrix that way. Scoped to
# `values::T... where T<:Tuple` so numeric hvcat (already working) is untouched.
# Ragged row specs (which native rejects) throw here too → parity, never a wrong
# shape. Remove when codegen handles `_typed_hvncat` without the StackOverflow.
@overlay WASM_METHOD_TABLE function Base.hvcat(rows::Tuple{Vararg{Int}}, values::T...) where {T<:Tuple}
    nc = rows[1]
    for r in rows
        r == nc || throw(ArgumentError("hvcat: row lengths must be uniform"))
    end
    n = length(values)
    nr = n ÷ nc
    m = Matrix{T}(undef, nr, nc)
    k = 1
    for i in 1:nr
        for j in 1:nc
            m[i, j] = values[k]
            k += 1
        end
    end
    return m
end

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

# `partialsort!` permits arbitrary permutation of its input outside the selected
# indices. A full stable sort is therefore an exact (if less asymptotically
# selective) implementation and stays on the same pure-Julia array path.
@overlay WASM_METHOD_TABLE function Base.partialsort!(v::AbstractVector, k;
        lt=isless, by=identity, rev::Bool=false,
        order::Base.Order.Ordering=Base.Order.Forward)
    sort!(v; lt=lt, by=by, rev=rev, order=order)
    return v[k]
end

# ─── sort Overlay (non-mutating) ──────────────────────────────────────────
# Why: Base.sort uses internal copyto!/getindex with foreigncall(:memmove).
#      Use our copy overlay + sort! overlay for a clean path.
#      Kwargs forwarded to sort! — the kwarg dispatch machinery
#      (_apply_iterate(iterate, Core.tuple, vec) + isa(result, Tuple{}))
#      is handled by the compiler's _apply_iterate handler (Core.tuple case).
# Remove when: codegen handles foreigncall(:memmove) or Base.sort IR is simpler
@overlay WASM_METHOD_TABLE function Base.sort(v::AbstractVector;
        lt=isless, by=identity, rev::Bool=false,
        alg::Base.Sort.Algorithm=Base.Sort.InsertionSort,
        order::Base.Order.Ordering=Base.Order.Forward)
    result = copy(v)
    # SILENT-WRONG FIX: forward ALL comparator kwargs to sort!, not just `rev` — the
    # previous `sort!(result, rev=rev)` silently dropped `by`/`lt`/`order`, so
    # `sort(v, by=f)` / `sort(v, lt=cmp)` returned the DEFAULT-`isless` order (the
    # sort! overlay's body already honors lt/by/rev correctly).
    sort!(result; lt=lt, by=by, rev=rev, alg=alg, order=order)
    return result
end

# ─── sortperm Overlay ──────────────────────────────────────────────────────
# Why: generic Base.sortperm dispatches through deep Ordering/algorithm chains that WT
#      mis-compiled to a no-op → it returned the IDENTITY permutation (silent-wrong),
#      and loud-rejected with kwargs. Stable insertion sort on the index vector, comparing
#      by v[index], mirroring the sort! overlay. Strict `lt` only → stable (ties keep order).
@overlay WASM_METHOD_TABLE function Base.sortperm(v::AbstractVector;
        lt=isless, by=identity, rev::Bool=false,
        alg::Base.Sort.Algorithm=Base.Sort.InsertionSort,
        order::Base.Order.Ordering=Base.Order.Forward)
    n = length(v)
    p = collect(1:n)
    for i in 2:n
        key = p[i]
        j = i - 1
        while j >= 1
            should_shift = rev ? lt(by(v[p[j]]), by(v[key])) : lt(by(v[key]), by(v[p[j]]))
            !should_shift && break
            p[j + 1] = p[j]
            j -= 1
        end
        p[j + 1] = key
    end
    return p
end

# ─── String Concatenation Overlays ────────────────────────────────────────
# Why: Base.*(::String, ::String) calls string() which uses print_to_string/IOBuffer
#      with deep dispatch chains and foreigncalls. Pure Julia byte-copy works in WASM.
# Remove when: codegen handles IOBuffer-based string construction

@noinline @overlay WASM_METHOD_TABLE function Base.:*(a::String, b::String)
    al = ncodeunits(a)
    bl = ncodeunits(b)
    bytes = UInt8[]
    i = 1
    while i <= al
        push!(bytes, codeunit(a, i))
        i += 1
    end
    i = 1
    while i <= bl
        push!(bytes, codeunit(b, i))
        i += 1
    end
    return String(bytes)
end

@noinline @overlay WASM_METHOD_TABLE function Base.:*(a::String, b::String, c::String)
    return (a * b) * c
end

# ─── string(::Complex) Overlay ─────────────────────────────────────────────
# Why: string(z::Complex) routes through show(io::IOBuffer, ::Complex), i.e. the
#      general Base IOBuffer string-building machinery (ensureroom growth +
#      jl_string_ptr/jl_string_to_genericmemory memmove + take!) that WT does not
#      implement — empty IOBuffer() yields a null .data array → trap. (gap
#      cfd419793b0d, Snapshot.jl fractal labels like "0.9 + 0.4im".)
# How:  byte-assemble the result directly, reusing string(::Real) for the parts
#      (which WT supports via the Ryu/StringVector overlays). The wrapper logic
#      mirrors Base.show(io, ::Complex) EXACTLY (sign on imag, " + "/" - ", the
#      "*" separator for non-finite/non-Integer imag, "im" suffix) so the
#      differential oracle agrees. Non-compact form (what string() produces).
# Remove when: codegen handles Base IOBuffer string construction.
@noinline @overlay WASM_METHOD_TABLE function Base.string(z::Complex)
    r = real(z)
    i = imag(z)
    rs = string(r)
    neg = signbit(i) && !isnan(i)
    ia = neg ? -i : i
    is = string(ia)
    # Base appends "*" unless imag is a non-Bool Integer or a finite AbstractFloat.
    star = !((isa(i, Integer) && !isa(i, Bool)) || (isa(i, AbstractFloat) && isfinite(i)))
    bytes = UInt8[]
    k = 1
    nr = ncodeunits(rs)
    while k <= nr
        push!(bytes, codeunit(rs, k))
        k += 1
    end
    push!(bytes, UInt8(' '))
    push!(bytes, neg ? UInt8('-') : UInt8('+'))
    push!(bytes, UInt8(' '))
    k = 1
    ni = ncodeunits(is)
    while k <= ni
        push!(bytes, codeunit(is, k))
        k += 1
    end
    if star
        push!(bytes, UInt8('*'))
    end
    push!(bytes, UInt8('i'))
    push!(bytes, UInt8('m'))
    return String(bytes)
end

# Why: `string(::Vector{Int64})` (and `_plain_body(v)=string(v)` in PI island
#      cells, e.g. convolution_1d `treatment_in = [a1_s, …]`) goes through Base's
#      array-show → IOBuffer machinery, which WT can't codegen → trap "unreachable".
# How: byte-assemble the one-line array repr `[e1, e2, …]`, reusing string(::Int64)
#      (line ~1643) for each element — bit-exact with `show(io, ::Vector{Int64})`.
#      Scoped to the DEFAULT eltype (Int64): a `Vector{Int64}` shows WITHOUT the
#      `Int64[…]` type prefix that non-default eltypes (Int32, Bool) get, so a bare
#      element `string` is correct here and would be WRONG for those. The empty
#      vector is the one exception — Base shows `Int64[]` — handled explicitly.
# Remove when: codegen handles Base IOBuffer / array-show string construction (#39).
@noinline @overlay WASM_METHOD_TABLE function Base.string(v::Vector{Int64})
    n = length(v)
    bytes = UInt8[]
    if n == 0
        # empty array shows with the eltype prefix: `Int64[]`
        for c in (UInt8('I'), UInt8('n'), UInt8('t'), UInt8('6'), UInt8('4'),
                  UInt8('['), UInt8(']'))
            push!(bytes, c)
        end
        return String(bytes)
    end
    push!(bytes, UInt8('['))
    i = 1
    while i <= n
        es = string(v[i])
        m = ncodeunits(es)
        k = 1
        while k <= m
            push!(bytes, codeunit(es, k))
            k += 1
        end
        if i < n
            push!(bytes, UInt8(','))
            push!(bytes, UInt8(' '))
        end
        i += 1
    end
    push!(bytes, UInt8(']'))
    return String(bytes)
end

# Why: same array-show trap for `string(::Vector{Float64})` (PI numeric island cells
#      that display a vector of measurements/features, e.g. EEG band powers).
# How: byte-assemble `[e1, e2, …]` reusing string(::Float64) (Ryu) per element —
#      bit-exact with show(io, ::Vector{Float64}). Float64 is the default float
#      eltype → no `Float64[…]` prefix for non-empty; empty shows `Float64[]`.
@noinline @overlay WASM_METHOD_TABLE function Base.string(v::Vector{Float64})
    n = length(v)
    bytes = UInt8[]
    if n == 0
        for c in (UInt8('F'), UInt8('l'), UInt8('o'), UInt8('a'), UInt8('t'),
                  UInt8('6'), UInt8('4'), UInt8('['), UInt8(']'))
            push!(bytes, c)
        end
        return String(bytes)
    end
    push!(bytes, UInt8('['))
    i = 1
    while i <= n
        es = string(v[i])
        m = ncodeunits(es)
        k = 1
        while k <= m
            push!(bytes, codeunit(es, k))
            k += 1
        end
        if i < n
            push!(bytes, UInt8(','))
            push!(bytes, UInt8(' '))
        end
        i += 1
    end
    push!(bytes, UInt8(']'))
    return String(bytes)
end

# Why: `string(::Vector{String})` (PI dither island shows its colour palette via
#      `_plain_body(colorscheme)`) hits the same array-show trap.
# How: byte-assemble `["e1", "e2", …]`, quoting each element as show(io, ::String)
#      does — escape `"`, `\`, `$`. SOUND-OR-TRAP: show keeps non-ASCII printable
#      bytes verbatim but escapes non-printable ones via `\uXXXX`, which needs
#      Unicode printability tables WT lacks. Rather than risk silently-wrong bytes,
#      this is bit-exact for printable-ASCII elements (0x20–0x7e, the dither hex
#      colours) and TRAPS loudly on any control/≥0x80 byte. Empty ⇒ `String[]`.
# Remove when: codegen handles Base IOBuffer / Unicode-aware escape_string (#39).
@noinline @overlay WASM_METHOD_TABLE function Base.string(v::Vector{String})
    n = length(v)
    bytes = UInt8[]
    if n == 0
        for c in (UInt8('S'), UInt8('t'), UInt8('r'), UInt8('i'), UInt8('n'),
                  UInt8('g'), UInt8('['), UInt8(']'))
            push!(bytes, c)
        end
        return String(bytes)
    end
    push!(bytes, UInt8('['))
    i = 1
    while i <= n
        s = v[i]
        push!(bytes, UInt8('"'))
        m = ncodeunits(s)
        k = 1
        while k <= m
            b = codeunit(s, k)
            if b < 0x20 || b > 0x7e
                # control or non-ASCII: needs escape_string's Unicode-aware logic
                error("string(::Vector{String}): non-printable-ASCII element unsupported")
            end
            if b == UInt8('"') || b == UInt8('\\') || b == UInt8('$')
                push!(bytes, UInt8('\\'))
            end
            push!(bytes, b)
            k += 1
        end
        push!(bytes, UInt8('"'))
        if i < n
            push!(bytes, UInt8(','))
            push!(bytes, UInt8(' '))
        end
        i += 1
    end
    push!(bytes, UInt8(']'))
    return String(bytes)
end

# Why: `string(nothing)` / `_plain_body(nothing)` routes through Base's `print`/
#      `show(::Nothing)` → IOBuffer, trapping (null deref) in WT. (PI PlutoUI island.)
# How: it's the constant "nothing"; return it directly.
@overlay WASM_METHOD_TABLE function Base.string(::Nothing)
    return "nothing"
end

# Why: `collect(::Vector{T})` for a REFERENCE element type (String, …) routes through
#      similar + copyto!, whose Memory allocation null-derefs in WT (the String-array
#      null-Memory class); isbits eltypes (Int, Float) are fine. `collect` of a Vector
#      is just a shallow copy, and WT's element-by-element `copy` overlay works for ALL
#      eltypes. (PI convolution_1d `collect([emoji…])`.)
# How: route to copy. Only matches an explicit collect of a concrete Vector — generator
#      comprehensions lower to collect(::Generator), unaffected.
@overlay WASM_METHOD_TABLE function Base.collect(v::Vector{T}) where {T}
    return copy(v)
end

# Why: `v[a:b]` on a Vector{String} (and other ref-element vectors) routes through
#      similar + copyto!, hitting the same null-Memory bug → null-deref trap. (PI
#      convolution_1d `(collect([…]))[1:len]`.) isbits-eltype slices use the working
#      array path and are left untouched (this overlay is String-scoped).
# How: build the slice element-by-element via push! (a verified-working path for
#      String vectors). An out-of-range index traps on the element read, matching
#      Base's BoundsError (the differential oracle treats a native throw as a trap).
@overlay WASM_METHOD_TABLE function Base.getindex(v::Vector{String}, r::UnitRange{Int})
    out = String[]
    i = first(r)
    stop = last(r)
    while i <= stop
        push!(out, v[i])
        i += 1
    end
    return out
end

# ─── String Comparison Overlays ────────────────────────────────────────────
# Base implementations use foreigncall :memcmp which can't run in WASM.
# Pure Julia byte-by-byte comparisons using ncodeunits + codeunit.

# Typed `AbstractString` (not just `String`) so SubString operands work too — e.g.
# `startswith(s, chomp(t))`, where chomp returns a SubString. `codeunit`/`ncodeunits`
# both compile for SubString, but `String(::SubString)` traps (memmove), so we must
# byte-compare in place rather than materialize. Byte prefix == UTF-8 prefix.
@overlay WASM_METHOD_TABLE function Base.startswith(a::AbstractString, b::AbstractString)
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

@overlay WASM_METHOD_TABLE function Base.endswith(a::AbstractString, b::AbstractString)
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
    # Reverse by CHARACTER, not byte: a naive byte-reverse splits multi-byte UTF-8
    # codepoints (e.g. the 2-byte 'é'), producing invalid strings whose char count
    # then differs from the input. Walk from the end; for each char, skip its
    # continuation bytes (0b10xxxxxx) back to the start byte, then emit that char's
    # bytes in FORWARD order.
    n = ncodeunits(s)
    bytes = UInt8[]
    i = n
    while i >= 1
        j = i
        while j >= 1 && (codeunit(s, j) & 0xc0) == 0x80
            j -= 1
        end
        k = j
        while k <= i
            push!(bytes, codeunit(s, k))
            k += 1
        end
        i = j - 1
    end
    return String(bytes)
end

# NOTE: `uppercase`/`lowercase`(::SubString) is NOT overlaid. The natural overlay
# (byte-loop reading codeunit(s,i) from the SubString into a fresh String) compiles
# but is SILENTLY WRONG: `codeunit(::SubString)` reads return 0 inside this
# nested-build context (length comes out right, bytes come out zero) — the same
# SubString/String(bytes) codegen class the strip overlays contort around. A loud
# compile error (gap 05bc422e7ffb) is better than silently-wrong content; the real
# fix needs that underlying codegen bug. Triaged for Part 2 with the strip gaps.

@noinline function _wasm_titlecase_impl(s::String, strict::Bool)
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

@overlay WASM_METHOD_TABLE function Base.titlecase(s::String; wordsep=nothing, strict::Bool=true)
    return _wasm_titlecase_impl(s, strict)
end

@noinline function _wasm_lowercasefirst_impl(s::String)
    n = ncodeunits(s)
    n == 0 && return s
    bytes = UInt8[]
    b = codeunit(s, 1)
    # Branchless: codegen bug corrupts push! result when if/else precedes a while loop
    is_upper = (b >= UInt8('A')) & (b <= UInt8('Z'))
    push!(bytes, b + UInt8(32) * UInt8(is_upper))
    i = 2
    while i <= n
        push!(bytes, codeunit(s, i))
        i += 1
    end
    return String(bytes)
end

@overlay WASM_METHOD_TABLE function Base.Unicode.lowercasefirst(s::String)
    return _wasm_lowercasefirst_impl(s)
end

@noinline function _wasm_uppercasefirst_impl(s::String)
    n = ncodeunits(s)
    n == 0 && return s
    bytes = UInt8[]
    b = codeunit(s, 1)
    # Branchless: codegen bug corrupts push! result when if/else precedes a while loop
    is_lower = (b >= UInt8('a')) & (b <= UInt8('z'))
    push!(bytes, b - UInt8(32) * UInt8(is_lower))
    i = 2
    while i <= n
        push!(bytes, codeunit(s, i))
        i += 1
    end
    return String(bytes)
end

@overlay WASM_METHOD_TABLE function Base.Unicode.uppercasefirst(s::String)
    return _wasm_uppercasefirst_impl(s)
end

# ─── strip Overlay ─────────────────────────────────────────────────────────
# Why: Base.strip uses SubString ref cast that codegen can't handle.
#      Delegate to working lstrip + rstrip overlays.
# Remove when: codegen stackifier handles inlined lstrip+rstrip (526 stmts)
# Using @noinline to prevent Julia from inlining lstrip/rstrip into strip,
# keeping each function's IR small enough for the stackifier.
@overlay WASM_METHOD_TABLE function Base.strip(s::AbstractString)
    return @noinline rstrip(@noinline lstrip(s))
end

# NOTE: Two-pass approach avoids codegen bug where `===` comparison combined with
# push! in a loop produces wrong results. Pass 1 finds the boundary index, Pass 2
# does an unconditional copy.
# P2-batch7: scan/copy bounds are BYTE counts — these loops index codeunits, and
# the old `length(s)` bound (char count) truncated multibyte strings
# (strip("héllo") dropped the last byte → gap 0beb5ec969a2 family). The
# ncodeunits-on-String(bytes) aliasing bug that originally forced length() here
# no longer reproduces (probed: ncodeunits is correct on built strings).
# Handles space (0x20), tab (0x09), newline (0x0a), CR (0x0d), VT (0x0b), FF (0x0c)
@noinline @overlay WASM_METHOD_TABLE function Base.lstrip(s::String)
    n = length(s)
    n == 0 && return s
    # Pass 1: find first non-whitespace byte index. Leading whitespace is ASCII
    # (1 char == 1 byte), so the char-count bound is always >= the prefix length
    # — and length(s) here keeps the loop in the exact shape that compiles
    # correctly (this overlay is knife-edge sensitive: swapping the SCAN bound
    # to sizeof/ncodeunits miscompiles in dependency context — see NOTE above).
    start = 1
    while start <= n
        bi = Int64(codeunit(s, start))
        # Use Int64 != comparisons (avoids UInt8 === codegen bug)
        if bi != Int64(0x20) && bi != Int64(0x09) && bi != Int64(0x0a) && bi != Int64(0x0d) && bi != Int64(0x0b) && bi != Int64(0x0c)
            break
        end
        start += 1
    end
    start > n && return ""
    # Pass 2: unconditional copy from start to the LAST BYTE. P2-batch7: the
    # copy bound must be the byte count — the old length(s) bound truncated
    # multibyte strings (strip("héllo") dropped a byte, gap 0beb5ec969a2).
    nb = sizeof(s)
    bytes = UInt8[]
    i = start
    while i <= nb
        push!(bytes, codeunit(s, i))
        i += 1
    end
    return String(bytes)
end

@noinline @overlay WASM_METHOD_TABLE function Base.rstrip(s::String)
    n = sizeof(s)   # P2-batch7: BYTE count — backward scan starts at the last
    # byte; UTF-8 continuation bytes (0x80-0xBF) never match ASCII whitespace,
    # so byte-wise scanning is multibyte-safe. (The old length(s) bound started
    # the scan mid-string for multibyte inputs and truncated the result.)
    n == 0 && return s
    # Scan backward from end to find last non-whitespace
    last_nws = n
    while last_nws >= 1
        bi = Int64(codeunit(s, last_nws))
        if bi != Int64(0x20) && bi != Int64(0x09) && bi != Int64(0x0a) && bi != Int64(0x0d) && bi != Int64(0x0b) && bi != Int64(0x0c)
            break
        end
        last_nws -= 1
    end
    last_nws < 1 && return ""
    last_nws == n && return s
    # Copy 1..last_nws (single loop, no dependency on previous loop variable)
    bytes = UInt8[]
    i = 1
    while i <= last_nws
        push!(bytes, codeunit(s, i))
        i += 1
    end
    return String(bytes)
end

# ─── Ryu scalar writeshortest Overlay (string(::Float64/Float32)) ─────────
# Why: the digit-generation kernel writeshortest(buf, pos, x, ...) compiles
#      fine, but the scalar wrapper that string(x::AbstractFloat) calls steals
#      its buffer via String(resize!(buf, ...)) → atomic_pointerset, which
#      codegen stubs → every string(::Float64) trapped (gap 5741ab865252
#      family: string(0.0) in Set/Dict/length). Same kernel, but materialize
#      the result through the String(bytes) path every other overlay uses.
# Remove when: codegen handles the unsafe_takestring / atomic_pointerset
#      buffer-steal idiom.
@noinline @overlay WASM_METHOD_TABLE function Base.Ryu.writeshortest(x::T) where {T <: Union{Float32, Float64}}
    # Explicit 1-arg method (no default-arg expansion: @overlay does not put the
    # generated wrapper arities in the overlay table, so a defaulted definition
    # never shadowed Base's 1-arg call from string()).
    cap = Base.Ryu.neededdigits(T)
    buf = UInt8[]
    i = 0
    while i < cap
        push!(buf, 0x00)
        i += 1
    end
    pos = Base.Ryu.writeshortest(buf, 1, x, false, false, true, -1,
                                 UInt8('e'), false, UInt8('.'), false, false)
    out = UInt8[]
    i = 1
    while i < pos
        push!(out, buf[i])
        i += 1
    end
    return String(out)
end

# ─── string(::Float64/Float32) Overlay ─────────────────────────────────────
# Why: Base.string(x::IEEEFloat) (Ryu.jl:122) does NOT route through the
#      scalar writeshortest wrapper — the StringVector + buffer-steal
#      (String(resize!(buf, ...)) → atomic_pointerset) lives INLINE in its own
#      body, which codegen stubs → unreachable trap (gap 5741ab865252 family).
#      Same Ryu kernel, result materialized through the String(bytes) path
#      the other overlays use.
@noinline @overlay WASM_METHOD_TABLE function Base.string(x::T) where {T <: Union{Float32, Float64}}
    cap = Base.Ryu.neededdigits(T)
    buf = UInt8[]
    i = 0
    while i < cap
        push!(buf, 0x00)
        i += 1
    end
    pos = Base.Ryu.writeshortest(buf, 1, x, false, false, true, -1,
                                 UInt8('e'), false, UInt8('.'), false, false)
    out = UInt8[]
    i = 1
    while i < pos
        push!(out, buf[i])
        i += 1
    end
    return String(out)
end

# ─── Ryu scalar writefixed/writeexp Overlays (WASMMAKIE W-004) ────────────
# Why: same buffer-steal idiom as writeshortest — the scalar wrappers build a
#      StringVector and materialize via String(resize!(buf, ...)) →
#      atomic_pointerset, which codegen stubs → unreachable trap. The digit
#      kernels writefixed(buf, pos, x, precision, ...) compile fine. Same
#      treatment: push!-built buffer + String(bytes) materialization.
#      (Consumers: tick-label formatting — Makie tick_format / Showoff.)
# Remove when: codegen handles the unsafe_takestring buffer-steal idiom.
@noinline @overlay WASM_METHOD_TABLE function Base.Ryu.writefixed(x::T, precision::Integer) where {T <: Union{Float32, Float64}}
    cap = precision + Base.Ryu.neededdigits(T)
    buf = UInt8[]
    i = 0
    while i < cap
        push!(buf, 0x00)
        i += 1
    end
    pos = Base.Ryu.writefixed(buf, 1, x, precision, false, false, false,
                              UInt8('.'), false)
    out = UInt8[]
    i = 1
    while i < pos
        push!(out, buf[i])
        i += 1
    end
    return String(out)
end

@noinline @overlay WASM_METHOD_TABLE function Base.Ryu.writeexp(x::T, precision::Integer) where {T <: Union{Float32, Float64}}
    cap = precision + Base.Ryu.neededdigits(T)
    buf = UInt8[]
    i = 0
    while i < cap
        push!(buf, 0x00)
        i += 1
    end
    pos = Base.Ryu.writeexp(buf, 1, x, precision, false, false, false,
                            UInt8('e'), UInt8('.'), false)
    out = UInt8[]
    i = 1
    while i < pos
        push!(out, buf[i])
        i += 1
    end
    return String(out)
end

# ─── reinterpret Overlay (P2-batch20) ─────────────────────────────────────
# Why: Base.reinterpret between primitive bits types inlines to ~390 stmts of
#      generic bit-checking machinery (padding checks, _foldl_impl, LazyString
#      error paths) that miscompiles (gap e817213d1890). For same-size
#      primitives it is exactly Core.bitcast, which the wasm backend lowers to
#      i32/i64.reinterpret_f32/f64 or a no-op.
# Remove when: the generic Base.reinterpret path compiles clean.
const _WT_BITS32 = Union{Int32, UInt32, Float32, Char}
const _WT_BITS64 = Union{Int64, UInt64, Float64}
const _WT_BITS16 = Union{Int16, UInt16}
const _WT_BITS8  = Union{Int8, UInt8, Bool}
@overlay WASM_METHOD_TABLE function Base.reinterpret(::Type{Out}, x::_WT_BITS32) where {Out<:_WT_BITS32}
    Core.bitcast(Out, x)
end
@overlay WASM_METHOD_TABLE function Base.reinterpret(::Type{Out}, x::_WT_BITS64) where {Out<:_WT_BITS64}
    Core.bitcast(Out, x)
end
@overlay WASM_METHOD_TABLE function Base.reinterpret(::Type{Out}, x::_WT_BITS16) where {Out<:_WT_BITS16}
    Core.bitcast(Out, x)
end
@overlay WASM_METHOD_TABLE function Base.reinterpret(::Type{Out}, x::_WT_BITS8) where {Out<:_WT_BITS8}
    Core.bitcast(Out, x)
end

# Same-size, padding-free ReinterpretArray elements are the parent's bits with a
# primitive reinterpret. Julia's generic implementation probes GC object headers
# through pointer_from_objref; WasmGC has no such header ABI, while this valid-Julia
# definition states the representation-independent semantics directly.
@overlay WASM_METHOD_TABLE function Base.getindex(
        a::Base.ReinterpretArray{T,N,S,A,false}, i::Int) where {T,N,S,A}
    return reinterpret(T, getindex(parent(a), i))
end
@overlay WASM_METHOD_TABLE function Base.setindex!(
        a::Base.ReinterpretArray{T,N,S,A,false}, value, i::Int) where {T,N,S,A}
    converted = convert(T, value)
    setindex!(parent(a), reinterpret(S, converted), i)
    return value
end

# ─── show typeinfo overlay ────────────────────────────────────────────────

# Julia's native implementation walks mutable BindingPartition history. Keep
# the native meaning for ordinary Julia execution, but preserve one non-inlined
# semantic boundary for WT inference so codegen can read the immutable result
# captured in its TypeName metadata. This is analogous to dart2wasm retaining a
# recognized runtime operation instead of inlining VM implementation details.
@noinline function _closed_world_type_bounds(tn::Core.TypeName)
    binding = ccall(:jl_get_module_binding, Ref{Core.Binding},
                    (Any, Any, Cint), tn.module, tn.name, true)
    isdefined(binding, :partitions) || return nothing
    partition = @atomic binding.partitions
    while true
        if Base.is_defined_const_binding(Base.binding_kind(partition))
            value = Base.partition_restriction(partition)
            if value isa Type && value <: tn.wrapper
                max_world = @atomic partition.max_world
                max_world == typemax(UInt) && return nothing
                return Int(partition.min_world):Int(max_world)
            end
        end
        isdefined(partition, :next) || return nothing
        partition = @atomic partition.next
    end
end

@noinline @overlay WASM_METHOD_TABLE function Base.check_world_bounded(tn::Core.TypeName)
    return _closed_world_type_bounds(tn)
end

@noinline function _closed_world_isvisible(sym::Symbol, parent::Module, from::Module)
    Base.isdeprecated(parent, sym) && return false
    Base.isdefinedglobal(from, sym) || return false
    Base.isdefinedglobal(parent, sym) || return false
    parent_binding = convert(Core.Binding, GlobalRef(parent, sym))
    from_binding = convert(Core.Binding, GlobalRef(from, sym))
    while true
        from_binding === parent_binding && return true
        partition = Base.lookup_binding_partition(Base.tls_world_age(), from_binding)
        Base.is_some_explicit_imported(Base.binding_kind(partition)) || break
        from_binding = Base.partition_restriction(partition)::Core.Binding
    end
    parent_partition = Base.lookup_binding_partition(Base.tls_world_age(), parent_binding)
    from_partition = Base.lookup_binding_partition(Base.tls_world_age(), from_binding)
    if Base.is_defined_const_binding(Base.binding_kind(parent_partition)) &&
       Base.is_defined_const_binding(Base.binding_kind(from_partition))
        return parent_partition.restriction === from_partition.restriction
    end
    return false
end

@noinline @overlay WASM_METHOD_TABLE function Base.isvisible(sym::Symbol, parent::Module,
                                                              from::Module)
    return _closed_world_isvisible(sym, parent, from)
end

# Why: `Base.nonnothing_nonmissing_typeinfo(io) =
#      nonmissingtype(nonnothingtype(get(io,:typeinfo,Any)))` does RUNTIME type
#      subtraction (typesplit over the type lattice), which the backend can't
#      lower — it stubs to `unreachable` and the surrounding block underflows
#      (`ref.is_null` with nothing on the stack: the dead-value/stackifier class).
#      It's called from `print(io, ::Float64)` (func print_3), so the invalid
#      body poisons the WHOLE module (WasmMakie canvas axis ticks; string(::Complex)
#      hits the same func). For a plain IOBuffer — which is what the float/Complex
#      formatting paths use — `get(io,:typeinfo,Any)` is `Any` and
#      `nonmissingtype(nonnothingtype(Any)) === Any`, so returning `Any` is exact.
#      (Only typeinfo-CONTEXT container display would differ; the Snapshot.jl
#      oracle byte-compares and degrades those rather than shipping them wrong.)
#      Inference const-folds the result, so callers' typeinfo branches collapse.
# Remove when: runtime type-subtraction (nonnothingtype/nonmissingtype) compiles,
#      or the dead-value-across-block-boundary stackifier defect is fixed.
@overlay WASM_METHOD_TABLE Base.nonnothing_nonmissing_typeinfo(io::IO) = Any

# ─── Shift Overlays (deterministic dispatch) ──────────────────────────────
# Why: under CC.OverlayMethodTable, `x << n` / `x >> n` with an Int64 amount
#      resolves to a raw-intrinsic-bodied method instead of Base's guarded
#      one, so huge/negative amounts leaked raw wasm shift semantics
#      (`0x01 << typemin(Int64)` returned 1; native gives 0 — gap
#      31d4d64b9325 family, 6 gaps). These overlays make dispatch
#      deterministic with Julia's documented semantics: negative amount
#      flips direction; over-shift → 0 (shl/lshr) or sign-fill (ashr).
#      The wasm-side emission of the intrinsics already guards over-shift,
#      so bodies compile to the existing guarded sequences.
# Remove when: overlay-table method selection matches native dispatch.
@overlay WASM_METHOD_TABLE function Base.:(<<)(x::T, n::Int64) where {T <: Base.BitInteger}
    nb = 8 * sizeof(T)
    if n >= 0
        return n >= nb ? zero(T) : Base.shl_int(x, Core.bitcast(UInt64, n))
    end
    m = -n   # NB: -typemin(Int64) wraps to typemin — caught by m < 0
    if m < 0 || m >= nb
        return T <: Signed ? Base.ashr_int(x, Core.bitcast(UInt64, Int64(nb - 1))) : zero(T)
    end
    return T <: Signed ? Base.ashr_int(x, Core.bitcast(UInt64, m)) : Base.lshr_int(x, Core.bitcast(UInt64, m))
end

@overlay WASM_METHOD_TABLE function Base.:(>>)(x::T, n::Int64) where {T <: Base.BitInteger}
    nb = 8 * sizeof(T)
    if n >= 0
        if n >= nb
            return T <: Signed ? Base.ashr_int(x, Core.bitcast(UInt64, Int64(nb - 1))) : zero(T)
        end
        return T <: Signed ? Base.ashr_int(x, Core.bitcast(UInt64, n)) : Base.lshr_int(x, Core.bitcast(UInt64, n))
    end
    m = -n
    (m < 0 || m >= nb) && return zero(T)
    return Base.shl_int(x, Core.bitcast(UInt64, m))
end

@overlay WASM_METHOD_TABLE function Base.:(>>>)(x::T, n::Int64) where {T <: Base.BitInteger}
    nb = 8 * sizeof(T)
    if n >= 0
        return n >= nb ? zero(T) : Base.lshr_int(x, Core.bitcast(UInt64, n))
    end
    m = -n
    (m < 0 || m >= nb) && return zero(T)
    return Base.shl_int(x, Core.bitcast(UInt64, m))
end

# ─── chomp Overlay ────────────────────────────────────────────────────────
# Why: Base.chomp returns a SubString{String}, and SubString poisons every
#      downstream consumer in the compiled world: uppercase(::SubString) emits
#      invalid wasm, SubString as a Dict value promotes the Dict to an abstract
#      value type that traps, and == against String stubs (gap 05bc422e7ffb /
#      627592b54cf2 / 655cf74e7170 family). The established convention here is
#      String-returning overlays (lstrip/rstrip already do this) — observable
#      only via typeof(), which generated programs don't inspect. Byte-level:
#      drop one trailing "\n" or "\r\n", exactly Base's semantics.
# Remove when: SubString has a full wasm repr (uppercase/==/Dict-value paths).
@noinline @overlay WASM_METHOD_TABLE function Base.chomp(s::String)
    n = sizeof(s)
    n == 0 && return s
    if codeunit(s, n) != 0x0a
        return s
    end
    last = (n >= 2 && codeunit(s, n - 1) == 0x0d) ? n - 2 : n - 1
    bytes = UInt8[]
    i = 1
    while i <= last
        push!(bytes, codeunit(s, i))
        i += 1
    end
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

# P4-stdlib (Statistics median/quantile on 1.13): _growend_internal! replaced
# the _growend! closures sort's scratch handling uses. WasmGC has no capacity
# concept — reallocate-and-copy exactly like the push!/append! overlays.
@static if VERSION >= v"1.13-"
@overlay WASM_METHOD_TABLE function Base._growend_internal!(a::Vector{T}, delta::Int, len::Int) where T
    newlen = len + delta
    new_v = similar(a, newlen)
    i = 1
    while i <= len
        new_v[i] = a[i]
        i += 1
    end
    setfield!(a, :ref, getfield(new_v, :ref))
    setfield!(a, :size, (newlen,))
    return nothing
end
end

# P4-stdlib (Random hash_seed): byte-wise reinterpret of primitive words —
# the generic Base._reinterpret_padding walks DataType padding metadata
# (host pointers; not compilable). Pure shift arithmetic is semantically
# identical for padding-free primitives.
@overlay WASM_METHOD_TABLE Base._reinterpret_padding(::Type{NTuple{4, UInt8}}, x::UInt32) =
    (x % UInt8, (x >> 8) % UInt8, (x >> 16) % UInt8, (x >> 24) % UInt8)
@overlay WASM_METHOD_TABLE Base._reinterpret_padding(::Type{NTuple{8, UInt8}}, x::UInt64) =
    (x % UInt8, (x >> 8) % UInt8, (x >> 16) % UInt8, (x >> 24) % UInt8,
     (x >> 32) % UInt8, (x >> 40) % UInt8, (x >> 48) % UInt8, (x >> 56) % UInt8)
@overlay WASM_METHOD_TABLE Base._reinterpret_padding(::Type{UInt32}, x::NTuple{4, UInt8}) =
    UInt32(x[1]) | (UInt32(x[2]) << 8) | (UInt32(x[3]) << 16) | (UInt32(x[4]) << 24)
@overlay WASM_METHOD_TABLE Base._reinterpret_padding(::Type{UInt64}, x::NTuple{8, UInt8}) =
    UInt64(x[1]) | (UInt64(x[2]) << 8) | (UInt64(x[3]) << 16) | (UInt64(x[4]) << 24) |
    (UInt64(x[5]) << 32) | (UInt64(x[6]) << 40) | (UInt64(x[7]) << 48) | (UInt64(x[8]) << 56)

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
            rj = result[j]
            # NaN-aware equality: `==` misses NaN (NaN==NaN is false) so unique kept
            # duplicate NaNs. `x != x` detects NaN (no-op for non-float T). (isequal
            # itself doesn't compile cleanly for Float here.)
            if rj == val || (rj != rj && val != val)
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

# Float-specialized `unique`: the generic overlay above compares with `==`, which
# treats -0.0 and 0.0 as equal, but Julia's `unique` uses `isequal` and keeps both.
# These more-specific overlays win dispatch for float vectors and add a signbit
# check (safe here: only floats, so `signbit` always compiles, unlike the generic
# AbstractVector path that can see Strings). NaN handled as before (`x != x`).
@overlay WASM_METHOD_TABLE function Base.unique(A::Vector{Float64})
    n = length(A)
    result = similar(A, 0)
    i = 1
    while i <= n
        val = A[i]
        found = false
        j = 1
        while j <= length(result)
            rj = result[j]
            if (rj != rj && val != val) || (rj == val && signbit(rj) == signbit(val))
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

@overlay WASM_METHOD_TABLE function Base.unique(A::Vector{Float32})
    n = length(A)
    result = similar(A, 0)
    i = 1
    while i <= n
        val = A[i]
        found = false
        j = 1
        while j <= length(result)
            rj = result[j]
            if (rj != rj && val != val) || (rj == val && signbit(rj) == signbit(val))
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

# ─── copy/copyto!(Matrix) Overlay ─────────────────────────────────────────
# Why: like copy(::Vector) above, Base.copy(::Matrix) and
#      copyto!(::Matrix, ::Matrix) bulk-copy via foreigncall(:memmove). WASM has
#      none, and (unlike the 1-D path) the 2-D memmove silently produced a ZERO
#      matrix — a wrong-value miscompile that blocked triu/tril/copy and any
#      matrix op routing through copy. Element-wise LINEAR-index copy is
#      bit-identical to memmove (dense column-major), verified vs native.
# Remove when: codegen lowers the 2-D memmove foreigncall.
@overlay WASM_METHOD_TABLE function Base.copy(m::Matrix{T}) where T
    result = similar(m)
    @inbounds for i in eachindex(m)
        result[i] = m[i]
    end
    return result
end

@overlay WASM_METHOD_TABLE function Base.copyto!(dest::Matrix{T}, src::Matrix{T}) where T
    @inbounds for i in eachindex(src)
        dest[i] = src[i]
    end
    return dest
end

# ─── (+)(Matrix, Matrix) Overlay ──────────────────────────────────────────
# Why: Base.:+(A::Array, Bs::Array...) is VARARGS — the splat routes 2-D
#      addition through a broadcast/`afoldl` instantiation that silently
#      produced a ZERO matrix (the 2-arg `-(A,B)` and scalar `*` take a clean
#      path and already work). Element-wise add is bit-identical and unblocks
#      matrix `+`. (Only the Matrix+Matrix case; vectors already work.)
# Remove when: codegen handles the varargs (+) broadcast instantiation for 2-D.
@overlay WASM_METHOD_TABLE function Base.:+(a::Matrix{T}, b::Matrix{T}) where T
    size(a) == size(b) || throw(DimensionMismatch("matrix add"))
    r = similar(a)
    @inbounds for i in eachindex(a)
        r[i] = a[i] + b[i]
    end
    return r
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

# ─── _collect(EltypeUnknown) Overlay ──────────────────────────────────────
# Why: Base's _collect for EltypeUnknown generators peeks the first element and
#      widens via setindex_widen_up_to / dynamic _similar_for — machinery codegen
#      can't translate. Whenever the map kernel's body can't be concrete-evaled
#      under the overlay table (string-literal constants like y->length(""), or
#      calls to overlayed methods like y->asin(1.0)), inlining bails and the
#      raw `invoke _collect` became an unsupported-method stub → runtime trap
#      (gap 3b005c4957f7 family). The empty-iterator branch of Base's version
#      also materialised Vector{Any} where native returns a typed empty vector.
#      In the closed-world wasm compile the kernel's return type IS statically
#      known — promote_op folds to a Const — so collect straight into Vector{T}
#      with a plain loop, no widening, and the n==0 branch is correctly typed.
# Remove when: codegen handles setindex_widen_up_to + dynamically-typed similar.
@overlay WASM_METHOD_TABLE function Base._collect(c::AbstractVector, itr::Base.Generator{<:AbstractVector},
                                                  ::Base.EltypeUnknown,
                                                  isz::Union{Base.HasLength, Base.HasShape{1}})
    f = itr.f
    A = itr.iter
    T = Base.promote_op(f, eltype(A))
    n = length(A)
    dest = Vector{T}(undef, n)
    i = 1
    while i <= n
        @inbounds dest[i] = f(A[i])
        i += 1
    end
    return dest
end

# ─── Dict delete! Overlay ─────────────────────────────────────────────────
# Why: Base._delete! uses atomic_pointerset(ptr, C_NULL, :monotonic) to null out
#      key/val references for GC. WASM codegen doesn't support atomic_pointerset.
#      WasmGC handles reference cleanup automatically, so we just clear the slot.
# Remove when: codegen handles atomic_pointerset as a regular store
@overlay WASM_METHOD_TABLE function Base.delete!(h::Dict{K,V}, key) where {K,V}
    index = Base.ht_keyindex(h, key)
    if index > 0
        h.slots[index] = 0x00
        h.count = h.count - 1
        h.age = h.age + 1
    end
    return h
end

# ─── Char Classification & Case Overlays ──────────────────────────────────
# Why: Base implementations use foreigncall(:utf8proc_category) / _toupper /
#      _tolower — C library calls that can't compile to WASM. P2-batch8:
#      extended from ASCII-only to EXACT ASCII + Latin-1 (U+0000–U+00FF)
#      coverage, table-verified against native Julia (uppercase('é')='É',
#      µ→Μ, ß→ẞ, ÿ→Ÿ, NEL/NBSP isspace, ª/µ/º letters). The fuzz generator's
#      char pool is ASCII + 'é', so this range is exhaustive for the
#      differential universe; codepoints > 0xFF keep identity/false.
#      Uses Core.bitcast (2 IR stmts) instead of reinterpret (400+ IR stmts).
# Remove when: codegen can link libutf8proc or a pure-Julia Unicode DB is available
# Char internal: UTF-8 bytes packed left-aligned into UInt32 —
#   'A' = 0x41000000 (1-byte), 'é' = 0xC3A90000 (2-byte), ASCII < 0x80000000

# Decode the packed-UTF-8 Char repr to a codepoint (all 1–4 byte forms).
@inline function _wt_codepoint(c::Char)
    raw = Core.bitcast(UInt32, c)
    raw < 0x80000000 && return raw >> 24
    if raw < 0xe0000000      # 110xxxxx 10xxxxxx
        return (((raw >> 24) & UInt32(0x1f)) << 6) | ((raw >> 16) & UInt32(0x3f))
    elseif raw < 0xf0000000  # 1110xxxx 10xxxxxx 10xxxxxx
        return (((raw >> 24) & UInt32(0x0f)) << 12) | (((raw >> 16) & UInt32(0x3f)) << 6) |
               ((raw >> 8) & UInt32(0x3f))
    else                     # 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
        return (((raw >> 24) & UInt32(0x07)) << 18) | (((raw >> 16) & UInt32(0x3f)) << 12) |
               (((raw >> 8) & UInt32(0x3f)) << 6) | (raw & UInt32(0x3f))
    end
end

# Encode a codepoint back into the packed-UTF-8 Char repr.
@inline function _wt_char(cp::UInt32)
    cp < UInt32(0x80) && return Core.bitcast(Char, cp << 24)
    if cp < UInt32(0x800)
        return Core.bitcast(Char, ((UInt32(0xc0) | (cp >> 6)) << 24) |
                                  ((UInt32(0x80) | (cp & UInt32(0x3f))) << 16))
    elseif cp < UInt32(0x10000)
        return Core.bitcast(Char, ((UInt32(0xe0) | (cp >> 12)) << 24) |
                                  ((UInt32(0x80) | ((cp >> 6) & UInt32(0x3f))) << 16) |
                                  ((UInt32(0x80) | (cp & UInt32(0x3f))) << 8))
    else
        return Core.bitcast(Char, ((UInt32(0xf0) | (cp >> 18)) << 24) |
                                  ((UInt32(0x80) | ((cp >> 12) & UInt32(0x3f))) << 16) |
                                  ((UInt32(0x80) | ((cp >> 6) & UInt32(0x3f))) << 8) |
                                  (UInt32(0x80) | (cp & UInt32(0x3f))))
    end
end

@overlay WASM_METHOD_TABLE function Base.uppercase(c::Char)
    cp = _wt_codepoint(c)
    if cp >= UInt32(0x61) && cp <= UInt32(0x7a)                       # a-z
        return _wt_char(cp - UInt32(0x20))
    elseif cp == UInt32(0xb5)                                          # µ → Μ
        return _wt_char(UInt32(0x39c))
    elseif cp == UInt32(0xdf)                                          # ß → ẞ
        return _wt_char(UInt32(0x1e9e))
    elseif (cp >= UInt32(0xe0) && cp <= UInt32(0xf6)) ||               # à-ö, ø-þ
           (cp >= UInt32(0xf8) && cp <= UInt32(0xfe))
        return _wt_char(cp - UInt32(0x20))
    elseif cp == UInt32(0xff)                                          # ÿ → Ÿ
        return _wt_char(UInt32(0x178))
    end
    return c
end

@overlay WASM_METHOD_TABLE function Base.lowercase(c::Char)
    cp = _wt_codepoint(c)
    if cp >= UInt32(0x41) && cp <= UInt32(0x5a)                        # A-Z
        return _wt_char(cp + UInt32(0x20))
    elseif (cp >= UInt32(0xc0) && cp <= UInt32(0xd6)) ||               # À-Ö, Ø-Þ
           (cp >= UInt32(0xd8) && cp <= UInt32(0xde))
        return _wt_char(cp + UInt32(0x20))
    end
    return c
end

@overlay WASM_METHOD_TABLE function Base.isletter(c::Char)
    cp = _wt_codepoint(c)
    return (cp >= UInt32(0x41) && cp <= UInt32(0x5a)) ||
           (cp >= UInt32(0x61) && cp <= UInt32(0x7a)) ||
           cp == UInt32(0xaa) || cp == UInt32(0xb5) || cp == UInt32(0xba) ||
           (cp >= UInt32(0xc0) && cp <= UInt32(0xd6)) ||
           (cp >= UInt32(0xd8) && cp <= UInt32(0xf6)) ||
           (cp >= UInt32(0xf8) && cp <= UInt32(0xff))
end

@overlay WASM_METHOD_TABLE function Base.isspace(c::Char)
    cp = _wt_codepoint(c)
    return (cp >= UInt32(0x09) && cp <= UInt32(0x0d)) || cp == UInt32(0x20) ||
           cp == UInt32(0x85) || cp == UInt32(0xa0)
end

@overlay WASM_METHOD_TABLE function Base.isuppercase(c::Char)
    cp = _wt_codepoint(c)
    return (cp >= UInt32(0x41) && cp <= UInt32(0x5a)) ||
           (cp >= UInt32(0xc0) && cp <= UInt32(0xd6)) ||
           (cp >= UInt32(0xd8) && cp <= UInt32(0xde))
end

@overlay WASM_METHOD_TABLE function Base.islowercase(c::Char)
    cp = _wt_codepoint(c)
    return (cp >= UInt32(0x61) && cp <= UInt32(0x7a)) ||
           cp == UInt32(0xaa) || cp == UInt32(0xb5) || cp == UInt32(0xba) ||
           cp == UInt32(0xdf) ||
           (cp >= UInt32(0xe0) && cp <= UInt32(0xf6)) ||
           (cp >= UInt32(0xf8) && cp <= UInt32(0xff))
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

# ─── maximum/minimum Overlays ────────────────────────────────────────────
# Why: Base maximum/minimum compile from mapreduce/`max`,`min` whose comparison
#      signedness flips to UNSIGNED in some compositions (e.g.
#      `sum([...]) + maximum(sort([0,x,x]))` returned the min: `0 >ᵤ -1` is false).
#      A simple explicit-loop overlay keeps the comparison correctly signed.
#      NaN poisons (matches Base: maximum/minimum return NaN if present).
# Remove when: native maximum/minimum codegen picks signed comparison in compositions.
@overlay WASM_METHOD_TABLE function Base.maximum(v::Vector{T}) where T
    n = length(v)
    n == 0 && throw(ArgumentError("collection must be non-empty"))
    i = 1
    while i <= n
        x = v[i]
        x != x && return x   # NaN
        i += 1
    end
    best = v[1]
    i = 2
    while i <= n
        v[i] > best && (best = v[i])
        i += 1
    end
    return best
end
@overlay WASM_METHOD_TABLE function Base.minimum(v::Vector{T}) where T
    n = length(v)
    n == 0 && throw(ArgumentError("collection must be non-empty"))
    i = 1
    while i <= n
        x = v[i]
        x != x && return x   # NaN
        i += 1
    end
    best = v[1]
    i = 2
    while i <= n
        v[i] < best && (best = v[i])
        i += 1
    end
    return best
end

# ─── reduce/foldl Overlays ───────────────────────────────────────────────
# Why: `reduce(op, v)` / `foldl(op, v)` over a Vector lower through native
#      mapreduce/mapfoldl. The CFG keeps a `mapreduce_impl` block (large-vector
#      branch) that emits invalid wasm, so the whole module fails to validate
#      even for small vectors — every reduce/foldl trapped (in lax mode it
#      returned garbage, e.g. `reduce(min, [5,3,8,1])` yielded the MAX). A plain
#      left-fold is exact for the generated associative ops (+, *, min, max) and
#      matches Base's observable result. (Float `+` differs only by pairwise-vs-
#      sequential rounding, within the differential harness's tolerance.)
#
#      `op::F` forces per-op specialization so the empty-collection identity
#      folds to a compile-time constant — otherwise `op` infers as abstract
#      `Function` and the empty branch becomes a `dynamic invoke ...::Union{}`
#      (Base.reduce_empty) that fails to compile. The `op === (+/*)` branches
#      give Base's empty identity (0 / 1); min/max (and any other op) throw on
#      empty, exactly as Base does.
# Remove when: native mapreduce/mapfoldl codegen is implemented.
@inline function _wasm_reduce_loop(op::F, v::Vector{T}) where {F,T}
    n = length(v)
    if n == 0
        op === (+) && return zero(T)
        op === (*) && return one(T)
        throw(ArgumentError("reducing over an empty collection is not allowed; consider supplying `init` to the reduce function"))
    end
    acc = v[1]
    i = 2
    while i <= n
        acc = op(acc, v[i])
        i += 1
    end
    return acc
end
@overlay WASM_METHOD_TABLE Base.reduce(op::F, v::Vector{T}) where {F,T} = _wasm_reduce_loop(op, v)
@overlay WASM_METHOD_TABLE Base.foldl(op::F, v::Vector{T}) where {F,T} = _wasm_reduce_loop(op, v)

# ─── argmax/argmin Overlays ──────────────────────────────────────────────
# Why: Base implementations use complex dispatch through _findmax/_findmin
#      with Pairs iterators and kwarg patterns that produce codegen errors.
# Remove when: codegen handles Pairs iterators and kwarg dispatch
@overlay WASM_METHOD_TABLE function Base.argmax(v::Vector{T}) where T
    n = length(v)
    n == 0 && throw(ArgumentError("collection must be non-empty"))
    # NaN poisons: Julia's findmax/argmax returns the FIRST NaN's index if any NaN.
    # (`x != x` is true only for NaN; a no-op for integer T.)
    i = 1
    while i <= n
        x = v[i]
        x != x && return i
        i += 1
    end
    best_idx = 1
    best_val = v[1]
    i = 2
    while i <= n
        # `>` plus a signed-zero tiebreak: +0.0 ranks above -0.0 (Julia's isless).
        # For non-zero/integer T the tiebreak is false (equal ⇒ same signbit).
        if v[i] > best_val || (v[i] == best_val && signbit(best_val) && !signbit(v[i]))
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
    i = 1   # NaN poisons (see argmax) — first NaN index wins
    while i <= n
        x = v[i]
        x != x && return i
        i += 1
    end
    best_idx = 1
    best_val = v[1]
    i = 2
    while i <= n
        if v[i] < best_val || (v[i] == best_val && !signbit(best_val) && signbit(v[i]))  # -0.0 ranks below +0.0
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

# ─── hypot(Float64) Overlay ──────────────────────────────────────────────
# Why: native Base.hypot's scaling/correction path produces NaN for tiny inputs in
#      wasm (e.g. hypot(1e-300,1e-300) → NaN, should be ~1.4e-300). Use the standard
#      scaled formula m·√((a/m)²+(b/m)²), which is overflow/underflow-safe and within
#      the differential's ULP tolerance of native.
# Remove when: native hypot compiles correctly across the float range.
@overlay WASM_METHOD_TABLE function Base.hypot(a::Float64, b::Float64)
    a = abs(a); b = abs(b)
    (isinf(a) || isinf(b)) && return Inf
    (isnan(a) || isnan(b)) && return NaN
    m = a > b ? a : b
    m == 0.0 && return 0.0
    r1 = a / m; r2 = b / m
    return m * sqrt(r1 * r1 + r2 * r2)
end

# ─── rem(Float64) Overlay ────────────────────────────────────────────────
# Why: Base.rem calls rem_internal which triggers stackifier bug
#      ("i64.sub expected i64, found anyref" — 100+ IR stmts with complex branches).
#      IEEE 754 floating-point remainder is a - trunc(a/b)*b.
# Remove when: stackifier correctly handles rem_internal's IR
@overlay WASM_METHOD_TABLE function Base.rem(x::Float64, y::Float64)
    # fmod semantics. `x - trunc(x/y)*y` is *lossy* for large quotients:
    # trunc(x/y)*y rounds, so rem(5.4e7, 1.41) drifts ~1e-9 off native fmod
    # (which is exact). Use scaled subtraction instead — each `a -= c` step is
    # exact by Sterbenz (c <= a < 2c), so the whole reduction is bit-exact.
    (isnan(x) || isnan(y) || isinf(x) || y == 0.0) && return NaN
    isinf(y) && return x                      # rem(finite, ±Inf) = x
    a = abs(x)
    b = abs(y)
    while a >= b
        c = b
        while c <= a * 0.5                    # largest c = b*2^k with c <= a
            c += c                            # exact: exponent bump
        end
        a -= c                                # exact: a/2 < c <= a (Sterbenz)
    end
    return signbit(x) ? -a : a                # rem takes the sign of x
end

# ─── mod(Float64) Overlay ────────────────────────────────────────────────
# Why: Base.mod(Float64,Float64) calls rem which calls rem_internal (stackifier bug).
#      IEEE 754 modulo is a - floor(a/b)*b.
# Remove when: stackifier correctly handles rem_internal's IR
@overlay WASM_METHOD_TABLE function Base.mod(x::Float64, y::Float64)
    # As rem, but the result takes the sign of the divisor. Guard Inf/NaN/zero.
    # Same exactness fix as rem: scaled subtraction, not `x - floor(x/y)*y`.
    (isnan(x) || isnan(y) || isinf(x) || y == 0.0) && return NaN
    if isinf(y)
        @static if VERSION >= v"1.13.0-"
            # 1.13 changed mod(finite, ±Inf) to return x regardless of sign
            # (gap f231ad158795: mod(1.0, -Inf) = 1.0 on 1.13, -Inf on 1.12)
            return x
        else
            # 1.12: x already matches divisor sign (or is 0) → x; else → y
            return (x == 0.0 || (x > 0.0) == (y > 0.0)) ? x : y
        end
    end
    a = abs(x)
    b = abs(y)
    while a >= b
        c = b
        while c <= a * 0.5
            c += c
        end
        a -= c
    end
    r = signbit(x) ? -a : a                   # = rem(x, y), exact
    # mod's result takes the sign of the divisor; one corrective add suffices.
    return (r != 0.0 && (signbit(r) != signbit(y))) ? r + y : r
end

# ─── Float32 exp / exp2 / exp10 Overlays ─────────────────────────────────
# Why: Base's Float32 exp family compiles to a dependency function that emits
#      invalid wasm (validation failure) — its table-driven Float32 kernel hits
#      a codegen gap the Float64 path doesn't. The Float64 kernel is correct, and
#      Float32(exp(Float64(x))) matches Julia's native exp(::Float32) to ≤1 ULP
#      (within the differential's transcendental tolerance), so redirect through it.
# Remove when: the Float32 transcendental kernel compiles to valid wasm directly.
@overlay WASM_METHOD_TABLE Base.exp(x::Float32) = Float32(exp(Float64(x)))
@overlay WASM_METHOD_TABLE Base.exp2(x::Float32) = Float32(exp2(Float64(x)))
@overlay WASM_METHOD_TABLE Base.exp10(x::Float32) = Float32(exp10(Float64(x)))

# ─── Hyperbolic Overlays (sinh / cosh / tanh) ────────────────────────────
# Why: Base's sinh/cosh/tanh have no native wasm codegen — they emit a value-stub
#      (nothing on the stack), so e.g. `hypot(Inf, sinh(x))` fails validation with
#      "expected f64 but nothing on stack". Implement via the (working) `exp`.
#      cosh = (eᵃ + e⁻ᵃ)/2 is exact everywhere (no cancellation; cosh ≥ 1).
#      sinh needs a Taylor branch for |x| < 0.35: the exp form eˣ-e⁻ˣ loses
#      precision to cancellation near 0 and would blow past the differential's
#      rtol=1e-9 in the band [1e-12, 1e-7] (below 1e-12 the atol covers it).
#      tanh = sinh/cosh with a |x|>20 ⇒ ±1 guard so large x can't make Inf/Inf.
# Remove when: native libm-style hyperbolic codegen exists.
const _WASM_LN2 = 0.6931471805599453             # log(2), for the overflow-safe eᵃ/2

# P3 gap c9f2efb08deb: the previous exp(a - ln2) trick for a > 20 carried ~3
# ulp error (argument rounding amplified by exp), which sin(sinh(x)) blew into
# full divergence at huge x — chaotic amplification. Fix ONLY that branch:
# the plain exp form is exact up to H_LARGE_X (exp(709) is finite), and above
# it Base's half-exponent squaring applies (bit-identical: exp compiles to
# the same Base kernel). Small/mid branches keep the catalogue-proven
# formulas — Base's minimax kernels can't be matched bitwise without fma.
@overlay WASM_METHOD_TABLE function Base.sinh(x::Float64)
    (isnan(x) || isinf(x)) && return x          # sinh(±Inf)=±Inf, sinh(NaN)=NaN
    a = abs(x)
    if a < 0.35
        # Taylor in x²: x·(1 + x²/3! + x⁴/5! + x⁶/7! + x⁸/9!); ≤7e-13 rel at 0.35.
        x2 = x * x
        return x * (1.0 + x2*(1/6 + x2*(1/120 + x2*(1/5040 + x2*(1/362880)))))
    elseif a >= 709.7822265633563                # H_LARGE_X(Float64), as in Base
        E = exp(0.5 * a)
        return copysign(0.5 * E * E, x)
    end
    E = exp(a)
    return copysign(0.5 * (E - 1.0 / E), x)      # 1/E underflows harmlessly at large a
end
@overlay WASM_METHOD_TABLE function Base.cosh(x::Float64)
    isnan(x) && return x
    a = abs(x)
    if a >= 709.7822265633563                    # H_LARGE_X(Float64), as in Base
        E = exp(0.5 * a)
        return 0.5 * E * E
    end
    E = exp(a)
    return 0.5 * (E + 1.0 / E)
end
@overlay WASM_METHOD_TABLE function Base.tanh(x::Float64)
    isnan(x) && return x
    abs(x) > 20.0 && return x < 0.0 ? -1.0 : 1.0  # saturated to ±1 (also ±Inf)
    return sinh(x) / cosh(x)                       # catalogue-proven quotient
end
@overlay WASM_METHOD_TABLE Base.sinh(x::Float32) = Float32(sinh(Float64(x)))
@overlay WASM_METHOD_TABLE Base.cosh(x::Float32) = Float32(cosh(Float64(x)))
@overlay WASM_METHOD_TABLE Base.tanh(x::Float32) = Float32(tanh(Float64(x)))

# ─── asin(Float64) Overlay ───────────────────────────────────────────────
# Why: Base's asin compiles fine standalone but its 600-stmt body mis-executes
#      (runtime trap) when pulled in as a *map-kernel dependency* — `map(asin, v)`
#      traps even for in-domain inputs, while `acos`/`atan`/`log` in map are fine.
#      Identity asin(x)=atan(x/√((1-x)(1+x))) reduces to atan (which works in map);
#      the (1-x)(1+x) form avoids cancellation near ±1 — verified ≤1 ULP over [-1,1].
# Remove when: large compiled functions work correctly as map-kernel dependencies.
@overlay WASM_METHOD_TABLE function Base.asin(x::Float64)
    abs(x) > 1.0 && throw(DomainError(x, "asin(x) requires -1 ≤ x ≤ 1"))
    return atan(x / sqrt((1.0 - x) * (1.0 + x)))   # NaN→NaN, ±1→±π/2 via ±Inf
end

# NOTE: A `length(::String)` overlay (lead-byte count via ncodeunits/codeunit) was
# trialed to fix the map-kernel-dependency trap (gap 3b005c4957f7) but had to be
# reverted: lstrip/rstrip above call `length(s)` internally as a *byte* count
# (char==byte for ASCII), and the overlay miscompiles in that dependency context —
# the same boolean-cond-in-while codegen class the strip overlays already contort
# around — silently breaking the previously-green ASCII strip tests. A global
# `length(::String)` that's correct both as a map kernel AND inside lstrip/rstrip
# needs the underlying codegen bug fixed first. Re-opened, triaged for Part 2.

# ─── isless(Float64) Overlay ────────────────────────────────────────────
# Why: Base.isless(Float64,Float64) produces 793 IR stmts with complex dispatch
#      through isnan checks and bitwise comparisons — triggers stackifier bug.
# Remove when: stackifier handles 793-stmt functions correctly
@overlay WASM_METHOD_TABLE function Base.isless(x::Float64, y::Float64)
    # Julia convention: NaN sorts to end (isless(x, NaN)=true, isless(NaN, x)=false)
    # Also: isless(-0.0, 0.0)=true
    if isnan(x)
        return false  # NaN is never less than anything
    end
    if isnan(y)
        return true   # everything is less than NaN
    end
    # Handle signed zero: -0.0 < 0.0
    if x == y
        return signbit(x) && !signbit(y)
    end
    return x < y
end

# ─── isless(Float32) Overlay ────────────────────────────────────────────
# Why: Base.isless(Float32,Float32) (like the Float64 case) emits invalid wasm —
#      a `type mismatch: expected i64, found anyref` validation failure — so any
#      Float32 ordering (e.g. `sort(::Vector{Float32})`, found by the fuzzer as
#      `length(sort([0f0,0f0,0f0]))`) fails to compile. Same NaN/signed-zero
#      convention as the Float64 overlay; isnan/signbit/== all work for Float32.
# Remove when: Base's Float32 isless compiles to valid wasm directly.
@overlay WASM_METHOD_TABLE function Base.isless(x::Float32, y::Float32)
    if isnan(x)
        return false
    end
    if isnan(y)
        return true
    end
    if x == y
        return signbit(x) && !signbit(y)
    end
    return x < y
end

# ─── pow_body(Float64, Int64) Overlay ────────────────────────────────────
# Why: Base.Math.pow_body(F64, Integer) is COMPENSATED power-by-squaring; its
#      fma/muladd ops fuse on the native host (ARM), so a naive square-and-
#      multiply loop (the previous overlay) drifted ~3 ulp — at 1e200 scale
#      that flips sin(x^x) entirely (gap e0f6a8de978a). This is a faithful
#      port of Base's algorithm with every fused op routed through
#      Base.fma_emulated (exact single rounding, == hardware fma/muladd).
# Remove when: muladd_float/fma_float lower to exact FMA in the wasm backend
@overlay WASM_METHOD_TABLE function Base.Math.pow_body(x::Float64, n::Int64)
    y = 1.0
    xnlo = -0.0
    ynlo = 0.0
    n == 3 && return x * x * x   # keep compatibility with literal_pow
    if n < 0
        rx = inv(x)
        n == -2 && return rx * rx
        isfinite(x) && (xnlo = -Base.fma_emulated(x, rx, -1.0) * rx)
        x = rx
        n = -n
    end
    while n > 1
        if n & 1 > 0
            err = Base.fma_emulated(y, xnlo, x * ynlo)
            t = x * y                              # two_mul(x, y)
            tlo = Base.fma_emulated(x, y, -t)
            y = t
            ynlo = tlo + err
        end
        err = x * 2 * xnlo
        t = x * x                                  # two_mul(x, x)
        tlo = Base.fma_emulated(x, x, -t)
        x = t
        xnlo = tlo + err
        n >>>= 1
    end
    err = Base.fma_emulated(y, xnlo, x * ynlo)
    return ifelse(isfinite(x) & isfinite(err), Base.fma_emulated(x, y, err), x * y)
end

# ─── repeat(String) Overlay ─────────────────────────────────────────────
# Why: Base.repeat(::String, ::Int) uses unsafe_copyto! with foreigncall(:memmove)
#      for efficient string repetition. Pure Julia loop with codeunit works in WASM.
# Remove when: codegen handles foreigncall(:memmove)
@overlay WASM_METHOD_TABLE function Base.repeat(s::String, n::Int)
    slen = ncodeunits(s)
    slen == 0 && return ""
    n <= 0 && return ""
    bytes = UInt8[]
    rep = 1
    while rep <= n
        i = 1
        while i <= slen
            push!(bytes, codeunit(s, i))
            i += 1
        end
        rep += 1
    end
    return String(bytes)
end

# ─── repeat(Char,Int) Overlay ───────────────────────────────────────────
# Why: WT's repeat(::Char, n) codegen (invoke.jl) assumes a SINGLE-byte char —
#      it array.new-fills n copies of just the char's FIRST UTF-8 byte
#      (char >> 24). That silently CORRUPTS any multibyte char: repeat('💊', 3)
#      gave [240,240,240] instead of the full 4-byte 'pill' three times (PI
#      convolution_1d `repeat('💊', i)`). Emit the char's full UTF-8 bytes n times.
# How: go through string(c) (1-char String) and replicate its codeunits — same
#      byte-assembly as the repeat(::String) overlay; correct for any char width.
@overlay WASM_METHOD_TABLE function Base.repeat(c::Char, n::Int)
    n <= 0 && return ""
    s = string(c)
    slen = ncodeunits(s)
    bytes = UInt8[]
    rep = 1
    while rep <= n
        i = 1
        while i <= slen
            push!(bytes, codeunit(s, i))
            i += 1
        end
        rep += 1
    end
    return String(bytes)
end

# ─── first(String,Int) Overlay ──────────────────────────────────────────
# Why: Base.first(::String, ::Int) uses nextind/SubString dispatch that triggers
#      codegen failures. Simple codeunit copy suffices for ASCII strings.
# Remove when: codegen handles SubString creation from nextind
@overlay WASM_METHOD_TABLE function Base.first(s::String, n::Int)
    slen = ncodeunits(s)
    take = n >= slen ? slen : n
    bytes = UInt8[]
    i = 1
    while i <= take
        push!(bytes, codeunit(s, i))
        i += 1
    end
    return String(bytes)
end

# ─── string(Int64) Overlay ──────────────────────────────────────────────
# Why: Base.string(::Int64) uses Ryu.writeshortest / dec() with complex dispatch
#      (hundreds of IR stmts, multiple autodiscover targets). Pure Julia digit
#      extraction works for all Int64 values.
# Remove when: codegen handles the Ryu string conversion pipeline
@overlay WASM_METHOD_TABLE function Base.string(x::Int64)
    x == Int64(0) && return "0"
    neg = x < 0
    # Extract digits WITHOUT negating x: `v = -x` overflows for typemin(Int64)
    # (-typemin == typemin, still negative) → the old loop produced "" → "-".
    # Process the value in place (digit magnitude via |q % 10|, ≤9 so -d is safe).
    digits = UInt8[]
    q = x
    while q != Int64(0)
        d = q - (q ÷ Int64(10)) * Int64(10)   # q % 10 (carries sign of q)
        d = d < Int64(0) ? -d : d             # magnitude 0..9
        push!(digits, UInt8(48 + d))          # '0' + d
        q = q ÷ Int64(10)                     # truncates toward zero
    end
    bytes = UInt8[]
    neg && push!(bytes, UInt8(45))            # '-'
    i = length(digits)
    while i >= 1
        push!(bytes, digits[i])
        i -= 1
    end
    return String(bytes)
end

# ─── first/last(Vector) Overlays ─────────────────────────────────────────
# Why: first(v)/last(v) compile to an unchecked array.get; on an empty vector that
#      reads the (capacity-allocated) backing array → returns garbage instead of
#      throwing BoundsError like native. Guard emptiness so wasm errors too (the
#      differential then matches: both error). Non-empty path is unchanged.
# Remove when: getindex bounds-checks the Vector size on OOB.
@overlay WASM_METHOD_TABLE function Base.first(v::Vector{T}) where T
    length(v) == 0 && throw(BoundsError())
    return v[1]
end
@overlay WASM_METHOD_TABLE function Base.last(v::Vector{T}) where T
    n = length(v)
    n == 0 && throw(BoundsError())
    return v[n]
end

# ─── empty!(Vector) Overlay ─────────────────────────────────────────────
# Why: Base.empty! uses internal _deleteend! with foreigncall(:memmove) for
#      clearing vector contents. Simple resize to 0 works in WASM.
# Remove when: codegen handles _deleteend! foreigncalls
@overlay WASM_METHOD_TABLE function Base.empty!(v::Vector{T}) where T
    while length(v) > 0
        pop!(v)
    end
    return v
end

# ─── reinterpret Overlay ──────────────────────────────────────────────────
# Why: The WasmInterpreter resolves reinterpret(UInt64, x::Float64) through the
#      full _reinterpret_padding path (type flags, padding checks, packedsize,
#      mapfoldl/kwerr infrastructure) — 200+ IR stmts. The native compiler inlines
#      it to Core.bitcast which is a single WASM instruction.
# Remove when: WasmInterpreter inference matches native compiler's reinterpret inlining
@overlay WASM_METHOD_TABLE function Base.reinterpret(::Type{UInt64}, x::Float64)
    return Core.bitcast(UInt64, x)
end
@overlay WASM_METHOD_TABLE function Base.reinterpret(::Type{Float64}, x::UInt64)
    return Core.bitcast(Float64, x)
end
@overlay WASM_METHOD_TABLE function Base.reinterpret(::Type{Int64}, x::Float64)
    return Core.bitcast(Int64, x)
end
@overlay WASM_METHOD_TABLE function Base.reinterpret(::Type{Float64}, x::Int64)
    return Core.bitcast(Float64, x)
end
@overlay WASM_METHOD_TABLE function Base.reinterpret(::Type{Int64}, x::UInt64)
    return Core.bitcast(Int64, x)
end
@overlay WASM_METHOD_TABLE function Base.reinterpret(::Type{UInt64}, x::Int64)
    return Core.bitcast(UInt64, x)
end
@overlay WASM_METHOD_TABLE function Base.reinterpret(::Type{Int32}, x::UInt32)
    return Core.bitcast(Int32, x)
end
@overlay WASM_METHOD_TABLE function Base.reinterpret(::Type{UInt32}, x::Int32)
    return Core.bitcast(UInt32, x)
end
@overlay WASM_METHOD_TABLE function Base.reinterpret(::Type{UInt32}, x::Float32)
    return Core.bitcast(UInt32, x)
end
@overlay WASM_METHOD_TABLE function Base.reinterpret(::Type{Float32}, x::UInt32)
    return Core.bitcast(Float32, x)
end

# ─── _reinterpret_padding Overlay ─────────────────────────────────────────
# Why: Base._reinterpret_padding goes through pointer_from_objref + packedsize
#      which generates 200+ IR stmts with mapfoldl/kwerr/fieldtype infrastructure.
#      Core.bitcast is a direct WASM reinterpret instruction (no-op on same-size types).
# Remove when: codegen handles the full reinterpret codepath natively
@overlay WASM_METHOD_TABLE function Base._reinterpret_padding(::Type{UInt64}, x::Float64)
    return Core.bitcast(UInt64, x)
end

@overlay WASM_METHOD_TABLE function Base._reinterpret_padding(::Type{Float64}, x::UInt64)
    return Core.bitcast(Float64, x)
end

@overlay WASM_METHOD_TABLE function Base._reinterpret_padding(::Type{UInt32}, x::Float32)
    return Core.bitcast(UInt32, x)
end

@overlay WASM_METHOD_TABLE function Base._reinterpret_padding(::Type{Float32}, x::UInt32)
    return Core.bitcast(Float32, x)
end

@overlay WASM_METHOD_TABLE function Base._reinterpret_padding(::Type{Int64}, x::Float64)
    return Core.bitcast(Int64, x)
end

@overlay WASM_METHOD_TABLE function Base._reinterpret_padding(::Type{Float64}, x::Int64)
    return Core.bitcast(Float64, x)
end

# ─── table_unpack Overlay ─────────────────────────────────────────────────
# Why: Base.Math.table_unpack indexes into J_TABLE::NTuple{256,UInt64} with a
#      runtime index. NTuple dynamic indexing generates massive IR (mapfoldl/
#      reduce_empty/fieldtype on all 256 fields). Vector indexing is O(1) in WASM.
# Remove when: codegen handles NTuple dynamic indexing efficiently
const _WASM_J_TABLE_VEC = UInt64[Base.Math.J_TABLE[i] for i in 1:256]

@overlay WASM_METHOD_TABLE function Base.Math.table_unpack(ind::Int32)
    i = Int64(ind & Int32(0xff)) + Int64(1)
    entry = _WASM_J_TABLE_VEC[i]
    jU = Core.bitcast(Float64, Base.Math.JU_CONST | (entry & Base.Math.JU_MASK))
    jL = Core.bitcast(Float64, Base.Math.JL_CONST | (entry >> UInt64(0x08)))
    return (jU, jL)
end

# ─── Set union! Overlay ────────────────────────────────────────────────────
# Why: Base.union!(::AbstractSet, itr) calls sizehint!(s, n; shrink=false) which
#      expands kwargs to 608 IR stmts with kwerr stubs that trap at runtime.
# Fix: Skip sizehint! (no-op in WasmGC) and just iterate+push!.
# Remove when: kwargs compilation handles kwerr stubs correctly (dead code elim)

@overlay WASM_METHOD_TABLE function Base.union!(s::AbstractSet{T}, itr) where T
    for x in itr
        push!(s, x)
    end
    return s
end

# ─── String hash Overlay (Julia 1.13+) ─────────────────────────────────────
# Why: 1.13 replaced the memhash foreigncall with pure-Julia rapidhash
#      (Base.hash_bytes) that reads string memory through 4/8-byte
#      pointerref(Ptr{UInt32/UInt64}) loads — WasmGC has no raw pointers, so
#      the inlined loads stubbed to unreachable (every Dict{String,...} op
#      trapped). The :invoke-level hash_bytes handler in invoke.jl only
#      catches the non-inlined form.
# Fix: Overlay hash(::String, ::UInt) with FNV-1a over codeunit() reads,
#      matching get_or_create_string_hash_func! (types.jl) EXACTLY — same
#      offset basis, prime, and low-32-bit seed mix — so Julia-level hashing
#      and the wasm helper (used by the memhash/hash_bytes fallback paths)
#      agree within one module. Hash values intentionally differ from native
#      Julia (1.12 precedent: internal consistency is what Dict needs).
# Remove when: codegen supports wide pointerref loads traced to string refs.

@static if VERSION >= v"1.13.0-"
    @noinline function _wasm_string_fnv1a(s::String, h::UInt)
        hv = 0xcbf29ce484222325 ⊻ UInt64(UInt32(h & 0xffffffff))
        i = 1
        n = ncodeunits(s)
        while i <= n
            hv = (hv ⊻ UInt64(codeunit(s, i))) * 0x00000100000001b3
            i += 1
        end
        return hv % UInt
    end

    @overlay WASM_METHOD_TABLE function Base.hash(data::String, h::UInt)
        return _wasm_string_fnv1a(data, h)
    end
end

# ─── String concatenation Overlay ───────────────────────────────────────────
# Why: Base._string (the Vararg backend of string(...) and String * SubString)
#      copies bytes through pointer arithmetic over the parts; the compiled
#      form null-derefs or traps for every multi-part call (gap 284d3e7059cd,
#      WASMMAKIE W-005 — even string("ab","cd") failed; only the dedicated
#      String*String path worked). Build bytes via codeunit reads instead.

@overlay WASM_METHOD_TABLE function Base._string(parts::Union{Char, SubString{String}, String, Symbol}...)
    out = UInt8[]
    for p in parts
        if p isa Char
            u = reinterpret(UInt32, p)
            nb = u == 0x00000000 ? 1 : (4 - (trailing_zeros(u) >> 3))
            i = 1
            while i <= nb
                push!(out, UInt8((u >> (8 * (4 - i))) & 0xFF))
                i += 1
            end
        elseif p isa String
            for i in 1:ncodeunits(p)
                push!(out, codeunit(p, i))
            end
        elseif p isa SubString{String}
            for i in 1:ncodeunits(p)
                push!(out, codeunit(p, i))
            end
        else  # Symbol — represented as a string in WasmGC
            s = String(p)
            for i in 1:ncodeunits(s)
                push!(out, codeunit(s, i))
            end
        end
    end
    return String(out)
end

# ─── Type-name rendering Overlays ─────────────────────────────────────────────
# Why: `string(typeof(x))`, `"$(typeof(x))"`, `show(io, T)` etc. all route through
#      Base's type-show machinery, which navigates DataType→TypeName→Symbol at
#      runtime — WT can't materialize the name and produces an EMPTY string (PI
#      Interactivity island: wasm "" != native "Int64"). But the type is ALWAYS a
#      compile-time constant at the call site (typeof of a typed value), so the name
#      is a compile-time literal.
# Fix: a @generated helper bakes `string(T)` as a String literal at specialization
#      time; overlay string/show of a Type to use it. Covers string(), repr(),
#      interpolation, and embedded `print(io, T)` (all funnel through show).
# Remove when: WT can navigate DataType.name.name to a string at runtime.
@generated _wt_type_name_str(::Type{T}) where {T} = :($(string(T)))

@overlay WASM_METHOD_TABLE Base.string(::Type{T}) where {T} = _wt_type_name_str(T)

@overlay WASM_METHOD_TABLE function Base.show(io::IO, ::Type{T}) where {T}
    print(io, _wt_type_name_str(T))
    return nothing
end

# Concrete 2-arg specializations: the Vararg method's invoke widens elements
# to the Union (heterogeneous-union tuple reads still miscompile — the
# hetero-Dict class), so give inference concrete signatures to prefer for the
# common mixed pairs ("m" * substring, str * char, ...).
@inline function _wasm_append_str!(out::Vector{UInt8}, s::Union{String, SubString{String}})
    for i in 1:ncodeunits(s)
        push!(out, codeunit(s, i))
    end
    return out
end
@inline function _wasm_append_char!(out::Vector{UInt8}, c::Char)
    u = reinterpret(UInt32, c)
    nb = u == 0x00000000 ? 1 : (4 - (trailing_zeros(u) >> 3))
    i = 1
    while i <= nb
        push!(out, UInt8((u >> (8 * (4 - i))) & 0xFF))
        i += 1
    end
    return out
end
@overlay WASM_METHOD_TABLE function Base._string(a::String, b::SubString{String})
    return String(_wasm_append_str!(_wasm_append_str!(UInt8[], a), b))
end
@overlay WASM_METHOD_TABLE function Base._string(a::SubString{String}, b::String)
    return String(_wasm_append_str!(_wasm_append_str!(UInt8[], a), b))
end
@overlay WASM_METHOD_TABLE function Base._string(a::String, b::Char)
    return String(_wasm_append_char!(_wasm_append_str!(UInt8[], a), b))
end
@overlay WASM_METHOD_TABLE function Base._string(a::Char, b::String)
    return String(_wasm_append_str!(_wasm_append_char!(UInt8[], a), b))
end

# String(::SubString) inlines an unsafe_string pointer conversion ("cannot
# convert NULL to string" guard) that null-derefs in WasmGC — copy bytes.
@overlay WASM_METHOD_TABLE function Base.String(s::SubString{String})
    out = UInt8[]
    for i in 1:ncodeunits(s)
        push!(out, codeunit(s, i))
    end
    return String(out)
end

# ─── MemoryRef slot-clear Overlay ───────────────────────────────────────────
# Why: Base._unsetindex!(::MemoryRef) nulls freed slots for the native GC. It
#      reads DataType layout metadata (getfield(Memory{T}, :layout) via
#      datatype_arrayelem/datatype_layoutsize) BEFORE its isbits early-return,
#      and those reads stub → uncatchable trap (gap 450889a9cb7e: Ryu
#      writeshortest's merged IR inlines it on the fixed-decimal path).
#      WasmGC tracks the backing array as a whole — slot clearing is a no-op.
# Cost: ref elements in freed slots stay reachable until the container dies
#      (same accepted trade-off as the _deleteend! overlay below).
@overlay WASM_METHOD_TABLE function Base._unsetindex!(A::MemoryRef{T}) where T
    return A
end

# ─── Vector shrink Overlay ──────────────────────────────────────────────────
# Why: shrinking resize! inlines Base._deleteend! whose freed-slot clearing
#      (atomic_pointerset GC bookkeeping) stubs to a runtime trap (gap
#      4c40e07c9230, WASMMAKIE T-005). In the WasmGC layout a Vector is
#      struct{array, size} with capacity ≥ size — shrinking is just a size
#      update; the GC tracks the backing array as a whole.
# Cost: ref-typed elements in the hidden capacity stay reachable until the
#      vector itself dies (bounded by capacity; same class as sizehint!).

@overlay WASM_METHOD_TABLE function Base._deleteend!(a::Vector{T}, delta::Int) where T
    n = length(a)
    setfield!(a, :size, (n - delta,))
    return nothing
end

# ─── Byte-vector membership Overlay ─────────────────────────────────────────
# Why: in(::Int8/UInt8, ::DenseInt8/DenseUInt8) goes through findfirst whose
#      fast path is a C memchr foreigncall over the vector's memory; Julia
#      1.13 inlines it into callers (gap fc7454877290 family). WasmGC has no
#      raw pointers, so the memchr stubbed to unreachable.
# Fix: plain loop — same semantics, no pointers. Applies on 1.12 too (the
#      memchr is present there as well; 1.12's IR shape just didn't surface
#      it in the fuzz catalogue).
# Remove when: codegen traces memchr's ptr arg back to the source array.

@overlay WASM_METHOD_TABLE function Base.in(a::UInt8, b::Base.DenseUInt8)
    for x in b
        x == a && return true
    end
    return false
end

@overlay WASM_METHOD_TABLE function Base.in(a::Int8, b::Base.DenseInt8)
    for x in b
        x == a && return true
    end
    return false
end

# ─── WasmInterpreter ───────────────────────────────────────────────────────

struct WasmInterpreter <: CC.AbstractInterpreter
    world::UInt
    method_table::CC.OverlayMethodTable
    inf_cache::Vector{CC.InferenceResult}
    inf_params::CC.InferenceParams
    opt_params::CC.OptimizationParams
    # P5-trim: codegen cache for the upstream CompilationQueue/compile!
    # closed-world collection (the juliac --trim machinery). compile! stashes
    # the uncompressed optimized CodeInfo of every collected CodeInstance
    # here — the (CodeInstance, CodeInfo) pairs the plugin handoff consumes.
    codegen::IdDict{Core.CodeInstance, Core.CodeInfo}
    # P5-trim: cache-partition token. The legacy pipeline shares :wasm_target
    # for cross-compile CodeInstance reuse; collect_closed_world uses a FRESH
    # per-collection token — a shared partition can hold CodeInstances
    # inferred by earlier interps whose codegen CodeInfos were never stashed,
    # tripping compile!'s `use_const_api || haskey(interp.codegen)` invariant.
    cache_token::Any
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
    WasmInterpreter(world, mt, CC.InferenceResult[], inf_params, opt_params,
                    IdDict{Core.CodeInstance, Core.CodeInfo}(), :wasm_target)
end

function WasmInterpreter(cache_token; world::UInt=Base.get_world_counter())
    base = WasmInterpreter(; world)
    WasmInterpreter(base.world, base.method_table, base.inf_cache,
                    base.inf_params, base.opt_params, base.codegen, cache_token)
end

# Required AbstractInterpreter API
CC.InferenceParams(interp::WasmInterpreter) = interp.inf_params
CC.OptimizationParams(interp::WasmInterpreter) = interp.opt_params
CC.get_inference_world(interp::WasmInterpreter) = interp.world
CC.get_inference_cache(interp::WasmInterpreter) = interp.inf_cache
CC.cache_owner(interp::WasmInterpreter) = interp.cache_token
CC.method_table(interp::WasmInterpreter) = interp.method_table
CC.codegen_cache(interp::WasmInterpreter) = interp.codegen

# Julia's native inference models `(∘)(runtime_vector...)` as an unbounded
# recursive union of nested ComposedFunction types, then specializes downstream
# IR into representation-specific getfield branches. WT uses one flat callable
# context, analogous to dart2wasm's closure context + vtable. Teach inference the
# target representation before optimization so downstream IR is generated from
# that truth; all unrelated builtins delegate unchanged to Julia's implementation.
function CC.abstract_apply(interp::WasmInterpreter, argtypes::Vector{Any},
                           si::CC.StmtInfo,
                           sv::Union{CC.IRInterpretationState,CC.InferenceState},
                           max_methods::Int)
    if length(argtypes) == 4
        local target = argtypes[3]
        local container = CC.widenconst(argtypes[4])
        if target isa CC.Const && target.val === (∘) &&
           container isa DataType && container <: AbstractVector
            # Conservative effects/exceptions are intentional: the source-level
            # callable may invoke arbitrary functions and rejects an empty list.
            return CC.Future(CC.CallMeta(_RuntimeComposition{container}, Any,
                                         CC.Effects(), CC.NoCallInfo()))
        end
    end
    return invoke(CC.abstract_apply,
                  Tuple{CC.AbstractInterpreter,Vector{Any},CC.StmtInfo,
                        Union{CC.IRInterpretationState,CC.InferenceState},Int},
                  interp, argtypes, si, sv, max_methods)
end

# Disable concrete eval (GPUCompiler pattern).
# Without this, the compiler constant-folds calls using Base implementation,
# bypassing overlays.
#
# DEFERRED (2026-06-22, wt-soundness-loop-4): an overlay-aware exception that folds
# pure TYPE-LEVEL calls (to fix the `cor` cluster — `one(float(nonmissingtype(T)))`
# leaking as `dynamic` dispatch on Type values) passed full Pkg.test on Julia 1.12
# but REGRESSED Julia 1.13-rc1 string-overlay codegen (repeat/lpad/rpad/chop/split/
# join/string-chains errored — concrete-eval perturbs WT's version-specific string
# IR shapes). Reverted to the blanket `:none`; the cor root cause + the type-level
# fold approach are recorded in test/fuzz/failures/3fd2f07bfc5c.md — re-attempt only
# with a Julia 1.13 environment available to verify against.
# A CURATED set of pure TYPE-LEVEL functions that concrete-eval may fold. They
# produce Types (or values trivially derived from Types) that WT fundamentally
# cannot lower as runtime values — so folding them is MANDATORY, not an
# optimization. They have no value-level overlays to bypass, and strings never
# call them, so re-enabling eval for ONLY these can't perturb WT's
# version-specific string IR (the failure mode that reverted the prior blanket
# `all-Type-args` attempts — see test/fuzz/failures/3fd2f07bfc5c.md). This is the
# `cor`/SparseArrays insight generalized: route the runtime type-machinery to its
# known compile-time constant, scoped surgically. MUST be total (runs during
# inference of arbitrary code).
function _is_typelevel_foldable(@nospecialize(f))::Bool
    f === Core.apply_type && return true
    (isdefined(Core, :_compute_sparams) && f === Core._compute_sparams) && return true
    (isdefined(Core, :_svec_ref)        && f === Core._svec_ref)        && return true
    (isdefined(Core, :_typevar)         && f === Core._typevar)         && return true
    f === Base.nonmissingtype && return true
    f === Base.promote_type   && return true
    (isdefined(Base, :typesplit) && f === Base.typesplit) && return true
    f === Base.eltype && return true
    (isdefined(Base, :_compute_eltype) && f === Base._compute_eltype) && return true
    # float/one fold only on a Type arg — concrete-eval fires ONLY on constant
    # args, so the value forms (one(::Float64)) never reach the fold here.
    f === Base.float && return true
    f === Base.one   && return true
    # SciML in-place detection (ODEProblem/ODEFunction): a Bool from method arity,
    # feeding apply_type. Match `isinplace` AND its kwarg body `#isinplace#NN`.
    # `nameof` throws for some callables (Base.BottomRF) — guard it.
    if f isa Function
        nm = try string(nameof(f)) catch; "" end
        (startswith(nm, "isinplace") || startswith(nm, "#isinplace#")) && return true
    end
    return false
end

function CC.concrete_eval_eligible(interp::WasmInterpreter,
        @nospecialize(f), result::CC.MethodCallResult, arginfo::CC.ArgInfo,
        sv::Union{CC.InferenceState, CC.IRInterpretationState})
    # Delegate to the normal effect-based eligibility ONLY for whitelisted pure
    # type-level functions; everything else stays disabled (overlays win, and
    # value-level/string codegen is byte-for-byte unchanged).
    if _is_typelevel_foldable(f)
        return @invoke CC.concrete_eval_eligible(interp::CC.AbstractInterpreter,
                                                 f, result, arginfo, sv)
    end
    return :none
end

"""
    get_wasm_interpreter() -> WasmInterpreter

Create a WasmInterpreter with overlay method table for the current world age.
Must be called after all user functions are defined (so they're visible to inference).
"""
get_wasm_interpreter() = WasmInterpreter(; world=Base.get_world_counter())
