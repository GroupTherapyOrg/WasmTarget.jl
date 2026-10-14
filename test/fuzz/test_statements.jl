# ============================================================================
# Statement-layer validation — run standalone:
#   julia --project=test/fuzz test/fuzz/test_statements.jl
# ============================================================================
# Asserts the GENERATOR's own health (well-typed natively, no gen errors) and runs the
# differential over a fixed draw of its programs (seeded: the same programs every run). A
# program WT rejects at compile time is reported (loud is correct); a program whose wasm
# answers differently from native — a wrong value, a trap, a divergent throw, an unsound
# optimization — fails the lane with its full source, input and both answers. Until
# 2026-09-29 the draw was unseeded and those were only reported: a wrong_value printed 100
# characters of its program and passed, and one draw stalled a Windows 1.13 job for 39 min.

using Test, Supposition, Random

include(joinpath(@__DIR__, "run.jl"))
# a wrong outcome is located at its first divergent statement (test/trace_localize.jl)
const WasmRunner = FuzzHarness.WasmRunner
include(joinpath(@__DIR__, "..", "trace_localize.jl"))
_js_arg(x::Int64)::String = "$(x)n"
_js_arg(x::Float64)::String = isnan(x) ? "NaN" : isinf(x) ? (x > 0 ? "Infinity" : "-Infinity") : repr(x)
function _locate(fn, input::Tuple)::String
    try
        return Base.invokelatest(TraceLocalize.first_divergence, fn, input...;
                                 js_args=join(map(_js_arg, input), ", ")).summary
    catch e
        return "(the wrong value could not be located: $(first(sprint(showerror, e), 200)))"
    end
end

const N = 40
const SEED = 0x5747_0001   # the fixed draw; a new seed is a new program set, reviewed as such

@testset "statement-layer generator health" begin
    for (ti, T0) in enumerate((Int64, Float64))
        Random.seed!(SEED + ti)   # Supposition.example draws from the default RNG
        gen = FuzzStatements.gen_program_stmts(T0; depth = 3)
        genfail = 0
        natfail = 0
        cats = Dict{Symbol,Int}()
        findings = String[]
        wrong = String[]
        drawn = String[]   # the programs drawn, for the draw's digest
        for k in 1:N
            body = try
                Supposition.example(gen)
            catch e
                genfail += 1
                continue
            end
            # native well-typedness: f(x) must run (or throw a DOMAIN error —
            # ÷0 etc. is fine) without UndefVarError/MethodError (gen bugs)
            fn, _, src = FuzzGen.make_function(body, T0)
            push!(drawn, src)
            for tup in FuzzGen.sample_inputs(T0)[1:3]
                try
                    Base.invokelatest(fn, tup...)
                catch e
                    if e isa UndefVarError || e isa MethodError
                        natfail += 1
                        natfail <= 3 && println("  NATIVE-INVALID [$T0] $(typeof(e)): $(first(src, 120))")
                    end
                end
            end
            o = try
                FuzzProperty.differential(body, T0)
            catch e
                println("  DIFF ERROR: $(first(sprint(showerror, e), 100))")
                continue
            end
            cats[o.category] = get(cats, o.category, 0) + 1
            if o.category === :compile_error
                length(findings) < 5 && push!(findings, "[compile_error] $(first(string(body), 100))")
            elseif o.category ∉ (:ok, :skip)
                push!(wrong, "[$(o.category)] program $k, input $(o.input): native $(o.native), " *
                             "wasm $(o.wasm)\n$(o.src)\n  " *
                             replace(_locate(fn, Tuple(o.input)), "\n" => "\n  "))
            end
        end
        println("$T0: ", sort(collect(cats)), "  genfail=$genfail natfail=$natfail  draw=",
                string(hash(join(drawn, '\0')); base=16))
        for f in findings
            println("    finding: ", f)
        end
        for w in wrong
            println("  WRONG OUTCOME [$T0] ", w)
        end
        @test isempty(wrong)
        @test genfail == 0
        @test natfail == 0
        @test get(cats, :ok, 0) + get(cats, :skip, 0) > 0   # the loop actually verified things
    end
end

# The lane is strict on throws (FuzzProperty.classify): a native throw matches only a Julia
# exception of native's type in wasm, never a trap or another type, as a Julia `catch` catches
# an exception of a type and never a wasm trap. Two planted miscompiles of `÷`'s guard
# (intrinsics_table.jl's checked_sdiv_int row, restored after) must fail it.
const _WT = WasmTarget
@testset "the statement lane is strict on throws" begin
    @test FuzzProperty.classify((:throw, DivideError()), (:throw, "DivideError")) === :match
    @test FuzzProperty.classify((:throw, DivideError()), (:trap, "divide by zero")) === :divergent_throw
    @test FuzzProperty.classify((:throw, DivideError()), (:throw, "ArgumentError")) === :divergent_throw
    @test FuzzProperty.classify((:throw, DivideError()), (:ok, 0)) === :divergent_throw
    @test FuzzProperty.classify((:ok, 1), (:throw, "DivideError")) === :runtime_trap
    k = (_WT.I64, _WT.I64, :checked_sdiv_int)
    saved = _WT.INTRINSIC_BINOPS[k]
    o0 = FuzzProperty.differential(:(x ÷ (x - x)), Int64)
    println("unplanted: ", o0.category)
    @test o0.category === :ok
    try
        # (i) no guard: wasm traps where Julia throws DivideError
        _WT.INTRINSIC_BINOPS[k] = _WT.BinOpEmit((b, ctx, jw) -> _WT.num!(b, _WT.Opcode.I64_DIV_S), _WT.I64)
        o = FuzzProperty.differential(:(x ÷ (x - x)), Int64)
        println("planted (i), no guard: ", o.category, ", native ", o.native, ", wasm ", o.wasm)
        @test o.category === :divergent_throw
        @test o.native[2] isa DivideError && o.wasm[1] === :trap && occursin("divide by zero", o.wasm[2])
        # (ii) the guard throws another fieldless exception the module numbers
        _WT.INTRINSIC_BINOPS[k] = _WT.BinOpEmit(_WT.I64) do b, ctx, jw
            la = UInt32(_WT.allocate_local!(ctx, _WT.I64)); lb = UInt32(_WT.allocate_local!(ctx, _WT.I64))
            bld = _WT._sub_builder(b, ctx, "planted guard", 2; narrow_to=_WT.I64)
            _WT.local_set!(bld, lb); _WT.local_set!(bld, la)
            _WT.local_get!(bld, lb); _WT.num!(bld, _WT.Opcode.I64_EQZ)
            _WT.if_!(bld); _WT._emit_throw_error_struct!(bld, ctx, StackOverflowError); _WT.end_block!(bld)
            _WT.local_get!(bld, la); _WT.local_get!(bld, lb)
            _WT.append_builder!(b, bld)
            _WT.num!(b, _WT.Opcode.I64_DIV_S)
        end
        o = FuzzProperty.differential(:(x ÷ (x - x)), Int64)
        println("planted (ii), StackOverflowError: ", o.category, ", native ", o.native, ", wasm ", o.wasm)
        @test o.category === :divergent_throw
        @test o.native[2] isa DivideError && o.wasm == (:throw, "StackOverflowError")
    finally
        _WT.INTRINSIC_BINOPS[k] = saved
    end
end
