using Test
using WasmTarget
using Random: Xoshiro

# A foreigncall whose lowering calls the host takes its import before any function is defined:
# an import is numbered ahead of every defined function, so one added later renumbers them
# under the calls already emitted to them.

@noinline _hi_inc(x::Int64)::Int64 = x + 1
@noinline _hi_mul(x::Int64)::Int64 = x * 100
_hi_clock(x::Int64)::Int64 = _hi_mul(x) + (time_ns() > 0 ? _hi_inc(x) : Int64(0))

@noinline function _hi_global_beside_rand(g::WasmGlobal{Int64,0})::Int64
    g[] = g[] + Int64(1)
    return rand() < 2.0 ? g[] : Int64(-1)
end

_hi_rand()::Float64 = rand()
_hi_rand_pair()::UInt64 = rand(UInt64) ⊻ rand(UInt64)

# `env.random_i64` answering the given words in order, as a JS closure
_hi_entropy(words) = "(() => { const s = [" *
    join(string.(reinterpret(Int64, collect(UInt64, words))) .* "n", ", ") *
    "]; let i = 0; return () => s[i++]; })()"

@testset "host imports precede every defined function" begin
    # time_ns() reads the host clock. Its import was once added while bodies compiled, and the
    # export `_hi_clock` then called the import: the module returned the clock's 1234.5.
    @test _hi_clock(Int64(3)) == 304
    bytes = WasmTarget.compile(_hi_clock, (Int64,); validate=true)
    clock = Dict{String,Any}("env" => Dict{String,Any}("perf_now" => "() => 1234.5"))
    @test run_wasm_with_imports(bytes, "_hi_clock", clock, Int64(3)) == 304

    # rand()'s state words are their own globals beside a WasmGlobal's: created first, they
    # took indices 0-3, and `WasmGlobal{Int64,0}` read and wrote the RNG's first state word.
    @test _hi_global_beside_rand(WasmGlobal{Int64,0}(0)) == 1
    bytes = WasmTarget.compile(_hi_global_beside_rand, (WasmGlobal{Int64,0},); validate=true)
    entropy = Dict{String,Any}("env" => Dict{String,Any}("random_i64" => _hi_entropy((1, 2, 3, 4))))
    @test run_wasm_with_imports(bytes, "_hi_global_beside_rand", entropy) == 1

    # The host seeds the RNG at startup, as Random.__init__ seeds the default RNG with four
    # draws from RandomDevice: given the same four words, the stream is Julia's own.
    words = (0x0123456789abcdef, 0xfedcba9876543210, 0x1111111122222222, 0x8000000000000001)
    entropy = Dict{String,Any}("env" => Dict{String,Any}("random_i64" => _hi_entropy(words)))
    bytes = WasmTarget.compile(_hi_rand, (); validate=true)
    @test run_wasm_with_imports(bytes, "_hi_rand", entropy) == rand(Xoshiro(words...))
    bytes = WasmTarget.compile(_hi_rand_pair, (); validate=true)
    native = let r = Xoshiro(words...); rand(r, UInt64) ⊻ rand(r, UInt64) end
    @test run_wasm_with_imports(bytes, "_hi_rand_pair", entropy) % UInt64 == native

    # the builder refuses an import after a definition
    mod = WasmTarget.WasmModule()
    WasmTarget.add_function!(mod, WasmTarget.WasmValType[], WasmTarget.WasmValType[],
                             WasmTarget.WasmValType[], UInt8[WasmTarget.Opcode.END])
    @test_throws WasmTarget.ModuleValidationError WasmTarget.add_import!(mod, "env", "late",
        WasmTarget.WasmValType[], WasmTarget.WasmValType[])
end
