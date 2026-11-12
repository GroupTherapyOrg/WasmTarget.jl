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
# a program naming each binding, so its closed world reads them all (NirBinding)
reads(x::Int) = (C, R, v, u, io_at_load, loaded, x)
end

# a collaborator's translator, of which these definitions read only the closed world, the one their bindings'
# facts come from (nir_binding)
struct GlobalsNodes <: D.KernelNodes
    component::WasmTarget.NirWorld
end

_rejection(f) = try; f(); nothing; catch x; x isa WasmTarget.RejectionError ? x.rejection : rethrow(); end

@testset "globals.dart" begin
    @test D.dart_field_table_use_cutoff() == 10
    local g = D.DartGlobals(Val(:_), GlobalsNodes(WasmTarget.build_nir(WasmTarget.check_subset(GlobalsCases.reads, (Int,), "globals", Base.get_world_counter()), "test")))
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
same(x::Int) = x
end

@testset "globals.dart: a program's static fields" begin
    # translate()'s steps before the globals: the classes collected, as a binding's type reads them
    # (its translator a local of its own: one named `t` was the testset's `t`, so the second call rebound it)
    local translator_of(f) = (local tr = D.Translator(WasmTarget.build_nir(WasmTarget.check_subset(f, (Int,), "globals", Base.get_world_counter()), "test"),
        D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions());
        D._init_modules(tr, nothing); collect(D.ClassInfoCollector(tr)); tr)
    local t = translator_of(GlobalsProgram.read_counter)
    local g = D.DartGlobals(t)
    # the bindings the closed world reads, each counted once by its wasm type; the functions it
    # calls (round, +) are declarations, never fields; every world also holds the runtime's roots, whose
    # bindings (a `nothing` a root compares with) a program of no binding of its own counts alike
    # (each translator defines its own wasm types, so the counts compare by the types' text)
    local base = Dict(string(k) => v for (k, v) in D.DartGlobals(translator_of(GlobalsProgram.same))._field_type_count)
    local tc = D.translate_type_of_field(t, GlobalRef(GlobalsProgram, :counter))
    local ts = D.translate_type_of_field(t, GlobalRef(GlobalsProgram, :scale))
    local own = Dict(string(k) => v - get(base, string(k), 0) for (k, v) in g._field_type_count if v != get(base, string(k), 0))
    @test tc != ts && own == Dict(string(tc) => 1, string(ts) => 1)
    # a definition reads the main module, which a translator whose modules are not yet built does not
    # have: a located rejection, never a value
    local t0 = D.Translator(WasmTarget.build_nir(WasmTarget.check_subset(GlobalsProgram.read_counter, (Int,), "globals", Base.get_world_counter()), "test"),
        D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    local e = try; D.get_definition_for_static_field(D.DartGlobals(Val(:_), t0), GlobalRef(GlobalsProgram, :counter)); nothing; catch x; x; end
    @test e isa WasmTarget.RejectionError
end

module GlobalsLazy
global counter::Int = 0
bump(x::Int) = counter + x
end

@testset "globals.dart: the lazy arm, its initializer keyed by the binding (dev/formal/StaticFieldInit.tla)" begin
    local t = D.Translator(WasmTarget.build_nir(WasmTarget.check_subset(GlobalsLazy.bump, (Int,), "globals", Base.get_world_counter()), "test"),
        D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    t.constants[] = D.Constants(t)
    local g = D.DartGlobals(t)
    local counter = GlobalRef(GlobalsLazy, :counter)
    local fc = t.functions[]
    # the initializer's key is the field's initializer reference: its type takes nothing and returns
    # the field's value, its name the binding's
    local init_ref = D.FieldReference(counter, D.FieldReferenceKind_initializer)
    local ft = D.get_function_type(fc, init_ref)
    @test isempty(ft.inputs) && ft.outputs == [D.translate_type_of_field(t, counter)]
    @test D.get_function_name(fc, init_ref) == "$counter field initializer"
    @test D.get_existing_function(fc, init_ref) === nothing
    # a non-const binding takes the lazy arm: a mutable global with its initialized flag (an Int64 is
    # no reference, so null cannot signal it), and the initializer function, made and queued
    local def = D.get_definition_for_static_field(g, counter)
    @test def isa D.WasmGlobalDartGlobal && def.initialized_flag !== nothing
    local init = D.get_existing_function(fc, init_ref)
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
    local w = WasmTarget.check_subset(InitTwice.read_seen, (Int,), "test", Base.get_world_counter())
    @test !any(x -> x isa Core.CodeInstance && x.def isa Core.MethodInstance && x.def.def.name === :__init__, w.codeinfos)
    # each binding as the closed world's world holds it, read once (NirBinding): the one the program names from the
    # closed world's own table, any other read at that world
    local nw = WasmTarget.build_nir(w, "test")
    local bound(ref) = WasmTarget.nir_binding!(WasmTarget.NirBindings(nw.world), ref)
    local v = WasmTarget.nir_binding_value(WasmTarget.nir_binding(nw, GlobalRef(InitTwice, :seen)), "test")
    @test v.c.val === InitTwice.seen
    # host state, by the closed world of the runtime's initializers (runtime_init_bindings, Julia's trim
    # over juliac's init list): (a) a binding no const holds that one touches (stdout, Sys.CPU_THREADS),
    # (b) a const object one passes to a call Julia's effects infer may write (DEPOT_PATH): rejected,
    # located, naming the initializer; a const table they only read (base36digits, powers_of_ten), and a
    # const free of mutation, start at their session value, as a juliac image holds them
    @test WasmTarget.runtime_initializers() == Function[Base.__init__, Base.GMP.__init__, Base.MPFR.__init__, Base.Sys.__init__]
    for (ref, init, how) in ((GlobalRef(Base, :stdout), "Base.__init__", "sets or reads"), (GlobalRef(Base, :DEPOT_PATH), "Base.__init__", "mutates"),
                             (GlobalRef(Base.Sys, :CPU_THREADS), "Base.Sys.__init__", "sets or reads"))
        local e = _rejection(() -> WasmTarget.nir_binding_value(bound(ref), "test"))
        @test e isa WasmTarget.Unquarantined && occursin("$init (the runtime's) $how", e.row)
    end
    for (m, n) in ((Base, :base36digits), (Base, :powers_of_ten))
        @test WasmTarget.nir_binding_value(bound(GlobalRef(m, n)), "test").c.val === getglobal(m, n)
    end
    @test WasmTarget.nir_binding_value(bound(GlobalRef(Base.Sys, :WORD_SIZE)), "test").c.val === Sys.WORD_SIZE
    @test WasmTarget.runtime_module(Base.Sys) && WasmTarget.runtime_module(Core.Compiler) && !WasmTarget.runtime_module(InitTwice) && !WasmTarget.runtime_module(Main)
    # (a) a binding no const holds that the closed world never names, set only behind a dynamic call
    # (have_color, which the REPL's start sets): unproved, rejected naming the dynamic calls (A77S1)
    local host = WasmTarget.runtime_init_bindings(nw.world)
    @test !haskey(host.touched, GlobalRef(Base, :have_color)) && !isconst(Base, :have_color)
    @test any(p -> first(p) === Base.__init__ && last(p) > 0, host.dynamic)
    local d = _rejection(() -> WasmTarget.nir_binding_value(bound(GlobalRef(Base, :have_color)), "test"))
    @test d isa WasmTarget.Unquarantined && occursin("dynamic calls whose callees may set it", d.row) && occursin("Base.__init__", d.row)
end

# bindings a program's world sees as they were: `k` redefined, `later` defined, both after the world is taken (a
# global, which Julia 1.12 does not backdate as it backdates a const, PARTITION_KIND_BACKDATED_CONST)
module WorldBound
const k = 1
read_k(x::Int) = k + x
end

@testset "a binding is read once, at its closed world's world, never the reader's (NirBinding)" begin
    local nw = WasmTarget.build_nir(WasmTarget.check_subset(WorldBound.read_k, (Int,), "test", Base.get_world_counter()), "test")
    Core.eval(WorldBound, :(const k = 2)); Core.eval(WorldBound, :(global later = 3))
    @test WorldBound.k == 2 && isdefinedglobal(WorldBound, :later)
    # the binding the program names, from the closed world's table: its value at the world, whoever reads it later
    local k = WasmTarget.nir_binding(nw, GlobalRef(WorldBound, :k))
    @test k.world == nw.world && WasmTarget.nir_binding_is_constant(k) && WasmTarget.nir_binding_value(k, "test").c.val === 1
    # every NirGlobal of the bodies holds that one binding
    @test all(v.binding === k for b in nw for st in b.stmts for v in WasmTarget.nir_operands(st) if v isa WasmTarget.NirGlobal && v.ref == GlobalRef(WorldBound, :k))
    # a binding defined after the world has no value there; one no body names is not in the table, located
    local later = WasmTarget.nir_binding!(WasmTarget.NirBindings(nw.world), GlobalRef(WorldBound, :later))
    local e = _rejection(() -> WasmTarget.nir_binding_value(later, "test"))
    @test !later.defined && e isa WasmTarget.Unquarantined && occursin("has no value", e.row)
    @test _rejection(() -> WasmTarget.nir_binding(nw, GlobalRef(WorldBound, :later))) isa WasmTarget.Internal
end

# planted initializers for the analysis (init_world_bindings): a const object reached through a PhiNode
# or a field read and passed to a call that may write is mutated; one only read is not; a dynamic call
# is counted, and a const object passed to one is mutated
module InitWorldCases
const A = Ref(0)
const B = Ref(0)
const T = (Ref(0), 1)
const D = Ref(0)
const ONLY_READ = Ref(5)
const FLAG = Ref(true)
const SINK = Any[]
@noinline pick() = FLAG[]
phi_init() = ((pick() ? A : B)[] = 1; nothing)
field_init() = (T[1][] = 2; nothing)
read_init() = (ONLY_READ[] + 1; nothing)
dynamic_init() = (push!(SINK[1], D); nothing)
end

@testset "init_world_bindings: a const through a PhiNode, a field read or a dynamic call (A77S1)" begin
    local I = InitWorldCases
    local w = WasmTarget.init_world_bindings(Function[I.phi_init, I.field_init, I.read_init, I.dynamic_init], Base.get_world_counter()).result
    @test haskey(w.mutated, GlobalRef(I, :A)) && haskey(w.mutated, GlobalRef(I, :B))
    @test haskey(w.mutated, GlobalRef(I, :T))
    @test !haskey(w.mutated, GlobalRef(I, :ONLY_READ))
    @test haskey(w.mutated, GlobalRef(I, :D))
    @test Dict(w.dynamic)[I.dynamic_init] >= 1 && Dict(w.dynamic)[I.read_init] == 0
end

# planted initializers for the analysis' reuse (spec v13 R8): one whose closed world infers h(::Int) against
# h(::Integer), and a second
module InitReuseCases
@noinline h(x::Integer) = x + 1
const R = Ref(0)
init() = (R[] = h(1); nothing)
other_init() = (R[] = 2; nothing)
end

@testset "an initializers' analysis is reused while Julia says it holds, and only then (spec v13 R8)" begin
    local I = InitReuseCases
    local w0 = Base.get_world_counter()
    local a = WasmTarget.init_world_bindings(Function[I.init], w0)
    @test !isempty(a.cis) && all(ci -> w0 in Core.Compiler.world_range(ci), a.cis)
    @test !isempty(a.bindings)   # the callees' bindings its effects analysis read, each with its partition
    # a method nothing in the closed world calls (a unit's, on its own type): the analysis holds at the later world
    Core.eval(I, :(struct Fresh end)); Core.eval(I, :(fresh(::Fresh) = 1))
    local w1 = Base.get_world_counter()
    @test w1 > w0 && WasmTarget._analysis_holds(a, w1, Function[I.init])
    # a method more specific than the one init's closed world was inferred against: Julia narrows that
    # CodeInstance's world range, so the analysis does not hold past it, and still holds before it
    Core.eval(I, :(h(x::Int) = x + 2))
    local w2 = Base.get_world_counter()
    @test !WasmTarget._analysis_holds(a, w2, Function[I.init])
    @test WasmTarget._analysis_holds(a, w1, Function[I.init])
    # another initializer list is another analysis
    @test !WasmTarget._analysis_holds(a, w1, Function[I.other_init])
    # a binding an analysis read, bound later (a unit's binding a closed world names): another partition at the later
    # world, so the analysis does not hold there (a's own read bindings are Base's and Core's, which no unit rebinds:
    # the rule is shown on the analysis with one more read binding, unbound when it was read)
    local ref = GlobalRef(I, :later_bound)
    local b = WasmTarget.RuntimeInitAnalysis(a.world, a.inits, a.cis,
        [a.bindings; ref => Base.lookup_binding_partition(w1, ref)], a.result)
    @test WasmTarget._analysis_holds(b, w1, Function[I.init])
    Core.eval(I, :(later_bound(x) = x))
    local w3 = Base.get_world_counter()
    @test Base.lookup_binding_partition(w3, ref) !== Base.lookup_binding_partition(w1, ref)
    @test !WasmTarget._analysis_holds(b, w3, Function[I.init])
    @test WasmTarget._analysis_holds(b, w1, Function[I.init])
    # the partition alone: at w3 the binding's partition read at w1 serves no more (the CodeInstances aside)
    local c = WasmTarget.RuntimeInitAnalysis(w1, Function[], Core.CodeInstance[], [ref => b.bindings[end].second], a.result)
    @test WasmTarget._analysis_holds(c, w1, Function[]) && !WasmTarget._analysis_holds(c, w3, Function[])
end
