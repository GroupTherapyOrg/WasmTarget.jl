# ============================================================================
# Source maps (pkg/wasm_builder/lib/source_map.dart)
# ============================================================================
# A module's instructions map to the Julia source they were compiled from. The builder
# records (instruction index → SourceInfo) as it emits (start_source_mapping! /
# stop_source_mapping!, instr_builder.jl); serialization turns each index into a byte offset
# of the function body (builder_code_mapped) and then of the module (to_bytes); and
# source_map_json writes the Source Map v3 JSON that a `sourceMappingURL` section points at.
# An engine reports a trapping frame as a module byte offset, which the map resolves to the
# statement that emitted the trapping instruction.

"""
    SourceInfo(file, line, col, name)

Where mapped code came from: a source file, a 0-based line and column, and a name. WT maps a
statement to its innermost source frame (the method it was inlined from, when it was) and
names it by the statement's inline chain, innermost first (`f @ file:line ← g @ file:line`):
Julia inlines across methods, so the chain carries what dart's enclosing-member name does
and the methods between.
parity(pkg/wasm_builder/lib/source_map.dart:39 SourceInfo)
"""
struct SourceInfo
    file::String
    line::Int
    col::Int
    name::Union{Nothing,String}
end

"""
    SourceMapping(offset, info)

A mapping from `offset` — an instruction index while a builder records it, a byte offset
once serialized — to `info`; `info === nothing` unmaps the code from `offset` on (a
statement with no source location, a body's end, a function the compiler generated).
parity(pkg/wasm_builder/lib/source_map.dart:7 SourceMapping)
"""
struct SourceMapping
    offset::Int
    info::Union{Nothing,SourceInfo}
end

"""
    body_end_mapping(code) -> SourceMapping

The mapping that ends a body's mappings: the code after the body is unmapped, so no function
borrows the last segment of the one before it. Every recorded body ends with it, a serialized
builder's (builder_code_mapped) and a body codegen maps whole, as dart's serializer ends every
body with `addMapping(s.offset, null)` (instructions.dart:78).
parity(pkg/wasm_builder/lib/src/ir/instructions.dart:47 Instructions.serialize)
"""
body_end_mapping(code::Vector{UInt8})::SourceMapping = SourceMapping(length(code), nothing)

# parity(pkg/wasm_builder/lib/source_map.dart:30 SourceMapping.shiftBy)
shift_by(m::SourceMapping, shift::Int)::SourceMapping =
    shift == 0 ? m : SourceMapping(m.offset + shift, m.info)

"""
    source_map_json(mappings) -> String

The Source Map v3 JSON of `mappings` (module byte offsets, in order): the `sources` and
`names` tables, and the `mappings` string of VLQ deltas — one segment per mapping, its
generated column the byte offset (a module is one generated line). Unmapped code before the
first mapped segment is left implicit, as dart leaves it.
parity(pkg/wasm_builder/lib/source_map.dart:97 _sourceMapToJson)
"""
function source_map_json(mappings::Vector{SourceMapping})::String
    local sources = String[]
    local source_index = Dict{String,Int}()
    local names = String[]
    local name_index = Dict{String,Int}()
    for m in mappings
        m.info === nothing && continue
        haskey(source_index, m.info.file) ||
            (source_index[m.info.file] = length(sources); push!(sources, m.info.file))
        local n = m.info.name
        (n === nothing || haskey(name_index, n)) || (name_index[n] = length(names); push!(names, n))
    end
    local io = IOBuffer()
    local last_target = 0
    local last_source = 0
    local last_line = 0
    local last_col = 0
    local last_name = 0
    local first = true
    for (i, m) in enumerate(mappings)
        local info = m.info
        (info === nothing && first) && continue
        first = false
        last_target = _encode_vlq!(io, m.offset, last_target)
        if info !== nothing
            last_source = _encode_vlq!(io, source_index[info.file], last_source)
            last_line = _encode_vlq!(io, info.line, last_line)
            last_col = _encode_vlq!(io, info.col, last_col)
            info.name === nothing || (last_name = _encode_vlq!(io, name_index[info.name], last_name))
        end
        i != length(mappings) && write(io, ',')
    end
    local quoted(v) = join(("\"" * _json_string_escape(s) * "\"" for s in v), ",")
    return string("{\"version\":3,\"sources\":[", quoted(sources), "],\"names\":[", quoted(names),
                  "],\"mappings\":\"", String(take!(io)), "\"}")
end

# parity(quarantine: the JSON text of a source map is written by hand, as src/ has no JSON dependency; dart writes it with dart:convert's jsonEncode.)
function _json_string_escape(s::AbstractString)::String
    local io = IOBuffer()
    for c in s
        if c == '"' || c == '\\'
            write(io, '\\', c)
        elseif c < ' '
            write(io, "\\u", string(UInt16(c); base=16, pad=4))
        else
            write(io, c)
        end
    end
    return String(take!(io))
end

# parity(pkg/wasm_builder/lib/source_map.dart:211 _vlqBaseShift)
const _VLQ_BASE_SHIFT = 5
# parity(pkg/wasm_builder/lib/source_map.dart:212 _vlqBaseMask)
const _VLQ_BASE_MASK = (1 << 5) - 1
# parity(pkg/wasm_builder/lib/source_map.dart:213 _vlqContinuationBit)
const _VLQ_CONTINUATION_BIT = 1 << 5
# parity(pkg/wasm_builder/lib/source_map.dart:214 _base64Digits)
const _BASE64_DIGITS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

"""
    _encode_vlq!(io, value, offset) -> value

Write the base64 VLQ of `value - offset` to `io` and return `value` (the next delta's base).
parity(pkg/wasm_builder/lib/source_map.dart:192 _encodeVLQ)
"""
function _encode_vlq!(io::IO, value::Int, offset::Int)::Int
    local delta = value - offset
    local sign_bit = 0
    if delta < 0
        sign_bit = 1
        delta = -delta
    end
    delta = (delta << 1) | sign_bit
    while true
        local digit = delta & _VLQ_BASE_MASK
        delta >>= _VLQ_BASE_SHIFT
        delta > 0 && (digit |= _VLQ_CONTINUATION_BIT)
        write(io, _BASE64_DIGITS[digit + 1])
        delta > 0 || break
    end
    return value
end
