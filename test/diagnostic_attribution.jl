# A rejection names its site: the statement, and the inline chain innermost-first.
# (dev/MARCH.md exit criterion 5, "a failure names its site"; parity target.dart:719
# DiagnosticReporter — located, structured, never a bare string.)
#
# With closed-world inlining a construct can sit hundreds of statements deep inside
# the root function's IR; before this, the diagnostic named the ROOT function and a
# line from the root's file, which is how a `copy(Dict{String,Int})` reject reported
# `cd2 at none:10` for a statement that really lived in
# Base.aligned_sizeof(::Type{String}) @ runtime_internals.jl:576, eight frames down.

using Test
using WasmTarget

module DiagAttrib
    # A receiver-free `show` kept out of line (its Method `show(x)` invoked directly).
    shows(x::Float64) = (@noinline show(x); x)
    hostprint(x::Int64) = (print(x); x)
    hostprintln(x::Int64) = (println(x); x)
    # An unsupported construct (a foreigncall WT has no lowering for) inside a helper
    # that inference inlines into its caller.
    @inline helper_uses_ccall(x::Float64) = ccall(:wt_test_no_such_symbol, Float64, (Float64,), x)
    outer(x::Float64) = helper_uses_ccall(x) + 1.0
    # The same construct reached through two inlined levels.
    @inline mid(x::Float64) = helper_uses_ccall(x) * 2.0
    outer2(x::Float64) = mid(x) - 1.0
    # for the internal-tier test: an Int64 add inside an inlined helper
    @inline bug_helper(x::Int64) = x + 1
    # dev/CHARTER.md C6: an inlined statement keeps its chain through get_typed_ir
    @inline c6_mid(x::Int64) = x * 3 + 1
    c6_outer(x::Int64) = c6_mid(x) - 2
    bug_outer(x::Int64) = bug_helper(x) * 2
end

_first_diag(f, argtypes) = try
    WasmTarget.compile(f, argtypes)
    nothing
catch e
    e isa WasmTarget.WasmCompileError ? e : rethrow()
end

# dev/CHARTER.md C6: IR retrieved through the one inference path (get_typed_ir, when the
# closed-world cache does not already hold it) keeps its DebugInfo, so every NIR statement
# carries a source line and an inlined statement's chain names its callee and its caller.
# Before 2026-09-22 get_typed_ir asked code_typed for no debuginfo: every line was 0.
@testset "the one inference path keeps source lines and inline chains" begin
    ci, _ = WasmTarget.get_typed_ir(DiagAttrib.c6_outer, (Int64,))
    nir = WasmTarget.build_nir(ci)
    @test !isempty(nir) && all(s -> s.line > 0, nir)
    # the multiply inside c6_mid, inlined into c6_outer: innermost first — Base's `*`, then
    # c6_mid, then the compiled function c6_outer
    k = findfirst(i -> any(f -> occursin("c6_mid", f), WasmTarget.stmt_frames(ci.debuginfo, i)), eachindex(ci.code))
    @test k !== nothing
    fr = WasmTarget.stmt_frames(ci.debuginfo, something(k, 1))
    im = findfirst(f -> occursin("c6_mid", f), fr)
    @test length(fr) >= 3 && im !== nothing && im > 1 && occursin("c6_outer", fr[end])
end

@testset "diagnostics: a rejection names its statement and inline chain" begin
    e = _first_diag(DiagAttrib.outer, (Float64,))
    @test e !== nothing
    d = e.diag
    @test d.stmt_idx > 0
    @test occursin("wt_test_no_such_symbol", d.stmt)
    # innermost frame first: the helper, at this file
    @test !isempty(d.frames)
    @test occursin("helper_uses_ccall", d.frames[1])
    @test occursin(basename(@__FILE__), d.frames[1])
    # the compiled function is the last frame
    @test occursin("outer", d.frames[end])
    # julia_loc is the innermost frame's file:line, not the root's
    @test d.julia_loc !== nothing && occursin(basename(@__FILE__), d.julia_loc)
    # the printed error carries the chain
    msg = sprint(showerror, e)
    @test occursin("statement %$(d.stmt_idx)", msg)
    @test occursin("helper_uses_ccall", msg)
    @test occursin("←", msg)

    e2 = _first_diag(DiagAttrib.outer2, (Float64,))
    @test e2 !== nothing
    fr = e2.diag.frames
    @test length(fr) >= 3
    @test occursin("helper_uses_ccall", fr[1])
    @test occursin("mid", fr[2])
    @test occursin("outer2", fr[end])
end

@testset "diagnostics: a codegen bug (the internal tier) is located the same way" begin
    # inject a failure into one intrinsics-table row, compile through an inlined
    # helper, restore the row
    k = (WasmTarget.I64, WasmTarget.I64, :add_int)
    saved = WasmTarget.INTRINSIC_BINOPS[k]
    WasmTarget.INTRINSIC_BINOPS[k] = WasmTarget.BinOpEmit((b, ctx, jw) -> error("simulated codegen bug"), saved.result)
    try
        err = try
            WasmTarget.compile(DiagAttrib.bug_outer, (Int64,))
            nothing
        catch e
            e
        end
        @test err isa WasmTarget.WasmInternalError
        @test err.stmt_idx > 0
        @test occursin("add_int", err.stmt)
        @test !isempty(err.frames) && occursin("bug_helper", err.frames[end - 1]) && occursin("bug_outer", err.frames[end])
        @test err.cause isa ErrorException && occursin("simulated", err.cause.msg)
        msg = sprint(showerror, err)
        @test occursin("codegen bug", msg) && occursin("bug_helper", msg) && occursin("cause:", msg)
        # the compiler frames it was raised through (dart CFECrashError.stackTrace): from the
        # injected emitter out to the catching statement entry, the innermost WT frame in the
        # headline — the compiler line a bug surfaced at, without instrumenting the compiler
        @test !isempty(err.stacktrace)
        @test err.stacktrace[1].func === :error &&
              any(f -> occursin("diagnostic_attribution.jl", string(f.file)), err.stacktrace[1:3])
        @test err.stacktrace[end].func === :compile_statement!
        headline = first(split(msg, '\n'))
        @test occursin(", raised at ", headline) && occursin(" @ src/codegen/", headline)
        @test occursin("raised through:", msg)
    finally
        WasmTarget.INTRINSIC_BINOPS[k] = saved
    end
end

@testset "diagnostics: the coercion funnel rejects a numeric pair it has no arm for" begin
    # Julia never converts float→int implicitly; a codegen type-chain defect that asks the
    # funnel for one must reject at the statement, never leave the value unconverted.
    ci, _ = WasmTarget.get_typed_ir(identity, (Float64,))
    ctx = WasmTarget.CompilationContext(WasmTarget.nir_body(ci), (Float64,), Float64, WasmTarget.WasmModule(), WasmTarget.TypeRegistry();
                                        translator=WasmTarget.Translator(nothing))
    ctx.current_stmt_idx = 1
    b = WasmTarget._ctx_builder(ctx, "funnel_negative")
    WasmTarget.f64_const!(b, 1.5)
    err = try
        WasmTarget.convert_type!(b, WasmTarget.F64, WasmTarget.I64, ctx)
        nothing
    catch e
        e
    end
    @test err isa WasmTarget.WasmCompileError
    @test occursin("no numeric conversion from F64 to I64", sprint(showerror, err))
    @test length(ctx.diagnostics) == 1 && ctx.diagnostics[1].stmt_idx == 1
end

@testset "diagnostics: the funnel rejects a cross-hierarchy ref pair and lands non-null abstract sinks (Coercion.tla)" begin
    ci, _ = WasmTarget.get_typed_ir(identity, (Float64,))
    mk() = begin
        ctx = WasmTarget.CompilationContext(WasmTarget.nir_body(ci), (Float64,), Float64, WasmTarget.WasmModule(), WasmTarget.TypeRegistry();
                                        translator=WasmTarget.Translator(nothing))
        ctx.current_stmt_idx = 1
        ctx, WasmTarget._ctx_builder(ctx, "funnel_negative")
    end
    # funcref → anyref: no bridge op exists between the func and any hierarchies
    ctx, b = mk()
    WasmTarget.ref_null!(b, WasmTarget.FuncRef)
    err = try
        WasmTarget.convert_type!(b, WasmTarget.FuncRef, WasmTarget.AnyRef, ctx)
        nothing
    catch e
        e
    end
    @test err isa WasmTarget.WasmCompileError
    @test occursin("hierarchies do not meet", sprint(showerror, err))
    # anyref → (ref struct): a NonNullAbstractRef sink gets a non-null abstract cast
    # (this pair emitted NOTHING before the model was checked)
    ctx, b = mk()
    WasmTarget.ref_null!(b, WasmTarget.AnyRef)
    WasmTarget.convert_type!(b, WasmTarget.AnyRef, WasmTarget.NonNullAbstractRef(UInt8(WasmTarget.StructRef)), ctx)
    @test b.instrs[end] isa WasmTarget.InstrIR.RefCastAbstract && !b.instrs[end].nullable
    @test b.v.stack[end] == WasmTarget.NonNullAbstractRef(UInt8(WasmTarget.StructRef))
    # externref (nullable) → (ref extern): the bridge is not needed, only a null check
    ctx, b = mk()
    WasmTarget.ref_null!(b, WasmTarget.ExternRef)
    WasmTarget.convert_type!(b, WasmTarget.ExternRef, WasmTarget.NonNullExternRef, ctx)
    @test b.instrs[end] isa WasmTarget.InstrIR.RefAsNonNull
end

@testset "diagnostics: the 5-field constructor still builds a located-less report" begin
    d = WasmTarget.WasmDiagnostic(:unsupported_type, "f", "x", nothing, nothing)
    @test d.stmt_idx == 0 && isempty(d.frames) && d.stmt == ""
    @test sprint(show, d) == "[unsupported_type] in `f`: x"
end

@testset "diagnostics: receiver-free print/println/show reject loudly at their statement (C6)" begin
    # Natively these write to the console; a WT module has no console, so each must
    # reject — never compile to nothing. The rejection lands on the statement that makes
    # the console call (Julia's own bodies route it through `stdout::IO`).
    for (f, argtypes) in ((DiagAttrib.hostprint, (Int64,)), (DiagAttrib.hostprintln, (Int64,)),
                          (DiagAttrib.shows, (Float64,)))
        @test_throws WasmTarget.WasmCompileError WasmTarget.compile(f, argtypes)
        e = _first_diag(f, argtypes)
        @test e !== nothing && e.diag.stmt_idx > 0 && !isempty(e.diag.stmt)
    end
end

@testset "diagnostics: a dynamic operator on operands of no one machine type rejects, never guesses a width (C6)" begin
    # The accumulator `s` carries Int64 then Float64; once the numeric-join VERIFY bans the
    # phi's Int64 seed the `+` sees (Any, Float64). The operator fallback once unboxed the Any
    # operand as i64 and failed with an internal stack error; it must reject at the `+`.
    f = (n::Int64) -> (s = 0; foreach(i -> (s += 0.5), 1:n); s isa Float64 ? 1 : 2)
    err = try WasmTarget.compile(f, (Int64,)); nothing catch e; e end
    @test err isa WasmTarget.WasmCompileError
    @test err !== nothing && occursin("has no single opcode", sprint(showerror, err))
end

module DiagCollect
dyn_eq(x::Int64) = (v = Any[x, 1.5]; v[x > 0 ? 1 : 2] == 1 ? 1 : 0)   # line 3: a dynamic `==`
end

@testset "diagnostics: a closed-world collection failure names the root and why it was enrolled" begin
    # the failed batch's roots are inferred again one at a time; the one that fails alone is
    # named with its enrollment reason, its own error and the frames it was raised through
    mi_sin = WasmTarget.entry_method_instance(sin, (Float64,))
    mi_cos = WasmTarget.entry_method_instance(cos, (Float64,))
    batch = Tuple{Any,String}[(mi_sin, "the call `sin(x)` in f(::Float64) (statement %2 @ a.jl:3)"),
                              (mi_cos, "the dispatch candidate for runtime class Float64 of `cos(%4)` in g(::Any) (statement %5 @ b.jl:9)")]
    planted(mi) = mi === mi_cos ? error("planted inference failure") : nothing
    err = try WasmTarget.throw_located_collection_failure(batch, ErrorException("the batch failed"), Base.backtrace(), planted) catch e; e end
    @test err isa WasmTarget.WasmInternalError
    msg = sprint(showerror, err)
    @test occursin("inferring cos(::Float64), enrolled as the dispatch candidate for runtime class Float64", msg)
    @test occursin("b.jl:9", msg) && occursin("planted inference failure", msg)
    @test !isempty(err.stacktrace)
    # no root fails alone: every root of the batch and the original error
    err2 = try WasmTarget.throw_located_collection_failure(batch, ErrorException("the batch failed"), Base.backtrace(), mi -> nothing) catch e; e end
    @test length(err2.frames) == 2 && occursin("the batch failed", sprint(showerror, err2))
    # real discovery records why: the dynamic `==` enrolls its candidates with its statement's line
    entry = WasmTarget.entry_method_instance(DiagCollect.dyn_eq, (Int64,))
    world = WasmTarget.collect_closed_world(Any[entry])
    @test any(r -> occursin("dispatch candidate for runtime class", r) &&
                   occursin("diagnostic_attribution.jl:", r) && occursin("dyn_eq", r), values(world.enrolled_as))
end

# getfield by a name known only at run time answers as jl_f_getfield or rejects with why: WT's
# layouts of DataType and TypeName are projections (reading by Julia's field order would read
# another field), and a Module's getfield reads a global binding. Until 2026-09-29 the first
# raised a codegen bug and the second threw FieldError where Julia returns (dev/AUDIT.md E1).
module DiagRuntimeName
@noinline dt_getfield(@nospecialize(T::DataType), s::Symbol) = getfield(T, s)
dt_use(x::Int64) = (v = dt_getfield(x > 0 ? Int64 : Float64, x > 2 ? :hash : :flags); v isa Int32 ? Int64(v::Int32) : -1)
mod_use(x::Int64) = getfield(x > 0 ? Base : Core, x > 2 ? :pi : :nothing) === nothing ? 1 : 2
end
@testset "diagnostics: getfield by a runtime name rejects where WT's layout is not Julia's" begin
    for (f, why) in ((DiagRuntimeName.dt_use, "WT's layout of DataType holds"),
                     (DiagRuntimeName.mod_use, "a Module's getfield reads the global binding"))
        err = try WasmTarget.compile(f, (Int64,)); nothing catch e; e end
        @test err isa WasmTarget.WasmCompileError
        @test occursin(why, sprint(showerror, err))
    end
end
