# dart2wasm's constants.dart, ported (src/constants.jl): arrays past maxArrayNewFixedLength, run against native Julia
# (split from test/src/constants_objects.jl, every testset verbatim; its other parts are test/src/constants_module.jl
# and test/src/constants_owners.jl).

# dart's _makeWasmArrayLiteral past maxArrayNewFixedLength (10,000 entries): an i16 or i32 array is initialised from the
# passive data segment, each entry its integer's bits, little-endian (dart's Uint16List and Uint32List); any other
# storage (an i8, i64 or f64 array) is dart's array.new of its commonest entry and array.set or array.fill of the
# rest; at 10,000 or fewer, array.new_fixed. Each constant Vector read at its first, a middle and its last index
# against native, at 10,000 and 10,001 entries alike, and each data segment's bytes the elements' own.
module LargeConstantArrays
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const WTChild = Main.WTChild
const D = WasmTarget.Dart2Wasm
const U16 = UInt16[(k * 40503) % 65536 for k in 1:46592]              # utf8proc's stage-2 length
const I16 = Int16[(k * 40503) % 65536 - 32768 for k in 1:12000]       # negative entries among them
const I32 = Int32[(k * 2654435761) % 4294967296 - 2147483648 for k in 1:12000]
const U32 = UInt32[(k * 2654435761) % 4294967296 for k in 1:12000]
const CHR = Char[Char(k % 0xd800) for k in 1:12000]                   # a Char's bits, its UTF-8 encoding
const U8 = UInt8[k % 251 for k in 1:12000]                            # i8: dart's array.new and array.set path
const I64 = Int64[k * 1_000_003 - 6_000_000_000 for k in 1:12000]      # i64: the same
const F64 = Float64[k / 7 for k in 1:12000]                           # f64: the same
const AT = UInt16[(k * 7919) % 65536 for k in 1:10000]                 # array.new_fixed, the limit itself
const PAST = UInt16[(k * 7919) % 65536 for k in 1:10001]               # the data segment, one past it
# entry i of array k as an Int64 (a Float64's bits)
function rd(k::Int64, i::Int64)::Int64
    k == 1 && return Int64(U16[i])
    k == 2 && return Int64(I16[i])
    k == 3 && return Int64(I32[i])
    k == 4 && return Int64(U32[i])
    k == 5 && return Int64(reinterpret(UInt32, CHR[i]))
    k == 6 && return Int64(U8[i])
    k == 7 && return I64[i]
    k == 8 && return reinterpret(Int64, F64[i])
    k == 9 && return Int64(AT[i])
    return Int64(PAST[i])
end
const LENGTHS = (46592, 12000, 12000, 12000, 12000, 12000, 12000, 12000, 10000, 10001)
# the first, a middle and the last entry, summed
sum3(k::Int64, n::Int64) = rd(k, Int64(1)) + rd(k, n ÷ 2) + rd(k, n)
u16(i::Int64) = Int64(U16[i])
# translated standalone, as WasmTarget.compile translates: a read that can throw BoundsError needs its stack trace class
translated(f) = (o = D.TranslatorOptions(; standalone = true);
    t = D.Translator(WasmTarget.build_nir(WasmTarget.check_subset(f, (Int64,), "constants", Base.get_world_counter()), "constants"),
    D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), o); D.translate(t, nothing); t)
@testset "constants.dart: a constant array past maxArrayNewFixedLength, each element kind, run against native" begin
    @test any(<(0), I16) && any(<(0), I32) && length(AT) == D.max_array_new_fixed_length()
    # each function one program, its two modules; sum3 at each array's length, rd at each index it sums
    local cases = WTChild.RunCase[]
    for (f, argsets) in ((sum3, [(k, n) for (k, n) in enumerate(LENGTHS)]),
                         (rd, [(k, i) for (k, n) in enumerate(LENGTHS) for i in (1, n ÷ 2, n)]))
        local own = WasmTarget.compile(f, (Int64, Int64))
        local plain = WasmTarget.compile(f, (Int64, Int64); optimize = false)
        for a in argsets
            push!(cases, WTChild.RunCase("$(nameof(f))$a", plain, Int64.(a), WTChild.native_answer(f, Int64.(a)); optimized = own))
        end
    end
    @test I16[12000 ÷ 2] < 0   # a negative Int16 among the entries read
    local results = WTChild.run_cases(cases)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test length(results) == length(cases) && all(r -> r.ok, results)
    # the 46,592-entry UInt16 table is one data segment of its 93,184 bytes, little-endian, read by array.new_data
    local t = translated(u16)
    local seg = only(values(t.constants[]._byte_segments))
    local bytes = Vector{UInt8}(reinterpret(UInt8, htol.(U16)))
    @test length(bytes) == 93184 && seg.content == bytes
end
end
