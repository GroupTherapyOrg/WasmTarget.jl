# String's byte-level operations by overlay (the String ruling, src/julia/classes.jl
# _string_instance_fields): Base reads and writes a String through a raw pointer (Core.sizeof of its
# memory, pointer(s, i) loads, jl_alloc_string, unsafe_copyto!), and WasmGC has no raw memory, so each
# such method is replaced in WasmTarget's overlay method table (METHOD_TABLE, src/julia/interpreter.jl) by one written against the
# String's data through dart:_wasm's array operations (src/julia/wasm_array.jl), as dart's own string
# patches read and write their WasmArray. Each overlay is consistent: natively it computes Base's
# answer. precedent(dart: the wasm target's @patch libraries, sdk/lib/_internal/wasm; gpucompiler: a
# device's overlays of Base in its method table).

@quarantine unpinned "Base's ncodeunits is Core.sizeof of the String's memory; WasmGC has no raw memory, so it is the data array's length" Base.ncodeunits @consistent_overlay METHOD_TABLE Base.ncodeunits(s::String) = wasm_string_length(s)

@quarantine unpinned "Base's sizeof of a String is Core.sizeof of its memory; WasmGC has no raw memory, so it is the data array's length" Base.sizeof @consistent_overlay METHOD_TABLE Base.sizeof(s::String) = wasm_string_length(s)

@quarantine unpinned "Base's codeunit loads through pointer(s, i); WasmGC has no pointer, so the byte is the data array's element" Base.codeunit @consistent_overlay METHOD_TABLE @inline function Base.codeunit(s::String, i::Int)
    @boundscheck checkbounds(s, i)
    return wasm_string_codeunit(s, i - 1)
end

@quarantine unpinned "Base's _string_n is a jl_alloc_string foreigncall; WasmGC allocates the String's struct and a new data array" Base._string_n @consistent_overlay METHOD_TABLE Base._string_n(n::Integer) = wasm_string_alloc(Int(n))

@quarantine pin"julia/base/strings/string.jl:118 String" "julia/base/strings/string.jl:118 String of a Symbol copies the bytes at its jl_symbol_name pointer; WasmGC reads the Symbol's name, dart's Symbol.getName; Base's @assume_effects :total is not carried over, so no call of it folds" Base.String @consistent_overlay METHOD_TABLE Base.String(s::Symbol) = wasm_symbol_name(s)

# Core's Symbol of a String (julia/base/boot.jl:687): _Symbol of the String's jl_string_ptr and its size,
# jl_symbol_n's (julia/src/symbol.c:113); WasmGC has no pointer, so the port of jl_symbol_n takes the String
# whose data array holds the bytes (src/julia/runtime/rtutils.jl jl_symbol_n), interning it in the module's
# symbol table, which every symbol constant is interned in too, so the Symbol is the constant of its name.
# Base's @_foldable_meta is not carried over: no claim, so no call of it folds on one
@quarantine pin"julia/base/boot.jl:687 Symbol" "julia/base/boot.jl:687 Symbol of a String is jl_symbol_n of its jl_string_ptr and size; WasmGC has no pointer, so the port of jl_symbol_n reads the String's data array" Core.Symbol @consistent_overlay METHOD_TABLE Core.Symbol(s::String) = jl_symbol_n(s)

@quarantine pin"julia/base/strings/string.jl:120 unsafe_wrap" "julia/base/strings/string.jl:120 unsafe_wrap of a String as a byte Memory is a jl_string_to_genericmemory foreigncall; WasmGC shares the String's data array" Base.unsafe_wrap @consistent_overlay METHOD_TABLE Base.unsafe_wrap(::Type{Memory{UInt8}}, s::String) = wasm_string_memory(s)

# Base's own body, its foreigncall the runtime's operation: an empty Memory is the empty String
@quarantine pin"julia/base/strings/string.jl:83 unsafe_takestring" "julia/base/strings/string.jl:83 unsafe_takestring of a byte Memory is a jl_genericmemory_to_string foreigncall; WasmGC wraps or copies the Memory's data array" Base.unsafe_takestring @consistent_overlay METHOD_TABLE Base.unsafe_takestring(m::Memory{UInt8}) =
    isempty(m) ? "" : wasm_memory_string(m, length(m))

# Base's own body (julia/base/strings/string.jl:65): a reference at its memory's start (Base compares
# `ptr_or_offset` with the memory's `ptr`, the element's address) takes the memory as the String
# (jl_genericmemory_to_string), any other copies its bytes into a new String (jl_pchar_to_string,
# julia/src/array.c:307: jl_alloc_string, then memcpy from the reference); the Vector is left empty.
# WasmTarget's reference holds the element's index, so the start is Julia's own memoryrefoffset of 1
# (jl_memoryrefoffset), and the copy is _string_n's String, its data shared as a Memory
# (unsafe_wrap) and filled by unsafe_copyto! from the reference, each an overlay above or in
# src/patch/genericmemory.jl
@quarantine pin"julia/base/strings/string.jl:65 String" "julia/base/strings/string.jl:65 String of a byte Vector compares its reference's address with its memory's, then jl_genericmemory_to_string or jl_pchar_to_string's copy from the address; WasmGC's reference holds the element's index" Base.String @consistent_overlay METHOD_TABLE function Base.String(v::Vector{UInt8})
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
@quarantine unpinned "Base's __unsafe_string! copies a String's bytes through pointers; WasmGC copies the data arrays (array.copy)" Base.__unsafe_string! @consistent_overlay METHOD_TABLE @inline function Base.__unsafe_string!(out::String, s::String, offs::Integer)
    local n = wasm_string_length(s)
    wasm_string_copy!(out, Int(offs) - 1, s, 0, n)
    return n
end

# Base's own body (julia/base/strings/string.jl:497), its copy of the range's bytes into the fresh String
# through pointer(ss) and pointer(s, i) the data arrays' array.copy from byte i - 1 (wasm_string_copy!), as
# dart's substring copies its code units into a new string (the VM's StringBase_substringUnchecked;
# dart2wasm's EmbedderStringImpl.substring delegates to its embedder, so the VM's is the nearest)
@quarantine pin"julia/base/strings/string.jl:497 getindex" "julia/base/strings/string.jl:497 getindex of a String at a UnitRange{Int} copies the range's bytes into a fresh String by unsafe_copyto! through pointer(s, i); WasmGC copies the data arrays' bytes (array.copy), as dart's substring copies its code units (sdk/lib/_internal/vm/lib/string_patch.dart:441 _StringBase._substringUnchecked; dart2wasm's sdk/lib/_internal/wasm/standalone/embedder_string.dart:313 EmbedderStringImpl.substring delegates to its embedder)" Base.getindex @consistent_overlay METHOD_TABLE @inline function Base.getindex(s::String, r::UnitRange{Int})
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

# Base's pointer of a String's bytes (julia/base/strings/string.jl:131), of a SubString{String}'s (its
# String's plus its offset, julia/base/strings/substring.jl:135) and of their CodeUnits' (the pointer of the
# string they wrap, julia/base/strings/basic.jl:810): WasmGC has no pointer, so a byte's place is the String
# whose data array holds it and the offset of the first byte in that array, as dart's _StringBase reads its
# code units by index (sdk/lib/_internal/vm/lib/string_patch.dart:362 codeUnitAt(i + start))
@quarantine pin"julia/base/strings/string.jl:131 pointer" "julia/base/strings/string.jl:131 pointer of a String is its bytes' address; WasmGC has no pointer, so it is the String whose data array holds them, from offset 0" Core.String wasm_string_place(a::String) = (a, 0)
@quarantine pin"julia/base/strings/substring.jl:135 pointer" "julia/base/strings/substring.jl:135 pointer of a SubString{String} is pointer(x.string) + x.offset; WasmGC has no pointer, so it is its String and its offset" Base.SubString wasm_string_place(a::SubString{String}) = (a.string, a.offset)
@quarantine pin"julia/base/strings/basic.jl:810 cconvert" "julia/base/strings/basic.jl:810 cconvert of CodeUnits to a pointer is cconvert of the String or SubString{String} it wraps (cconvert(Ptr{T}, s.s)), so its pointer is that string's; WasmGC has no pointer, so it is that string's place" Base.CodeUnits wasm_string_place(a::Base.CodeUnits{UInt8,<:Union{String,SubString{String}}}) = wasm_string_place(a.s)

# memcmp of `len` bytes from two places (wasm_string_place): the first differing bytes' difference, else 0,
# memcmp's value on this host (native Base._memcmp("abc", "axc", 3) is -22), so an overlay calling it is
# consistent with Base's value, not only its sign; dart's VM compareTo and _substringMatches walk their code
# units in order the same way. dart2wasm at the pin delegates compareTo to its embedder
# (embedder_string.dart:508), and its endsWith (embedder_string.dart:193) compares a new substring of the
# string's end with the other string; the walk follows Base's body instead (its _memcmp in place, no new
# String), the dart walk it matches the VM's _substringMatches (vm/lib/string_patch.dart:355).
@quarantine pin"julia/base/strings/string.jl:149 _memcmp" "julia/base/strings/string.jl:149 _memcmp compares len bytes by memcmp through pointers; WasmGC compares the data arrays' bytes in order, answering the first differing bytes' difference as memcmp does, as dart's VM compareTo walks its code units (sdk/lib/_internal/vm/lib/string_patch.dart:334 _StringBase.compareTo; dart2wasm's sdk/lib/_internal/wasm/standalone/embedder_string.dart:508 EmbedderStringImpl.compareTo delegates to its embedder)" Base.Int function wasm_string_memcmp(sa::String, oa::Int, sb::String, ob::Int, len::Int)
    for i in 0:len-1
        local ca = wasm_string_codeunit(sa, oa + i)
        local cb = wasm_string_codeunit(sb, ob + i)
        ca == cb || return Int(ca) - Int(cb)
    end
    return 0
end

# Base's _memcmp of two Strings or SubStrings of them: the walk of their data arrays from their places
@quarantine pin"julia/base/strings/string.jl:149 _memcmp" "julia/base/strings/string.jl:149 _memcmp of a String or SubString{String} compares len bytes by memcmp through pointers; WasmGC compares the data arrays' bytes in order (wasm_string_memcmp), as dart's VM compareTo walks its code units (sdk/lib/_internal/vm/lib/string_patch.dart:334 _StringBase.compareTo; dart2wasm's sdk/lib/_internal/wasm/standalone/embedder_string.dart:508 EmbedderStringImpl.compareTo delegates to its embedder)" Base._memcmp @consistent_overlay METHOD_TABLE function Base._memcmp(a::Union{String,SubString{String}}, b::Union{String,SubString{String}}, len::Int)
    local sa, oa = wasm_string_place(a)
    local sb, ob = wasm_string_place(b)
    return wasm_string_memcmp(sa, oa, sb, ob, len)
end

# Base's own body (julia/base/strings/util.jl:101), its _memcmp from pointer(a, astart) the walk of a's data
# array from the byte at astart (wasm_string_memcmp), as dart's VM endsWith compares the code units at the
# string's end with the other's (_substringMatches)
@quarantine pin"julia/base/strings/util.jl:101 endswith" "julia/base/strings/util.jl:101 endswith of a String or SubString{String} is _memcmp from pointer(a, astart), a pointer into a's bytes; WasmGC compares a's data array from the byte at astart (wasm_string_memcmp), as dart's VM endsWith walks the code units of its end (sdk/lib/_internal/vm/lib/string_patch.dart:369 _StringBase.endsWith, :355 _substringMatches; dart2wasm's sdk/lib/_internal/wasm/standalone/embedder_string.dart:193 EmbedderStringImpl.endsWith compares a substring)" Base.endswith @consistent_overlay METHOD_TABLE function Base.endswith(a::Union{String,SubString{String}}, b::Union{String,SubString{String}})
    local astart = ncodeunits(a) - ncodeunits(b) + 1
    astart < 1 && return false
    local sa, oa = wasm_string_place(a)
    local sb, ob = wasm_string_place(b)
    if wasm_string_memcmp(sa, oa + astart - 1, sb, ob, sizeof(b)) == 0
        return thisind(a, astart) == astart # check that end of `b` doesn't match a partial character in `a`
    end
    return false
end

# Base's body, its memchr from the byte at `i` (a pointer into the bytes) the walk of the data array's bytes
# from that offset, as dart's one-byte indexOf walks its code units for a one-character pattern (dart2wasm's
# indexOf delegates to its embedder, so the VM's is the nearest); the index is the found byte's, Base's
# (q - p + fst). A String, a SubString of one or their CodeUnits (which _searchindex of two Strings searches,
# julia/base/strings/search.jl:294) is walked; any other byte array (a Vector{UInt8}) stays Base's, a located
# rejection where it is reached.
@quarantine pin"julia/base/strings/search.jl:81 _search" "julia/base/strings/search.jl:81 _search of a byte in a String, a SubString{String} or their CodeUnits is a memchr foreigncall through pointer(a); WasmGC walks the data array's bytes from the place of a (wasm_string_place), as dart's one-byte indexOf walks its code units (sdk/lib/_internal/vm/lib/string_patch.dart:1087 _OneByteString.indexOf; dart2wasm's sdk/lib/_internal/wasm/standalone/embedder_string.dart:414 EmbedderStringImpl.indexOf delegates to its embedder)" Base._search @consistent_overlay METHOD_TABLE function Base._search(a::Union{String,SubString{String},Base.CodeUnits{UInt8,<:Union{String,SubString{String}}}}, b::Union{Int8,UInt8}, i::Integer = firstindex(a))
    local fst = firstindex(a)
    local lst = Base.last_byteindex(a)
    if i < fst
        throw(BoundsError(a, i))
    end
    if i > lst
        return i == lst+1 ? nothing : throw(BoundsError(a, i))
    end
    local s, o = wasm_string_place(a)
    local c = b % UInt8
    for j in Int(i):lst
        wasm_string_codeunit(s, o + j - fst) == c && return j
    end
    return nothing
end

# Base's body (julia/base/strings/substring.jl:273), its memset through unsafe_convert(Ptr{UInt8}, out) the
# store of the one byte at each offset of the fresh String's data array (wasm_string_write!) and its
# unsafe_copyto! from pointer(s) to pointer(out, i*n+1) the array.copy of s's bytes from its place
# (wasm_string_place, wasm_string_copy!), as dart's one-byte `*` sets each code unit of its allocated result
# (dart2wasm's `*` delegates to its embedder's stringRepeat, so the VM's is the nearest). Base's checks stay:
# a negative count throws Base's ArgumentError; String(s) of a count of 1 stays Base's.
@quarantine pin"julia/base/strings/substring.jl:273 repeat" "julia/base/strings/substring.jl:273 repeat of a String or SubString{String} fills a fresh String by memset or unsafe_copyto! through pointers; WasmGC stores the byte at each offset of the data array (wasm_string_write!) or copies s's data array from its place (wasm_string_copy!), as dart's one-byte operator * sets its result's code units (sdk/lib/_internal/vm/lib/string_patch.dart:1132 _OneByteString.*; dart2wasm's sdk/lib/_internal/wasm/standalone/embedder_string.dart:379 EmbedderStringImpl.* delegates to its embedder)" Base.repeat @consistent_overlay METHOD_TABLE function Base.repeat(s::Union{String,SubString{String}}, r::Integer)
    r < 0 && throw(ArgumentError("can't repeat a string $r times"))
    r = UInt(r)::UInt
    r == 0 && return ""
    r == 1 && return String(s)
    local n = sizeof(s)
    local out = Base._string_n(n*r)
    if n == 1
        local b = @inbounds codeunit(s, 1)
        for i in 0:Int(r)-1
            wasm_string_write!(out, i, b)
        end
    else
        local src, o = wasm_string_place(s)
        for i = 0:r-1
            wasm_string_copy!(out, Int(i*n), src, o, n)
        end
    end
    return out
end

# Base's body (julia/base/strings/string.jl:573), its memset, its unsafe_store! of a UInt16, of three bytes
# or of a UInt32 through pointer(s) each the store of the character's n bytes at each copy's offsets of the
# fresh String's data array (wasm_string_write!): byte k of a copy is (u >> 8k) % UInt8, the little-endian
# byte Base's store writes, as dart's one-byte `*` sets each code unit of its result. Base's checks stay.
# It is overlaid for a Char, the type Base's body converts every character to: an overlay of AbstractChar
# would cover Base's more specific repeat of an AnnotatedChar (an AnnotatedString), which stays Base's.
@quarantine pin"julia/base/strings/string.jl:573 repeat" "julia/base/strings/string.jl:573 repeat of a Char fills a fresh String by memset or unsafe_store! through pointer(s); WasmGC stores each copy's bytes at their offsets of the data array (wasm_string_write!), as dart's one-byte operator * sets its result's code units (sdk/lib/_internal/vm/lib/string_patch.dart:1132 _OneByteString.*; dart2wasm's sdk/lib/_internal/wasm/standalone/embedder_string.dart:379 EmbedderStringImpl.* delegates to its embedder)" Base.repeat @consistent_overlay METHOD_TABLE function Base.repeat(c::Char, r::Integer)
    r < 0 && throw(ArgumentError("can't repeat a character $r times"))
    r = UInt(r)::UInt
    c = Char(c)::Char
    r == 0 && return ""
    local u = bswap(reinterpret(UInt32, c))
    local n = 4 - (leading_zeros(u | 0xff) >> 3)
    local s = Base._string_n(n*r)
    for i in 0:Int(r)-1, k in 0:n-1
        wasm_string_write!(s, i*n + k, (u >> 8k) % UInt8)
    end
    return s
end

# Base's body (julia/base/strings/util.jl:977), its unsafe_write of the preserved portion's j - i bytes from
# pointer(str, i) the write of those bytes as the SubString of str past i - 1 (the unchecked :noshift
# SubString of the bytes the pointer names, i and j both indices of characters of str), which
# src/patch/io.jl's overlay copies into an IOBuffer's data array, as dart2wasm's replaceAll writes each
# preserved substring(startIndex, match.start) into its StringBuffer. It is overlaid for a String, the str
# every replace passes (julia/base/strings/util.jl:1093, _replace_(io, String(s), ...)); any other IO stays
# Base's write, a located rejection where it is reached.
@quarantine pin"julia/base/strings/util.jl:977 _replace_finish" "julia/base/strings/util.jl:977 _replace_finish writes each preserved portion of str by unsafe_write from pointer(str, i); WasmGC writes those bytes as the SubString of str holding them, as dart2wasm's replaceAll writes each preserved substring into its StringBuffer (sdk/lib/_internal/wasm/standalone/embedder_string.dart:201 EmbedderStringImpl.replaceAll; the VM's sdk/lib/_internal/vm/lib/string_patch.dart:706 _StringBase._joinReplaceAllOneByteResult copies the slice's code units)" Base._replace_finish @consistent_overlay METHOD_TABLE function Base._replace_finish(io::IO, str::String, count::Int,
                                                                                                                                     e1::Int, patterns::Tuple, replaces::Tuple, rs::Tuple)
    n = 1
    i = a = firstindex(str)
    while true
        p = argmin(map(first, rs))
        r = rs[p]
        j, k = first(r), last(r)
        j > e1 && break
        if i == a || i <= k
            # copy out preserved portion
            write(io, @inbounds SubString{String}(str, i - 1, j - i, Val(:noshift)))
            # copy out replacement string
            Base._replace(io, replaces[p], str, r, patterns[p])
        end
        if k < j
            i = j
            j == e1 && break
            k = nextind(str, j)
        else
            i = k = nextind(str, k)
        end
        n == count && break
        let k = k
            rs = map(patterns, rs) do p, r
                if first(r) < k
                    r = findnext(p, str, k)
                    if r === nothing || first(r) == 0
                        return e1+1:0
                    end
                    r isa Int && (r = r:r)
                end
                return r
            end
        end
        n += 1
    end
    foreach(Base._free_pat_replacer, patterns)
    write(io, SubString(str, i))
    return io
end
