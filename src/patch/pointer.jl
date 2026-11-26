# A pointer's comparisons by overlay: Base compares two pointers by their integer addresses
# (julia/base/pointer.jl:310-312, `UInt(x) == UInt(y)`, `<` and `-` likewise, UInt a bitcast of the bits,
# julia/base/boot.jl:968 UInt), and WasmTarget's pointer is a managed pointer, its base and its byte offset
# (src/julia/classes.jl managed_pointer, dart's byte view: a buffer's data array and its offsetInBytes,
# sdk/lib/_internal/wasm/common/typed_data.dart:93 ByteDataBase.offsetInBytes), whose address as an integer
# exists only where it has no base. Each method is replaced in WasmTarget's overlay method table
# (METHOD_TABLE, src/julia/interpreter.jl) by one that answers over the parts (src/julia/wasm_array.jl
# wasm_pointer_based, wasm_pointer_same_base, wasm_pointer_offset) only where Julia's answer is fixed by them:
# - two pointers of one base, by their offsets: the address of each is its base's plus its offset, as dart
#   reads a view's byte at its offsetInBytes plus the index within one buffer (typed_data.dart:515);
# - two of distinct data arrays, unequal: dart's two buffers are equal only when their data arrays are one
#   object (sdk/lib/_internal/wasm/common/typed_data.dart:1243 _I8ByteBuffer.==), and Julia gives each memory
#   its own storage, inline behind its own header or a block of its own (julia/src/genericmemory.c:30
#   jl_alloc_genericmemory_unchecked), so no address within one is an address within another;
# - C_NULL, address 0 (julia/base/pointer.jl:18 C_NULL), against a pointer into a data array: unequal and
#   below it, as Julia's allocator throws rather than return a null block (jl_gc_managed_malloc,
#   julia/src/gc-stock.c:3827), so no object's address is 0; and no unsigned address is below 0, Base's own
#   UInt order.
# Where the answer depends on where Julia placed an object (two objects' order or distance, an object's
# address against a nonzero integer), WasmTarget holds no answer, and dart's views of two buffers have no
# order either: Base's body reads the integer address, which a pointer into a data array does not have, the
# bitcast arm's gap at run time, located (src/intrinsics.jl's pointer arm), never an invented order. The
# overlays are consistent: natively every pointer has no base, so each computes Base's own answer.
# precedent(dart: the wasm target's @patch libraries, sdk/lib/_internal/wasm, its byte views compared by
# their buffers' data arrays). Julia's differs: Julia compares integer addresses; a pointer of no object is
# an integer here too, compared as Base compares it.

@quarantine pin"julia/base/boot.jl:968 UInt" "Base compares two pointers' integer addresses, UInt of each (julia/base/pointer.jl:310); a managed pointer into a data array has none, so two of one base compare their offsets, as dart's view reads at its offsetInBytes within one buffer, two of distinct data arrays are unequal, as dart's two buffers are equal only when their data arrays are identical and Julia gives each memory its own storage, and one into a data array is unequal to C_NULL, as no object's address is 0; any other pair reads the integer addresses, a located gap at run time where one has a base" Base.:(==) @consistent_overlay METHOD_TABLE function Base.:(==)(x::Ptr, y::Ptr)
    wasm_pointer_same_base(x, y) && return wasm_pointer_offset(x) == wasm_pointer_offset(y)
    # distinct bases: two data arrays, or one and an integer address
    wasm_pointer_based(x) && wasm_pointer_based(y) && return false
    (wasm_pointer_based(x) ? wasm_pointer_offset(y) : wasm_pointer_offset(x)) == 0 && return false
    return UInt(x) == UInt(y)
end

@quarantine pin"julia/base/boot.jl:968 UInt" "Base orders two pointers by their integer addresses, UInt of each (julia/base/pointer.jl:311); a managed pointer into a data array has none, so two of one base order by their offsets, as dart's view's offsetInBytes within one buffer, C_NULL's 0 is below every object's address, none of which is 0, and no unsigned address is below 0; two of distinct objects have no order WasmTarget holds and read the integer addresses, a located gap at run time" Base.:(<) @consistent_overlay METHOD_TABLE function Base.:(<)(x::Ptr, y::Ptr)
    wasm_pointer_same_base(x, y) && return wasm_pointer_offset(x) < wasm_pointer_offset(y)
    !wasm_pointer_based(x) && wasm_pointer_offset(x) == 0 && return true
    !wasm_pointer_based(y) && wasm_pointer_offset(y) == 0 && return false
    return UInt(x) < UInt(y)
end

@quarantine pin"julia/base/boot.jl:968 UInt" "Base's distance of two pointers is the difference of their integer addresses, UInt of each (julia/base/pointer.jl:312); two managed pointers of one base differ by their offsets, as dart's view's offsetInBytes within one buffer; two of distinct objects have no distance WasmTarget holds and read the integer addresses, a located gap at run time" Base.:(-) @consistent_overlay METHOD_TABLE function Base.:(-)(x::Ptr, y::Ptr)
    wasm_pointer_same_base(x, y) && return wasm_pointer_offset(x) - wasm_pointer_offset(y)
    return UInt(x) - UInt(y)
end
