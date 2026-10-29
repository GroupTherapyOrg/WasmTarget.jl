# parity(sdk/lib/_internal/wasm/js_common/js_string.dart): dart's JS string library at the pin, the part
# that makes a JS string from wasm code units, ported as Julia methods of the module Runtime
# (src/julia/parity.jl RUNTIME_FILES). dart's JSStringImpl wraps the host's string reference; Julia's
# String holds its own UTF-8 bytes (src/julia/classes.jl), so a JS string here is the host reference
# itself, a WasmExternRef, made from a String's code units when the program hands one to its host.

"""
The JS string of the UTF-16 code units `array[start:end)`: the JS string builtin
`wasm:js-string.fromCharCodeArray` (dart's `@pragma("wasm:import", "wasm:js-string.fromCharCodeArray")
external WasmExternRef jsStringFromCharCodeArray(WasmArray<WasmI16>? array, WasmI32 start, WasmI32
end)`), a host import (src/julia/runtime/rtutils.jl nir_host_import): a method whose whole body is the
foreign call, the nullable array declared Any to it (Julia's ccall has no C type for a Union). Never
inlined, so its call stays the import's call.
"""
@parity "sdk/lib/_internal/wasm/js_common/js_string.dart:858 jsStringFromCharCodeArray" @noinline js_string_from_char_code_array(array::Union{Nothing,WasmArray{WasmI16}}, start::Int32, end_::Int32)::WasmExternRef =
    ccall((:fromCharCodeArray, "wasm:js-string"), WasmExternRef, (Any, Int32, Int32), array, start, end_)

"""
The JS string of the code units `source[start:end)` (dart's `JSStringImpl.fromCharCodeArray`), its
offsets wrapped to the i32 the builtin takes, as dart's `toWasmI32`. dart wraps the reference in a
JSStringImpl (`fromRefUnchecked`); Julia has no such class, so the reference is the JS string.
"""
@parity "sdk/lib/_internal/wasm/js_common/js_string.dart:171 JSStringImpl.fromCharCodeArray" JSStringImpl_from_char_code_array(source::WasmArray{WasmI16}, start::Int, end_::Int)::WasmExternRef =
    js_string_from_char_code_array(source, start % Int32, end_ % Int32)

"""
The JS string of the code units `source[start:end)` of a String (dart's `JSStringImpl.fromAsciiBytes`):
dart widens each byte of an ASCII string into a `WasmArray<WasmI16>` and makes the string of it.
Julia's String is UTF-8, so the widening is Julia's own UTF-8 to UTF-16 conversion, Base's
`transcode(UInt16, ::AbstractVector{UInt8})` (strings/cstring.jl:181) as written: a multi-byte
character its one or two UTF-16 code units, a byte of invalid UTF-8 the code unit of its own value,
as Base's. An ASCII byte is widened as dart widens it. A character never takes more code units than bytes,
so the array has one element per byte, and the string is made of the units written.

Reshaped: `source` is the String itself, whose bytes are read through dart:_wasm's
`WasmArray<WasmI8>.readUnsigned` on its data (wasm_string_codeunit), a String's data array being no
value Julia code holds; `start` counts from 0 as dart's does. dart's `_codeUnitsCache`, a static
array reused for short strings, is not ported: Julia's runtime has no mutable static initialized at
startup, so each string takes its own array.
"""
@parity "sdk/lib/_internal/wasm/js_common/js_string.dart:151 JSStringImpl.fromAsciiBytes" function JSStringImpl_from_ascii_bytes(source::String, start::Int, end_::Int)::WasmExternRef
    local n = end_ - start
    # Base's `src[i]` is the byte at offset `start + i - 1`, `dst`'s push! a write at `length`
    local array = wasm_array_new(WasmArray{WasmI16}, n)
    local length = 0
    n > 0 || return JSStringImpl_from_char_code_array(array, 0, 0)
    local i = 1
    local a = wasm_string_codeunit(source, start)
    while true
        if i < n && -64 <= a % Int8 <= -12 # multi-byte character
            local b = wasm_string_codeunit(source, start + (i += 1) - 1)
            if -64 <= (b % Int8) || a == 0xf4 && 0x8f < b
                # invalid UTF-8 (non-continuation or too-high code point)
                (wasm_array_write!(array, length, UInt16(a)); length += 1)
                a = b; continue
            elseif a < 0xe0 # 2-byte UTF-8
                (wasm_array_write!(array, length, xor(0x3080, UInt16(a) << 6, b)); length += 1)
            elseif i < n # 3/4-byte character
                local c = wasm_string_codeunit(source, start + (i += 1) - 1)
                if -64 <= (c % Int8) # invalid UTF-8 (non-continuation)
                    (wasm_array_write!(array, length, UInt16(a)); length += 1); (wasm_array_write!(array, length, UInt16(b)); length += 1)
                    a = c; continue
                elseif a < 0xf0 # 3-byte UTF-8
                    (wasm_array_write!(array, length, xor(0x2080, UInt16(a) << 12, UInt16(b) << 6, c)); length += 1)
                elseif i < n
                    local d = wasm_string_codeunit(source, start + (i += 1) - 1)
                    if -64 <= (d % Int8) # invalid UTF-8 (non-continuation)
                        (wasm_array_write!(array, length, UInt16(a)); length += 1); (wasm_array_write!(array, length, UInt16(b)); length += 1); (wasm_array_write!(array, length, UInt16(c)); length += 1)
                        a = d; continue
                    elseif a == 0xf0 && b < 0x90 # overlong encoding
                        (wasm_array_write!(array, length, xor(0x2080, UInt16(b) << 12, UInt16(c) << 6, d)); length += 1)
                    else # 4-byte UTF-8
                        (wasm_array_write!(array, length, 0xe5b8 + (UInt16(a) << 8) + (UInt16(b) << 2) + (c >> 4)); length += 1)
                        (wasm_array_write!(array, length, xor(0xdc80, UInt16(c & 0xf) << 6, d)); length += 1)
                    end
                else # too short
                    (wasm_array_write!(array, length, UInt16(a)); length += 1); (wasm_array_write!(array, length, UInt16(b)); length += 1); (wasm_array_write!(array, length, UInt16(c)); length += 1)
                    break
                end
            else # too short
                (wasm_array_write!(array, length, UInt16(a)); length += 1); (wasm_array_write!(array, length, UInt16(b)); length += 1)
                break
            end
        else # ASCII or invalid UTF-8 (continuation byte or too-high code point)
            (wasm_array_write!(array, length, UInt16(a)); length += 1)
        end
        i < n || break
        a = wasm_string_codeunit(source, start + (i += 1) - 1)
    end
    return JSStringImpl_from_char_code_array(array, 0, length)
end
