# dart2wasm's util.dart, ported (src/util.jl, dev/MARCH.md 1.C): the pure helpers on fixed inputs, each
# expected value Julia's own (Base64, Julia's integer and string functions).
using Test, Base64
using WasmTarget

const U = WasmTarget.Dart2Wasm.Util

# the decoding of a min string over `digits` starting at `first`, the inverse of the encoder: Julia's
# arithmetic, never the port's
_decode(s, base, digit) = sum((digit(c)) * base^(k - 1) for (k, c) in enumerate(s)) - 1

@testset "util.dart" begin
    @test U.compiler_asserts_enabled()
    @test sprint(show, U.ImportName("env", "f")) == "env.f" && U.ImportName("a", "b").item_name == "b"
    # little-endian bytes, the fewest that hold the value read unsigned (at least one), each Julia's
    for i in Int64[0, 1, 255, 256, 65535, 2^40 + 7, typemax(Int64), -1, typemin(Int64)]
        local le = reinterpret(UInt8, [htol(i)])
        local k = max(1, something(findlast(!iszero, le), 0))
        @test U._int_to_little_endian_bytes(i) == le[1:k]
        @test U.int_to_base64(i) == base64encode(le[1:k])
    end
    @test U.module_name_from_id(0) == "M" && U.module_name_from_id(7) == "M7"
    @test all(id -> U.module_name_to_id(U.module_name_from_id(id)) == id, 0:50)
    @test U.module_name_to_id("X1") === nothing && U.module_name_to_id("Mx") === nothing && U.module_name_to_id("M") == 0
    # the min strings: printable 35..126, never empty, one string per int, decoded back by Julia
    local mins = [U.int_to_min_string(i) for i in 0:20_000]
    @test allunique(mins) && all(s -> !isempty(s) && all(c -> 35 <= Int(c) <= 126, s), mins)
    @test all(i -> _decode(mins[i + 1], 92, c -> Int(c) - 35) == i, 0:20_000)
    # 0 is "\$" (the encoder adds one first), 90 the last one-character string, 91 the first of two
    @test U.int_to_min_string(0) == "\$" && U.int_to_min_string(90) == "~" && U.int_to_min_string(91) == "#\$"
    local js = [U.int_to_min_js_safe_string(i) for i in 0:20_000]
    @test allunique(js) && all(s -> !isempty(s) && all(c -> isletter(c) && isascii(c), s), js)
    @test all(i -> _decode(js[i + 1], 52, c -> isuppercase(c) ? Int(c) - 65 : Int(c) - 97 + 26) == i, 0:20_000)
    local e = try; U.int_to_min_string(-1); nothing; catch x; x; end
    @test e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.Internal
end

@testset "util.dart: moduleNameToId reads dart's int.tryParse forms" begin
    # dart's int.tryParse reads 0x and hexadecimal digits; Julia parses them in base 16
    @test U.module_name_to_id("M0x10") == parse(Int, "10"; base = 16) == 16
    @test U.module_name_to_id("M-0x1f") == -31 && U.module_name_to_id("M0xZ") === nothing
end
