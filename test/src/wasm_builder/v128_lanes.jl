# The v128.const lane forms of src/wasm_builder (instructions.dart:2113-2245): each lane is stored as
# dart's ByteData setters store it, little-endian and modulo its width (setInt64/setInt32/setInt16/
# setInt8, setFloat64/setFloat32), so the 16 bytes are the wasm spec's v128.const layout (Binary
# Format 5.4.8, `0xFD 12` then the 16 bytes, lane 0 first, each lane little-endian). One case per lane
# shape; each byte vector below is written from the spec's layout, never read back from the builder.

module V128LanesTest

using Test
using WasmTarget

const W = WasmTarget.WasmBuilder
const I = W.IR

function body()
    local mb = W.ModuleBuilder("m", nothing)
    local f = W.define(mb.functions[], W.define_function(mb.types[], I.ValueType[], I.ValueType[]))
    return W.body(f)
end
# the bytes of the one V128Const a lane form adds
function lane_bytes(emit)::Vector{UInt8}
    local b = body()
    emit(b)
    local i = b._instructions[end]
    @test i isa I.V128Const
    return i.bytes
end

@testset "v128.const lane forms store each lane little-endian, modulo its width" begin
    # i64x2: dart's setInt64; -1 is eight 0xff, a positive lane its bytes low first
    @test lane_bytes(b -> W.v128_const_i64x2(b, -1, Int(0x0102030405060708))) ==
          UInt8[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]
    @test lane_bytes(b -> W.v128_const_i64x2(b, typemin(Int), 0)) ==
          UInt8[0, 0, 0, 0, 0, 0, 0, 0x80, 0, 0, 0, 0, 0, 0, 0, 0]
    # i32x4: dart's setInt32 keeps the low 32 bits of a wider int
    @test lane_bytes(b -> W.v128_const_i32x4(b, -2, Int(0x01020304), 2^32 + 5, -2^31)) ==
          UInt8[0xfe, 0xff, 0xff, 0xff, 0x04, 0x03, 0x02, 0x01, 0x05, 0, 0, 0, 0, 0, 0, 0x80]
    # i16x8: dart's setInt16, low 16 bits
    @test lane_bytes(b -> W.v128_const_i16x8(b, -2, Int(0x1234), Int(0x12345), 65535, 65536, -32768, 1, 0)) ==
          UInt8[0xfe, 0xff, 0x34, 0x12, 0x45, 0x23, 0xff, 0xff, 0, 0, 0x00, 0x80, 0x01, 0, 0, 0]
    # i8x16: dart's setInt8, low 8 bits
    @test lane_bytes(b -> W.v128_const_i8x16(b, -1, 255, 256, -129, 127, -128, 1, 2, 3, 4, 5, 6, 7, 8, 9, Int(0x1ff))) ==
          UInt8[0xff, 0xff, 0x00, 0x7f, 0x7f, 0x80, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0xff]
    # f64x2 and f32x4: the IEEE bits, little-endian (1.0 = 0x3ff0000000000000, 1.0f0 = 0x3f800000)
    @test lane_bytes(b -> W.v128_const_f64x2(b, 1.0, -0.0)) ==
          UInt8[0, 0, 0, 0, 0, 0, 0xf0, 0x3f, 0, 0, 0, 0, 0, 0, 0, 0x80]
    @test lane_bytes(b -> W.v128_const_f32x4(b, 1.0, -0.0, 2.0, 0.5)) ==
          UInt8[0, 0, 0x80, 0x3f, 0, 0, 0, 0x80, 0, 0, 0, 0x40, 0, 0, 0, 0x3f]
end

end # module
