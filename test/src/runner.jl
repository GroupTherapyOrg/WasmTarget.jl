# test/runner.jl, the differential runner: hand-assembled modules show each marshalled type crossing
# and returning with its bits, a wrong answer failing located, and what the runner cannot run failing,
# never skipped; WasmTarget's own modules show a tuple answer read leaf by leaf, both modules each.
using Test, WasmTarget
isdefined(Main, :WTRunner) || Base.include(Main, joinpath(@__DIR__, "..", "runner.jl"))
const WTR = Main.WTRunner

# a module exporting `f`, one function of one parameter of wasm type `t` to `t`: local.get 0, `ops`
function _run_one_function(t::UInt8, ops::Vector{UInt8} = UInt8[])::Vector{UInt8}
    local body = vcat(UInt8[0x00, 0x20, 0x00], ops, UInt8[0x0b])
    local code = vcat(UInt8[0x01, UInt8(length(body))], body)
    return vcat(UInt8[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00],
                UInt8[0x01, 0x06, 0x01, 0x60, 0x01, t, 0x01, t],
                UInt8[0x03, 0x02, 0x01, 0x00],
                UInt8[0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00],
                UInt8[0x0a, UInt8(length(code))], code)
end
const _RUN_I32, _RUN_I64, _RUN_F32, _RUN_F64 = 0x7f, 0x7e, 0x7d, 0x7c
# a module importing m.f and exporting nothing
const _RUN_IMPORTS = UInt8[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60, 0x01, 0x7f, 0x01, 0x7f,
                      0x02, 0x07, 0x01, 0x01, 0x6d, 0x01, 0x66, 0x00, 0x00]
const _RUN_ADD1 = _run_one_function(_RUN_I32, UInt8[0x41, 0x01, 0x6a])   # i32.const 1, i32.add

@testset "each marshalled type crosses with its bits; what differs or cannot run fails, located" begin
    @test WTR.node_binary() !== nothing
    local cases = [
        WTR.RunCase("i32 add", _RUN_ADD1, (Int32(41),), Int32(42)),
        WTR.RunCase("i32 wraps", _RUN_ADD1, (typemax(Int32),), typemin(Int32)),
        WTR.RunCase("i64", _run_one_function(_RUN_I64), (typemin(Int64),), typemin(Int64)),
        WTR.RunCase("f64 -0.0", _run_one_function(_RUN_F64), (-0.0,), -0.0),
        WTR.RunCase("f64 Inf", _run_one_function(_RUN_F64), (-Inf,), -Inf),
        WTR.RunCase("f32", _run_one_function(_RUN_F32), (1.5f0,), 1.5f0),
        WTR.RunCase("Bool", _run_one_function(_RUN_I32), (true,), true),
        WTR.RunCase("wrong", _RUN_ADD1, (Int32(1),), Int32(1)),
        WTR.RunCase("-0.0 is not 0.0", _run_one_function(_RUN_F64), (-0.0,), 0.0),
        WTR.RunCase("a tuple", _RUN_ADD1, (Int32(1),), (Int32(2),)),
        WTR.RunCase("imports", _RUN_IMPORTS, (Int32(1),), Int32(2)),
        WTR.RunCase("no such entry", _RUN_ADD1, (Int32(1),), Int32(2); entry = "g"),
        WTR.RunCase("not wasm", UInt8[0x00, 0x01], (Int32(1),), Int32(2)),
        WTR.RunCase("both modules agree", _RUN_ADD1, (Int32(41),), Int32(42); optimized = _RUN_ADD1),
        WTR.RunCase("the optimizer miscompiles", _RUN_ADD1, (Int32(41),), Int32(42); optimized = _run_one_function(_RUN_I32)),
        WTR.RunCase("i32 add, its module instantiated once", _RUN_ADD1, (Int32(1),), Int32(2)),
    ]
    local r = WTR.run_cases(cases)
    @test length(r) == length(cases) && [x.label for x in r] == [c.label for c in cases]
    @test all(x -> x.ok, r[1:7]) && r[14].ok && r[16].ok
    @test !r[8].ok && occursin("answers 2", r[8].why) && occursin("native Julia 1", r[8].why)
    @test !r[9].ok && occursin("answers -0.0", r[9].why)
    @test !r[10].ok && occursin("marshals no Tuple{Int32}", r[10].why)
    @test !r[11].ok && occursin("imports m.f", r[11].why)
    @test !r[12].ok && occursin("no entry", r[12].why)
    @test !r[13].ok && !isempty(r[13].why)
    @test !r[15].ok && occursin("the wasm-opt'd module answers 41", r[15].why) && occursin("differ: 42 against 41", r[15].why) &&
          !occursin("the module answers", r[15].why)
    @test WTR.run_cases(WTR.RunCase[]) == WTR.RunResult[]
end

@testset "a compiled case: codegen's module and compile's wasm-opt'd one, both run" begin
    local comp(f, ts; optimize::Bool = true) = optimize ? _run_one_function(_RUN_I32) : _RUN_ADD1
    local c = WTR.compiled_case("two modules", comp, identity, (Int32(1),), Int32(2))
    @test c.bytes == _RUN_ADD1 && c.optimized == _run_one_function(_RUN_I32)
    local r = only(WTR.run_cases([c]))
    @test !r.ok && occursin("the wasm-opt'd module answers 1", r.why)
    local same = WTR.compiled_case("one module", (f, ts; optimize::Bool = true) -> _RUN_ADD1, identity, (Int32(1),), Int32(2))
    @test same.bytes == _RUN_ADD1 && isempty(same.optimized) && only(WTR.run_cases([same])).ok
    # optimized = false compiles codegen's module alone, compile's optimize = false
    local calls = Bool[]
    local logged(f, ts; optimize::Bool = true) = (push!(calls, optimize); _RUN_ADD1)
    local plain = WTR.compiled_case("codegen's module", logged, identity, (Int32(1),), Int32(2); optimized = false)
    @test calls == [false] && isempty(plain.optimized) && only(WTR.run_cases([plain])).ok
end

@testset "a module that never returns fails as a hang, the others keep their answers" begin
    local forever = _run_one_function(_RUN_I32, UInt8[0x03, 0x40, 0x0c, 0x00, 0x0b])   # loop: br 0; end
    local t0 = time()
    local r = WTR.run_cases([WTR.RunCase("before", _RUN_ADD1, (Int32(1),), Int32(2)), WTR.RunCase("forever", forever, (Int32(1),), Int32(1)),
                           WTR.RunCase("after", _RUN_ADD1, (Int32(1),), Int32(2))]; run_budget = 0.2, node_start = 1.0)
    @test time() - t0 < 10
    @test r[1].ok
    @test !r[2].ok && occursin("node killed: a hang or a blow-up", r[2].why)
    @test !r[3].ok && occursin("node killed", r[3].why)
end

# a program whose answer is a nest of tuples of two leaf types, compiled by WasmTarget
_runner_facts(x::Int64) = (x + 1, (x > 0, x * 2), x < 0)

@testset "a tuple answer's leaves, one reader per leaf type, each leaf named by its path" begin
    # the readers as answer_cases builds them, with a compile that only counts its calls
    local calls = Ref(0)
    local counted(f, ts; optimize::Bool = true) = (calls[] += 1; _RUN_ADD1)
    local cs = WTR.answer_cases("t", counted, _runner_facts, (Int64(3),), (4, (true, 6), 0.5, "x"))
    @test [c.label for c in cs] == ["t(1,)", "t(2, 2)", "t(2, 1)", "t(3,)", "t(4,)"]
    @test [c.args for c in cs] == [(3, 1), (3, 2), (3, 1), (3, 1), (3, 1)]
    @test calls[] == 2 * 3   # Int64, Bool and Float64 each one reader, each both modules; no reader for String
    # a leaf of a type the runner does not marshal has no reader and fails, named
    @test isempty(cs[5].bytes) && occursin("marshals no String", WTR.run_cases(cs[5:5])[1].why)
end

@testset "a tuple answer read leaf by leaf from WasmTarget's modules" begin
    local cs = WTR.answer_cases("facts", WasmTarget.compile, _runner_facts, (Int64(3),), _runner_facts(Int64(3)))
    @test all(c -> !isempty(c.bytes) && !isempty(c.optimized), cs)
    @test all(x -> x.ok, WTR.run_cases(cs))
    # an answer that differs in one leaf fails that leaf alone, named by its path
    local planted = Dict("facts(2, 2)" => 7)
    local r = WTR.run_cases([WTR.RunCase(c.label, c.bytes, c.optimized, c.args, get(planted, c.label, c.native), c.entry) for c in cs])
    @test [x.label for x in r if !x.ok] == ["facts(2, 2)"]
    @test occursin("answers 6, native Julia 7", only(x.why for x in r if !x.ok))
end
