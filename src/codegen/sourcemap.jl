# ============================================================================
# Source Map Generation
# Maps Wasm byte offsets back to Julia source file/line via Source Map V3
# ============================================================================

"""
    SourceMapping

A single mapping from a Wasm byte offset to a Julia source location.
"""
struct SourceMapping
    wasm_offset::UInt32   # Byte offset in the Wasm code section
    source_idx::UInt32    # Index into sources array
    line::Int32           # 0-based line number in source file
    column::Int32         # 0-based column (0 if unknown)
end

"""
    SourceMapInfo

Collected source location info for all compiled functions.
"""
mutable struct SourceMapInfo
    sources::Vector{String}       # Source file paths
    source_contents::Vector{String}  # Optional inline source content
    mappings::Vector{SourceMapping}
    source_index::Dict{String, UInt32}  # path → index into sources
end

SourceMapInfo() = SourceMapInfo(String[], String[], SourceMapping[], Dict{String, UInt32}())

"""
    add_source!(smi::SourceMapInfo, filepath::String) -> UInt32

Register a source file and return its index (0-based).
"""
function add_source!(smi::SourceMapInfo, filepath::String)
    get!(smi.source_index, filepath) do
        idx = UInt32(length(smi.sources))
        push!(smi.sources, filepath)
        push!(smi.source_contents, "")
        return idx
    end
end

"""
    collect_source_info(functions::Vector) -> SourceMapInfo

Extract source file/line information from Julia functions.
Uses Method metadata (file, line) for function-level mapping.
"""
function collect_source_info(functions::Vector)
    smi = SourceMapInfo()

    for entry in functions
        f = entry[1]
        arg_types = entry[2]

        try
            ms = methods(f, Tuple{arg_types...})
            if length(ms.ms) > 0
                m = ms.ms[1]
                filepath = string(m.file)
                line = Int32(m.line)

                # Register source file
                src_idx = add_source!(smi, filepath)

                # Store function-level mapping (wasm_offset filled later)
                push!(smi.mappings, SourceMapping(UInt32(0), src_idx, line - Int32(1), Int32(0)))
            end
        catch
            # If method lookup fails, skip — function may be a lambda
        end
    end

    return smi
end

# ============================================================================
# VLQ Encoding (Source Map V3 format)
# ============================================================================

const VLQ_BASE_SHIFT = 5
const VLQ_BASE = 1 << VLQ_BASE_SHIFT  # 32
const VLQ_BASE_MASK = VLQ_BASE - 1     # 0x1F
const VLQ_CONTINUATION_BIT = VLQ_BASE  # 0x20

const BASE64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

"""
    vlq_encode(value::Int) -> String

Encode an integer as a VLQ base64 string for Source Map V3.
"""
function vlq_encode(value::Int)
    result = Char[]

    # Convert to VLQ signed: positive → even, negative → odd
    vlq = value < 0 ? ((-value) << 1) + 1 : value << 1

    while true
        digit = vlq & VLQ_BASE_MASK
        vlq >>= VLQ_BASE_SHIFT
        if vlq > 0
            digit |= VLQ_CONTINUATION_BIT
        end
        push!(result, BASE64_CHARS[digit + 1])  # 1-indexed
        vlq == 0 && break
    end

    return String(result)
end

# ============================================================================
# Source Map V3 JSON Generation
# ============================================================================

"""
    generate_source_map(smi::SourceMapInfo; file::String="module.wasm") -> String

Generate a Source Map V3 JSON string from collected source info.
"""
function generate_source_map(smi::SourceMapInfo; file::String="module.wasm")
    # Sort mappings by wasm_offset
    sorted = sort(smi.mappings, by=m -> m.wasm_offset)

    # Generate VLQ-encoded mappings string
    # Each segment: [generatedColumn, sourceIndex, originalLine, originalColumn]
    # Segments separated by commas; lines separated by semicolons
    # For Wasm, we use a single "line" (the entire binary)
    mappings_str = IOBuffer()

    prev_col = 0
    prev_src = 0
    prev_line = 0
    prev_orig_col = 0

    for (i, m) in enumerate(sorted)
        if i > 1
            write(mappings_str, ',')
        end

        # Generated column (Wasm byte offset delta)
        col_delta = Int(m.wasm_offset) - prev_col
        write(mappings_str, vlq_encode(col_delta))
        prev_col = Int(m.wasm_offset)

        # Source index delta
        src_delta = Int(m.source_idx) - prev_src
        write(mappings_str, vlq_encode(src_delta))
        prev_src = Int(m.source_idx)

        # Original line delta (0-based)
        line_delta = Int(m.line) - prev_line
        write(mappings_str, vlq_encode(line_delta))
        prev_line = Int(m.line)

        # Original column delta
        col_orig_delta = Int(m.column) - prev_orig_col
        write(mappings_str, vlq_encode(col_orig_delta))
        prev_orig_col = Int(m.column)
    end

    mappings_encoded = String(take!(mappings_str))

    # Build JSON manually (avoid dependency on JSON package in src/)
    sources_json = join(["\"$(escape_json(s))\"" for s in smi.sources], ",")

    json = """{
  "version": 3,
  "file": "$(escape_json(file))",
  "sources": [$sources_json],
  "names": [],
  "mappings": "$mappings_encoded"
}"""

    return json
end

function escape_json(s::String)
    s = replace(s, "\\" => "\\\\")
    s = replace(s, "\"" => "\\\"")
    s = replace(s, "\n" => "\\n")
    s = replace(s, "\r" => "\\r")
    s = replace(s, "\t" => "\\t")
    return s
end

# ============================================================================
# Wasm Custom Section: sourceMappingURL
# ============================================================================

"""
    append_source_mapping_url!(wasm_bytes::Vector{UInt8}, url::String) -> Vector{UInt8}

Append a `sourceMappingURL` custom section to the Wasm binary.
This tells browser DevTools where to find the source map.
"""
function append_source_mapping_url!(wasm_bytes::Vector{UInt8}, url::String)
    w = WasmWriter()

    # Custom section id
    write_byte!(w, 0x00)

    # Section content
    section = WasmWriter()
    write_name!(section, "sourceMappingURL")
    write_name!(section, url)

    # Section size + content
    write_u32!(w, length(section.buffer))
    append!(w.buffer, section.buffer)

    append!(wasm_bytes, w.buffer)
    return wasm_bytes
end

"""
    compile_with_sourcemap(f, arg_types; optimize=false, sourcemap_url="module.wasm.map")
        -> (wasm_bytes, sourcemap_json)

Compile a function and generate both the Wasm binary and a Source Map V3 JSON.
The Wasm binary includes a `sourceMappingURL` custom section.
"""
function compile_with_sourcemap(f, arg_types::Tuple;
                                optimize=false,
                                sourcemap_url::String="module.wasm.map")
    func_name = string(nameof(f))

    # Collect source info before compilation
    smi = collect_source_info([(f, arg_types, func_name)])

    # Compile
    mod = compile_function(f, arg_types, func_name)
    bytes = to_bytes(mod)

    if optimize !== false
        level = optimize === true ? :size : optimize
        bytes = WasmTarget.optimize(bytes; level=level)
    end

    # Update mappings with approximate Wasm offsets
    # The code section starts after header + type/import/function/table/memory/global/export/start/element sections
    # For function-level mapping, we use the start of the code section as the offset
    # This gives "approximately correct" line numbers
    update_function_offsets!(smi, bytes)

    # Generate source map
    sourcemap_json = generate_source_map(smi; file=basename_or_default(sourcemap_url))

    # Append sourceMappingURL custom section
    append_source_mapping_url!(bytes, sourcemap_url)

    return (bytes, sourcemap_json)
end

"""
    compile_multi_with_sourcemap(functions; optimize=false, sourcemap_url="module.wasm.map")
        -> (wasm_bytes, sourcemap_json)

Compile multiple functions and generate both Wasm binary and Source Map V3 JSON.
"""
function compile_multi_with_sourcemap(functions::Vector;
                                       optimize=false,
                                       sourcemap_url::String="module.wasm.map")
    # Collect source info
    smi = collect_source_info(functions)

    # Compile
    mod = compile_module(functions)
    bytes = to_bytes(mod)

    if optimize !== false
        level = optimize === true ? :size : optimize
        bytes = WasmTarget.optimize(bytes; level=level)
    end

    # Update mappings
    update_function_offsets!(smi, bytes)

    # Generate source map
    sourcemap_json = generate_source_map(smi; file=basename_or_default(sourcemap_url))

    # Append sourceMappingURL section
    append_source_mapping_url!(bytes, sourcemap_url)

    return (bytes, sourcemap_json)
end

"""
    update_function_offsets!(smi::SourceMapInfo, wasm_bytes::Vector{UInt8})

Scan the Wasm binary to find the code section and assign approximate
byte offsets to each function mapping.
"""
function update_function_offsets!(smi::SourceMapInfo, wasm_bytes::Vector{UInt8})
    isempty(smi.mappings) && return

    # Find code section (section id 10 = 0x0A)
    code_offset = find_section_offset(wasm_bytes, 0x0A)
    code_offset === nothing && return

    # Parse code section to find function body offsets
    pos = code_offset
    # Read section size (LEB128)
    section_size, pos = read_leb128(wasm_bytes, pos)
    # Read function count (LEB128)
    func_count, pos = read_leb128(wasm_bytes, pos)

    # For each function body, record the start offset
    func_offsets = UInt32[]
    for i in 1:func_count
        push!(func_offsets, UInt32(pos))
        # Read body size and skip
        body_size, pos = read_leb128(wasm_bytes, pos)
        pos += body_size
    end

    # Assign offsets to mappings (one mapping per user function)
    # Skip import functions — func_offsets are for defined functions only
    for (i, mapping) in enumerate(smi.mappings)
        if i <= length(func_offsets)
            smi.mappings[i] = SourceMapping(
                func_offsets[i],
                mapping.source_idx,
                mapping.line,
                mapping.column
            )
        end
    end
end

"""
    find_section_offset(wasm_bytes::Vector{UInt8}, section_id::UInt8) -> Union{Int, Nothing}

Find the byte offset of a section's content (after the section id byte)
in a Wasm binary. Returns the position right after the section id byte.
"""
function find_section_offset(wasm_bytes::Vector{UInt8}, section_id::UInt8)
    length(wasm_bytes) < 8 && return nothing

    # Skip magic + version (8 bytes)
    pos = 9  # 1-indexed

    while pos <= length(wasm_bytes)
        sid = wasm_bytes[pos]
        pos += 1
        if sid == section_id
            return pos  # position of section size LEB128
        end
        # Skip this section (read size, advance)
        size, pos = read_leb128(wasm_bytes, pos)
        pos += size
    end

    return nothing
end

"""
    read_leb128(bytes::Vector{UInt8}, pos::Int) -> (value, new_pos)

Read an unsigned LEB128 value starting at position `pos` (1-indexed).
"""
function read_leb128(bytes::Vector{UInt8}, pos::Int)
    result = UInt64(0)
    shift = 0
    while pos <= length(bytes)
        b = bytes[pos]
        pos += 1
        result |= UInt64(b & 0x7F) << shift
        if (b & 0x80) == 0
            return (Int(result), pos)
        end
        shift += 7
    end
    return (Int(result), pos)
end

function basename_or_default(path::String)
    parts = split(path, '/')
    return isempty(parts) ? "module.wasm" : string(last(parts))
end
