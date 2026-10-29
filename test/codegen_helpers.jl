# The helpers test/src/code_generator*.jl share (each file includes this into its own module):
# the translator and code generator of a function, the instructions a thunk emits, the rejection a
# call raises, the native runs queued for the third oracle, and the module of one function.
using Test
using WasmTarget

const D = WasmTarget.Dart2Wasm
const W = WasmTarget
const IR = W.WasmBuilder.IR

module CodegenCases
f_add(x::Int32) = x + Int32(1)
f_poly(x::Float64, y::Float64) = x * y - 1.0
f_narrow(x::Int8) = x + Int8(1)
f_twice(x::Int64) = f_add(x % Int32) === Int32(3)
abstract type Shape end
struct Circle <: Shape; r::Float64; end
struct Square <: Shape; s::Float64; end
shapes(n::Int) = n > 0 ? Circle(Float64(n)) : Square(2.0)
loop(n::Int) = (s = 0; for i in 1:n; s += i; end; s)
end

# the translator of the closed world of `f` at `argtypes`, one main module
translator_of(f, argtypes) = D.Translator(WasmTarget.build_nir(W.check_subset(f, argtypes, "code_generator"), "test"),
    D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())

# the code generator of the entry body of `f` at `argtypes`, its wasm signature `ins -> outs`
function codegen_of(f, argtypes, ins, outs)
    local t = translator_of(f, argtypes)
    local mi = only(nb.ci.def for nb in t.component if nb.ci.def.def.name === nameof(f))
    return D.get_inlinable_member_code_generator(t, IR.FunctionType(IR.ValueType[ins...], IR.ValueType[outs...]), mi)
end

# the code generator of `f` ready to emit, as `generate` leaves it before the body: translate()'s
# steps before code, its builder a function of signature `ins -> outs`, its parameters set up
function ready_codegen_of(f, argtypes, ins, outs)
    local B = W.WasmBuilder
    local t = translator_of(f, argtypes)
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    t.constants[] = D.Constants(t)
    local mi = only(nb.ci.def for nb in t.component if nb.ci.def.def.name === nameof(f))
    local mb = D.main_module(t)
    local fb = B.define(mb.functions[], B.define_function(mb.types[], IR.ValueType[ins...], IR.ValueType[outs...]), "f")
    local g = D.get_inlinable_member_code_generator(t, fb.type, mi)
    g.b[] = B.body(fb)
    g.param_locals[] = B.locals(fb)
    g.return_label[] = nothing
    D.setup_parameters_for_normal_entry(g, g.member)
    return g
end

# the instructions `thunk` emits into the builder of `g`, by name
function emitted_by(thunk, g)
    local n0 = length(g.b[]._instructions)
    thunk()
    return String[W.WasmBuilder.name(i) for i in g.b[]._instructions[n0+1:end]]
end

# the rejection `f()` raises, or nothing
rejection(f) = try; f(); nothing; catch e; e isa W.RejectionError ? e : rethrow(); end

isdefined(Main, :WTRunner) || Base.include(Main, joinpath(@__DIR__, "runner.jl"))
const WTRunner = Main.WTRunner

# the modules the file's cases compiled, each with its argument tuples and native Julia's answers,
# queued for one node process at the file's end (test/runner.jl, the third oracle): a node start per
# module would cost more than the cases
const NATIVE_RUNS = WTRunner.RunCase[]
queue_native!(label, bytes, f, argsets) =
    append!(NATIVE_RUNS, [WTRunner.RunCase("$label$a", bytes, a, f(a...)) for a in argsets])

# the instructions `generate` emits for the body of `f` at `argtypes`, compile_one's steps, the
# bodies of the functions it calls not generated
function generated_instructions(f, argtypes)
    local B = W.WasmBuilder
    local t = translator_of(f, argtypes)
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    t.constants[] = D.Constants(t)
    local mb = D.main_module(t)
    local nb = only(nb for nb in t.component if nb.ci.def.def.name === nameof(f))
    local sig = B.define_function(mb.types[], IR.ValueType[D.translate_type(t, T) for T in argtypes], IR.ValueType[D.translate_return_type(t, nb.ci.rettype)])
    local fb = B.define(mb.functions[], sig, "f")
    local b = B.body(fb)
    D.generate(D.get_member_code_generator(t, fb, nb.ci.def), b, B.locals(fb), nothing)
    return String[B.name(i) for i in b._instructions]
end

# the module of one function: translate()'s steps before code, the body generated, `f` exported
function compile_one(f, argtypes)
    local B = W.WasmBuilder
    local t = translator_of(f, argtypes)
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    t.constants[] = D.Constants(t)
    local mb = D.main_module(t)
    local nb = only(t.component)
    local sig = B.define_function(mb.types[], IR.ValueType[D.translate_type(t, T) for T in argtypes], IR.ValueType[D.translate_return_type(t, nb.ci.rettype)])
    local fb = B.define(mb.functions[], sig, "f")
    D.generate(D.get_member_code_generator(t, fb, nb.ci.def), B.body(fb), B.locals(fb), nothing)
    B.var"export"(mb.exports, "f", fb)
    local s = B.Serializer(); B.serialize(s, B.build(mb))
    return B.data(s)
end
