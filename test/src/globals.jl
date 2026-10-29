# dart2wasm's globals.dart and table_based_globals.dart, ported (src/globals.jl,
# src/table_based_globals.jl): what answers without a module to build into, each expected value
# Julia's own (its bindings, isdefinedglobal and getglobal, and ===).
using Test
using WasmTarget

const D = WasmTarget.Dart2Wasm

module GlobalsCases
const C = (1, "two")
const R = Ref(1)        # const, but its object mutable: a load may change it
v = 3.5
global u::Int
# a global __init__ sets, as Base sets stdout: run again at load, never a build-time constant
global io_at_load::Int = 0
const loaded = Ref(0)
function __init__()
    global io_at_load = 7
    loaded[] = 1
end
end

# a collaborator's translator, which these definitions hold and never read
struct GlobalsNodes <: D.KernelNodes end

_rejection(f) = try; f(); nothing; catch x; x isa WasmTarget.RejectionError ? x.rejection : rethrow(); end

@testset "globals.dart" begin
    @test D.dart_field_table_use_cutoff() == 10
    local g = D.DartGlobals(Val(:_), GlobalsNodes())
    # a binding's initializer is its value only for a const binding holding a mutation-free value,
    # which no load can change; Julia's own object (===)
    local c = D.get_constant_initializer(g, GlobalRef(GlobalsCases, :C))
    @test c isa WasmTarget.NirConst && c.c.val === GlobalsCases.C
    # every other binding takes the lazy path: non-const, unassigned, const holding a mutable
    # object, and the ones __init__ writes (whose session values here are the post-__init__ ones)
    @test GlobalsCases.io_at_load == 7 && GlobalsCases.loaded[] == 1
    for n in (:v, :u, :R, :io_at_load, :loaded)
        @test D.get_constant_initializer(g, GlobalRef(GlobalsCases, n)) === nothing
    end
    @test D._member_name(g, GlobalRef(GlobalsCases, :v)) == string(GlobalRef(GlobalsCases, :v))
    # no pragma answers false (dart's `getPragma(..., defaultValue: true) ?? false`)
    @test !D._initialize_at_startup(g, GlobalRef(GlobalsCases, :v))
    # the sealed class is constructed only through a subclass
    @test _rejection(() -> D.DartGlobalDefinition()) isa WasmTarget.Internal
end

module GlobalsProgram
global counter::Int = 0
global scale::Float64 = 2.0
read_counter(x::Int) = counter + x + round(Int, scale)
end

@testset "globals.dart: a program's static fields" begin
    local t = D.Translator(WasmTarget.build_nir(WasmTarget.check_subset(GlobalsProgram.read_counter, (Int,), "globals"), "test"),
        D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    local g = D.DartGlobals(t)
    # the bindings the closed world reads, each counted once by its wasm type; the functions it
    # calls (round, +) are declarations, never fields
    local tc = D.translate_type_of_field(t, GlobalRef(GlobalsProgram, :counter))
    local ts = D.translate_type_of_field(t, GlobalRef(GlobalsProgram, :scale))
    @test tc != ts && g._field_type_count[tc] == 1 && g._field_type_count[ts] == 1 && sum(values(g._field_type_count)) == 2
    # a definition reads the main module, which this translator, its modules not yet built, does
    # not have: a located rejection, never a value
    local e = try; D.get_definition_for_static_field(g, GlobalRef(GlobalsProgram, :counter)); nothing; catch x; x; end
    @test e isa WasmTarget.RejectionError
end
