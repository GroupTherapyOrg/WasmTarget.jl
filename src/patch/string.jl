# String's byte-level operations by overlay (the String ruling, src/julia/classes.jl
# _string_instance_fields): Base reads and writes a String through a raw pointer (Core.sizeof of its
# memory, pointer(s, i) loads, jl_alloc_string, unsafe_copyto!), and WasmGC has no raw memory, so each
# such method is replaced in WasmInterpreter's overlay method table by one written against the
# String's data through dart:_wasm's array operations (src/julia/wasm_array.jl), as dart's own string
# patches read and write their WasmArray. Each overlay is consistent: natively it computes Base's
# answer. precedent(dart: the wasm target's @patch libraries, sdk/lib/_internal/wasm; gpucompiler: a
# device's overlays of Base in its method table).

@quarantine "Base's ncodeunits is Core.sizeof of the String's memory; WasmGC has no raw memory, so it is the data array's length" Base.ncodeunits @consistent_overlay WasmInterpreter.METHOD_TABLE Base.ncodeunits(s::String) = wasm_string_length(s)

@quarantine "Base's sizeof of a String is Core.sizeof of its memory; WasmGC has no raw memory, so it is the data array's length" Base.sizeof @consistent_overlay WasmInterpreter.METHOD_TABLE Base.sizeof(s::String) = wasm_string_length(s)

@quarantine "Base's codeunit loads through pointer(s, i); WasmGC has no pointer, so the byte is the data array's element" Base.codeunit @consistent_overlay WasmInterpreter.METHOD_TABLE @inline function Base.codeunit(s::String, i::Int)
    @boundscheck checkbounds(s, i)
    return wasm_string_codeunit(s, i - 1)
end

@quarantine "Base's _string_n is a jl_alloc_string foreigncall; WasmGC allocates the String's struct and a new data array" Base._string_n @consistent_overlay WasmInterpreter.METHOD_TABLE Base._string_n(n::Integer) = wasm_string_alloc(Int(n))

# Base's takes any `out` it can take a pointer to; the String its callers allocate is the one a data
# array holds, so any other `out` stays Base's, a located rejection where it is reached
@quarantine "Base's __unsafe_string! copies a String's bytes through pointers; WasmGC copies the data arrays (array.copy)" Base.__unsafe_string! @consistent_overlay WasmInterpreter.METHOD_TABLE @inline function Base.__unsafe_string!(out::String, s::String, offs::Integer)
    local n = wasm_string_length(s)
    wasm_string_copy!(out, Int(offs) - 1, s, 0, n)
    return n
end
