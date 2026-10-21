# A module's import section read back from its bytes: a test tool, as dart's wasm_builder
# Deserializer serves dart's tools and tests (pkg/wasm_builder: bin/wasm2wat.dart:61,
# test/ir_test.dart:171, test/wasm_read_write_test.dart:39) and never the path from a compile to
# its runtime. The compile generates a module's runtime from its own record of the imports it
# added (WasmTarget.host_runtime_js); a harness that holds only a module's bytes reads them back
# here, as a host reads a module's imports with WebAssembly.Module.imports.
#
# Every read is bounds-checked and every malformed module refused by name, never read past or
# answered with a default: the 8-byte preamble (Module._deserializeTopLevel, module.dart:145), each
# section a view over exactly its bytes, so every offset an error names is the module's own, one
# import section (dart's `importSections?.single`) read to its exact end, each integer a LEB128 of
# at most the width the binary format gives its field (u32 for a count, a length, an index; s33 for
# a heap type), each name valid UTF-8, a global import's value type, heap type and mutability as
# ValueType/RefType/HeapType.deserialize accept them (type.dart:67, :256, :361), mutability 0 or 1.
module WasmReader

import WasmTarget

export module_function_imports, module_runtime_js

# a module's bytes and the next byte to read (1-based), within `stop`, the last byte of the module
# or of the section it reads (`what`)
# parity(pkg/wasm_builder/lib/src/serialize/deserializer.dart:8 Deserializer)
mutable struct Deserializer
    data::Vector{UInt8}
    offset::Int
    stop::Int
    what::String
end

# parity(pkg/wasm_builder/lib/src/serialize/deserializer.dart:16 Deserializer.isAtEnd)
is_at_end(d::Deserializer)::Bool = d.offset > d.stop

# parity(pkg/wasm_builder/lib/src/serialize/deserializer.dart:18 Deserializer.readByte)
function read_byte!(d::Deserializer)::UInt8
    is_at_end(d) && throw(ArgumentError(
        "the $(d.what) ends at byte $(d.offset - 1), where a byte is read"))
    local b = d.data[d.offset]
    d.offset += 1
    return b
end

# the next `n` bytes' range, refused when fewer remain (dart's sublistView raises a RangeError)
# parity(pkg/wasm_builder/lib/src/serialize/deserializer.dart:26 Deserializer.readBytes)
function read_range!(d::Deserializer, n::Integer)::UnitRange{Int}
    (0 <= n <= d.stop - d.offset + 1) || throw(ArgumentError(
        "$(d.stop - d.offset + 1) byte(s) remain after byte $(d.offset - 1), where $(n) are read"))
    local r = d.offset:d.offset + Int(n) - 1
    d.offset += Int(n)
    return r
end

# a u32: an unsigned LEB128 of at most 5 bytes, the 5th holding bits 28-31 alone
# parity(pkg/wasm_builder/lib/src/serialize/deserializer.dart:49 Deserializer.readUnsigned)
function read_u32!(d::Deserializer)::UInt32
    local at = d.offset - 1
    local result = UInt64(0)
    for k in 0:4
        local byte = read_byte!(d)
        (k == 4 && byte & 0xf0 != 0) &&
            throw(ArgumentError("a u32 at byte $(at) longer than 5 bytes or past 32 bits"))
        result |= UInt64(byte & 0x7f) << (7k)
        byte & 0x80 == 0 && return UInt32(result)
    end
end

# an s33 (a heap type): a signed LEB128 of at most 5 bytes, the 5th holding bits 28-32, its two
# high bits the sign's extension
# parity(pkg/wasm_builder/lib/src/serialize/deserializer.dart:32 Deserializer.readSigned)
function read_s33!(d::Deserializer)::Int64
    local at = d.offset - 1
    local result = Int64(0)
    for k in 0:4
        local byte = read_byte!(d)
        (k == 4 && (byte & 0x80 != 0 || (byte & 0x70 != 0x00 && byte & 0x70 != 0x70))) &&
            throw(ArgumentError("an s33 at byte $(at) longer than 5 bytes or past 33 bits"))
        result |= Int64(byte & 0x7f) << (7k)
        if byte & 0x80 == 0
            byte & 0x40 != 0 && (result |= ~Int64(0) << (7k + 7))
            return result
        end
    end
end

# a name: its length, then that many bytes of UTF-8 (dart's utf8.decode refuses invalid UTF-8)
# parity(pkg/wasm_builder/lib/src/serialize/deserializer.dart:73 Deserializer.readName)
function read_name!(d::Deserializer)::String
    local at = d.offset - 1
    local bytes = d.data[read_range!(d, read_u32!(d))]
    isvalid(String, bytes) || throw(ArgumentError("the name at byte $(at) is not valid UTF-8"))
    return String(bytes)
end

# a heap type: a type index (an s33 >= 0) or one of the abstract heap types' codes
# parity(pkg/wasm_builder/lib/src/ir/type.dart:361 HeapType.deserialize)
function read_heap_type!(d::Deserializer)::Int64
    local at = d.offset - 1
    local code = read_s33!(d)
    (code >= 0 || -23 <= code <= -12) ||   # -0x17 (exn) through -0x0c (noexn)
        throw(ArgumentError("invalid heap type code $(code) at byte $(at)"))
    return code
end

# a value type: a number type's byte, a reference type's prefix (0x63, 0x64) and its heap type, or
# an abstract heap type's shorthand (a type index is a value type only after a prefix)
# parity(pkg/wasm_builder/lib/src/ir/type.dart:67 ValueType.deserialize)
function read_value_type!(d::Deserializer)::Nothing
    local at = d.offset - 1
    local code = d.offset <= d.stop ? d.data[d.offset] : read_byte!(d)
    if 0x7b <= code <= 0x7f
        read_byte!(d)
    elseif code == 0x63 || code == 0x64
        read_byte!(d)
        read_heap_type!(d)
    else
        # parity(pkg/wasm_builder/lib/src/ir/type.dart:256 RefType.deserialize): the shorthand's heap type
        read_heap_type!(d) < 0 || throw(ArgumentError("a type index at byte $(at) without a reference type's prefix"))
    end
    return nothing
end

# A module's sections by id, each a view over exactly its bytes (custom sections, id 0, read for
# their name and left out), after the 8-byte preamble; a section past the module's end is refused.
# parity(pkg/wasm_builder/lib/src/ir/module.dart:145 Module._deserializeTopLevel)
function module_sections(bytes::Vector{UInt8})::Dict{UInt8,Vector{Deserializer}}
    local d = Deserializer(bytes, 1, length(bytes), "module")
    length(bytes) >= 8 && bytes[read_range!(d, 8)] == UInt8[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00] ||
        throw(ArgumentError("the bytes are not a WebAssembly module: invalid Wasm preamble (`\\0asm`, version 1)"))
    local sections = Dict{UInt8,Vector{Deserializer}}()
    while !is_at_end(d)
        local id = read_byte!(d)
        local r = read_range!(d, read_u32!(d))
        local section = Deserializer(bytes, first(r), last(r), "section")
        if id == 0x00
            read_name!(section)   # a custom section: its name, refused when not UTF-8
        else
            push!(get!(() -> Deserializer[], sections, id), section)
        end
    end
    return sections
end

"""
    module_function_imports(bytes) -> Vector{Tuple{String,String}}

The function imports a module's bytes declare, `(module, field)` each in import order, from its one
import section (a second is refused), which ends exactly where its last import does. A module
WasmTarget writes imports functions and globals only (to_bytes), so an import of another kind is
refused; a global's value type and mutability are read and checked, never skipped.
parity(pkg/wasm_builder/lib/src/serialize/sections.dart:161 ImportSection.deserialize)
"""
function module_function_imports(bytes::Vector{UInt8})::Vector{Tuple{String,String}}
    local found = get(module_sections(bytes), 0x02, Deserializer[])
    length(found) <= 1 || throw(ArgumentError("the module holds $(length(found)) import sections, where a module holds one"))
    local out = Tuple{String,String}[]
    isempty(found) && return out
    local d = only(found)
    for _ in 1:read_u32!(d)
        local m = read_name!(d)
        local f = read_name!(d)
        local kind = read_byte!(d)
        if kind == 0x00                       # a function: its type index
            read_u32!(d)
            push!(out, (m, f))
        elseif kind == 0x03                   # a global: its value type, its mutability
            # parity(pkg/wasm_builder/lib/src/ir/type.dart:1320 GlobalType.deserialize)
            read_value_type!(d)
            local at = d.offset - 1
            read_byte!(d) in (0x00, 0x01) || throw(ArgumentError("a global's mutability at byte $(at) is neither 0 nor 1"))
        else
            throw(ArgumentError("the module imports $(m).$(f) of kind $(kind): a module WasmTarget writes imports functions and globals only"))
        end
    end
    is_at_end(d) || throw(ArgumentError(
        "the import section holds $(d.stop - d.offset + 1) byte(s) after its last import"))
    return out
end

"""
    module_runtime_js(bytes) -> String

The runtime of the module `bytes` as its compile generates it (WasmTarget.host_runtime_js over its
function-import record), the record read back from the bytes: for a harness that holds the bytes
alone (the compile hands its own runtime back beside them, WasmTarget.compile_with_runtime).
"""
module_runtime_js(bytes::Vector{UInt8})::String = WasmTarget.host_runtime_js(module_function_imports(bytes))

end # module WasmReader
