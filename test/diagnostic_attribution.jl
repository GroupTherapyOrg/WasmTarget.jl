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
    # An unsupported construct (a foreigncall WT has no lowering for) inside a helper
    # that inference inlines into its caller.
    @inline helper_uses_ccall(x::Float64) = ccall(:wt_test_no_such_symbol, Float64, (Float64,), x)
    outer(x::Float64) = helper_uses_ccall(x) + 1.0
    # The same construct reached through two inlined levels.
    @inline mid(x::Float64) = helper_uses_ccall(x) * 2.0
    outer2(x::Float64) = mid(x) - 1.0
    # for the internal-tier test: an Int64 add inside an inlined helper
    @inline bug_helper(x::Int64) = x + 1
    bug_outer(x::Int64) = bug_helper(x) * 2
end

_first_diag(f, argtypes) = try
    WasmTarget.compile(f, argtypes)
    nothing
catch e
    e isa WasmTarget.WasmCompileError ? e : rethrow()
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
    finally
        WasmTarget.INTRINSIC_BINOPS[k] = saved
    end
end

@testset "diagnostics: the coercion funnel rejects a numeric pair it has no arm for" begin
    # Julia never converts float→int implicitly; a codegen type-chain defect that asks the
    # funnel for one must reject at the statement, never leave the value unconverted.
    ci, _ = WasmTarget.get_typed_ir(identity, (Float64,))
    ctx = WasmTarget.CompilationContext(ci, (Float64,), Float64, WasmTarget.WasmModule(), WasmTarget.TypeRegistry())
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
        ctx = WasmTarget.CompilationContext(ci, (Float64,), Float64, WasmTarget.WasmModule(), WasmTarget.TypeRegistry())
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
