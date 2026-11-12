# test/verdict.jl, the verdict (spec v16 X1): the wire's leaf kinds and their bits, the raw grammar read strictly, a
# module's raw result judged by bits at native's leaf kind, the binding the compiling process and the verdict share, the
# calls checked against the answer's, and the runner's fixtures refusing a runner that is not bit-exact. A judge's test
# file: no move's rule admits it (dev/climb/core.py MOVE_RULES), as no move's rule admits the file it tests.
using Test
import SHA
isdefined(Main, :WTVerdict) || Base.include(Main, joinpath(@__DIR__, "..", "verdict.jl"))
const WV = Main.WTVerdict
const WVO = Main.WTOracle
const WVR = Main.WTOracleRead

@testset "the wire's leaf kinds: a value crosses as the bits Julia stores, zero-extended to its wasm type" begin
    @test [WV.leaf_kind(T) for T in (Bool, UInt8, Int32, UInt32, Char, Int64, UInt64, Float32, Float64)] ==
          [:i32, :i32, :i32, :i32, :i32, :i64, :i64, :f32, :f64]
    @test WV.leaf_kind(Nothing) === :void && WV.leaf_kind(Int16) === nothing && WV.leaf_kind(Symbol) === nothing &&
          WV.leaf_kind(Tuple{Int32}) === nothing && WV.leaf_kind(String) === nothing
    @test WV.wire_arg(true) == "i32:00000001" && WV.wire_arg(0xc8) == "i32:000000c8" && WV.wire_arg(Int32(-1)) == "i32:ffffffff"
    @test WV.wire_arg('é') == "i32:c3a90000" && WV.wire_arg(reinterpret(Char, 0xff000000)) == "i32:ff000000"
    @test WV.wire_arg(typemin(Int64)) == "i64:8000000000000000" && WV.wire_arg(typemax(UInt64)) == "i64:ffffffffffffffff"
    @test WV.wire_arg(reinterpret(Float32, 0x7f800001)) == "f32:7f800001" && WV.wire_arg(-0.0) == "f64:8000000000000000"
    @test WV.wire_arg(nothing) === nothing && WV.wire_arg(Int16(3)) === nothing
    # a group's kind from its shape alone: the compiling process and the verdict decide alike, resolving no type
    @test WV._group_kind(:bits, WVO.type_path(UInt8)) === :i32 && WV._group_kind(:bits, WVO.type_path(Int16)) === nothing &&
          WV._group_kind(:void, "anything") === :void && WV._group_kind(:opaque, WVO.type_path(Int64)) === nothing
end

@testset "the raw wire is read strictly: a line no raw result reads is the runner's, located" begin
    @test WV.read_raw("ret i32 0000002a 0.1") isa WV.Raw && WV.read_raw("ret i32 0000002a 0.1").bits == 0x2a
    @test WV.read_raw("ret f64 7ff0000000000001 3").bits == 0x7ff0000000000001
    @test WV.read_raw("ret null - 0.0").kind === :null && WV.read_raw("exc x y").text == "x y" && WV.read_raw("err").what === :err
    for bad in ("ret i32 2a 0.1", "ret i32 0000002A 0.1", "ret i64 0000002a 0.1", "ret f32 0000002a", "ret i16 0000 0.1",
                "ret void 0 0.1", "ok 42 0.1", "ret i32 0000002a -1", "passed")
        @test WV.read_raw(bad) isa String
    end
end

const _V_ADD = UInt8[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]   # bytes the plan carries; no run here
_v_case(native; opt = UInt8[]) = WV.RunCase("c", _V_ADD, opt, (Int64(1),), native, "", "")
_v_judge(native, raws...; opt = isempty(raws) || length(raws) == 1 ? UInt8[] : UInt8[1]) =
    only(WV.verdicts([_v_case(native; opt)], WV.plan([_v_case(native; opt)])..., Any[WV.read_raw(r) for r in raws]))

@testset "a module's raw result is judged by bits at native's leaf kind, located" begin
    @test _v_judge(0xc8, "ret i32 000000c8 0.1").ok && !_v_judge(0xc8, "ret i32 ffffffc8 0.1").ok   # never truncated to fit
    @test occursin("answers the i32 0xffffffc8, native Julia 0xc8", _v_judge(0xc8, "ret i32 ffffffc8 0.1").why)
    @test _v_judge(true, "ret i32 00000001 0").ok && !_v_judge(true, "ret i32 00000002 0").ok
    @test !_v_judge(-0.0, "ret f64 0000000000000000 0").ok && occursin("answers 0.0, native Julia -0.0", _v_judge(-0.0, "ret f64 0000000000000000 0").why)
    local snan, qnan = reinterpret(Float32, 0x7f800001), reinterpret(Float32, 0x7fc00001)
    @test _v_judge(snan, "ret f32 7f800001 0").ok && !_v_judge(snan, "ret f32 7fc00001 0").ok   # a quieted NaN is another value
    @test !_v_judge(Int32(4), "ret i64 0000000000000004 0").ok && !_v_judge(4.0f0, "ret i32 40800000 0").ok   # another kind
    # a singleton is its reader's (spec v17 Y2): its own module returns anything without a trap, and `void` alone matches
    # no answer, every singleton type sharing it
    @test _v_judge(WV.ReturnsAny(), "ret void - 0").ok && _v_judge(WV.ReturnsAny(), "ret null - 0").ok &&
          _v_judge(WV.ReturnsAny(), "ret i32 00000000 0").ok && _v_judge(WV.ReturnsAny(), "err trap: unreachable").outcome === :wrong
    # a reader's singleton leaf (typeasserted to exactly that type): `void` is exact, a null another value
    @test _v_judge(nothing, "ret void - 0").ok && _v_judge(nothing, "ret null - 0").outcome === :wrong
    @test _v_judge(WV.ReturnsRef(), "ret ref - 0").ok && !_v_judge(WV.ReturnsRef(), "ret null - 0").ok
    local t = WVO.Throws(DivideError)
    @test _v_judge(t, "exc x").ok && occursin("where native Julia throws DivideError", _v_judge(t, "err trap: unreachable").why)
    @test occursin("returns, where native Julia throws DivideError", _v_judge(t, "ret i64 0000000000000001 0").why)
    @test occursin("throws a wasm exception", _v_judge(Int64(1), "exc x").why)
    @test occursin("past its 5.0 s budget", _v_judge(Int64(1), "ret i64 0000000000000001 5001").why) &&
          _v_judge(Int64(1), "ret i64 0000000000000001 5001").outcome === :errored   # no `_matches`: never wrong (Y2)
    @test _v_judge(Int64(1), "ret i64 0000000000000002 0").outcome === :wrong && _v_judge(t, "exc x").outcome === :passed
    @test occursin("the runner wrote a line no raw result reads: ok 1 0.1", _v_judge(Int64(1), "ok 1 0.1").why)
    @test occursin("the judge's wire has no leaf kind for Tuple{Int64}", _v_judge((Int64(1),), "ret ref - 0").why) &&
          _v_judge((Int64(1),), "ret ref - 0").outcome === WV.JUDGE_GAP
    # both modules: each against native, and the two against each other
    @test _v_judge(Int64(2), "ret i64 0000000000000002 0", "ret i64 0000000000000002 0").ok
    local d = _v_judge(Int64(2), "ret i64 0000000000000002 0", "ret i64 0000000000000003 0")
    @test !d.ok && occursin("the wasm-opt'd module answers 3", d.why) && occursin("differ: 2 against 3", d.why)
    # an argument of no leaf kind is no call: the plan decides it, the run never sees it
    local calls, decided = WV.plan([WV.RunCase("s", _V_ADD, UInt8[], (Int16(1),), Int64(1), "", "")])
    @test isempty(calls) && decided[1][1] === WV.JUDGE_GAP && occursin("no leaf kind for the argument type Int16", decided[1][2])
end

# the fixtures' bytes, pinned (spec v17 Y6): test/fixtures/runner.wat and runner_patch.wat assembled by
# test/fixtures/make_fixtures.py (by hand, when a fixture changes; nothing assembles at test or run time), their modules'
# sha256 here, so a fixture module edited in its .tsv alone, or assembled from another text, is refused
const _V_FIXTURE_SHA256 = ("runner_calls.tsv" => "33266ffc3de4613cb4d883c6692a23a2701244cf1e279a8e5a0412ab98bdfcac",
                           "runner_patch.tsv" => "80c4161f9a969805931ac9e3d9fba56724f7cf508056bf7d0d4164264f46405d")
@testset "the fixtures' modules are the bytes their generator wrote (spec v17 Y6)" begin
    for (file, sha) in _V_FIXTURE_SHA256
        local m = [split(l, '\t')[end] for l in eachline(joinpath(WV.FIXTURES, file)) if startswith(l, "module\t")]
        @test length(m) == 1 && bytes2hex(SHA.sha256(WV.Base64.base64decode(only(m)))) == sha
    end
    @test isfile(joinpath(WV.FIXTURES, "runner.wat")) && isfile(joinpath(WV.FIXTURES, "runner_patch.wat")) &&
          isfile(joinpath(WV.FIXTURES, "make_fixtures.py"))
end

@testset "the runner's fixtures: exact, and a runner that is not bit-exact is refused by fixture name" begin
    local want = WV.fixtures()
    @test length(want) >= 30 && any(w -> occursin("signaling NaN", w[1]), want)
    local exact = [w * (startswith(w, "ret") ? " 0.3" : "") for (_, w) in want]
    @test isempty(WV.fixture_failures(exact, want))
    # a runner that answers passed-shaped lines for everything, or quiets a signaling NaN, or shares an instance
    @test length(WV.fixture_failures(fill("ret i32 00000001 0.0", length(want)), want)) >= length(want) - 4
    local quiet = replace.(exact, "ret f32 7f800001" => "ret f32 7fc00001")
    @test any(b -> occursin("f32 signaling NaN through", b), WV.fixture_failures(quiet, want))
    local shared = copy(exact); shared[end] = "ret i32 00000002 0.0"
    @test only(WV.fixture_failures(shared, want)) == "the runner's fixture a fresh instance, second call wrote `ret i32 00000002`, its wire is `ret i32 00000001`"
    @test !isempty(WV.fixture_failures(exact[1:end-1], want))   # a line missing
    # judge() refuses the whole run part on a fixture, before any case
    @test_throws WV.FixtureFailure WV.judge(String[], String[], quiet)
end

_v_tup(x::Int64) = (x + 1, (x > 0, "é"))
@testset "one binding: the compiling process (a shape, no value) and the verdict (the answer) make the same calls" begin
    local a = WVO.answer_of("", _v_tup, (Int64(3),))
    local s = WVR.Shape(a)
    @test s.nargs == 1 && [g.kind for g in s.groups] == [:bits, :bits, :bits, :bits] && count(g -> g.on_string, s.groups) == 2
    # the compiling side: each compile a distinct module, recorded in order; no native value anywhere in its cases
    local recorded = Tuple{String,Vector{UInt8}}[]
    local comp(f, ts; optimize::Bool = true) = (b = UInt8[length(recorded)]; push!(recorded, (WVO._key(ts) * (optimize ? "" : " unoptimized"), b)); b)
    local mine = WV.bind(s, (Int64(3),), comp; f = _v_tup)
    @test all(c -> c.native === nothing || c.native isa WV.ReturnsRef, mine)
    # the verdict: the answer bound to the recorded modules, popped by key
    local q = copy(recorded)
    local pop(key; optimize::Bool = true) = (r = popfirst!(q); r[1] == key * (optimize ? "" : " unoptimized") || error("key"); r[2])
    local theirs = WV.bind(s, a.args, pop; a)
    @test isempty(q) && [c.label for c in mine] == [c.label for c in theirs] && [c.args for c in mine] == [c.args for c in theirs]
    @test [(c.args, c.entry) for c in first(WV.plan(mine))] == [(c.args, c.entry) for c in first(WV.plan(theirs))]
    @test [c.native for c in theirs[2:end]] == Any[4, true, 2, 0xc3, 0xa9]
    # the shape the driver writes reads back as the answer's own
    local text = ["shape\tg/c\t$(WVO._b64(a.label))\t-\t-\t1\t$(WVO._b64(a.key))\t$(WVO._b64(a.rkey))\t$(length(a.groups))\t-";
                  ["sgroup\tg/c\t$(WVO._b64(g.tpath))\tbits\t$(g.on_string ? 1 : 0)\t$(length(g.paths))\t" *
                   join((WVO._path_code(p) for p in g.paths), ';') for g in a.groups]]
    local back = WVR.read_shapes(text)["g/c"]
    @test back isa WVR.Shape && (back.label, back.P, back.S, back.nargs, back.key, back.rkey, back.aggregate) ==
          (s.label, s.P, s.S, s.nargs, s.key, s.rkey, s.aggregate) &&
          [(g.tpath, g.kind, g.on_string, g.paths) for g in back.groups] == [(g.tpath, g.kind, g.on_string, g.paths) for g in s.groups]
    @test WVR.read_shapes(text[1:end-1])["g/c"] isa String && WVR.read_shapes(["noanswer\tg/c"])["g/c"] == "no native answer"
end

_v_inc(x::Int64) = x + 1
@testset "the verdict process: the compile's calls must be the answer's, each call's raw line judged" begin
    local a = WVO.answer_of("", _v_inc, (Int64(3),))
    local answers = WVO.answer_lines("g/c", a)
    local b64(x) = WVO._b64(x)
    local mods = ["started\tg/c", "module\tg/c\t$(a.key) unoptimized\t$(b64(UInt8[1]))", "module\tg/c\t$(a.key)\t$(b64(UInt8[2]))"]
    local fx = [w * (startswith(w, "ret") ? " 0.1" : "") for (_, w) in WV.fixtures()]
    local run(calls, raws) = WV.judge([mods; calls; "compiled\tg/c\t0.5"], answers, [fx; raws])
    local good = ["call\tg/c\t0\t-\ti64:0000000000000003", "call\tg/c\t1\t-\ti64:0000000000000003"]
    @test first(run(good, ["ret i64 0000000000000004 0.1", "ret i64 0000000000000004 0.1"]))[1][2] === :passed
    local w = first(run(good, ["ret i64 0000000000000004 0.1", "ret i64 0000000000000005 0.1"]))[1]
    @test w[2] === :wrong && occursin("the wasm-opt'd module answers 5, native Julia 4", w[4])
    # a call with another argument than the answer's, a call missing, a call to the other module: errored, located
    for calls in (["call\tg/c\t0\t-\ti64:0000000000000004", good[2]], good[1:1], [good[2], good[1]])
        local e = first(run(calls, fill("ret i64 0000000000000004 0.1", length(calls))))[1]
        @test e[2] === :errored && occursin("the compiling process's calls are not its answer's", e[4])
    end
    # a row keeps the compile's own outcome, never a judgement's; a label with no answer is errored
    @test first(WV.judge(["row\tg/c\tpassed\t0.1\t$(b64("x"))"], answers, fx))[1][2] === :errored
    @test first(WV.judge([mods; good; "compiled\tg/c\t0.5"], String[], [fx; "ret i64 0000000000000004 0"; "ret i64 0000000000000004 0"]))[1][2] === :errored
end

@testset "the driver's plan: each fixture where it was drawn, its wire from the judge's table alone (spec v17 Y1)" begin
    local want = WV.fixtures()
    # each drawn fixture's wire follows from its plan line: an identity's argument, a patched slot's bits, p_add's sum mod 2^64
    @test WV.fixture_wire(["ident", "f32", "f32:7f800001"], want)[2] == "ret f32 7f800001"
    @test WV.fixture_wire(["patched", "p_i64", "0123456789abcdef"], want)[2] == "ret i64 0123456789abcdef"
    @test WV.fixture_wire(["patched", "p_add", "ffffffffffffffff", "i64:0000000000000002"], want)[2] == "ret i64 0000000000000001"
    @test WV.fixture_wire(["patched", "p_trap"], want)[2] == "err trap: unreachable"
    @test WV.fixture_wire(["frozen", "1"], want) == want[1]
    for bad in (["ident", "f32", "i32:00000001"], ["ident", "f32", "f32:1"], ["patched", "p_none", "00"], ["patched", "p_add", "00"],
                ["frozen", "0"], ["case"])
        @test_throws ArgumentError WV.fixture_wire(bad, want)
    end
    # the patched module's slots and exports are exactly the judge's table's (test/fixtures/runner_patch.tsv, generated)
    local tsv = [split(l, '\t') for l in eachline(joinpath(WV.FIXTURES, "runner_patch.tsv")) if !startswith(l, '#')]
    @test [(String(f[2]), Symbol(f[5])) for f in tsv if f[1] == "slot"] == [(k, v) for (k, v) in WV.PATCH_SLOTS]
    @test [String(f[2]) for f in tsv if f[1] == "fixed"] == [k for (k, _) in WV.PATCH_FIXED]
    # a run judged by its plan: the fixtures after the cases pass where they stand, and a runner that spares the first
    # length(want) lines (red p3) fails the trap the plan put last
    local a = WVO.answer_of("", _v_inc, (Int64(3),))
    local b64(x) = WVO._b64(x)
    local mods = ["started\tg/c", "module\tg/c\t$(a.key) unoptimized\t$(b64(UInt8[1]))", "module\tg/c\t$(a.key)\t$(b64(UInt8[2]))",
                  "call\tg/c\t0\t-\ti64:0000000000000003", "call\tg/c\t1\t-\ti64:0000000000000003", "compiled\tg/c\t0.5"]
    local t = findfirst(w -> w[2] == "err trap: unreachable", want)
    local order = [[k for k in length(want):-1:1 if k != t]; t]   # the trap last: run line length(want) + 1
    local plan = ["case\t2"; ["frozen\t$k" for k in order]; "case\t1"; "patched\tp_add\t0000000000000001\ti64:0000000000000002"]
    local raws = ["ret i64 0000000000000004 0.1"; [want[k][2] * (startswith(want[k][2], "ret") ? " 0.1" : "") for k in order];
                  "ret i64 0000000000000004 0.1"; "ret i64 0000000000000003 0.1"]
    @test first(WV.judge(mods, WVO.answer_lines("g/c", a), raws; run_plan = plan))[1][2] === :passed
    local liar = [i > length(want) && startswith(r, "err trap:") ? "exc trap" : r for (i, r) in enumerate(raws)]
    @test liar != raws
    @test_throws WV.FixtureFailure WV.judge(mods, WVO.answer_lines("g/c", a), liar; run_plan = plan)
    # a case's lines come from its ordinal, wherever the run wrote them; a plan naming a call twice is the driver's fault
    local cs = WV.place(["x", "y", "z"], ["case\t2", "frozen\t1", "case\t1"]; want)
    @test cs[3] == Any["z", "x"] && cs[1] == ["y"]
    @test_throws ArgumentError WV.place(["x", "y"], ["case\t1", "case\t1"]; want)
    @test_throws ArgumentError WV.place(["x"], ["case\t2"]; want)
end

_v_thr(x::Int64) = x > 0 ? throw(DivideError()) : x
_v_none(x::Int64) = x > 0 ? nothing : missing
@testset "the judge reads a type where the answer is a type, and decides each outcome by its cause (spec v17 Y2)" begin
    # the judge-built readers, run natively: a throw's exception type, a singleton's value type, one i32 leaf
    @test WV.Catches{_v_thr,DivideError}()(Int64(1)) === Int32(1) && WV.Catches{_v_thr,BoundsError}()(Int64(1)) === Int32(2) &&
          WV.Catches{_v_thr,DivideError}()(Int64(-1)) === Int32(0)
    @test WV.IsA{_v_none,Nothing}()(Int64(1)) === true && WV.IsA{_v_none,Nothing}()(Int64(-1)) === false
    for (f, kind, T, want) in ((_v_thr, :throws, DivideError, Int32(1)), (_v_none, :void, Nothing, true))
        local a = WVO.answer_of("", f, (Int64(1),))
        local s = WVR.Shape(a)
        @test (s.native_kind, s.native_tpath) == (kind, WVO.type_path(T))
        # the compiling side builds the reader from the shape alone; the verdict pops the same compiles, by key
        local recorded = Tuple{String,Vector{UInt8}}[]
        local comp(g, ts; optimize::Bool = true) = (b = UInt8[length(recorded)]; push!(recorded, (WVO._key(ts) * (optimize ? "" : " unoptimized"), b)); b)
        local mine = WV.bind(s, (Int64(1),), comp; f)
        @test length(mine) == 2 && length(recorded) == 4 && mine[2].native === want
        local q = copy(recorded)
        local pop(key; optimize::Bool = true) = (r = popfirst!(q); r[1] == key * (optimize ? "" : " unoptimized") || error("key"); r[2])
        local theirs = WV.bind(s, a.args, pop; a)
        @test isempty(q) && [(c.args, c.entry) for c in first(WV.plan(mine))] == [(c.args, c.entry) for c in first(WV.plan(theirs))]
        @test theirs[1].native == (kind === :throws ? WVO.Throws(DivideError) : WV.ReturnsAny()) && theirs[2].native === want
        # the reader's leaf decides: its type native's passes; another type, or a module that returns, is wrong
        local cs, (ps, dec) = theirs, WV.plan(theirs)
        local own = kind === :throws ? "exc x" : "ret void - 0"
        local ok = kind === :throws ? "ret i32 00000001 0" : "ret i32 00000001 0"
        local bad = kind === :throws ? "ret i32 00000002 0" : "ret i32 00000000 0"
        local judged(lines) = WV.case_outcome(WV.verdicts(cs, ps, dec, Any[WV.read_raw(l) for l in lines]))
        @test judged([own, own, ok, ok])[1] === :passed
        @test judged([own, own, bad, bad])[1] === :wrong
        # a reader WasmTarget rejects is the port's: unported, never wrong
        local q2 = copy(recorded)
        local pop2(key; optimize::Bool = true) = (r = popfirst!(q2); length(q2) < 2 ? throw(WV.ReaderRejected("unported: the dart definition X")) : r[2])
        local rej = WV.bind(s, a.args, pop2; a)
        @test rej[2].gap === :unported && WV.case_outcome(WV.verdicts(rej, WV.plan(rej)..., Any[WV.read_raw(own), WV.read_raw(own)]))[1] === :unported
    end
    # the shape record names the type, and reads back
    local a = WVO.answer_of("", _v_thr, (Int64(1),))
    local rec = "shape\tg/t\t$(WVO._b64(a.label))\t-\t-\t1\t$(WVO._b64(a.key))\t$(WVO._b64(a.rkey))\t-\tthrows,$(WVO._b64(WVO.type_path(DivideError)))"
    local back = WVR.read_shapes([rec])["g/t"]
    @test back isa WVR.Shape && back.native_kind === :throws && back.native_tpath == WVO.type_path(DivideError)
    @test WVR.read_shapes([replace(rec, "throws," => "bits,")])["g/t"] isa String
    # a case's outcome from its facts': wrong over errored over unported over judge-gap
    local R(o) = WV.RunResult("x", o, "why")
    @test WV.case_outcome([R(:passed), R(WV.JUDGE_GAP), R(:unported)])[1] === :unported &&
          WV.case_outcome([R(:errored), R(:wrong)])[1] === :wrong && WV.case_outcome([R(:passed), R(WV.JUDGE_GAP)])[1] === WV.JUDGE_GAP &&
          WV.case_outcome(WV.RunResult[])[1] === :errored && WV.case_outcome([R(:passed)]) == (:passed, "")
end

@testset "a shape the runner cannot call or read is the judge's gap, never wrong (spec v18 P2)" begin
    @test WV.read_raw("gap no entry: the module exports the functions [f]") isa WV.Raw
    local g = _v_judge(Int64(1), "gap no entry: the module exports the functions [f]")
    @test g.outcome === WV.RUNNER_GAP && occursin("no entry", g.why)   # the architect's p1 case 5 read :wrong
    @test _v_judge(Int64(1), "err trap: unreachable").outcome === :wrong   # a trap where native answers: the module's
    @test _v_judge(Int64(1), "err the module does not compile: x").outcome === :errored   # no answer: never wrong
    @test WV.case_outcome([WV.RunResult("x", WV.RUNNER_GAP, "g"), WV.RunResult("y", WV.JUDGE_GAP, "j")])[1] === WV.RUNNER_GAP
    # the runner's child gets no src-test record variable (red round 15 4)
    isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
    withenv("WT_SRC_RECORDS" => "/x", "WT_SRC_CLAIMS" => "/y", "WT_PROGRESS" => "/z", "WT_OTHER" => "k") do
        local e = Main.WTChild.child_env()
        @test !any(k -> startswith(k, "WT_SRC_") || k == "WT_PROGRESS", keys(e)) && e["WT_OTHER"] == "k"
    end
end

@testset "the verdict process loads no runner" begin
    local out = read(`$(Base.julia_cmd()) --startup-file=no -e "include(\"$(joinpath(@__DIR__, "..", "verdict.jl"))\"); print(isdefined(Main, :WTRunner))"`, String)
    @test out == "false"
    @test !occursin("runner.jl\"", read(joinpath(@__DIR__, "..", "verdict.jl"), String))
    # nor does the test suite's run (spec v17 Y5): test/run_child.jl runs the runner in a child alone
    local child = read(`$(Base.julia_cmd()) --startup-file=no -e "include(\"$(joinpath(@__DIR__, "..", "run_child.jl"))\"); print(isdefined(Main, :WTRunner))"`, String)
    @test child == "false"
end
