# String's byte-level operations by overlay (the String ruling, src/julia/classes.jl
# _string_instance_fields): Base reads and writes a String through a raw pointer (Core.sizeof of its
# memory, pointer(s, i) loads, jl_alloc_string, unsafe_copyto!), and WasmGC has no raw memory, so each
# such method is replaced in WasmTarget's overlay method table (METHOD_TABLE, src/julia/interpreter.jl) by one written against the
# String's data through dart:_wasm's array operations (src/julia/wasm_array.jl), as dart's own string
# patches read and write their WasmArray. Each overlay is consistent: natively it computes Base's
# answer. precedent(dart: the wasm target's @patch libraries, sdk/lib/_internal/wasm; gpucompiler: a
# device's overlays of Base in its method table).

@quarantine "Base's ncodeunits is Core.sizeof of the String's memory; WasmGC has no raw memory, so it is the data array's length" Base.ncodeunits @consistent_overlay METHOD_TABLE Base.ncodeunits(s::String) = wasm_string_length(s)

@quarantine "Base's sizeof of a String is Core.sizeof of its memory; WasmGC has no raw memory, so it is the data array's length" Base.sizeof @consistent_overlay METHOD_TABLE Base.sizeof(s::String) = wasm_string_length(s)

@quarantine "Base's codeunit loads through pointer(s, i); WasmGC has no pointer, so the byte is the data array's element" Base.codeunit @consistent_overlay METHOD_TABLE @inline function Base.codeunit(s::String, i::Int)
    @boundscheck checkbounds(s, i)
    return wasm_string_codeunit(s, i - 1)
end

@quarantine "Base's _string_n is a jl_alloc_string foreigncall; WasmGC allocates the String's struct and a new data array" Base._string_n @consistent_overlay METHOD_TABLE Base._string_n(n::Integer) = wasm_string_alloc(Int(n))

@quarantine "julia/base/strings/string.jl:120 unsafe_wrap of a String as a byte Memory is a jl_string_to_genericmemory foreigncall; WasmGC shares the String's data array" Base.unsafe_wrap @consistent_overlay METHOD_TABLE Base.unsafe_wrap(::Type{Memory{UInt8}}, s::String) = wasm_string_memory(s)

# Base's own body, its foreigncall the runtime's operation: an empty Memory is the empty String
@quarantine "julia/base/strings/string.jl:83 unsafe_takestring of a byte Memory is a jl_genericmemory_to_string foreigncall; WasmGC wraps or copies the Memory's data array" Base.unsafe_takestring @consistent_overlay METHOD_TABLE Base.unsafe_takestring(m::Memory{UInt8}) =
    isempty(m) ? "" : wasm_memory_string(m, length(m))

# Base's own body (julia/base/strings/string.jl:65): a reference at its memory's start (Base compares
# `ptr_or_offset` with the memory's `ptr`, the element's address) takes the memory as the String
# (jl_genericmemory_to_string), any other copies its bytes into a new String (jl_pchar_to_string,
# julia/src/array.c:307: jl_alloc_string, then memcpy from the reference); the Vector is left empty.
# WasmTarget's reference holds the element's index, so the start is Julia's own memoryrefoffset of 1
# (jl_memoryrefoffset), and the copy is _string_n's String, its data shared as a Memory
# (unsafe_wrap) and filled by unsafe_copyto! from the reference, each an overlay above or in
# src/patch/genericmemory.jl
@quarantine "julia/base/strings/string.jl:65 String of a byte Vector compares its reference's address with its memory's, then jl_genericmemory_to_string or jl_pchar_to_string's copy from the address; WasmGC's reference holds the element's index" Base.String @consistent_overlay METHOD_TABLE function Base.String(v::Vector{UInt8})
    local len = length(v)
    len == 0 && return ""
    local ref = v.ref
    local str = if Core.memoryrefoffset(ref) == 1
        wasm_memory_string(ref.mem, len)
    else
        local s = Base._string_n(len)
        unsafe_copyto!(memoryref(unsafe_wrap(Memory{UInt8}, s)), ref, len)
        s
    end
    setfield!(v, :size, (0,))
    setfield!(v, :ref, memoryref(Memory{UInt8}()))
    return str
end

# Base's takes any `out` it can take a pointer to; the String its callers allocate is the one a data
# array holds, so any other `out` stays Base's, a located rejection where it is reached
@quarantine "Base's __unsafe_string! copies a String's bytes through pointers; WasmGC copies the data arrays (array.copy)" Base.__unsafe_string! @consistent_overlay METHOD_TABLE @inline function Base.__unsafe_string!(out::String, s::String, offs::Integer)
    local n = wasm_string_length(s)
    wasm_string_copy!(out, Int(offs) - 1, s, 0, n)
    return n
end

# Base's own body (julia/base/strings/string.jl:497), its copy of the range's bytes into the fresh String
# through pointer(ss) and pointer(s, i) the data arrays' array.copy from byte i - 1 (wasm_string_copy!), as
# dart's substring copies its code units into a new string (the VM's StringBase_substringUnchecked;
# dart2wasm's EmbedderStringImpl.substring delegates to its embedder, so the VM's is the nearest)
@quarantine "julia/base/strings/string.jl:497 getindex of a String at a UnitRange{Int} copies the range's bytes into a fresh String by unsafe_copyto! through pointer(s, i); WasmGC copies the data arrays' bytes (array.copy), as dart's substring copies its code units (sdk/lib/_internal/vm/lib/string_patch.dart:441 _StringBase._substringUnchecked; dart2wasm's sdk/lib/_internal/wasm/standalone/embedder_string.dart:313 EmbedderStringImpl.substring delegates to its embedder)" Base.getindex @consistent_overlay METHOD_TABLE @inline function Base.getindex(s::String, r::UnitRange{Int})
    isempty(r) && return ""
    local i, j = first(r), last(r)
    @boundscheck begin
        checkbounds(s, r)
        @inbounds isvalid(s, i) || Base.string_index_err(s, i)
        @inbounds isvalid(s, j) || Base.string_index_err(s, j)
    end
    j = nextind(s, j) - 1
    local n = j - i + 1
    local ss = Base._string_n(n)
    wasm_string_copy!(ss, 0, s, i - 1, n)
    return ss
end

# Base's _memcmp compares `len` bytes of the two Strings' data from their offsets by memcmp through pointers;
# WasmGC compares the data arrays' bytes in order, as dart's VM compareTo walks its code units, and answers
# the first differing bytes' difference, else 0: memcmp's value on this host (native Base._memcmp("abc",
# "axc", 3) is -22), so the overlay is consistent with Base's value, not only its sign. dart2wasm at the
# pin delegates compareTo and indexOf to its embedder (embedder_string.dart:508 and :414), so the VM's
# walk is the nearest dart counterpart. A Ptr operand (endswith's pointer(a, i)) stays Base's, a located
# rejection where it is reached.
@quarantine "julia/base/strings/string.jl:149 _memcmp of a String or SubString{String} compares len bytes by memcmp through pointers; WasmGC compares the data arrays' bytes in order, answering the first differing bytes' difference as memcmp does, as dart's VM compareTo walks its code units (sdk/lib/_internal/vm/lib/string_patch.dart:334 _StringBase.compareTo; dart2wasm's sdk/lib/_internal/wasm/standalone/embedder_string.dart:508 EmbedderStringImpl.compareTo delegates to its embedder)" Base._memcmp @consistent_overlay METHOD_TABLE function Base._memcmp(a::Union{String,SubString{String}}, b::Union{String,SubString{String}}, len::Int)
    local sa, oa = a isa String ? (a, 0) : (a.string, a.offset)
    local sb, ob = b isa String ? (b, 0) : (b.string, b.offset)
    for i in 0:len-1
        local ca = wasm_string_codeunit(sa, oa + i)
        local cb = wasm_string_codeunit(sb, ob + i)
        ca == cb || return Int(ca) - Int(cb)
    end
    return 0
end

# Base's body, its memchr from the byte at `i` (a pointer into the String's bytes) the walk of the
# data array's bytes from that offset, as dart's one-byte indexOf walks its code units for a
# one-character pattern (dart2wasm's indexOf delegates to its embedder, so the VM's is the nearest); the
# index is the found byte's, Base's (q - p + fst). A byte array (codeunits, a Vector{UInt8}) stays Base's,
# a located rejection where it is reached.
@quarantine "julia/base/strings/search.jl:81 _search of a byte in a String or SubString{String} is a memchr foreigncall through pointer(a); WasmGC walks the data array's bytes, as dart's one-byte indexOf walks its code units (sdk/lib/_internal/vm/lib/string_patch.dart:1087 _OneByteString.indexOf; dart2wasm's sdk/lib/_internal/wasm/standalone/embedder_string.dart:414 EmbedderStringImpl.indexOf delegates to its embedder)" Base._search @consistent_overlay METHOD_TABLE function Base._search(a::Union{String,SubString{String}}, b::Union{Int8,UInt8}, i::Integer = firstindex(a))
    local fst = firstindex(a)
    local lst = Base.last_byteindex(a)
    if i < fst
        throw(BoundsError(a, i))
    end
    if i > lst
        return i == lst+1 ? nothing : throw(BoundsError(a, i))
    end
    local s, o = a isa String ? (a, 0) : (a.string, a.offset)
    local c = b % UInt8
    for j in Int(i):lst
        wasm_string_codeunit(s, o + j - fst) == c && return j
    end
    return nothing
end
