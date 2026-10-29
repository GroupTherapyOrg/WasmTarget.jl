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
        WTR.RunCase("UInt32 past typemax(Int32)", _RUN_ADD1, (typemax(UInt32) - UInt32(1),), typemax(UInt32)),
        WTR.RunCase("UInt64 past typemax(Int64)", _run_one_function(_RUN_I64), (typemax(UInt64),), typemax(UInt64)),
        WTR.RunCase("a value where native answers nothing", _RUN_ADD1, (Int32(1),), nothing),
    ]
    local r = WTR.run_cases(cases)
    @test length(r) == length(cases) && [x.label for x in r] == [c.label for c in cases]
    @test all(x -> x.ok, r[1:7]) && r[14].ok && r[16].ok && r[17].ok && r[18].ok
    @test !r[8].ok && occursin("answers 2", r[8].why) && occursin("native Julia 1", r[8].why)
    @test !r[9].ok && occursin("answers -0.0", r[9].why)
    @test !r[10].ok && occursin("marshals no Tuple{Int32}", r[10].why)
    @test !r[11].ok && occursin("imports m.f", r[11].why)
    @test !r[12].ok && occursin("no entry", r[12].why)
    @test !r[13].ok && !isempty(r[13].why)
    @test !r[15].ok && occursin("the wasm-opt'd module answers 41", r[15].why) && occursin("differ: 42 against 41", r[15].why) &&
          !occursin("the module answers", r[15].why)
    @test !r[19].ok && occursin("the module answers \"a_value:number\", native Julia nothing", r[19].why)   # A56E1
    @test WTR.run_cases(WTR.RunCase[]) == WTR.RunResult[]
end

# modules whose `f` (i32 -> i32) raises a wasm exception: tags of type () -> (), `throw <tag>`, and the tags exported
function _run_thrower(ntags::Int, thrown::Int, exported::Vector{Int})::Vector{UInt8}
    local tags = vcat(UInt8[ntags], reduce(vcat, (UInt8[0x00, 0x01] for _ in 1:ntags); init = UInt8[]))
    local exps = vcat(UInt8[0x01, 0x66, 0x00, 0x00], reduce(vcat, (UInt8[0x01, UInt8('s' + t), 0x04, UInt8(t)] for t in exported); init = UInt8[]))
    return vcat(UInt8[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00],
                UInt8[0x01, 0x09, 0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x00, 0x00],   # types: i32 -> i32, () -> ()
                UInt8[0x03, 0x02, 0x01, 0x00],                                            # f has type 0
                UInt8[0x0d, UInt8(length(tags))], tags,
                UInt8[0x07, UInt8(length(exps) + 1), UInt8(1 + length(exported))], exps,
                UInt8[0x0a, 0x06, 0x01, 0x04, 0x00, 0x08, UInt8(thrown), 0x0b])          # f: throw <thrown>
end
const _RUN_THROWS = _run_thrower(1, 0, [0])
const _RUN_TRAPS = _run_one_function(_RUN_I32, UInt8[0x00])   # local.get 0, unreachable

@testset "a native throw wants a wasm exception: neither a trap nor a return" begin
    local r = WTR.run_cases([WTR.RunCase("throws as native does", _RUN_THROWS, (Int32(1),), WTR.Throws(DivideError)),
                             WTR.RunCase("traps where native throws", _RUN_TRAPS, (Int32(1),), WTR.Throws(DivideError)),
                             WTR.RunCase("returns where native throws", _RUN_ADD1, (Int32(1),), WTR.Throws(DivideError)),
                             WTR.RunCase("throws where native returns", _RUN_THROWS, (Int32(1),), Int32(2)),
                             WTR.RunCase("both modules throw", _RUN_THROWS, (Int32(1),), WTR.Throws(DivideError); optimized = _RUN_THROWS),
                             WTR.RunCase("throws under another tag", _run_thrower(2, 1, [0]), (Int32(1),), WTR.Throws(DivideError)),
                             WTR.RunCase("exports no tag", _run_thrower(1, 0, Int[]), (Int32(1),), WTR.Throws(DivideError)),
                             WTR.RunCase("exports two tags", _run_thrower(2, 0, [0, 1]), (Int32(1),), WTR.Throws(DivideError))])
    @test r[1].ok && r[5].ok
    @test !r[6].ok && occursin("under another tag than the module's exported s", r[6].why)   # A61E1
    @test !r[7].ok && occursin("exports 0 tags", r[7].why) && !r[8].ok && occursin("exports 2 tags", r[8].why)
    @test !r[2].ok && occursin("trap: ", r[2].why) && occursin("where native Julia throws DivideError", r[2].why)
    @test !r[3].ok && occursin("returns, where native Julia throws DivideError", r[3].why)
    @test !r[4].ok && occursin("throws a wasm exception", r[4].why) && occursin("native Julia answers 2", r[4].why)
end

_runner_add1(x::Int32) = x + Int32(1)

@testset "a compiled case: codegen's module and compile's wasm-opt'd one, both run" begin
    local comp(f, ts; optimize::Bool = true) = optimize ? _run_one_function(_RUN_I32) : _RUN_ADD1
    local c = WTR.compiled_case("two modules", comp, _runner_add1, (Int32(1),))
    @test c.bytes == _RUN_ADD1 && c.optimized == _run_one_function(_RUN_I32) && c.native === Int32(2)
    local r = only(WTR.run_cases([c]))
    @test !r.ok && occursin("the wasm-opt'd module answers 1", r.why)
    local same = WTR.compiled_case("one module", (f, ts; optimize::Bool = true) -> _RUN_ADD1, _runner_add1, (Int32(1),))
    @test same.bytes == _RUN_ADD1 && isempty(same.optimized) && only(WTR.run_cases([same])).ok
    # optimized = false compiles codegen's module alone, compile's optimize = false
    local calls = Bool[]
    local logged(f, ts; optimize::Bool = true) = (push!(calls, optimize); _RUN_ADD1)
    local plain = WTR.compiled_case("codegen's module", logged, _runner_add1, (Int32(1),); optimized = false)
    @test calls == [false] && isempty(plain.optimized) && only(WTR.run_cases([plain])).ok
end

# the A61S4 plant's log, and programs that log their native call (a reader's type parameter wants a function with
# no captured state, so they are top-level)
const _RUNNER_EVENTS = String[]
_runner_counted(x::Int32) = (push!(_RUNNER_EVENTS, "native"); x + Int32(1))
_runner_tup(x::Int64) = (push!(_RUNNER_EVENTS, "native"); (x + 1, x > 0))

@testset "the native answer is computed once, by the runner, after the compiles it is compared against (A61S4)" begin
    local events = _RUNNER_EVENTS
    local logged(f, ts; optimize::Bool = true) = (push!(events, optimize ? "opt" : "plain"); _RUN_ADD1)
    empty!(events)
    local c = WTR.compiled_case("order", logged, _runner_counted, (Int32(1),))
    @test events == ["plain", "opt", "native"] && c.native === Int32(2)
    empty!(events)
    local cs, native = WTR.answer_cases("order", logged, _runner_counted, (Int32(1),))
    @test events == ["plain", "opt", "native"] && native === Int32(2) && only(cs).native === Int32(2)
    # a read answer: its own modules, then the one native call, then the readers its shape needs
    empty!(events)
    local ts, tn = WTR.answer_cases("tuple", logged, _runner_tup, (Int64(3),))
    @test events == ["plain", "opt", "native", "plain", "opt", "plain", "opt"] && tn == (4, true)
    # a native throw is the runner's Throws, never a caller's guess
    @test WTR.native_answer(x -> div(x, 0), (1,)) === WTR.Throws(DivideError)
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
# answers of the shapes the readers' plants need, each native's own (A61S4: the runner computes the answer)
_runner_shape_t(x::Int64) = (x + 1, (x > 0, 2x), 0.5, :x)
_runner_shape_b(x::Int64) = (x + 1, x > 0)
_runner_shape_n(x::Int64) = (x + 1, nothing)
_runner_shape_v(x::Int64) = (x + 1, [x > 0, x < 0])
_runner_shape_s(x::Int64) = (x + 1, "ab")

@testset "a tuple answer's leaves, one reader per leaf type, each leaf named by its path" begin
    # the readers as answer_cases builds them, with a compile that only counts its calls
    local calls = Ref(0)
    local counted(f, ts; optimize::Bool = true) = (calls[] += 1; _RUN_ADD1)
    local cs = first(WTR.answer_cases("t", counted, _runner_shape_t, (Int64(3),)))
    @test cs[1].label == "t(own module)" && cs[1].native === WTR.ReturnsRef()   # the case's own module, run too
    @test [c.label for c in cs[2:end]] == ["t(1,)", "t(2, 2)", "t(2, 1)", "t(3,)", "t(4,)"]
    @test [c.args for c in cs[2:end]] == [(3, 1), (3, 2), (3, 1), (3, 1), (3, 1)]
    @test calls[] == 2 + 2 * 3   # the own module and Int64, Bool and Float64's readers, each both modules; no reader for Symbol
    # `own`, the caller's compile, spares the own module's second compile
    calls[] = 0; WTR.answer_cases("t", counted, _runner_shape_b, (Int64(3),); own = _RUN_ADD1)
    @test calls[] == 1 + 2 * 2
    # the own module must return a non-null reference: a number, as from an i32 module, fails
    @test occursin("the module returns a_value:number", only(WTR.run_cases([WTR.RunCase("n", _RUN_ADD1, (Int32(1),), WTR.ReturnsRef())])).why)
    # a leaf of a singleton type crosses as "void": its call returns, its type its value
    local v = first(WTR.answer_cases("v", counted, _runner_shape_n, (Int64(3),)))
    @test [c.label for c in v[2:end]] == ["v(1,)", "v(2,)"] && WTR._wire_answer(nothing) == ("void", "-") && WTR._unwire(Nothing, "-") === nothing
    # a vector inside the answer: its length a leaf, each element a leaf, read by getindex
    local vec = first(WTR.answer_cases("w", counted, _runner_shape_v, (Int64(3),)))
    @test [c.label for c in vec[2:end]] == ["w(1,)", "w(2, :len)", "w(2, (:ix, 1))", "w(2, (:ix, 2))"]
    @test [c.native for c in vec[2:end]] == Any[4, 2, true, false]
    @test WTR._pick((4, [true, false]), Val(((2, (:ix, 2)),)), Bool, Int64(1)) === false &&
          WTR._pick((4, [true, false]), Val(((2, :len),)), Int64, Int64(1)) === Int64(2)
    # the pick is typeasserted to the leaves' type: a leaf held as Any comes back at native's type
    @test WTR._pick(Any[Int64(5), true], Val((((:ix, 1),),)), Int64, Int64(1)) === Int64(5)
    @test_throws TypeError WTR._pick(Any[true], Val((((:ix, 1),),)), Int64, Int64(1))
    # a String is read as its ncodeunits and each codeunit; while its reader is rejected (Unported), the String
    # is one case the runner does not read, "marshals no String", never a failure of WT's
    local sc = first(WTR.answer_cases("s", counted, _runner_shape_s, (Int64(3),)))
    @test [c.label for c in sc[2:end]] == ["s(1,)", "s(2, :ncu)", "s(2, (:cu, 1))", "s(2, (:cu, 2))"]
    @test [c.native for c in sc[2:end]] == Any[4, 2, 0x61, 0x62]
    local refused(f, ts; optimize::Bool = true) = f isa WTR.Leaves && any(p -> WTR._on_string(p), typeof(f).parameters[2]) ?
        throw(WasmTarget.RejectionError(WasmTarget.Unported("dart2wasm/lib/intrinsics.dart:1194 Intrinsifier.generateStaticIntrinsic"), "codeunit")) : _RUN_ADD1
    local su = first(WTR.answer_cases("s", refused, _runner_shape_s, (Int64(3),)))
    @test [c.label for c in su[2:end]] == ["s(1,)", "s(2,)"] && su[3].native == "ab" && isempty(su[3].bytes)
    @test occursin("the runner does not read it yet, its reader is rejected", WTR.run_cases(su[3:3])[1].why)
    # any reader rejected as Unported leaves its facts unread, named; an Internal propagates
    local boxed(f, ts; optimize::Bool = true) = f isa WTR.Leaves && Int64 in map(p -> typeof(foldl(WTR._step, p; init = (4, true))), collect(typeof(f).parameters[2])) ?
        throw(WasmTarget.RejectionError(WasmTarget.Unported("dart2wasm/lib/translator.dart:1597 Translator.convertType"), "boxing")) : _RUN_ADD1
    local bx = first(WTR.answer_cases("b", boxed, _runner_shape_b, (Int64(3),)))
    @test [c.label for c in bx[2:end]] == ["b(1,)", "b(2,)"] && occursin("convertType", WTR.run_cases(bx[2:2])[1].why) && isempty(bx[3].unread)
    local broken(f, ts; optimize::Bool = true) = throw(WasmTarget.RejectionError(WasmTarget.Internal("x"), "y"))
    @test_throws WasmTarget.RejectionError WTR.answer_cases("i", broken, _runner_shape_b, (Int64(3),))
    @test WTR._unwire(UInt8, "255") === 0xff && WTR._unwire(UInt8, "-1") isa String
    # a leaf of a type the runner does not marshal has no reader and fails, named
    @test isempty(cs[6].bytes) && occursin("marshals no Symbol", WTR.run_cases(cs[6:6])[1].why)
end

@testset "a tuple answer read leaf by leaf from WasmTarget's modules" begin
    local cs = first(WTR.answer_cases("facts", WasmTarget.compile, _runner_facts, (Int64(3),)))
    @test all(c -> !isempty(c.bytes) && !isempty(c.optimized), cs)
    @test all(x -> x.ok, WTR.run_cases(cs))
    # an answer that differs in one leaf fails that leaf alone, named by its path
    local planted = Dict("facts(2, 2)" => 7)
    local r = WTR.run_cases([WTR.RunCase(c.label, c.bytes, c.optimized, c.args, get(planted, c.label, c.native), c.entry) for c in cs])
    @test [x.label for x in r if !x.ok] == ["facts(2, 2)"]
    @test occursin("answers 6, native Julia 7", only(x.why for x in r if !x.ok))
end
