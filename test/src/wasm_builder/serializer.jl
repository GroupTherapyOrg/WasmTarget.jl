# The byte writer and the source map of src/wasm_builder (dev/MARCH.md 1.B): LEB128 integers, IEEE
# floats and UTF-8 names encode to the bytes the wasm binary format specifies, a misuse rejects where
# it is written, and a source map's mappings encode as source map v3's base64 VLQ deltas.

module SerializerTest

using Test
using WasmTarget

const W = WasmTarget.WasmBuilder

function bytes_of(f)::Vector{UInt8}
    s = W.Serializer()
    f(s)
    W.data(s)
end

rejects(f) = try
    f()
    false
catch e
    e isa WasmTarget.RejectionError
end

@testset "the serializer writes the binary format's encodings" begin
    # the wasm spec's examples and the edges of one and two LEB128 bytes
    @test bytes_of(s -> W.write_unsigned(s, 624485)) == [0xe5, 0x8e, 0x26]
    @test bytes_of(s -> W.write_signed(s, -123456)) == [0xc0, 0xbb, 0x78]
    @test bytes_of(s -> W.write_unsigned(s, 127)) == [0x7f]
    @test bytes_of(s -> W.write_unsigned(s, 128)) == [0x80, 0x01]
    @test bytes_of(s -> W.write_signed(s, 63)) == [0x3f]
    @test bytes_of(s -> W.write_signed(s, 64)) == [0xc0, 0x00]
    @test bytes_of(s -> W.write_signed(s, -64)) == [0x40]
    @test bytes_of(s -> W.write_signed(s, -65)) == [0xbf, 0x7f]
    @test bytes_of(s -> W.write_f32(s, 1.5f0)) == [0x00, 0x00, 0xc0, 0x3f]
    @test bytes_of(s -> W.write_f64(s, -2.25)) == [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xc0]
    @test bytes_of(s -> W.write_name(s, "héllo")) == [0x06, 0x68, 0xc3, 0xa9, 0x6c, 0x6c, 0x6f]
    @test W.Serializer_write_unsigned_byte_count(624485) == 3
    # a buffer grows past its first 24 bytes
    @test bytes_of(s -> foreach(i -> W.write_byte(s, UInt8(i)), 0:99)) == UInt8.(0:99)
    # a nested chunk is copied in
    @test bytes_of(s -> (c = W.Serializer(); W.write_name(c, "ab"); W.write_data(s, c))) == [0x02, 0x61, 0x62]
    # a negative unsigned value rejects at the write; a watch point outside the chunk writes it as is
    @test rejects(() -> bytes_of(s -> W.write_unsigned(s, -1)))
    @test bytes_of(s -> W.write_data(s, W.Serializer(), [1])) == UInt8[]
end

@testset "the source map encodes its mappings as base64 VLQ deltas" begin
    m = W.SourceMapSerializer()
    W.add_mapping(m, 0, nothing)                            # a leading unmapped range writes nothing
    W.add_mapping(m, 0, W.SourceInfo("a.jl", 0, 16, "f"))   # column 16: a two-digit VLQ, gB
    W.add_mapping(m, 5, W.SourceInfo("a.jl", 1, 2, nothing))  # column delta -14: d
    W.add_mapping(m, 9, nothing)
    W.add_mapping(m, 12, W.SourceInfo("b.jl", 0, 0, nothing)) # line and column deltas -1 and -2: D, F
    j = W.serialize_as_json(m)
    @test j.version == 3
    @test j.sources == ["a.jl", "b.jl"]
    @test j.names == ["f"]
    @test j.mappings == "AAAgBA,KACd,I,GCDF"
    # a chunk's mappings move by the offset it is copied at
    c = W.SourceMapSerializer()
    W.copy_mappings(c, m, 100)
    @test [x.instruction_offset for x in c.mappings] == [100, 100, 105, 109, 112]
    @test W.shift_by(W.SourceMapping_unmapped(3), 4).instruction_offset == 7
    # toString, == and hashCode as dart writes them
    @test sprint(show, W.SourceInfo("a.jl", 1, 2, nothing)) == "a.jl:1:2 (null)"
    @test sprint(show, W.SourceMapping(7, "a.jl", 1, 2, "g")) == "7 -> a.jl:1:2 (g)"
    @test sprint(show, W.SourceMapping_unmapped(7)) == "7 -> null"
    @test W.SourceInfo("a.jl", 1, 2, "g") == W.SourceInfo("a" * ".jl", 1, 2, "g")
    @test W.SourceInfo("a.jl", 1, 2, "g") != W.SourceInfo("a.jl", 1, 3, "g")
    @test hash(W.SourceInfo("a.jl", 1, 2, "g")) == hash(W.SourceInfo("a" * ".jl", 1, 2, "g"))
end

@testset "serializer.dart: a watch point prints its byte and the trace that wrote it" begin
    local chunk = W.Serializer()
    local s = W.Serializer()
    W.Serializer_trace_enabled[] = true
    local out = try
        W.write_byte(chunk, 0x0a); W.write_byte(chunk, 0xbc)
        W.write_byte(s, 0x01)
        # the chunk lands at offset 1: watch point 2 is its second byte, 0xbc; 9 is past it
        mktemp() do path, io
            redirect_stdout(io) do
                W.write_data(s, chunk, [2, 9])
            end
            close(io)
            read(path, String)
        end
    finally
        W.Serializer_trace_enabled[] = false
    end
    @test W.data(s) == UInt8[0x01, 0x0a, 0xbc]
    @test startswith(out, "Watch 2: 0xbc\n") && count("Watch", out) == 1
    # the trace of byte 2 is followed into the chunk, whose byte 1 a write_byte call wrote
    @test occursin("write_byte", out)
    # the first trace at a position is kept
    @test first.(s._traces) == [0, 1] && s._traces[2].second === chunk
    # with no trace recorded, a watch point has nothing to follow: WasmTarget's own defect
    local e = try; W.write_data(W.Serializer(), chunk, [0]); nothing; catch x; x; end
    @test e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.Internal
end

@testset "type.dart: _WithMutability writes its type, then its mutability flag" begin
    # the binary format's mut: the value type's byte (i32 0x7f, f64 0x7c), then 0x00 const or 0x01 var
    @test bytes_of(s -> W.serialize(s, W.IR._WithMutability(W.IR.NumType_i32; mutable = true))) == [0x7f, 0x01]
    @test bytes_of(s -> W.serialize(s, W.IR._WithMutability(W.IR.NumType_f64; mutable = false))) == [0x7c, 0x00]
    @test sprint(show, W.IR._WithMutability(W.IR.NumType_i32; mutable = false)) == "const i32"
end

end # module SerializerTest
