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

@noinline function _runtime_composition_apply(fs::AbstractVector, i::Int, x)::Any
    i == 0 && return x
    return _runtime_composition_apply(fs, i - 1, fs[i](x))
end

@noinline function (c::_RuntimeComposition)(x)
    isempty(c.fs) && throw(MethodError(∘, ()))
    return _runtime_composition_apply(c.fs, length(c.fs), x)
end


# ─── String Concatenation Overlays ────────────────────────────────────────
# Why: Base.*(::String, ::String) calls string() which uses print_to_string/IOBuffer
#      with deep dispatch chains and foreigncalls. Pure Julia byte-copy works in WASM.
# Remove when: codegen handles IOBuffer-based string construction

@inline _wasm_print_to_string_tuple(::Tuple{})::String = ""
@inline function _wasm_print_to_string_tuple(xs::Tuple)::Union{Missing, Base.AnnotatedString{String}, Regex, String}
    return string(first(xs)) * _wasm_print_to_string_tuple(Base.tail(xs))
end

# Julia's print_to_string builds an IOBuffer (which takes pointer_from_objref, jl_value_ptr)
# and prints each part through show — a vector's through show_vector, which asks
# Base.invoke_in_world (arrayshow.jl:553). WT lowers neither, so each part is its string.
# parity(quarantine: Julia's print_to_string writes an IOBuffer through pointer_from_objref,
# and shows a vector through Base.invoke_in_world; WT lowers neither.)
@noinline @overlay WASM_METHOD_TABLE function Base.print_to_string(xs...)
    # Tuple recursion preserves each fixed call site's concrete heterogeneous
    # field types. Iterating `xs` widens the element to Any and enrolls the
    # generic show/IO universe even for interpolation like (String, Int, String).
    return _wasm_print_to_string_tuple(xs)
end

# Julia's titlecase writes through an IOBuffer, which takes pointer_from_objref
# (jl_value_ptr, pointer.jl:302); WT rejects a pointer into an object. This is titlecase's
# rule over the String's characters (_wasm_titlecase_impl).
# parity(quarantine: Julia's titlecase writes through an IOBuffer that takes
# pointer_from_objref, jl_value_ptr; a WT object has no address.)
@overlay WASM_METHOD_TABLE function Base.titlecase(s::String; wordsep=nothing, strict::Bool=true)
    return _wasm_titlecase_impl(s, strict)
end

# Julia's string of a vector runs show_vector, which asks Base.invoke_in_world for
# _typeinfo_implicit (arrayshow.jl:553); WT does not lower invoke_in_world (R33). These write
# Julia's text for the three element types a program prints: "[1, 2]", "[1.5, 2.0]",
# ["a", "b"] with its quotes.
# parity(quarantine: Julia's show_vector calls Base.invoke_in_world, which WT does not lower.)
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

# parity(quarantine: Julia's show_vector calls Base.invoke_in_world, which WT does not lower.)
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

# parity(quarantine: Julia's show_vector calls Base.invoke_in_world, which WT does not lower.)
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

# Julia's repr of a vector runs show_vector, which asks Base.invoke_in_world for
# _typeinfo_implicit (arrayshow.jl:553); WT does not lower invoke_in_world (R33).
# parity(quarantine: Julia's show_vector calls Base.invoke_in_world, which WT does not lower.)
@overlay WASM_METHOD_TABLE Base.repr(v::AbstractVector) = string(v)

# Julia's hvcat of tuple elements shapes the matrix through _typed_hvncat_shape
# (abstractarray.jl:52), which WT does not compile. This builds the same rectangular matrix
# with Matrix{T}(undef, m, n) and element stores.
# parity(quarantine: Julia's hvcat shapes the result through _typed_hvncat_shape, which WT does
# not compile.)
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

# Julia's string(::Complex) is print_to_string(z), which WT's print_to_string overlay answers
# with string(z) — itself (dev/MARCH.md 13.10); the call recursed until the stack ran out. This
# writes Julia's text, re ± im "im".
# parity(quarantine: WT's print_to_string overlay answers print_to_string(x) with string(x),
# which is print_to_string(x) for a value with no string method of its own.)
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

# Julia's string(nothing) is print_to_string(nothing), which WT's print_to_string overlay
# answers with string(first(xs)) — itself — so the call has no end (dev/MARCH.md 13.10). This
# is Julia's answer; it goes with that overlay.
# parity(quarantine: WT's print_to_string overlay answers print_to_string(x) with string(x),
# which is print_to_string(x) for a value with no string method of its own.)
@overlay WASM_METHOD_TABLE function Base.string(::Nothing)
    return "nothing"
end

# ─── String Manipulation Overlays ──────────────────────────────────────────
# Base versions use SubString, IOBuffer, or deep dispatch chains.
# All overlays use only: ncodeunits, codeunit, String(UInt8[...]) construction.
# This is pure Julia that WasmTarget's codegen can handle.

# NOTE: `uppercase`/`lowercase`(::SubString) is NOT overlaid. The natural overlay
# (byte-loop reading codeunit(s,i) from the SubString into a fresh String) compiles
# but is SILENTLY WRONG: `codeunit(::SubString)` reads return 0 inside this
# nested-build context (length comes out right, bytes come out zero) — the same
# SubString/String(bytes) codegen class the strip overlays contort around. A loud
# compile error (gap 05bc422e7ffb) is better than silently-wrong content; the real
# fix needs that underlying codegen bug. Triaged for Part 2 with the strip gaps.

@noinline function _wasm_titlecase_impl(s::String, strict::Bool)::String
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


# The padding-free primitive element types of the reinterpret overlays below, by width.
const _WT_BITS32 = Union{Int32, UInt32, Float32, Char}
const _WT_BITS64 = Union{Int64, UInt64, Float64}
const _WT_BITS16 = Union{Int16, UInt16}
const _WT_BITS8  = Union{Int8, UInt8, Bool}
const _WT_PRIMITIVE_BITS = Union{_WT_BITS8, _WT_BITS16, _WT_BITS32, _WT_BITS64}

# Padding-free ReinterpretArray elements are assembled from the parent's value bits.
# Julia's native implementation probes GC object headers through pointer_from_objref;
# WasmGC has no such header ABI. State the complete little-endian value semantics in
# valid Julia instead: equal-width elements bitcast directly, wider destinations pack
# consecutive parent elements, and narrower destinations select their byte lane.
_wt_uint_type(::Val{1})::Type{UInt8} = UInt8
_wt_uint_type(::Val{2})::Type{UInt16} = UInt16
_wt_uint_type(::Val{4})::Type{UInt32} = UInt32
_wt_uint_type(::Val{8})::Type{UInt64} = UInt64

# Primitive numeric elements have no padding. Folding this target-independent
# layout fact keeps ReinterpretArray construction out of Julia's host pointer/
# datatype-layout machinery while preserving Base.array_subpadding semantics.
# parity(quarantine: Julia's isbitstype/array_subpadding read the DataType's layout flags, host layout; for primitive bit types the answer is the same on every target.)
@overlay WASM_METHOD_TABLE Base.isbitstype(
    ::Type{T}) where {T<:_WT_PRIMITIVE_BITS} = true
# parity(quarantine: Julia's isbitstype/array_subpadding read the DataType's layout flags, host layout; for primitive bit types the answer is the same on every target.)
@overlay WASM_METHOD_TABLE Base.array_subpadding(
    ::Type{S}, ::Type{T}) where {S<:_WT_PRIMITIVE_BITS,T<:_WT_PRIMITIVE_BITS} = true

# parity(quarantine: Julia's ReinterpretArray element access probes the GC object header through pointer_from_objref; WasmGC has no header ABI, so the element is assembled from the parent's value bits.)
@overlay WASM_METHOD_TABLE function Base.getindex(
        a::Base.ReinterpretArray{T,N,S,A,false}, i::Int
    ) where {T<:_WT_PRIMITIVE_BITS,N,S<:_WT_PRIMITIVE_BITS,A}
    parent_array = getfield(a, 1)
    target_bytes = sizeof(T)
    source_bytes = sizeof(S)
    TargetBits = _wt_uint_type(Val(target_bytes))
    SourceBits = _wt_uint_type(Val(source_bytes))
    if target_bytes == source_bytes
        return Core.bitcast(T, getindex(parent_array, i))
    elseif target_bytes > source_bytes
        ratio = target_bytes ÷ source_bytes
        first_parent = (i - 1) * ratio + 1
        bits = zero(TargetBits)
        for lane in 0:(ratio - 1)
            source = Core.bitcast(SourceBits, getindex(parent_array, first_parent + lane))
            bits |= convert(TargetBits, source) << (8 * source_bytes * lane)
        end
        return Core.bitcast(T, bits)
    else
        ratio = source_bytes ÷ target_bytes
        parent_index = (i - 1) ÷ ratio + 1
        lane = (i - 1) % ratio
        source = Core.bitcast(SourceBits, getindex(parent_array, parent_index))
        bits = (source >> (8 * target_bytes * lane)) % TargetBits
        return Core.bitcast(T, bits)
    end
end
# parity(quarantine: Julia's ReinterpretArray element access probes the GC object header through pointer_from_objref; WasmGC has no header ABI, so the element is assembled from the parent's value bits.)
@overlay WASM_METHOD_TABLE function Base.setindex!(
        a::Base.ReinterpretArray{T,N,S,A,false}, value, i::Int
    ) where {T<:_WT_PRIMITIVE_BITS,N,S<:_WT_PRIMITIVE_BITS,A}
    converted = convert(T, value)
    parent_array = getfield(a, 1)
    target_bytes = sizeof(T)
    source_bytes = sizeof(S)
    TargetBits = _wt_uint_type(Val(target_bytes))
    SourceBits = _wt_uint_type(Val(source_bytes))
    target = Core.bitcast(TargetBits, converted)
    if target_bytes == source_bytes
        setindex!(parent_array, Core.bitcast(S, target), i)
    elseif target_bytes > source_bytes
        ratio = target_bytes ÷ source_bytes
        first_parent = (i - 1) * ratio + 1
        for lane in 0:(ratio - 1)
            bits = (target >> (8 * source_bytes * lane)) % SourceBits
            setindex!(parent_array, Core.bitcast(S, bits), first_parent + lane)
        end
    else
        ratio = source_bytes ÷ target_bytes
        parent_index = (i - 1) ÷ ratio + 1
        lane = (i - 1) % ratio
        shift = 8 * target_bytes * lane
        old = Core.bitcast(SourceBits, getindex(parent_array, parent_index))
        lane_mask = convert(SourceBits, typemax(TargetBits)) << shift
        merged = (old & ~lane_mask) | (convert(SourceBits, target) << shift)
        setindex!(parent_array, Core.bitcast(S, merged), parent_index)
    end
    return value
end

# ─── show typeinfo overlay ────────────────────────────────────────────────

# parity(quarantine: Julia's ReinterpretArray element access probes the GC object header through pointer_from_objref; WasmGC has no header ABI, so the element is assembled from the parent's value bits.)
@overlay WASM_METHOD_TABLE function Base.getindex(
        a::Base.ReinterpretArray{T,N,S,A,false}, r::UnitRange{Int}
    ) where {T<:_WT_PRIMITIVE_BITS,N,S<:_WT_PRIMITIVE_BITS,A}
    out = Vector{T}(undef, length(r))
    source_index = first(r)
    for destination_index in eachindex(out)
        out[destination_index] = getindex(a, source_index)
        source_index += 1
    end
    return out
end

# Julia's native implementation walks mutable BindingPartition history. Keep
# the native meaning for ordinary Julia execution, but preserve one non-inlined
# semantic boundary for WT inference so codegen can read the immutable result
# captured in its TypeName metadata. This is analogous to dart2wasm retaining a
# recognized runtime operation instead of inlining VM implementation details.
@noinline function _closed_world_type_bounds(tn::Core.TypeName)::Union{Nothing, UnitRange{Int64}}
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

# parity(quarantine: Julia's check_world_bounded walks the TypeName's binding partitions at run
# time; the closed module has one world, WASM_WORLD_AGE, and answers from compile-time metadata.)
@noinline @overlay WASM_METHOD_TABLE function Base.check_world_bounded(tn::Core.TypeName)
    return _closed_world_type_bounds(tn)
end

@noinline function _closed_world_isvisible(sym::Symbol, parent::Module, from::Module)::Bool
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

# parity(quarantine: Julia's isvisible walks binding partitions at the current world; the closed
# module has one world and answers from compile-time binding metadata.)
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
#      Only an IOBuffer: an IOContext may carry a :typeinfo whose answer differs, and
#      it keeps Julia's body (compiled, or rejected loudly), never this `Any`.
# parity(quarantine: Julia's nonnothing_nonmissing_typeinfo subtracts Nothing and Missing from
# the context's :typeinfo at run time, typesplit, which WT does not lower; an IOBuffer has no
# context, so its answer is Any.)
@overlay WASM_METHOD_TABLE Base.nonnothing_nonmissing_typeinfo(io::Base.GenericIOBuffer) = Any

# A primitive word reinterpreted as its byte tuple, and back: the word's little-endian
# byte lanes. Base's generic `_reinterpret` first proves the two packed sizes equal by
# walking the host layout (`packedsize` → `padding` → `fieldoffset`), a fold WT refuses
# (`_wt_reads_host_layout`) and a foreigncall it cannot lower; left in the program, that
# runtime reflection over `fieldtype(T, i)::Any` fanned dynamic-dispatch discovery out
# over every class of the closed world (9,644 functions collected for
# `reinterpret(NTuple{8, UInt8}, ::UInt64)`). A primitive word has no padding, so its
# packed size is its size and the answer is the byte lanes of its bits.
# parity(quarantine: Julia defines reinterpret to and from a byte tuple by host memory layout; WT has no host layout, and a padding-free primitive's layout is its little-endian bytes.)
_wt_le_bytes(u::UInt8)::NTuple{1, UInt8} = (u,)
# parity(quarantine: the little-endian byte lanes of a primitive word, see _wt_le_bytes.)
_wt_le_bytes(u::UInt16)::NTuple{2, UInt8} = (u % UInt8, (u >> 8) % UInt8)
# parity(quarantine: the little-endian byte lanes of a primitive word, see _wt_le_bytes.)
_wt_le_bytes(u::UInt32)::NTuple{4, UInt8} =
    (u % UInt8, (u >> 8) % UInt8, (u >> 16) % UInt8, (u >> 24) % UInt8)
# parity(quarantine: the little-endian byte lanes of a primitive word, see _wt_le_bytes.)
_wt_le_bytes(u::UInt64)::NTuple{8, UInt8} =
    (u % UInt8, (u >> 8) % UInt8, (u >> 16) % UInt8, (u >> 24) % UInt8,
     (u >> 32) % UInt8, (u >> 40) % UInt8, (u >> 48) % UInt8, (u >> 56) % UInt8)
# parity(quarantine: the primitive word of little-endian byte lanes, see _wt_le_bytes.)
_wt_le_word(b::NTuple{1, UInt8})::UInt8 = b[1]
# parity(quarantine: the primitive word of little-endian byte lanes, see _wt_le_bytes.)
_wt_le_word(b::NTuple{2, UInt8})::UInt16 = UInt16(b[1]) | (UInt16(b[2]) << 8)
# parity(quarantine: the primitive word of little-endian byte lanes, see _wt_le_bytes.)
_wt_le_word(b::NTuple{4, UInt8})::UInt32 =
    UInt32(b[1]) | (UInt32(b[2]) << 8) | (UInt32(b[3]) << 16) | (UInt32(b[4]) << 24)
# parity(quarantine: the primitive word of little-endian byte lanes, see _wt_le_bytes.)
_wt_le_word(b::NTuple{8, UInt8})::UInt64 =
    UInt64(b[1]) | (UInt64(b[2]) << 8) | (UInt64(b[3]) << 16) | (UInt64(b[4]) << 24) |
    (UInt64(b[5]) << 32) | (UInt64(b[6]) << 40) | (UInt64(b[7]) << 48) | (UInt64(b[8]) << 56)
# parity(quarantine: Julia's _reinterpret to or from a byte tuple reads the host layout (jl_get_field_offset); see _wt_le_bytes.)
@overlay WASM_METHOD_TABLE Base._reinterpret(::Type{NTuple{1, UInt8}}, x::_WT_BITS8) =
    _wt_le_bytes(Core.bitcast(UInt8, x))
# parity(quarantine: Julia's _reinterpret to or from a byte tuple reads the host layout (jl_get_field_offset); see _wt_le_bytes.)
@overlay WASM_METHOD_TABLE Base._reinterpret(::Type{NTuple{2, UInt8}}, x::_WT_BITS16) =
    _wt_le_bytes(Core.bitcast(UInt16, x))
# parity(quarantine: Julia's _reinterpret to or from a byte tuple reads the host layout (jl_get_field_offset); see _wt_le_bytes.)
@overlay WASM_METHOD_TABLE Base._reinterpret(::Type{NTuple{4, UInt8}}, x::_WT_BITS32) =
    _wt_le_bytes(Core.bitcast(UInt32, x))
# parity(quarantine: Julia's _reinterpret to or from a byte tuple reads the host layout (jl_get_field_offset); see _wt_le_bytes.)
@overlay WASM_METHOD_TABLE Base._reinterpret(::Type{NTuple{8, UInt8}}, x::_WT_BITS64) =
    _wt_le_bytes(Core.bitcast(UInt64, x))
# parity(quarantine: Julia's _reinterpret to or from a byte tuple reads the host layout (jl_get_field_offset); see _wt_le_bytes.)
@overlay WASM_METHOD_TABLE Base._reinterpret(::Type{T}, x::NTuple{1, UInt8}) where {T<:_WT_BITS8} =
    Core.bitcast(T, _wt_le_word(x))
# parity(quarantine: Julia's _reinterpret to or from a byte tuple reads the host layout (jl_get_field_offset); see _wt_le_bytes.)
@overlay WASM_METHOD_TABLE Base._reinterpret(::Type{T}, x::NTuple{2, UInt8}) where {T<:_WT_BITS16} =
    Core.bitcast(T, _wt_le_word(x))
# parity(quarantine: Julia's _reinterpret to or from a byte tuple reads the host layout (jl_get_field_offset); see _wt_le_bytes.)
@overlay WASM_METHOD_TABLE Base._reinterpret(::Type{T}, x::NTuple{4, UInt8}) where {T<:_WT_BITS32} =
    Core.bitcast(T, _wt_le_word(x))
# parity(quarantine: Julia's _reinterpret to or from a byte tuple reads the host layout (jl_get_field_offset); see _wt_le_bytes.)
@overlay WASM_METHOD_TABLE Base._reinterpret(::Type{T}, x::NTuple{8, UInt8}) where {T<:_WT_BITS64} =
    Core.bitcast(T, _wt_le_word(x))


# Julia's splice!(v, i) compiles its default `ins` branch `only(::Vector{Any})`, which builds
# `(x, 2)` from an `Any` value: Julia gives that tuple the runtime type of its elements
# (jl_f_tuple), and WT classes a tuple by its static type, so it has no numbered class
# (dev/MARCH.md 13.10). This is Julia's splice!(v, i): the element, then deleteat!.
# parity(quarantine: Julia's splice!(v, i) compiles a tuple of an Any value whose runtime type
# is its element's, jl_f_tuple; WT classes a tuple by its static type.)
@overlay WASM_METHOD_TABLE function Base.splice!(v::Vector{T}, i::Integer) where T
    val = v[Int(i)]
    deleteat!(v, i)
    return val
end

# Julia's repeat(::AbstractChar, r) writes the String's UTF-8 bytes through raw pointers
# (`unsafe_store!` into `pointer(s)`, strings/string.jl:573); a WT String is a GC byte array.
# This writes the same bytes: the char's UTF-8 encoding r times, ArgumentError for r < 0.
# parity(quarantine: Julia's repeat(::Char) stores into a String through raw pointers; a WT
# String is a GC byte array with no address.)
@overlay WASM_METHOD_TABLE function Base.repeat(c::Char, n::Int)
    n < 0 && throw(ArgumentError("can't repeat a character $n times"))
    n == 0 && return ""
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

# Base._unsetindex!(::MemoryRef{T}) clears a freed slot: a bits element keeps its bits, an
# isbits-union slot keeps its value, and any other slot is nulled (`atomic_pointerset(p,
# C_NULL)`, which WT lowers to storing null, so `isassigned` then reads it unset). Base
# decides which by reading the Memory's host layout (datatype_arrayelem, datatype_layoutsize),
# which WT does not fold, so the decision is made here from T itself; the clearing store is
# Julia's own.
# parity(quarantine: Base._unsetindex! selects its clearing by reading host layout metadata;
# the same selection follows from T, as dart's GrowableList.length= nulls freed slots,
# list.dart:611.)
@overlay WASM_METHOD_TABLE function Base._unsetindex!(A::MemoryRef{T}) where T
    (isbitstype(T) || Base.isbitsunion(T)) && return A
    Core.Intrinsics.atomic_pointerset(Ptr{Ptr{Cvoid}}(pointer(A)), C_NULL, :monotonic)
    return A
end

# ─── String hash Overlay — bit-exact with native Julia ─────────────────────
# Why: Base's hash(::String,::UInt)/hash(::SubString{String},::UInt) reach
#      string bytes through raw pointers (1.12: `ccall(:memhash_seed,...)`
#      over Ptr{UInt8}; 1.13: pointerref(Ptr{UInt32/UInt64}) loads inside the
#      pure-Julia rapidhash `hash_bytes`) — WasmGC has no raw pointers, so the
#      inlined loads stub to unreachable and every Dict{String,...}/
#      Set{String} op traps. A prior version of this overlay used FNV-1a,
#      internally consistent but NOT bit-exact with native — which silently
#      broke any Dict{String,V}/Set{String} CONSTANT built natively and
#      embedded as a compile-time struct.new (its slots array was placed by
#      the native hash; probing it with a different wasm hash landed in the
#      wrong slot and KeyError'd/missed).
# Fix: Overlay hash(::String,::UInt) and hash(::SubString{String},::UInt)
#      with a pure-Julia port of Julia's OWN native algorithm — ground truth,
#      not a WT invention — reading bytes via codeunit(s,i) instead of
#      pointers:
#        1.12 (base/hashing.jl:195-200): `h += memhash_seed; ccall(memhash,
#        UInt, (Ptr{UInt8},Csize_t,UInt32), s, sizeof(s), h % UInt32) + h`
#        where C `memhash_seed` (support/hashing.c) is
#        `MurmurHash3_x64_128(buf, n, seed, out); return out[1]`
#        (support/MurmurHash3.c, JuliaLang/julia @ v1.12.7). Ported straight
#        over codeunit reads — verified bit-exact against the live
#        `ccall(:memhash_seed,...)` over every length 0..64, every 16-byte
#        tail-remainder class (0..15) crossed with 0..3 leading full blocks,
#        ASCII/binary/non-ASCII UTF-8, 7 fixed + 200 random seeds, exhaustive
#        SubString slices of a 90-codepoint string, and the full hash(s,h)
#        formula (6537 cases total, 0 mismatches).
#        1.13 (base/hashing.jl): `hash_bytes(pointer(s), sizeof(s),
#        UInt64(h), HASH_SECRET)`, an adaptation of rapidhash. Ported the
#        same way (codeunit reads); the 64×64→128 multiply (`mul_parts`/
#        `hash_mix`) is done with plain UInt64 arithmetic (32-bit-half
#        decomposition) instead of Int128/widemul, so it rests only on
#        integer ops WT already lowers everywhere — independently verified
#        against native `widemul` (5064 cases) and the full port verified
#        bit-exact against native `Base.hash` (16000 cases: every length
#        0..80, the <=16/>16 and 4/8/16/32/48-byte boundary classes, non-ASCII,
#        500 random (h,len) pairs, and exhaustive SubString slices of a
#        140+-byte string — 0 mismatches).
#      grep of Base (1.12.7 and 1.13.0-rc1) confirms String/SubString{String}
#      hash are the ONLY callers of memhash/memhash_seed/hash_bytes for
#      strings (1.13's gmp.jl also calls hash_bytes, for BigInt — unrelated,
#      out of WT's scope), so overlaying these two methods makes the
#      `:memhash` foreigncall and the hash_bytes pointer path unreachable for
#      every string-hashing call site.
# Remove when: codegen supports wide pointerref loads traced to string refs
#      (only relevant if some future Base version routes a THIRD caller
#      through memhash/hash_bytes for strings).

@inline function _wasm_rotl64(x::UInt64, r::Int)::UInt64
    return (x << r) | (x >> (64 - r))
end

# The bytes memhash reads: a string's codeunits, or a byte vector (an immutable value's bits,
# _wasm_bits_hash).
# parity(quarantine: C memhash_seed reads the bytes through a pointer, support/MurmurHash3.c)
@inline _wasm_mm3_byte(s::AbstractString, i::Int)::UInt8 = codeunit(s, i)
# parity(quarantine: C memhash_seed reads the bytes through a pointer, support/MurmurHash3.c)
@inline _wasm_mm3_byte(v::Vector{UInt8}, i::Int)::UInt8 = @inbounds v[i]
# parity(quarantine: C memhash_seed takes the byte count, support/MurmurHash3.c)
@inline _wasm_mm3_len(s::AbstractString)::Int = ncodeunits(s)
# parity(quarantine: C memhash_seed takes the byte count, support/MurmurHash3.c)
@inline _wasm_mm3_len(v::Vector{UInt8})::Int = length(v)

# parity(quarantine: C memhash_seed reads the bytes through a pointer, support/MurmurHash3.c;
# here a little-endian word is read over codeunits)
@inline function _wasm_mm3_load_u64(s, start::Int, nbytes::Int)::UInt64
    v = UInt64(0)
    i = 0
    while i < nbytes
        v |= UInt64(_wasm_mm3_byte(s, start + i)) << (8 * i)
        i += 1
    end
    return v
end

# parity(quarantine: MurmurHash3's fmix64 finalizer, support/MurmurHash3.c)
@inline function _wasm_mm3_fmix64(k::UInt64)::UInt64
    k ⊻= k >> 33
    k *= 0xff51afd7ed558ccd
    k ⊻= k >> 33
    k *= 0xc4ceb9fe1a85ec53
    k ⊻= k >> 33
    return k
end

# MurmurHash3_x64_128(buf, n, seed, out) -> out[1], C `memhash_seed` on Julia 1.12 and 1.13:
# 1.12 Base hashes a String with it, and both versions derive a Symbol's hash from it.
# parity(quarantine: Julia's memhash_seed is C, support/hashing.c; ported over codeunit reads)
@noinline function _wasm_memhash_seed(s::Union{String,SubString{String},Vector{UInt8}}, seed::UInt32)::UInt64
    n = _wasm_mm3_len(s)
    c1 = 0x87c37b91114253d5
    c2 = 0x4cf5ad432745937f
    h1 = UInt64(seed)
    h2 = UInt64(seed)

    nblocks = n >> 4   # div(n, 16)
    blk = 0
    while blk < nblocks
        base = blk * 16 + 1
        k1 = _wasm_mm3_load_u64(s, base, 8)
        k2 = _wasm_mm3_load_u64(s, base + 8, 8)

        k1 *= c1
        k1 = _wasm_rotl64(k1, 31)
        k1 *= c2
        h1 ⊻= k1
        h1 = _wasm_rotl64(h1, 27)
        h1 += h2
        h1 = h1 * 5 + 0x52dce729

        k2 *= c2
        k2 = _wasm_rotl64(k2, 33)
        k2 *= c1
        h2 ⊻= k2
        h2 = _wasm_rotl64(h2, 31)
        h2 += h1
        h2 = h2 * 5 + 0x38495ab5

        blk += 1
    end

    tailstart = nblocks * 16
    rem = n - tailstart

    if rem >= 9
        k2 = _wasm_mm3_load_u64(s, tailstart + 9, rem - 8)
        k2 *= c2
        k2 = _wasm_rotl64(k2, 33)
        k2 *= c1
        h2 ⊻= k2
    end
    if rem >= 1
        nb = rem >= 8 ? 8 : rem
        k1 = _wasm_mm3_load_u64(s, tailstart + 1, nb)
        k1 *= c1
        k1 = _wasm_rotl64(k1, 31)
        k1 *= c2
        h1 ⊻= k1
    end

    h1 ⊻= UInt64(n)
    h2 ⊻= UInt64(n)
    h1 += h2
    h2 += h1
    h1 = _wasm_mm3_fmix64(h1)
    h2 = _wasm_mm3_fmix64(h2)
    h1 += h2
    h2 += h1

    return h2
end

@static if VERSION < v"1.13.0-"
    const _WASM_MEMHASH_SEED = 0x71e729fd56419c81

    @noinline function _wasm_hash_string(s::Union{String,SubString{String}}, h::UInt)::UInt
        h2 = h + _WASM_MEMHASH_SEED
        return (_wasm_memhash_seed(s, h2 % UInt32) + h2) % UInt
    end

    # parity(quarantine: Julia 1.12's hash of a String calls C memhash_seed over the bytes' address, support/hashing.c; this is the same algorithm over code units.)
    @overlay WASM_METHOD_TABLE function Base.hash(s::String, h::UInt)
        return _wasm_hash_string(s, h)
    end
    # parity(quarantine: Julia 1.12's hash of a String calls C memhash_seed over the bytes' address, support/hashing.c; this is the same algorithm over code units.)
    @overlay WASM_METHOD_TABLE function Base.hash(s::SubString{String}, h::UInt)
        return _wasm_hash_string(s, h)
    end
else
    # rapidhash hash_bytes(ptr, n, seed, secret) -> UInt (1.13+ Base), ported
    # over codeunit reads; the widening multiply avoids Int128/widemul (see
    # comment above).
    @inline function _wasm_rh_umul128(a::UInt64, b::UInt64)::Tuple{UInt64,UInt64}
        a_lo = a & 0x00000000ffffffff
        a_hi = a >> 32
        b_lo = b & 0x00000000ffffffff
        b_hi = b >> 32

        lo_lo = a_lo * b_lo
        hi_lo = a_hi * b_lo
        lo_hi = a_lo * b_hi
        hi_hi = a_hi * b_hi

        cross = (lo_lo >> 32) + (hi_lo & 0x00000000ffffffff) + (lo_hi & 0x00000000ffffffff)
        hi = hi_hi + (hi_lo >> 32) + (lo_hi >> 32) + (cross >> 32)
        lo = (cross << 32) | (lo_lo & 0x00000000ffffffff)
        return hi, lo
    end

    @inline function _wasm_rh_mix(a::UInt64, b::UInt64)::UInt64
        hi, lo = _wasm_rh_umul128(a, b)
        return hi ⊻ lo
    end

    @inline function _wasm_rh_load_le64(s, i::Int)::UInt64
        v = UInt64(0)
        j = 0
        while j < 8
            v |= UInt64(codeunit(s, i + j)) << (8 * j)
            j += 1
        end
        return v
    end

    @inline function _wasm_rh_load_le32(s, i::Int)::UInt64
        v = UInt64(0)
        j = 0
        while j < 4
            v |= UInt64(codeunit(s, i + j)) << (8 * j)
            j += 1
        end
        return v
    end

    @noinline function _wasm_hash_bytes(s::Union{String,SubString{String}}, seed_in::UInt64,
                                         secret::NTuple{4,UInt64})::UInt64
        n = ncodeunits(s)
        buflen = UInt64(n)
        seed = seed_in ⊻ _wasm_rh_mix(seed_in ⊻ secret[3], secret[2])

        a = UInt64(0)
        b = UInt64(0)
        i = buflen

        if buflen <= 16
            if buflen >= 4
                seed ⊻= buflen
                if buflen >= 8
                    a = _wasm_rh_load_le64(s, 1)
                    b = _wasm_rh_load_le64(s, n - 7)
                else
                    a = _wasm_rh_load_le32(s, 1)
                    b = _wasm_rh_load_le32(s, n - 3)
                end
            elseif buflen > 0
                a = (UInt64(codeunit(s, 1)) << 45) | UInt64(codeunit(s, n))
                b = UInt64(codeunit(s, div(n, 2) + 1))
            end
        else
            pos = 1
            if i > 48
                see1 = seed
                see2 = seed
                while i > 48
                    seed = _wasm_rh_mix(_wasm_rh_load_le64(s, pos) ⊻ secret[1], _wasm_rh_load_le64(s, pos + 8) ⊻ seed)
                    see1 = _wasm_rh_mix(_wasm_rh_load_le64(s, pos + 16) ⊻ secret[2], _wasm_rh_load_le64(s, pos + 24) ⊻ see1)
                    see2 = _wasm_rh_mix(_wasm_rh_load_le64(s, pos + 32) ⊻ secret[3], _wasm_rh_load_le64(s, pos + 40) ⊻ see2)
                    pos += 48
                    i -= 48
                end
                seed ⊻= see1
                seed ⊻= see2
            end
            if i > 16
                seed = _wasm_rh_mix(_wasm_rh_load_le64(s, pos) ⊻ secret[3], _wasm_rh_load_le64(s, pos + 8) ⊻ seed)
                if i > 32
                    seed = _wasm_rh_mix(_wasm_rh_load_le64(s, pos + 16) ⊻ secret[3], _wasm_rh_load_le64(s, pos + 24) ⊻ seed)
                end
            end

            a = _wasm_rh_load_le64(s, n - 15) ⊻ i
            b = _wasm_rh_load_le64(s, n - 7)
        end

        a = a ⊻ secret[2]
        b = b ⊻ seed
        b, a = _wasm_rh_umul128(a, b)
        return _wasm_rh_mix(a ⊻ secret[4], b ⊻ secret[2] ⊻ i)
    end

    @noinline function _wasm_hash_string(s::Union{String,SubString{String}}, h::UInt)::UInt
        return _wasm_hash_bytes(s, UInt64(h), Base.HASH_SECRET) % UInt
    end

    # parity(quarantine: Julia 1.13's rapidhash of a String loads the bytes through pointerref at their address; this is the same algorithm over code units.)
    @overlay WASM_METHOD_TABLE function Base.hash(s::String, h::UInt)
        return _wasm_hash_string(s, h)
    end
    # parity(quarantine: Julia 1.13's rapidhash of a String loads the bytes through pointerref at their address; this is the same algorithm over code units.)
    @overlay WASM_METHOD_TABLE function Base.hash(s::SubString{String}, h::UInt)
        return _wasm_hash_string(s, h)
    end
end

# ─── Symbol objectid Overlay — bit-exact with native Julia ─────────────────
# Why: Julia interns Symbols, and objectid(::Symbol) (hence hash(::Symbol) and every
#      Dict{Symbol}/Set{Symbol} slot) is jl_object_id reading the interned jl_sym_t's
#      `hash`, which symbol.c `hash_symbol` derives from the name alone:
#      `int64hash(-(memhash(name) ⊻ 0xaaaaaaaaaaaaaaaa))`, `memhash` being
#      `memhash_seed(·, 0xcafe8881)` (measured equal to native objectid on 1.12.7 and
#      1.13.0). WT builds a fresh Symbol object per `Symbol(...)` call, so the lowered
#      jl_object_id (a per-object counter) gave two equal Symbols two ids.

# parity(quarantine: Thomas Wang's int64hash, support/hashing.c, which symbol.c
# hash_symbol applies to the name's memhash)
@inline function _wasm_int64hash(key::UInt64)::UInt64
    key = (~key) + (key << 21)
    key = key ⊻ (key >> 24)
    key = (key + (key << 3)) + (key << 8)
    key = key ⊻ (key >> 14)
    key = (key + (key << 2)) + (key << 4)
    key = key ⊻ (key >> 28)
    key = key + (key << 31)
    return key
end

# parity(sdk/lib/_internal/wasm/common/symbol_patch.dart:34 Symbol.hashCode): a Symbol hashes by its name alone; the
# function is Julia's (symbol.c hash_symbol)
@overlay WASM_METHOD_TABLE function Base.objectid(s::Symbol)
    return _wasm_int64hash(-(_wasm_memhash_seed(String(s), 0xcafe8881) ⊻ 0xaaaaaaaaaaaaaaaa)) % UInt
end

# A String's objectid is its content's hash too: `"ab" === "ab"` holds for two objects,
# and jl_object_id_ (builtins.c) answers `memhash_seed(bytes, len, 0xedc3b677)` for a
# String (measured equal to native objectid on 1.12.7 and 1.13.0).
# parity(quarantine: jl_object_id_ for a String, builtins.c — memhash_seed of the bytes
# seeded 0xedc3b677)
@overlay WASM_METHOD_TABLE Base.objectid(s::String) = _wasm_memhash_seed(s, 0xedc3b677) % UInt

# ─── objectid of an immutable value — Julia's jl_object_id_ ─────────────────
# Why: jl_object_id (builtins.c) answers identity only for a mutable object. An immutable
#      value's objectid is its content's hash (immut_id_): the type's hash (the DataType's
#      `hash`, a uint32) mixed with each field's id, or the bits' hash when the layout is plain
#      bits (no padding, bits-egal, no pointers). Base.hash of any value without its own
#      method is objectid-based, so this is the hash of a user's immutable struct (a Dict or
#      Set key). The lowered jl_object_id gives a mutable object its identity; an immutable
#      reaching it rejects (it once got a per-object counter: two equal keys, two ids).
# Measured equal to native objectid on 1.12.7 and 1.13.0 (test/immutable_objectid.jl).

# parity(quarantine: Thomas Wang's int32hash, support/hashing.c)
@inline function _wasm_int32hash(a::UInt32)::UInt32
    a = (a + 0x7ed55d16) + (a << 12)
    a = (a ⊻ 0xc761c23c) ⊻ (a >> 19)
    a = (a + 0x165667b1) + (a << 5)
    a = (a + 0xd3a2646c) ⊻ (a << 9)
    a = (a + 0xfd7046c5) + (a << 3)
    a = (a ⊻ 0xb55a4f09) ⊻ (a >> 16)
    return a
end

# parity(quarantine: bitmix, support/hashing.h: int64hash(a ^ bswap_64(b)))
@inline _wasm_bitmix(a::UInt64, b::UInt64)::UInt64 = _wasm_int64hash(a ⊻ bswap(b))

# The primitive leaves of a plain-bits layout, each at its byte offset (a primitive value, or a
# struct flattened field by field). The layout has no padding, so the leaves cover every byte.
# parity(quarantine: jl_object_id_ reads an immutable's bytes through a pointer, builtins.c)
function _wasm_bits_leaves(@nospecialize(T), off::Int, path::Vector{Int}, out::Vector{Any})::Vector{Any}
    if isprimitivetype(T)
        push!(out, (off, T, copy(path)))
    else
        for i in 1:fieldcount(T)
            _wasm_bits_leaves(fieldtype(T, i), off + Int(fieldoffset(T, i)), push!(copy(path), i), out)
        end
    end
    return out
end

# The unsigned integer type of a primitive's size, to read its bits
# parity(quarantine: jl_object_id_ reads an immutable's bytes through a pointer, builtins.c)
function _wasm_uint_of_size(n::Int)::DataType
    n == 1 && return UInt8
    n == 2 && return UInt16
    n == 4 && return UInt32
    n == 8 && return UInt64
    n == 16 && return UInt128
    error("_wasm_uint_of_size: no unsigned integer of $n bytes")
end

# bits_hash(v, sz), builtins.c: int32hash of a 1-, 2- or 4-byte value (1 and 2 bytes read
# signed and widened), int64hash of an 8-byte one, memhash (seed 0xcafe8881) of the bytes
# otherwise.
# parity(quarantine: bits_hash, builtins.c)
@generated function _wasm_bits_hash(x::T)::UInt64 where T
    local sz = sizeof(T)
    local leaves = _wasm_bits_leaves(T, 0, Int[], Any[])
    local getleaf(path) = foldl((e, i) -> :(getfield($e, $i)), path; init=:x)
    # the value's bits as a UInt64 (sizes up to 8)
    local bits = Expr(:call, :|, UInt64(0),
        (:(UInt64(reinterpret($(_wasm_uint_of_size(sizeof(LT))), $(getleaf(path)))) << $(8off))
         for (off, LT, path) in leaves)...)
    if sz == 1
        return :(UInt64(_wasm_int32hash(reinterpret(UInt32, Int32(($bits % UInt8) % Int8)))))
    elseif sz == 2
        return :(UInt64(_wasm_int32hash(reinterpret(UInt32, Int32(($bits % UInt16) % Int16)))))
    elseif sz == 4
        return :(UInt64(_wasm_int32hash($bits % UInt32)))
    elseif sz == 8
        return :(_wasm_int64hash($bits))
    end
    local body = Expr(:block, :(bytes = Vector{UInt8}(undef, $sz)))
    for (off, LT, path) in leaves
        local nb = sizeof(LT)
        push!(body.args, :(w = reinterpret($(_wasm_uint_of_size(sizeof(LT))), $(getleaf(path)))))
        for k in 0:nb-1
            push!(body.args, :(@inbounds bytes[$(off + k + 1)] = (w >> $(8k)) % UInt8))
        end
    end
    push!(body.args, :(return _wasm_memhash_seed(bytes, 0xcafe8881)))
    return body
end

# immut_id_(dt, v, h), builtins.c: ~h for a zero-size value; the bits' hash xor h for a
# plain-bits layout; else h mixed (bitmix) with each field's id -- a pointer field's objectid
# (0 when undefined), an inline field's own immut_id_ from 0 (a Union field by the value's
# component; 0 when the inline field is undefined).
# parity(quarantine: immut_id_, builtins.c)
@generated function _wasm_immut_id(x::T, h::UInt64)::UInt64 where T
    sizeof(T) == 0 && return :(~h)
    if fieldcount(T) == 0 || (!Base.datatype_haspadding(T) && Base.datatype_isbitsegal(T) &&
                              Base.datatype_pointerfree(T))
        return :(_wasm_bits_hash(x) ⊻ h)
    end
    local body = Expr(:block, :(acc = h))
    for i in 1:fieldcount(T)
        local FT = fieldtype(T, i)
        local u = Base.allocatedinline(FT) ?
            :(isdefined(x, $i) ? _wasm_immut_id(getfield(x, $i), UInt64(0)) : UInt64(0)) :
            :(isdefined(x, $i) ? UInt64(objectid(getfield(x, $i))) : UInt64(0))
        push!(body.args, :(acc = _wasm_bitmix(acc, $u)))
    end
    push!(body.args, :(return acc))
    return body
end

# The one objectid: a mutable object's identity is the lowered jl_object_id; an immutable
# value's is its content's hash from its type's own hash (String and Symbol have their own
# methods above). It stays a call, as Julia's foreigncall is: Base.dataids compares a
# storage address against it, which _is_never_a_storage_pointer (statements.jl) recognizes
# by the call.
# parity(quarantine: jl_object_id__cold, builtins.c: identity for a mutable object, immut_id_
# from dt->hash for an immutable one)
@overlay WASM_METHOD_TABLE @noinline function Base.objectid(x::T)::UInt where T
    ismutabletype(T) && return ccall(:jl_object_id, UInt, (Any,), x)
    return _wasm_immut_id(x, _wasm_type_hash(T)) % UInt
end

# dt->hash, a uint32 the DataType carries (read on the host: a literal in the module)
# parity(quarantine: jl_datatype_t's hash field, julia.h)
@generated function _wasm_type_hash(::Type{T})::UInt64 where T
    return :(UInt64($(UInt64(reinterpret(UInt32, getfield(T, :hash))))))
end

# ─── Operator-name predicates Overlay — Julia's parser answer for any name ──
# Why: Base._isoperator and Base.is_syntactic_operator are the foreigncalls
#      jl_is_operator / jl_is_syntactic_operator (ast.c), which ask the flisp parser
#      (julia-parser.scm, identical in 1.12.7 and 1.13.0): `syntactic-op?` is membership
#      in a fixed list, and `operator?` is membership in the fixed `operators` list after
#      `maybe-strip-op-suffix` — strip-op-suffix (flisp/julia_extensions.c) cuts the name
#      at its first jl_op_suffix_char codepoint, decoded by u8_nextchar (support/utf8.c),
#      and the cut name is used unless nothing was cut, the cut is at 0, or the cut name
#      is in `no-suffix?`. WasmGC has no parser at run time, so the tables are Julia's own
#      answers, read at build time: the candidates are Julia's token names
#      (JuliaSyntax kinds), each optionally dotted and optionally followed by `=`, and each
#      with any character replaced by one Julia's charmap normalizes to it
#      (Base.Unicode._julia_charmap); an operator is a candidate jl_is_operator accepts
#      that holds no suffix character, and it takes no suffix when jl_is_operator rejects
#      it followed by ′ (U+2032, a suffix character). The derived sets equal the parser's
#      own `operators` (1307) and `syntactic-operators` (41) as `julia --lisp` prints them
#      on 1.12.7 and 1.13.0 (test/symbol_syntax_metadata.jl pins this). A name is packed
#      little-endian into a UInt64 (operators are at most 5 bytes and hold no NUL) and
#      looked up in the sorted tables.

# parity(quarantine: jl_op_suffix_char, flisp/julia_extensions.c — every codepoint it accepts)
const _WT_OP_SUFFIX_CHARS = UInt32[cp for cp in UInt32(0xA1):UInt32(0x10ffff)
                                   if ccall(:jl_op_suffix_char, Cint, (UInt32,), cp) != 0]

# parity(quarantine: the operator name packed as the parser's table key, little-endian bytes)
function _wt_pack_name(s::String, n::Int)::UInt64
    v = UInt64(0)
    i = 1
    while i <= n
        v |= UInt64(codeunit(s, i)) << (8 * (i - 1))
        i += 1
    end
    return v
end

# parity(quarantine: the operator candidates are Julia's own token names, JuliaSyntax kinds,
# dotted, with `=` appended, and under Julia's charmap normalization)
const _WT_OP_CANDIDATES = let names = collect(values(Base.JuliaSyntax._kind_int_to_str))
    local plain = unique(vcat(names, ["." * s for s in names]))
    local cands = unique(vcat(plain, [s * "=" for s in plain]))
    local preimage = Dict{Char,Vector{Char}}()
    for (k, v) in sort!(collect(Base.Unicode._julia_charmap))
        push!(get!(preimage, Char(v), Char[]), Char(k))
    end
    local variants = String[]
    for s in cands
        local cs = collect(s)
        for i in eachindex(cs), k in get(preimage, cs[i], Char[])
            local alt = copy(cs)
            alt[i] = k
            push!(variants, String(alt))
        end
    end
    String[s for s in unique(vcat(cands, variants)) if 1 <= ncodeunits(s) <= 8 && !occursin('\0', s)]
end
# parity(quarantine: julia-parser.scm `operators`, read through jl_is_operator)
const _WT_OPERATORS = sort!(unique(UInt64[_wt_pack_name(s, ncodeunits(s)) for s in _WT_OP_CANDIDATES
    if ccall(:jl_is_operator, Cint, (Cstring,), s) != 0 &&
       !any(c -> isvalid(c) && ccall(:jl_op_suffix_char, Cint, (UInt32,), UInt32(c)) != 0, s)]))
# parity(quarantine: julia-parser.scm `no-suffix?` over `operators`, read through jl_is_operator)
const _WT_NO_SUFFIX_OPERATORS = let unpack(v::UInt64)::String = String(UInt8[(v >> (8 * i)) % UInt8 for i in 0:7
                                                           if (v >> (8 * i)) % UInt8 != 0x00])
    UInt64[v for v in _WT_OPERATORS if ccall(:jl_is_operator, Cint, (Cstring,), unpack(v) * "′") == 0]
end
# parity(quarantine: julia-parser.scm `syntactic-operators`, read through jl_is_syntactic_operator)
const _WT_SYNTACTIC_OPERATORS = sort!(unique(UInt64[_wt_pack_name(s, ncodeunits(s)) for s in _WT_OP_CANDIDATES
    if ccall(:jl_is_syntactic_operator, Cint, (Cstring,), s) != 0]))

# parity(quarantine: membership in one of the parser's sorted tables)
function _wt_in_sorted(table::Vector{T}, x::T)::Bool where {T}
    lo, hi = 1, length(table)
    while lo <= hi
        mid = (lo + hi) >>> 1
        @inbounds v = table[mid]
        v == x && return true
        v < x ? (lo = mid + 1) : (hi = mid - 1)
    end
    return false
end

# parity(quarantine: strip-op-suffix, flisp/julia_extensions.c, decoding by u8_nextchar,
# support/utf8.c — the byte count before the first suffix codepoint; a byte past the end
# reads as the terminating NUL)
function _wt_op_suffix_start(s::String)::Int
    n = ncodeunits(s)
    i = 0
    while i < n
        b0 = codeunit(s, i + 1)
        sz = b0 < 0xc0 ? 1 : b0 < 0xe0 ? 2 : b0 < 0xf0 ? 3 : b0 < 0xf8 ? 4 : b0 < 0xfc ? 5 : 6
        ch = UInt32(0)
        j = i
        k = 0
        while k < sz
            ch = (ch << 6) + UInt32(j < n ? codeunit(s, j + 1) : 0x00)
            j += 1
            k += 1
        end
        ch -= sz == 1 ? 0x00000000 : sz == 2 ? 0x00003080 : sz == 3 ? 0x000E2080 :
              sz == 4 ? 0x03C82080 : sz == 5 ? 0xFA082080 : 0x82082080
        _wt_in_sorted(_WT_OP_SUFFIX_CHARS, ch) && return i
        i = j
    end
    return n
end

# parity(quarantine: julia-parser.scm `operator?`, the SuffSet over `operators`)
function _wt_parser_is_operator(s::String)::Bool
    n = ncodeunits(s)
    i = _wt_op_suffix_start(s)
    if i == n || i == 0
        return n <= 8 && _wt_in_sorted(_WT_OPERATORS, _wt_pack_name(s, n))
    end
    i <= 8 || return false
    p = _wt_pack_name(s, i)
    return _wt_in_sorted(_WT_OPERATORS, p) && !_wt_in_sorted(_WT_NO_SUFFIX_OPERATORS, p)
end

# parity(quarantine: julia-parser.scm `syntactic-op?`, membership in `syntactic-operators`)
function _wt_parser_is_syntactic_operator(s::String)::Bool
    n = ncodeunits(s)
    return n <= 8 && _wt_in_sorted(_WT_SYNTACTIC_OPERATORS, _wt_pack_name(s, n))
end

# parity(quarantine: jl_is_operator over a Symbol's name, ast.c; symbols hold no NUL)
@overlay WASM_METHOD_TABLE Base._isoperator(s::Symbol) = _wt_parser_is_operator(String(s))
# parity(quarantine: jl_is_operator over a string passed as a Cstring, strings/cstring.jl
# unsafe_convert: an embedded NUL throws)
@overlay WASM_METHOD_TABLE function Base._isoperator(s::AbstractString)
    str = String(s)::String
    Base.containsnul(str) &&
        throw(ArgumentError("embedded NULs are not allowed in C strings: $(repr(str))"))
    return _wt_parser_is_operator(str)
end
# parity(quarantine: jl_is_syntactic_operator over a Symbol's name, ast.c)
@overlay WASM_METHOD_TABLE Base.is_syntactic_operator(s::Symbol) =
    _wt_parser_is_syntactic_operator(String(s))


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
@generated function _wt_type_name_str(::Type{T})::String where {T}
    return :($(string(T)))
end

# parity(quarantine: Julia's show of a Type walks its TypeName and module bindings at run time, show_datatype, a reflection world WT does not compile; the text is Julia's own string(T), taken at compile time.)
@overlay WASM_METHOD_TABLE Base.string(::Type{T}) where {T} = _wt_type_name_str(T)

# Base.print(io, x::Type) reaches show through a deliberately unspecialized
# argument and loses the concrete Type{T}. Preserve that static parameter at the
# overlay boundary so generated type-name metadata never becomes runtime data.
# parity(quarantine: Julia's show of a Type walks its TypeName and module bindings at run time, show_datatype, a reflection world WT does not compile; the text is Julia's own string(T), taken at compile time.)
@overlay WASM_METHOD_TABLE function Base.print(io::IO, ::Type{T}) where {T}
    print(io, _wt_type_name_str(T))
    return nothing
end

# parity(quarantine: Julia's show of a Type walks its TypeName and module bindings at run time, show_datatype, a reflection world WT does not compile; the text is Julia's own string(T), taken at compile time.)
@overlay WASM_METHOD_TABLE function Base.show(io::IO, ::Type{T}) where {T}
    print(io, _wt_type_name_str(T))
    return nothing
end

# Concrete 2-arg specializations: the Vararg method's invoke widens elements
# to the Union (heterogeneous-union tuple reads still miscompile — the
# hetero-Dict class), so give inference concrete signatures to prefer for the
# common mixed pairs ("m" * substring, str * char, ...).
@inline function _wasm_append_str!(out::Vector{UInt8}, s::Union{String, SubString{String}})::Vector{UInt8}
    for i in 1:ncodeunits(s)
        push!(out, codeunit(s, i))
    end
    return out
end
@inline function _wasm_append_char!(out::Vector{UInt8}, c::Char)::Vector{UInt8}
    u = reinterpret(UInt32, c)
    nb = u == 0x00000000 ? 1 : (4 - (trailing_zeros(u) >> 3))
    i = 1
    while i <= nb
        push!(out, UInt8((u >> (8 * (4 - i))) & 0xFF))
        i += 1
    end
    return out
end


# On 1.13 Julia inlines in(::UInt8/Int8, dense byte vector)'s findfirst into a C memchr over
# the vector's memory (pointer.jl:77), a raw pointer WT does not lower; on 1.12 Julia's own
# body compiles. These are the same membership as a loop over the elements.
# parity(quarantine: Julia 1.13 finds a byte through a C memchr over the vector's memory; a WT
# vector has no address.)
@static if VERSION >= v"1.13-"
    # parity(quarantine: Julia 1.13's memchr over the vector's memory, as above.)
    @overlay WASM_METHOD_TABLE function Base.in(a::UInt8, b::Base.DenseUInt8)
        for x in b
            x == a && return true
        end
        return false
    end
    # parity(quarantine: as above, Julia 1.13's memchr.)
    @overlay WASM_METHOD_TABLE function Base.in(a::Int8, b::Base.DenseInt8)
        for x in b
            x == a && return true
        end
        return false
    end
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

function WasmInterpreter(; world::UInt=Base.get_world_counter())::WasmInterpreter
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

function WasmInterpreter(cache_token; world::UInt=Base.get_world_counter())::WasmInterpreter
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

# Disable concrete eval by default (GPUCompiler pattern): without any override
# here, a WasmInterpreter would fold calls using Base's real implementation and
# bypass overlays. `CC.concrete_eval_eligible` below re-enables it PER CALL, by
# RULE rather than by an enumerated list of function names: trust Julia's own
# effect system — `is_foldable` + all-const args + overlay-safety, exactly
# what `Core.Compiler.concrete_eval_eligible` already computes — to decide
# WHETHER a call folds, then apply two result-level guards that a compiler
# producing a module meant to outlive this process needs on top of Julia's own
# answer:
#
#  1. NEVER `:semi_concrete_eval`, unconditionally. Native eligibility gates
#     `:concrete_eval` on overlay-safety but does NOT gate `:semi_concrete_eval`
#     on it at all (`Compiler/src/abstractinterpretation.jl`), so an
#     overlay-tainted-but-otherwise-foldable call silently falls through to
#     it. Unlike `:concrete_eval` — which executes the call exactly once via
#     `Core._call_in_world_total` and keeps only the returned VALUE —
#     `:semi_concrete_eval` partially interprets the callee's own optimized
#     IR, and on that path a `getfield` of an opaque/pointer-typed `DataType`
#     field (e.g. `.layout`) gets folded to the live pointer itself —
#     something ordinary type inference's `getfield` tfunc deliberately
#     refuses (it types `.layout` as widened `Ptr{Nothing}`, never `Const`,
#     for exactly this reason; confirmed by dumping this file's own baseline
#     IR). REPRODUCED 2026-09-07: broadening eligibility to "constant args are
#     all Type/Symbol/Integer" (the prior attempt recorded by a teammate) made
#     `Base.datatype_arrayelem(Memory{UInt8})` — reached from
#     `copy(::Memory{UInt8})` — take this path and left
#     `pointerref($(QuoteNode(Ptr{DataTypeLayout}(0x0000000128c43628))), 1, 1)`
#     — a live host address baked as a literal IR operand — in the typed IR
#     (`WasmTarget.get_typed_ir`). Refusing `:semi_concrete_eval` outright
#     (independent of the eligibility predicate that reached it) closes this;
#     `:concrete_eval` alone never has the failure mode because it never
#     exposes intermediate pointer arithmetic, only the callee's final value.
#  2. Never a `Ptr`-typed result, never a `Ptr`-valued constant argument, and
#     never `objectid`/`hash`. A folded call's result must be a PROGRAM value.
#     `Ptr` is a host memory address, never portable. `Base.objectid` (the generic `hash` fallbacks that call it, and the
#     `Type`-hash helper `hash(::Type, ::UInt)` is built on) are marked fully
#     `:consistent`+`:nothrow`+`:effect_free` by Julia's own effect system
#     (verified with `Base.infer_effects`) — yet `hash`'s docstring states
#     outright: "The hash value may change when a new Julia process is
#     started." `:consistent` means reproducible within ONE world, not across
#     the separate processes and architectures a compiled module must run on.
#
# `:concrete_eval` itself already tolerates a call that isn't `:nothrow` (e.g.
# `apply_type`, `nonmissingtype` — both foldable but NOT nothrow per
# `infer_effects`, and both load-bearing for the `cor`/SparseArrays type-level
# fold that motivated the original curated list): if the real execution throws,
# `concrete_eval_call` discards the value and the call's type becomes `Bottom`
# (dead code), never a bad value. So nothrow is not required here — `is_foldable`
# (which already excludes any externally-visible side effect), overlay-safety,
# and the two result guards above are what make this safe.
# The VALUE a fold produces must be a program value — one the module can carry as a
# constant and that means the same thing in every process and on every architecture:
# a Type, a Symbol, a String, a Char, nothing/missing, a Bool or a non-pointer Number,
# a singleton, or an isbits aggregate / tuple of those with no Ptr anywhere inside.
# A host memory address (`Ptr`, including one riding inside a struct) is none of
# these. This is checked on the value itself, after evaluation: eligibility runs
# before the call, and a result typed `Any` (getproperty on a DataType) or an
# address already bit-cast to an integer would pass any type-level test.
function _wt_has_pointer_field(@nospecialize(T))::Bool
    T isa DataType || return true
    T <: Ptr && return true
    for ft in fieldtypes(T)
        _wt_has_pointer_field(ft) && return true
    end
    return false
end
function _wt_program_value(@nospecialize(v))::Bool
    v isa Type && return true
    v isa Symbol && return true
    v isa String && return true
    v isa Char && return true
    (v === nothing || v === missing) && return true
    v isa Ptr && return false
    v isa Number && return true
    v isa Tuple && return all(_wt_program_value, v)
    T = typeof(v)
    Base.issingletontype(T) && return true
    return isbits(v) && !_wt_has_pointer_field(T)
end

# `objectid`/`hash` (and the Type-hash helper they build on) are `:consistent` by
# Julia's effect system — reproducible within ONE process — yet "may change when a
# new Julia process is started" (hash's own docstring): not program values.
function _wt_host_identity_fold(@nospecialize(f))::Bool
    f === Base.objectid && return true
    f === Base.hash && return true
    isdefined(Base, :_jl_type_hash) && f === Base._jl_type_hash && return true
    return false
end

# `_wt_type_name_str` is a `@generated` function that exists solely to bake
# the name of a statically known type into the module (feeds the
# `Base.string(::Type)` overlay below). Force it through concrete-eval
# regardless of what native eligibility computes for a generated function's
# synthesized body: letting its generator-staging machinery
# (`Core._compute_sparams` and friends, used to resolve the static parameter)
# leak into the IR as if it were ordinary user code would turn compiler
# metadata into runtime data. The one genuinely special case left, with a
# reason: everything else is the general rule above.
_wt_forced_concrete_eval(@nospecialize(f))::Bool = f === _wt_type_name_str

function CC.concrete_eval_eligible(interp::WasmInterpreter,
        @nospecialize(f), result::CC.MethodCallResult, arginfo::CC.ArgInfo,
        sv::Union{CC.InferenceState, CC.IRInterpretationState})
    eligibility = @invoke CC.concrete_eval_eligible(interp::CC.AbstractInterpreter,
                                                     f, result, arginfo, sv)
    if _wt_forced_concrete_eval(f)
        return eligibility === :none ? :none : :concrete_eval
    elseif eligibility !== :concrete_eval
        return :none   # never :semi_concrete_eval
    elseif _wt_host_identity_fold(f)
        return :none
    elseif !_wt_type_level_call(arginfo.argtypes, result.rt)
        return :none
    elseif _wt_reads_host_layout(result.edge)
        return :none
    end
    return :concrete_eval
end

# A fold may not depend on the HOST's memory layout of a type. `datatype_layoutsize`,
# `datatype_alignment`, `fieldoffset`, `datatype_pointerfree`, `Core.sizeof(::Type)` …
# are `@assume_effects :total` in Base and read `DataType.layout` — the host ABI's
# sizes, not the module's (WT lays out its own structs and arrays; e.g.
# memory_element_stride is the element stride the wasm side uses). `isbitstype` and
# its kin read `DataType.flags`, a property of the Julia type, and stay foldable. A
# foreigncall into libjulia (`allocatedinline` → jl_stored_inline) answers for the host
# too. Decided mechanically from the callee's own typed IR (the one inference path),
# transitively through its invokes, memoized per specialization.
function _wt_reads_host_layout(@nospecialize(edge))::Bool
    edge isa Core.CodeInstance || return true    # no edge to inspect: never fold blind
    return ir_reads_host_layout(edge)
end

# WT folds TYPE-LEVEL calls only — a call with a Type among its constant arguments, or
# one whose result is a Type: the runtime type machinery (apply_type, promote_type,
# isbitstype, eltype, datatype_layoutsize, isinplace …) that the module cannot carry as
# values and MUST resolve at compile time. Value-level constant arithmetic
# (`1 + 2`, tuple destructuring of a constant, `Val(1)`) is left to Julia's own
# constant propagation, exactly as before: folding it too changed inlining decisions
# downstream (SparseArrays' hvcat_internal stopped inlining and reached a runtime
# Vararg splat WT has no lowering for) without any type-level need.
function _wt_type_level_call(argtypes::Vector{Any}, @nospecialize(rt))::Bool
    for i in 2:length(argtypes)
        local a = argtypes[i]
        a isa CC.Const && a.val isa Type && return true
        (a isa Type && a <: Type && a !== Type) && return true    # Type{T} / Const-like singleton
    end
    local w = CC.widenconst(rt)
    return w <: Type && w !== Type
end

# The value-level half of the rule ("allow external abstract interpreters to disable
# concrete evaluation ad-hoc" — Compiler/src/abstractinterpretation.jl): evaluate as
# Julia would, then keep the fold only when what came back is a program value.
function CC.concrete_eval_call(interp::WasmInterpreter,
        @nospecialize(f), result::CC.MethodCallResult, arginfo::CC.ArgInfo,
        sv::Union{CC.InferenceState, CC.IRInterpretationState},
        invokecall::Union{CC.InvokeCall, Nothing}=nothing)
    r = @invoke CC.concrete_eval_call(interp::CC.AbstractInterpreter, f, result, arginfo, sv, invokecall)
    r === nothing && return nothing
    rt = r.rt
    rt isa CC.Const && !_wt_program_value(rt.val) && return nothing
    return r
end

"""
    get_wasm_interpreter() -> WasmInterpreter

Create a WasmInterpreter with overlay method table for the current world age.
Must be called after all user functions are defined (so they're visible to inference).
"""
get_wasm_interpreter()::WasmInterpreter = WasmInterpreter(; world=Base.get_world_counter())
