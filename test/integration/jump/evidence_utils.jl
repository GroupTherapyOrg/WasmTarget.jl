module JumpCertificationEvidence

using SHA

export canonical_text_sha256, is_wasm_tools_version

"""
Hash committed text independent of Git's native-line-ending checkout, while
rejecting ambiguous lone carriage returns rather than silently rewriting them.
"""
function canonical_text_sha256(path)
    canonical = replace(read(path, String), "\r\n" => "\n")
    occursin('\r', canonical) &&
        error("text provenance contains an unsupported lone carriage return")
    return bytes2hex(sha256(codeunits(canonical)))
end

"""
Accept the pinned semantic wasm-tools version with either no build metadata or
wasm-tools' constrained `(commit date)` suffix.
"""
function is_wasm_tools_version(value, expected)
    value isa AbstractString || return false
    parsed = match(
        r"^wasm-tools ([0-9]+\.[0-9]+\.[0-9]+)(?: \([0-9a-f]+ [0-9]{4}-[0-9]{2}-[0-9]{2}\))?$",
        value,
    )
    return parsed !== nothing && only(parsed.captures) == expected
end

end
