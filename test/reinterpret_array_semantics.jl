using Test

function _reinterpret_pack_u8_to_u64()::UInt64
    return reinterpret(UInt64, UInt8[1, 2, 3, 4, 5, 6, 7, 8])[1]
end

function _reinterpret_split_u32_to_u8()::UInt64
    bytes = reinterpret(UInt8, UInt32[0x04030201, 0x08070605])[1:8]
    total = UInt64(0)
    for i in eachindex(bytes)
        total |= UInt64(bytes[i]) << (8 * (i - 1))
    end
    return total
end

function _reinterpret_store_both_directions()::UInt64
    bytes = zeros(UInt8, 8)
    wide = reinterpret(UInt64, bytes)
    wide[1] = 0x0807060504030201

    words = zeros(UInt32, 2)
    narrow = reinterpret(UInt8, words)
    for i in 1:8
        narrow[i] = bytes[i]
    end
    return UInt64(words[1]) | (UInt64(words[2]) << 32)
end

@testset "primitive ReinterpretArray structural semantics" begin
    expected = 0x0807060504030201
    @test _reinterpret_pack_u8_to_u64() == expected
    @test _reinterpret_split_u32_to_u8() == expected
    @test _reinterpret_store_both_directions() == expected
    @test compare_julia_wasm(_reinterpret_pack_u8_to_u64).pass
    @test compare_julia_wasm(_reinterpret_split_u32_to_u8).pass
    @test compare_julia_wasm(_reinterpret_store_both_directions).pass

    source = read(joinpath(@__DIR__, "..", "src", "codegen", "interpreter.jl"), String)
    @test occursin("Base.array_subpadding", source)
    @test !occursin("getfield(a, :parent)", source)
end
