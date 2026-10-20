# Binary serialization for WebAssembly modules
# Reference: https://webassembly.github.io/spec/core/binary/conventions.html

export encode_leb128_unsigned, encode_leb128_signed, WasmWriter

# ============================================================================
# LEB128 Encoding (Section 5.2.2)
# ============================================================================

"""
    encode_leb128_unsigned(value) -> Vector{UInt8}

Encode an unsigned integer using LEB128 (Little Endian Base 128).
parity(pkg/wasm_builder/lib/src/serialize/serializer.dart:69 Serializer.writeUnsigned)
"""
function encode_leb128_unsigned(value::Integer)::Vector{UInt8}
    result = UInt8[]
    value = unsigned(value)
    while true
        byte = UInt8(value & 0x7F)
        value >>= 7
        if value != 0
            byte |= 0x80  # Set continuation bit
        end
        push!(result, byte)
        value == 0 && break
    end
    return result
end

"""
    encode_leb128_signed(value) -> Vector{UInt8}

Encode a signed integer using LEB128 (Little Endian Base 128).
parity(pkg/wasm_builder/lib/src/serialize/serializer.dart:61 Serializer.writeSigned)
"""
function encode_leb128_signed(value::Integer)::Vector{UInt8}
    result = UInt8[]
    more = true
    while more
        byte = UInt8(value & 0x7F)
        value >>= 7
        # Check if we need more bytes
        if (value == 0 && (byte & 0x40) == 0) || (value == -1 && (byte & 0x40) != 0)
            more = false
        else
            byte |= 0x80  # Set continuation bit
        end
        push!(result, byte)
    end
    return result
end

# ============================================================================
# WasmWriter - Binary stream builder
# ============================================================================

"""
    WasmWriter

A mutable buffer for building WebAssembly binary data.
parity(pkg/wasm_builder/lib/src/serialize/serializer.dart:17 Serializer)
"""
mutable struct WasmWriter
    buffer::Vector{UInt8}
end

# parity(pkg/wasm_builder/lib/src/serialize/serializer.dart:17 Serializer)
WasmWriter()::WasmWriter = WasmWriter(UInt8[])

# parity(pkg/wasm_builder/lib/src/serialize/serializer.dart:29 Serializer.offset)
Base.length(w::WasmWriter) = length(w.buffer)
# parity(pkg/wasm_builder/lib/src/serialize/serializer.dart:141 Serializer.data)
bytes(w::WasmWriter)::Vector{UInt8} = w.buffer

"""
Write raw bytes to the buffer.
parity(pkg/wasm_builder/lib/src/serialize/serializer.dart:55 Serializer.writeBytes)
"""
function write_bytes!(w::WasmWriter, data::Vector{UInt8})::WasmWriter
    append!(w.buffer, data)
    return w
end

# parity(pkg/wasm_builder/lib/src/serialize/serializer.dart:55 Serializer.writeBytes)
function write_bytes!(w::WasmWriter, data::UInt8...)::WasmWriter
    append!(w.buffer, data)
    return w
end

"""
Write a single byte.
parity(pkg/wasm_builder/lib/src/serialize/serializer.dart:48 Serializer.writeByte)
"""
function write_byte!(w::WasmWriter, b::UInt8)::WasmWriter
    push!(w.buffer, b)
    return w
end

"""
Write an unsigned LEB128 integer.
parity(pkg/wasm_builder/lib/src/serialize/serializer.dart:69 Serializer.writeUnsigned)
"""
function write_u32!(w::WasmWriter, value::Integer)::WasmWriter
    append!(w.buffer, encode_leb128_unsigned(value))
    return w
end

"""
Write a signed LEB128 integer.
parity(pkg/wasm_builder/lib/src/serialize/serializer.dart:61 Serializer.writeSigned)
"""
function write_i32!(w::WasmWriter, value::Integer)::WasmWriter
    append!(w.buffer, encode_leb128_signed(value))
    return w
end

"""
Write a name (UTF-8 string with length prefix).
parity(pkg/wasm_builder/lib/src/serialize/serializer.dart:103 Serializer.writeName)
"""
function write_name!(w::WasmWriter, name::String)::WasmWriter
    name_bytes = Vector{UInt8}(name)
    write_u32!(w, length(name_bytes))
    append!(w.buffer, name_bytes)
    return w
end

# ============================================================================
# Deserialization: the import section a module's bytes declare
# ============================================================================

"""
    WasmDeserializer(bytes)

A module's bytes, or one section's, and the offset of the next byte to read, as dart's
wasm_builder reads a module back (its Deserializer). Every read is bounds-checked: reading past
the end is refused, never answered with a default.
parity(pkg/wasm_builder/lib/src/serialize/deserializer.dart:8 Deserializer)
"""
mutable struct WasmDeserializer
    data::Vector{UInt8}
    offset::Int   # 1-based, the next byte
end

# parity(pkg/wasm_builder/lib/src/serialize/deserializer.dart:12 Deserializer)
WasmDeserializer(data::Vector{UInt8})::WasmDeserializer = WasmDeserializer(data, 1)

# parity(pkg/wasm_builder/lib/src/serialize/deserializer.dart:16 Deserializer.isAtEnd)
is_at_end(d::WasmDeserializer)::Bool = d.offset > length(d.data)

# parity(pkg/wasm_builder/lib/src/serialize/deserializer.dart:18 Deserializer.readByte)
function read_byte!(d::WasmDeserializer)::UInt8
    is_at_end(d) && throw(ArgumentError("the module's bytes end at byte $(d.offset - 1), where a byte is read"))
    local b = d.data[d.offset]
    d.offset += 1
    return b
end

# the next `n` bytes, refused when fewer remain (dart's sublistView raises a RangeError)
# parity(pkg/wasm_builder/lib/src/serialize/deserializer.dart:26 Deserializer.readBytes)
function read_bytes!(d::WasmDeserializer, n::Integer)::Vector{UInt8}
    (0 <= n <= length(d.data) - d.offset + 1) || throw(ArgumentError(
        "the module's bytes hold $(length(d.data) - d.offset + 1) byte(s) after byte $(d.offset - 1), where $(n) are read"))
    local bytes = d.data[d.offset:d.offset + Int(n) - 1]
    d.offset += Int(n)
    return bytes
end

# an unsigned LEB128 integer (refused past 64 bits: a tenth byte holds bit 63 alone)
# parity(pkg/wasm_builder/lib/src/serialize/deserializer.dart:49 Deserializer.readUnsigned)
function read_unsigned!(d::WasmDeserializer)::UInt64
    local result = UInt64(0)
    local shift = 0
    local byte = read_byte!(d)
    result |= UInt64(byte & 0x7f) << shift
    shift += 7
    while byte & 0x80 != 0
        shift < 64 || throw(ArgumentError("an unsigned LEB128 integer longer than 64 bits at byte $(d.offset - 1)"))
        byte = read_byte!(d)
        (shift == 63 && byte & 0x7e != 0) &&
            throw(ArgumentError("an unsigned LEB128 integer longer than 64 bits at byte $(d.offset - 1)"))
        result |= UInt64(byte & 0x7f) << shift
        shift += 7
    end
    return result
end

# a signed LEB128 integer (a heap type's s33; refused past 64 bits: a tenth byte holds the sign
# bit 63 and its extension alone)
# parity(pkg/wasm_builder/lib/src/serialize/deserializer.dart:32 Deserializer.readSigned)
function read_signed!(d::WasmDeserializer)::Int64
    local result = Int64(0)
    local shift = 0
    local byte = read_byte!(d)
    result |= Int64(byte & 0x7f) << shift
    shift += 7
    while byte & 0x80 != 0
        shift < 64 || throw(ArgumentError("a signed LEB128 integer longer than 64 bits at byte $(d.offset - 1)"))
        byte = read_byte!(d)
        (shift == 63 && byte & 0x7f != 0x00 && byte & 0x7f != 0x7f) &&
            throw(ArgumentError("a signed LEB128 integer longer than 64 bits at byte $(d.offset - 1)"))
        result |= Int64(byte & 0x7f) << shift
        shift += 7
    end
    (shift < 64 && byte & 0x40 != 0) && (result |= ~Int64(0) << shift)
    return result
end

# a name: its length, then that many bytes of UTF-8 (dart's utf8.decode refuses invalid UTF-8)
# parity(pkg/wasm_builder/lib/src/serialize/deserializer.dart:73 Deserializer.readName)
function read_name!(d::WasmDeserializer)::String
    local at = d.offset - 1
    local bytes = read_bytes!(d, read_unsigned!(d))
    isvalid(String, bytes) || throw(ArgumentError("the name at byte $(at) is not valid UTF-8"))
    return String(bytes)
end

"""
    module_sections(bytes) -> Dict{UInt8,Vector{WasmDeserializer}}

A module's sections, each read as its own deserializer over exactly its bytes, by section id
(custom sections, id 0, read for their name and left out): the module's 8-byte preamble (the magic
`\\0asm` and version 1) is checked first, and a section whose size runs past the module's end is
refused.
parity(pkg/wasm_builder/lib/src/ir/module.dart:145 Module._deserializeTopLevel)
"""
function module_sections(bytes::Vector{UInt8})::Dict{UInt8,Vector{WasmDeserializer}}
    local d = WasmDeserializer(bytes)
    length(bytes) >= 8 && read_bytes!(d, 8) == UInt8[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00] ||
        throw(ArgumentError("the bytes are not a WebAssembly module: invalid Wasm preamble (`\\0asm`, version 1)"))
    local sections = Dict{UInt8,Vector{WasmDeserializer}}()
    while !is_at_end(d)
        local id = read_byte!(d)
        local section = WasmDeserializer(read_bytes!(d, read_unsigned!(d)))
        if id == 0x00
            read_name!(section)   # a custom section: its name, refused when not UTF-8
        else
            push!(get!(() -> WasmDeserializer[], sections, id), section)
        end
    end
    return sections
end

"""
    module_function_imports(bytes) -> Vector{Tuple{String,String}}

The function imports a module's bytes declare, `(module, field)` each in import order, read from
its one import section (a second is refused, as dart's `importSections?.single`), which must end
exactly where its last import does; an imported global's value type and mutability are read past.
A module WasmTarget writes imports functions and globals only (to_bytes), so an import of another
kind is refused, never skipped.
parity(pkg/wasm_builder/lib/src/serialize/sections.dart:161 ImportSection.deserialize)
"""
function module_function_imports(bytes::Vector{UInt8})::Vector{Tuple{String,String}}
    local found = get(module_sections(bytes), SECTION_IMPORT, WasmDeserializer[])
    length(found) <= 1 || throw(ArgumentError("the module holds $(length(found)) import sections, where a module holds one"))
    local out = Tuple{String,String}[]
    isempty(found) && return out
    local d = only(found)
    for _ in 1:read_unsigned!(d)
        local m = read_name!(d)
        local f = read_name!(d)
        local kind = read_byte!(d)
        if kind == 0x00                       # a function: its type index
            read_unsigned!(d)
            push!(out, (m, f))
        elseif kind == 0x03                   # a global: its value type, its mutability
            local vt = read_byte!(d)
            (vt == 0x63 || vt == 0x64) && read_signed!(d)   # a reference's heap type
            read_byte!(d)
        else
            throw(ArgumentError("the module imports $(m).$(f) of kind $(kind): a module WasmTarget writes imports functions and globals only"))
        end
    end
    is_at_end(d) || throw(ArgumentError(
        "the import section holds $(length(d.data) - d.offset + 1) byte(s) after its last import"))
    return out
end
