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
# a global __init__ sets, as Base sets stdout: set once in this session, at the module's definition
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

module GlobalsLazy
global counter::Int = 0
bump(x::Int) = counter + x
end

@testset "globals.dart: the lazy arm, its initializer keyed by the binding (dev/formal/StaticFieldInit.tla)" begin
    local t = D.Translator(WasmTarget.build_nir(WasmTarget.check_subset(GlobalsLazy.bump, (Int,), "globals"), "test"),
        D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    t.constants[] = D.Constants(t)
    local g = D.DartGlobals(t)
    local counter = GlobalRef(GlobalsLazy, :counter)
    local fc = t.functions[]
    # the initializer's key is the binding: its type takes nothing and returns the field's value,
    # its name the binding's
    local ft = D.get_function_type(fc, counter)
    @test isempty(ft.inputs) && ft.outputs == [D.translate_type_of_field(t, counter)]
    @test D.get_function_name(fc, counter) == "$counter field initializer"
    @test D.get_existing_function(fc, counter) === nothing
    # a non-const binding takes the lazy arm: a mutable global with its initialized flag (an Int64 is
    # no reference, so null cannot signal it), and the initializer function, made and queued
    local def = D.get_definition_for_static_field(g, counter)
    @test def isa D.WasmGlobalDartGlobal && def.initialized_flag !== nothing
    local init = D.get_existing_function(fc, counter)
    @test init !== nothing && init.type == ft && init.function_name == "$counter field initializer"
    @test D.translated_procedures(fc) isa Vector{Core.MethodInstance}
end

# a module whose __init__ is not idempotent: this session ran it once, at the module's definition
module InitTwice
const seen = Ref(0)
__init__() = (seen[] += 1; nothing)
read_seen(x::Int) = seen[] + x
end

@testset "a binding starts at its session value, past every __init__ (dev/MODULE_INIT.md)" begin
    # the session ran InitTwice.__init__ once: its value is juliac's after startup, and no __init__ is
    # compiled, which would run it a second time
    @test InitTwice.seen[] == 1 && InitTwice.read_seen(1) == 2
    local v = WasmTarget.nir_binding_value(GlobalRef(InitTwice, :seen), "test")
    @test v.c.val === InitTwice.seen
    local w = WasmTarget.check_subset(InitTwice.read_seen, (Int,), "test")
    @test !any(x -> x isa Core.CodeInstance && x.def isa Core.MethodInstance && x.def.def.name === :__init__, w.codeinfos)
    # a binding of the runtime that is not const, or holds a mutable value, is host state Base.__init__
    # set: rejected, located, naming it; a const value free of mutation is Julia's own
    for ref in (GlobalRef(Base, :stdout), GlobalRef(Base, :DEPOT_PATH), GlobalRef(Base.Sys, :CPU_THREADS))
        local e = _rejection(() -> WasmTarget.nir_binding_value(ref, "test"))
        @test e isa WasmTarget.Unquarantined && occursin("Base.__init__ (the runtime's)", e.row)
    end
    @test WasmTarget.nir_binding_value(GlobalRef(Base.Sys, :WORD_SIZE), "test").c.val === Sys.WORD_SIZE
    @test WasmTarget.runtime_module(Base.Sys) && WasmTarget.runtime_module(Core.Compiler) && !WasmTarget.runtime_module(InitTwice) && !WasmTarget.runtime_module(Main)
end
