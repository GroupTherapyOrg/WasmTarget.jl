# A pointer's comparisons by overlay: Base compares two pointers by their integer addresses
# (julia/base/pointer.jl:310-312, `UInt(x) == UInt(y)`, `<` and `-` likewise), and WasmTarget's pointer is a
# managed pointer, its base and its byte offset (src/julia/classes.jl managed_pointer), whose address as an
# integer exists only where it has no base. Each method is replaced in WasmTarget's overlay method table
# (METHOD_TABLE, src/julia/interpreter.jl) by one that answers over the parts (src/julia/wasm_array.jl
# wasm_pointer_based, wasm_pointer_same_base, wasm_pointer_offset) wherever Julia's answer is fixed by them:
# two pointers of one base by their offsets, as the address of each is its base's plus its offset; two of
# distinct data arrays are never equal, as no two of Julia's live objects share an address; the null pointer
# lies below every object's address and is equal to none. Where the answer depends on where Julia placed an
# object (two objects' order or distance, an object's address against a nonzero integer), Base's body reads
# the integer address, which a pointer into a data array does not have: the bitcast arm's gap at run time,
# located (src/intrinsics.jl's pointer arm). The overlays are consistent: natively every pointer has no base,
# so each computes Base's own answer.
# precedent(dart: the wasm target's @patch libraries, sdk/lib/_internal/wasm; graalvm: Sulong's
# LLVMManagedPointer comparisons, equal when their objects are one and their offsets equal).

@quarantine pin"julia/base/boot.jl:968 UInt" "Base compares two pointers' integer addresses, UInt of each (julia/base/pointer.jl:310); a managed pointer into a data array has none, so two of one base compare their offsets and two of distinct objects or of an object and null are unequal" Base.:(==) @consistent_overlay METHOD_TABLE function Base.:(==)(x::Ptr, y::Ptr)
    wasm_pointer_same_base(x, y) && return wasm_pointer_offset(x) == wasm_pointer_offset(y)
    # distinct bases: two data arrays, or one and an integer address
    wasm_pointer_based(x) && wasm_pointer_based(y) && return false
    (wasm_pointer_based(x) ? wasm_pointer_offset(y) : wasm_pointer_offset(x)) == 0 && return false
    return UInt(x) == UInt(y)
end

@quarantine pin"julia/base/boot.jl:968 UInt" "Base orders two pointers by their integer addresses, UInt of each (julia/base/pointer.jl:311); a managed pointer into a data array has none, so two of one base compare their offsets and the null pointer lies below every object's" Base.:(<) @consistent_overlay METHOD_TABLE function Base.:(<)(x::Ptr, y::Ptr)
    wasm_pointer_same_base(x, y) && return wasm_pointer_offset(x) < wasm_pointer_offset(y)
    !wasm_pointer_based(x) && wasm_pointer_offset(x) == 0 && return true
    !wasm_pointer_based(y) && wasm_pointer_offset(y) == 0 && return false
    return UInt(x) < UInt(y)
end

@quarantine pin"julia/base/boot.jl:968 UInt" "Base's distance of two pointers is the difference of their integer addresses, UInt of each (julia/base/pointer.jl:312); two managed pointers of one base differ by their offsets" Base.:(-) @consistent_overlay METHOD_TABLE function Base.:(-)(x::Ptr, y::Ptr)
    wasm_pointer_same_base(x, y) && return wasm_pointer_offset(x) - wasm_pointer_offset(y)
    return UInt(x) - UInt(y)
end
