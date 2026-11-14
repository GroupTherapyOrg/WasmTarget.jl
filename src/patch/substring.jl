# A Char's bytes written into a String or a byte Vector by overlay, as src/patch/string.jl's String
# operations: Base stores a Char's UTF-8 bytes into a fresh String, or the byte Vector map fills
# (a StringVector), through a raw pointer (base/strings/substring.jl __unsafe_string!, unsafe_store!
# through pointer(out, offs)), and WasmGC has no raw memory, so the method is replaced in WasmTarget's
# overlay method table (METHOD_TABLE, src/julia/interpreter.jl) by one that stores each byte into the
# String's data array (src/julia/wasm_array.jl wasm_string_write!) or the Vector's elements, as dart's
# string patches write their WasmArray. The overlay is consistent: natively it computes Base's answer.
# precedent(dart: the wasm target's @patch libraries, sdk/lib/_internal/wasm; gpucompiler: a device's
# overlays of Base in its method table).

# The byte Base stores through pointer(out, i + 1) (julia/base/strings/substring.jl:203 unsafe_store!):
# a String's data array element i (wasm_string_write!), or a byte Vector's element i + 1, the slot
# pointer(out, i + 1) addresses (pointer(x, i), julia/base/abstractarray.jl:1256), unchecked as Base's
# store is
@quarantine pin"julia/base/strings/substring.jl:199 __unsafe_string!" "Base's __unsafe_string! stores each byte by unsafe_store! through pointer(out, offs) (:203), the element at offs; WasmGC has no pointer, so it stores the String's data array element (array.set) or the byte Vector's element offs" Base.setindex! @inline function _char_byte_store!(out::Union{String,Vector{UInt8}}, i::Int, v::UInt8)::Nothing
    if out isa String
        wasm_string_write!(out, i, v)
    else
        @inbounds setindex!(out, v, i + 1)
    end
    return nothing
end

# Base's body, each byte of the Char's UTF-8 stored into its fresh String's data array, or its byte
# Vector's elements, in place of through pointer(out, offs); any other `out` stays Base's, a located
# rejection where it is reached
@quarantine "julia/base/strings/substring.jl:199 __unsafe_string! of a Char stores its UTF-8 bytes through pointer(out, offs); WasmGC stores the data array's elements (array.set)" Base.__unsafe_string! @consistent_overlay METHOD_TABLE @inline function Base.__unsafe_string!(out::Union{String,Vector{UInt8}}, c::Char, offs::Integer)
    local x = bswap(reinterpret(UInt32, c))
    local n = ncodeunits(c)
    local o = Int(offs) - 1
    _char_byte_store!(out, o, x % UInt8)
    n == 1 && return n
    x >>= 8
    _char_byte_store!(out, o + 1, x % UInt8)
    n == 2 && return n
    x >>= 8
    _char_byte_store!(out, o + 2, x % UInt8)
    n == 3 && return n
    x >>= 8
    _char_byte_store!(out, o + 3, x % UInt8)
    return n
end

# A SubString's bytes written into a String, Base's own body (julia/base/strings/substring.jl:223): its
# byte count is its sizeof, its ncodeunits, and its bytes, which Base copies by unsafe_copyto! from
# pointer(s), its String's pointer past its offset (julia/base/strings/substring.jl:135 pointer), are its
# String's data array's from that offset, copied as a String's are (array.copy); any other `out` stays
# Base's, a located rejection where it is reached
@quarantine "julia/base/strings/substring.jl:223 __unsafe_string! of a SubString{String} copies its bytes from pointer(s), its String's address past its offset; WasmGC copies its String's data array from that offset (array.copy)" Base.__unsafe_string! @consistent_overlay METHOD_TABLE @inline function Base.__unsafe_string!(out::String, s::SubString{String}, offs::Integer)
    local n = sizeof(s)
    wasm_string_copy!(out, Int(offs) - 1, s.string, s.offset, n)
    return n
end

# A Symbol's bytes written into a String, Base's own body (julia/base/strings/substring.jl:229): its byte
# count is Core.sizeof of the Symbol (src/intrinsics.jl's sizeof arm, jl_f_sizeof's), and its bytes,
# which Base copies by unsafe_copyto! from jl_symbol_name's pointer, are its name's, dart's
# Symbol.getName (src/julia/wasm_array.jl wasm_symbol_name), copied as a String's are (array.copy);
# any other `out` stays Base's, a located rejection where it is reached. Base's @assume_effects :nothrow
# is not carried over, as String(::Symbol)'s :total is not (src/patch/string.jl): Base promises it of an
# unchecked pointer copy, and the overlay's array.copy is checked, trapping past the String's end, so no
# call of it is removed or folded on a promise the overlay does not keep
@quarantine "julia/base/strings/substring.jl:229 __unsafe_string! of a Symbol copies the bytes at its jl_symbol_name pointer; WasmGC copies its name's data array (array.copy), the name dart's Symbol.getName reads; Base's @assume_effects :nothrow is not carried over, the checked array.copy trapping where Base's unchecked copy promises no throw" Base.__unsafe_string! @consistent_overlay METHOD_TABLE @inline function Base.__unsafe_string!(out::String, s::Symbol, offs::Integer)
    local n = sizeof(s)
    wasm_string_copy!(out, Int(offs) - 1, wasm_symbol_name(s), 0, n)
    return n
end
