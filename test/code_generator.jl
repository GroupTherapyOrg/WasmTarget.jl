# dart2wasm's code_generator.dart, ported (src/code_generator.jl, dev/MARCH.md 1.C and 1.D): the
# statement dispatch over the NIR, each form reaching its arm.
using Test
using WasmTarget

const DC = WasmTarget.Dart2Wasm

module CodegenCases
abstract type Shape end
struct Circle <: Shape; r::Float64; end
struct Square <: Shape; s::Float64; end
shapes(n::Int) = n > 0 ? Circle(Float64(n)) : Square(2.0)
loop(n::Int) = (s = 0; for i in 1:n; s += i; end; s)
end

# a code generator with no state, standing for the ported ones, so each arm's target is reached
struct ProbeGenerator <: DC.AstCodeGenerator end

_reached(st, used) = try
    DC.translate_statement(ProbeGenerator(), st, used); nothing
catch e
    e isa WasmTarget.RejectionError ? e.rejection : rethrow()
end

@testset "code_generator.dart: translateStatement over the NIR" begin
    local W = WasmTarget
    local bodies = vcat((W.build_nir(W.check_subset(f, at, "code_generator"), "code_generator")
                         for (f, at) in ((CodegenCases.shapes, (Int,)), (CodegenCases.loop, (Int,))))...)
    local stmts = [st for b in bodies for st in b.stmts]
    local forms = Set(W.stmt_form(st) for st in stmts)
    @test "return" in forms && "gotoifnot" in forms && "new" in forms
    for st in stmts
        local r = _reached(st, true)
        if st isa W.NirReturn
            @test r isa W.Unported && occursin("visitReturnStatement", r.anchor)
        elseif st isa W.NirNothing
            @test r isa W.Unported && occursin("visitEmptyStatement", r.anchor)
        elseif st isa Union{W.NirCall, W.NirInvoke, W.NirNew, W.NirGlobalRead}
            # a used value is a local declared with its initializer; an unused one an expression statement
            @test r isa W.Unported && occursin("translateVariableDeclaration", r.anchor)
            local r2 = _reached(st, false)
            @test r2 isa W.Unported && occursin("visitExpressionStatement", r2.anchor)
        elseif st isa Union{W.NirForeignCall, W.NirCFunction}
            @test r isa W.Unquarantined && occursin("1.F", r.row)
        else
            # every Julia-only form rejects in its own arm, naming the stackifier's row
            @test r isa W.Unquarantined && occursin("1.D", r.row)
        end
    end
    # forms no program above holds, built directly
    @test _reached(W.NirGoto(1), false) isa W.Unquarantined
    @test _reached(W.NirUnreachable(), false) isa W.Unquarantined
end
