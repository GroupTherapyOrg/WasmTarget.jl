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

@testset "diagnostics: the 5-field constructor still builds a located-less report" begin
    d = WasmTarget.WasmDiagnostic(:unsupported_type, "f", "x", nothing, nothing)
    @test d.stmt_idx == 0 && isempty(d.frames) && d.stmt == ""
    @test sprint(show, d) == "[unsupported_type] in `f`: x"
end
