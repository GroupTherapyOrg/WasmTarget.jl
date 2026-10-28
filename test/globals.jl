# dart2wasm's globals.dart and table_based_globals.dart, ported (src/globals.jl,
# src/table_based_globals.jl): what answers without a module to build into, each expected value
# Julia's own (its bindings, isdefinedglobal and getglobal, and ===).
using Test
using WasmTarget

const D = WasmTarget.Dart2Wasm

module GlobalsCases
const C = (1, "two")
v = 3.5
global u::Int
end

# a collaborator's translator, which these definitions hold and never read
struct GlobalsNodes <: D.KernelNodes end

_rejection(f) = try; f(); nothing; catch x; x isa WasmTarget.RejectionError ? x.rejection : rethrow(); end

@testset "globals.dart" begin
    @test D.dart_field_table_use_cutoff() == 10
    local g = D.DartGlobals(Val(:_), GlobalsNodes())
    # a binding's initializer is the value it holds, Julia's own object (===), or none when unassigned
    local c = D.get_constant_initializer(g, GlobalRef(GlobalsCases, :C))
    @test c isa Core.Const && c.val === GlobalsCases.C
    @test D.get_constant_initializer(g, GlobalRef(GlobalsCases, :v)) === Core.Const(3.5)
    @test D.get_constant_initializer(g, GlobalRef(GlobalsCases, :u)) === nothing
    @test D._member_name(g, GlobalRef(GlobalsCases, :v)) == string(GlobalRef(GlobalsCases, :v))
    @test D._initialize_at_startup(g, GlobalRef(GlobalsCases, :v))
    # the sealed class is constructed only through a subclass
    @test _rejection(() -> D.DartGlobalDefinition()) isa WasmTarget.Internal
end
