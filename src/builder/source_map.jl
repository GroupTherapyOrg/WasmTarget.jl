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

# The source map extension that names each class of a minified build: dart2js's
# `x_org_dartlang_dart2js.minified_names`, which maps "Class<id>" to an index of `names`.
# parity(pkg/dart2wasm/lib/source_map_utils.dart:5 _sourceMapExtensionName)
const _SOURCE_MAP_EXTENSION_NAME = "x_org_dartlang_dart2js"

"""
    add_minified_class_names(source_map_json, class_names) -> String

The source map with the names of the module's classes, so a `minified:Class<id>` a host prints
for an escaped exception (host_escape_js) reads as the class's name: `class_names[id + 1]` is
class `id`'s name, `nothing` for an id no class has. A name already in `names` is reused,
the rest are appended, and the extension's `global` lists "Class<id>,<name index>" pairs
(its `instance` list empty, as tools expect it present).
parity(pkg/dart2wasm/lib/source_map_utils.dart:15 addMinifiedClassNames)
"""
function add_minified_class_names(source_map_json::String, class_names::Vector{Union{Nothing,String}})::String
    local sm = _json_read(source_map_json)::Vector{Pair{String,Any}}
    local names = _json_field(sm, "names")::Vector{Any}
    local name_indices = Dict{String,Int}()
    for (i, n) in enumerate(names)
        name_indices[n] = i - 1
    end
    local minified_to_unminified = String[]
    for (k, unminified) in enumerate(class_names)
        unminified === nothing && continue
        local index = get(name_indices, unminified, nothing)
        if index === nothing
            index = length(names)
            push!(names, unminified)
        end
        push!(minified_to_unminified, "Class$(k - 1),$(index)")
    end
    local extension = Pair{String,Any}["minified_names" => Pair{String,Any}[
        "global" => join(minified_to_unminified, ","), "instance" => ""]]
    local at = findfirst(p -> p.first == _SOURCE_MAP_EXTENSION_NAME, sm)
    at === nothing ? push!(sm, _SOURCE_MAP_EXTENSION_NAME => extension) :
                     (sm[at] = _SOURCE_MAP_EXTENSION_NAME => extension)
    return _json_write(sm)
end

"""
    minified_class_names(source_map_json) -> Union{Nothing, Vector{Union{Nothing,String}}}

The class names add_minified_class_names wrote into a source map, `[id + 1]` for class `id`
(trailing ids no class has dropped), or `nothing` for a map without the extension.
parity(pkg/dart2wasm/lib/source_map_utils.dart:63 getMinifiedClassNames)
"""
function minified_class_names(source_map_json::String)::Union{Nothing,Vector{Union{Nothing,String}}}
    local sm = _json_read(source_map_json)::Vector{Pair{String,Any}}
    local names = _json_field(sm, "names")::Vector{Any}
    local extension = _json_field(sm, _SOURCE_MAP_EXTENSION_NAME)
    extension === nothing && return nothing
    local global_list = _json_field(_json_field(extension, "minified_names"), "global")::String
    local global_minified_names = isempty(global_list) ? String[] : split(global_list, ",")
    local unminified_class_names = Union{Nothing,String}[]
    for i in 1:2:length(global_minified_names)
        local minified = global_minified_names[i]
        startswith(minified, "Class") || error("source map: a minified class name `$minified` is not Class<id>")
        local class_id = parse(Int, minified[6:end])
        local unminified = names[parse(Int, global_minified_names[i + 1]) + 1]::String
        while length(unminified_class_names) <= class_id
            push!(unminified_class_names, nothing)
        end
        unminified_class_names[class_id + 1] === nothing ||
            error("source map: class $class_id is named twice")
        unminified_class_names[class_id + 1] = unminified
    end
    return unminified_class_names
end

# A source map's JSON value: an object as its (key => value) pairs in order, an array, a string,
# an integer or a float, true, false and null (nothing).
# parity(quarantine: src/ has no JSON dependency (as _json_string_escape); dart decodes a source map with dart:convert's jsonDecode, io_util.dart:168)
const _JsonValue = Union{Vector{Pair{String,Any}}, Vector{Any}, String, Int, Float64, Bool, Nothing}

# A source map's JSON text, read into its value.
# parity(quarantine: src/ has no JSON dependency (as _json_string_escape); dart decodes a source map with dart:convert's jsonDecode, io_util.dart:168)
function _json_read(s::String)::_JsonValue
    local v, i = _json_value(s, _json_skip(s, 1))
    _json_skip(s, i) > ncodeunits(s) || error("source map: text after its JSON value, at byte $i")
    return v
end

# parity(quarantine: src/ has no JSON dependency (as _json_string_escape); dart decodes a source map with dart:convert's jsonDecode, io_util.dart:168)
function _json_skip(s::String, i::Int)::Int
    while i <= ncodeunits(s) && codeunit(s, i) in (0x20, 0x09, 0x0a, 0x0d)
        i += 1
    end
    return i
end

# parity(quarantine: src/ has no JSON dependency (as _json_string_escape); dart decodes a source map with dart:convert's jsonDecode, io_util.dart:168)
function _json_value(s::String, i::Int)::Tuple{_JsonValue,Int}
    i <= ncodeunits(s) || error("source map: its JSON ends inside a value")
    local c = codeunit(s, i)
    c == UInt8('"') && return _json_string(s, i)
    if c == UInt8('{') || c == UInt8('[')
        local object = c == UInt8('{')
        local close = object ? UInt8('}') : UInt8(']')
        local items = object ? Pair{String,Any}[] : Any[]
        i = _json_skip(s, i + 1)
        local first = true
        while i <= ncodeunits(s) && codeunit(s, i) != close
            if !first
                codeunit(s, i) == UInt8(',') || error("source map: no `,` between values, at byte $i")
                i = _json_skip(s, i + 1)
            end
            first = false
            if object
                local key
                key, i = _json_string(s, i)
                i = _json_skip(s, i)
                codeunit(s, i) == UInt8(':') || error("source map: no `:` after key \"$key\", at byte $i")
                local v
                v, i = _json_value(s, _json_skip(s, i + 1))
                any(p -> p.first == key, items) && error("source map: duplicate key \"$key\" in an object")
                push!(items, key => v)
            else
                local v
                v, i = _json_value(s, i)
                push!(items, v)
            end
            i = _json_skip(s, i)
        end
        i <= ncodeunits(s) || error("source map: its JSON ends inside a value")
        return items, i + 1
    end
    local j = i
    while j <= ncodeunits(s) && !(codeunit(s, j) in (UInt8(','), UInt8('}'), UInt8(']'), 0x20, 0x09, 0x0a, 0x0d))
        j += 1
    end
    local word = s[i:prevind(s, j)]
    word == "true" && return true, j
    word == "false" && return false, j
    word == "null" && return nothing, j
    # JSON's number grammar exactly (RFC 8259 §6): no `+`, no leading zero, no Inf or NaN
    local m = match(r"^-?(?:0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$", word)
    m === nothing && error("source map: `$word` is not a JSON value, at byte $i")
    if m.captures[1] === nothing && m.captures[2] === nothing
        local n = tryparse(Int, word)
        n === nothing && error("source map: the integer `$word` does not fit an Int, at byte $i")
        return n, j
    end
    return parse(Float64, word), j
end

# parity(quarantine: src/ has no JSON dependency (as _json_string_escape); dart decodes a source map with dart:convert's jsonDecode, io_util.dart:168)
function _json_string(s::String, i::Int)::Tuple{String,Int}
    codeunit(s, i) == UInt8('"') || error("source map: a string expected at byte $i")
    local io = IOBuffer()
    i += 1
    while i <= ncodeunits(s)
        local c = codeunit(s, i)
        c == UInt8('"') && return String(take!(io)), i + 1
        c < 0x20 && error("source map: a raw control character (0x$(string(c, base=16, pad=2))) in a string, at byte $i")
        if c != UInt8('\\')
            write(io, c)
            i += 1
            continue
        end
        i + 1 <= ncodeunits(s) || error("source map: its JSON ends inside a string")
        local e = Char(codeunit(s, i + 1))
        if e == 'u'
            local u = _json_hex4(s, i)
            i += 6
            if 0xd800 <= u <= 0xdbff
                # a high surrogate is half of a pair: its low half must follow
                (i + 1 <= ncodeunits(s) && codeunit(s, i) == UInt8('\\') && codeunit(s, i + 1) == UInt8('u')) ||
                    error("source map: a high surrogate \\u$(string(u; base=16)) with no low surrogate, at byte $(i - 6)")
                local lo = _json_hex4(s, i)
                0xdc00 <= lo <= 0xdfff ||
                    error("source map: a high surrogate \\u$(string(u; base=16)) with no low surrogate, at byte $(i - 6)")
                u = 0x10000 + ((u - 0xd800) << 10) + (lo - 0xdc00)
                i += 6
            elseif 0xdc00 <= u <= 0xdfff
                error("source map: a low surrogate \\u$(string(u; base=16)) with no high surrogate, at byte $(i - 6)")
            end
            write(io, Char(u))
        elseif e in ('"', '\\', '/', 'b', 'f', 'n', 'r', 't')
            write(io, e == 'n' ? '\n' : e == 't' ? '\t' : e == 'r' ? '\r' : e == 'b' ? '\b' : e == 'f' ? '\f' : e)
            i += 2
        else
            error("source map: the escape `\\$e` is not JSON's, at byte $i")
        end
    end
    error("source map: its JSON ends inside a string")
end

# the four hex digits of the `\u` escape at byte `i`
# parity(quarantine: src/ has no JSON dependency (as _json_string_escape); dart decodes a source map with dart:convert's jsonDecode, io_util.dart:168)
function _json_hex4(s::String, i::Int)::UInt32
    (i + 5 <= ncodeunits(s) && all(k -> codeunit(s, k) in UInt8('0'):UInt8('9') ||
                                       codeunit(s, k) in UInt8('a'):UInt8('f') ||
                                       codeunit(s, k) in UInt8('A'):UInt8('F'), i + 2:i + 5)) ||
        error("source map: `\\u` needs four hex digits, at byte $i")
    return parse(UInt32, s[i + 2:i + 5]; base=16)
end

# A JSON value as text, an object's pairs in their order.
# parity(quarantine: src/ has no JSON dependency (as _json_string_escape); dart encodes a source map with dart:convert's jsonEncode, io_util.dart:209)
function _json_write(v)::String
    v isa Vector{Pair{String,Any}} &&
        return "{" * join(("\"" * _json_string_escape(k) * "\":" * _json_write(x) for (k, x) in v), ",") * "}"
    v isa Vector{Any} && return "[" * join((_json_write(x) for x in v), ",") * "]"
    v isa String && return "\"" * _json_string_escape(v) * "\""
    v === nothing && return "null"
    v isa Bool && return v ? "true" : "false"
    v isa Int && return string(v)
    v isa Float64 && isfinite(v) && return repr(v)
    error("source map: no JSON text for $(repr(v))")
end

# the value of `key` in a JSON object read by _json_read, or nothing
# parity(quarantine: src/ has no JSON dependency (as _json_string_escape); dart reads a decoded map by key, source_map_utils.dart:19)
function _json_field(object::Vector{Pair{String,Any}}, key::String)::_JsonValue
    local at = findfirst(p -> p.first == key, object)
    return at === nothing ? nothing : object[at].second
end
