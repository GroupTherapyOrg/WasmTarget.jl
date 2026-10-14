# Constant evaluation by RULE (dev/MARCH.md Phase 12 C): the WasmInterpreter folds a call
# when Julia's own effect system says it is foldable (CC.concrete_eval_eligible) and the
# VALUE that comes back is a program value — a Type, Symbol, String, Char, Bool, non-pointer
# Number, singleton, or an isbits aggregate of those — never a host address, never a
# per-process identity (objectid/hash), never through :semi_concrete_eval (which inlines
# the callee's IR with the live pointer arithmetic in it). src/codegen/interpreter.jl.
using Test
using WasmTarget

_fr_string_of_bytes(v::Vector{UInt8}) = String(v)          # Memory{UInt8}.layout is read on this path
_fr_promote(::Type{T}) where {T} = promote_type(T, Float64)   # a pure type-level call
_fr_hash(s::String) = hash(s)                                 # a per-process identity

_stmts(f, ats) = string.(WasmTarget.get_typed_ir(f, ats)[1].code)

@testset "constant evaluation by rule" begin
    # a host address is never a program value: no pointer literal survives in the IR,
    # even where the layout read's null check folds around it
    @test !any(s -> occursin("QuoteNode(Ptr", s), _stmts(_fr_string_of_bytes, (Vector{UInt8},)))
    # a type-level call IS folded (the SciML/cor shape the old enumeration existed for)
    st = _stmts(_fr_promote, (Type{Int64},))
    @test !any(s -> occursin("promote_type", s), st)
    # a per-process identity is never folded to a literal, even with a constant argument
    stc = _stmts(() -> hash("wasm"), ())
    @test any(s -> occursin("hash", s), stc)
    # the value filter itself
    @test WasmTarget._wt_program_value(Int64) && WasmTarget._wt_program_value(:sym) &&
          WasmTarget._wt_program_value("s") && WasmTarget._wt_program_value((1, 2.0)) &&
          WasmTarget._wt_program_value(nothing) && WasmTarget._wt_program_value(1.5f0)
    @test !WasmTarget._wt_program_value(Ptr{Nothing}(UInt(0x1234))) &&
          !WasmTarget._wt_program_value((1, Ptr{Nothing}(UInt(0x1234)))) &&
          !WasmTarget._wt_program_value(Int64[1])
end
