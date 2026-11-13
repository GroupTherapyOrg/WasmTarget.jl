# A String's or a byte Vector's bytes written into an IOBuffer by overlay, as src/patch/string.jl's String
# operations: Base writes a String or a SubString of one (base/strings/io.jl:246 write,
# unsafe_write(io, pointer(s), sizeof(s))), or a byte Vector, as Ryu's show of a float writes its digits
# (base/io.jl:841 write of a StridedArray, unsafe_write(s, pointer(A), elsize(A) * length(A))), through
# a raw pointer to its bytes, and WasmGC has no raw memory, so the method is
# replaced in WasmTarget's overlay method table (METHOD_TABLE, src/julia/interpreter.jl) for the buffer
# whose data array the bytes are copied into (base/iobuffer.jl:822 unsafe_write of a GenericIOBuffer),
# the String's data shared as a byte Memory (src/julia/wasm_array.jl wasm_string_memory), or the
# Vector itself, in place of its pointer, as dart's string patches copy their WasmArray. The overlay is consistent: natively it
# computes Base's answer. Any other IO stays Base's, a located rejection where it is reached.
# precedent(dart: the wasm target's @patch libraries, sdk/lib/_internal/wasm; gpucompiler: a device's
# overlays of Base in its method table).

# Base's body of unsafe_write(to::GenericIOBuffer, p, nb) (base/iobuffer.jl:822), its source the
# String's bytes from its offset or the byte Vector's from its first: its _unsafe_write's copy
# (iobuffer.jl:849, unsafe_copyto! from the pointer into the buffer's data) is copyto! from the bytes
# shared as a Memory, or from the Vector, an array.copy
@quarantine "julia/base/strings/io.jl:246 write of a String or SubString{String}, and julia/base/io.jl:841 write of a byte Vector, write their bytes from pointer(s) (julia/base/iobuffer.jl:822 unsafe_write into a GenericIOBuffer, unsafe_copyto! from the pointer); WasmGC copies the String's data array, or the Vector's, into the buffer's (array.copy)" Base.write @consistent_overlay METHOD_TABLE function Base.write(to::Base.GenericIOBuffer, s::Union{String,SubString{String},Vector{UInt8}})
    local src, from = s isa String ? (wasm_string_memory(s), 0) : s isa SubString{String} ? (wasm_string_memory(s.string), s.offset) : (s, 0)
    local nb = UInt(sizeof(s))
    Base.ensureroom(to, nb)
    local size = to.size
    local append = to.append
    local ptr = append ? size + 1 : to.ptr
    local data = to.data
    local start_offset = ptr - 1
    local to_write = max(0, min(nb, (min(Int(length(data))::Int - start_offset, to.maxsize - (start_offset - Base.get_offset(to)))) % UInt) % Int)
    copyto!(data, ptr, src, from + 1, to_write)
    to.size = max(size, start_offset + to_write)
    if !append
        to.ptr = ptr + to_write
    end
    return to_write
end
