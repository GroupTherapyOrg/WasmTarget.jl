# reinterpret of one bits value as another against native Julia (src/patch/reinterpretarray.jl): Base's
# _reinterpret copies the bytes between two Refs' addresses, and the overlay stores the value's leaves into
# a byte Memory at their field offsets and reads the result's back. Every case compiles and answers as
# native Julia, both modules: a case that rejects or answers wrong fails, named. A value the overlay does
# not take (a nested tuple) stays Base's method, its jl_value_ptr a located rejection.
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))

module ReinterpretCases
# an integer's and a float's bytes, least significant first, weighted so each position counts
i2b(x::Int64) = (b = reinterpret(NTuple{8, UInt8}, x); sum(Int64(b[k]) * k for k in 1:8) + Int64(b[1]) * 10^6 + Int64(b[8]) * 10^4)
u2b(x::Int64) = (b = reinterpret(NTuple{8, UInt8}, x % UInt64); Int64(b[2]) * 1000 + Int64(b[7]))
f2b(x::Float64) = (b = reinterpret(NTuple{8, UInt8}, x); Int64(b[8]) * 1000 + Int64(b[7]))
f32b(x::Int64) = (b = reinterpret(NTuple{4, UInt8}, Float32(x) / 3.0f0); Int64(b[1]) + 256 * Int64(b[4]))
# bytes read back as an integer, a float and a Char's bits
b2u(x::Int64) = Int64(reinterpret(UInt32, (x % UInt8, 0x02, 0x03, 0x84)))
b2i(x::Int64) = Int64(reinterpret(Int16, (x % UInt8, 0x80)))
b2f(x::Int64) = reinterpret(Float64, (0x00, 0x00, 0x00, 0x00, 0x00, 0x00, x % UInt8, 0x3f))
cb(x::Int64) = (b = reinterpret(NTuple{4, UInt8}, Char(x)); Int64(b[1]) * 10^6 + Int64(b[2]) * 1000 + Int64(b[4]))
# a tuple as another tuple: an integer's bytes as two words, and a padded pair as another of the same padding
w2(x::Int64) = (w = reinterpret(NTuple{2, UInt32}, reinterpret(NTuple{8, UInt8}, x)); Int64(w[1]) - Int64(w[2]))
pad(x::Int64) = (p = reinterpret(Tuple{Int8, Int16}, (x % UInt8, (x * 7) % UInt16)); Int64(p[1]) * 100_000 + Int64(p[2]))
# Bools read from bytes, which the overlay takes and WasmTarget's bitcast of a byte to a Bool rejects, located
bl(x::Int64) = (t = reinterpret(Tuple{Bool, Bool}, (x % UInt8 & 0x01, 0x01)); Int64(t[1]) * 10 + Int64(t[2]) + Int64(reinterpret(UInt16, (isodd(x), true))))
# a nested tuple, which the overlay does not take
nested(x::Int64) = Int64(reinterpret(NTuple{2, NTuple{4, UInt8}}, x)[2][1])
end

const REINTERPRET_CASES = (
    ("i2b", ReinterpretCases.i2b, (Int64(0x0123456789abcdef),)), ("i2b", ReinterpretCases.i2b, (Int64(-2),)),
    ("u2b", ReinterpretCases.u2b, (Int64(-12345678901),)), ("u2b", ReinterpretCases.u2b, (Int64(77),)),
    ("f2b", ReinterpretCases.f2b, (1.5,)), ("f2b", ReinterpretCases.f2b, (-0.1,)),
    ("f32b", ReinterpretCases.f32b, (Int64(1),)), ("f32b", ReinterpretCases.f32b, (Int64(-100),)),
    ("b2u", ReinterpretCases.b2u, (Int64(0x1ff),)), ("b2u", ReinterpretCases.b2u, (Int64(3),)),
    ("b2i", ReinterpretCases.b2i, (Int64(7),)), ("b2i", ReinterpretCases.b2i, (Int64(255),)),
    ("b2f", ReinterpretCases.b2f, (Int64(0xf0),)), ("b2f", ReinterpretCases.b2f, (Int64(0),)),
    ("cb", ReinterpretCases.cb, (Int64(0xe9),)), ("cb", ReinterpretCases.cb, (Int64(0x1f600),)),
    ("w2", ReinterpretCases.w2, (Int64(0x0123456789abcdef),)), ("w2", ReinterpretCases.w2, (Int64(-1),)),
    ("pad", ReinterpretCases.pad, (Int64(300),)), ("pad", ReinterpretCases.pad, (Int64(-5),)))

@testset "reinterpret of a bits value against native Julia" begin
    local runs = Main.WTChild.RunCase[]
    for (name, f, args) in REINTERPRET_CASES
        local label = "reinterpretarray/$name$args"
        # every case compiles, both modules: a rejection is this case's located error, never a pass
        @testset "$label compiles" begin
            append!(runs, first(Main.WTChild.answer_cases(label, WasmTarget.compile, f, args)))
        end
    end
    for r in Main.WTChild.run_cases(runs)
        @test (r.label => r.why) == (r.label => "")
    end
end

# Base's _reinterpret is the overlay for a tuple of leaves over WasmTarget's overlay table, and Base's own
# for a nested tuple, which rejects at its Refs' jl_value_ptr, located; a Bool read from a byte, which the
# overlay takes, rejects at WasmTarget's bitcast of a byte to a Bool, located
@testset "reinterpret takes the overlay for leaves; a nested tuple and a Bool reject, located" begin
    local overlaid(Out, In) = Base._which(Tuple{typeof(Base._reinterpret), Type{Out}, In};
        method_table = Core.Compiler.OverlayMethodTable(Base.get_world_counter(), WasmTarget.METHOD_TABLE)).method.module
    @test overlaid(NTuple{8, UInt8}, Int64) === WasmTarget && overlaid(UInt32, NTuple{4, UInt8}) === WasmTarget
    @test overlaid(NTuple{2, NTuple{4, UInt8}}, Int64) === Base
    local e = try; WasmTarget.compile(ReinterpretCases.nested, (Int64,)); nothing; catch x; x; end
    @test e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.Unquarantined && occursin("jl_value_ptr", sprint(showerror, e))
    local eb = try; WasmTarget.compile(ReinterpretCases.bl, (Int64,)); nothing; catch x; x; end
    @test eb isa WasmTarget.RejectionError && eb.rejection isa WasmTarget.Unported && occursin("bitcast on Type{Bool}", sprint(showerror, eb))
end
