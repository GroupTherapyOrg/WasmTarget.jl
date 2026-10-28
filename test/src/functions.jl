# functions.dart (src/functions.jl): the shapes of dynamic calls. A shape's kind says whether it calls a
# getter, a setter or a method; a method shape matches a Julia method by its positional arity (a
# trailing vararg takes any number), and passes no type arguments or named ones, which a Julia
# method's body never declares; shapes compare and hash by their fields, as dart's do.

module FunctionsTest

using Test
using WasmTarget

const WT = WasmTarget
const W = WasmTarget.Dart2Wasm

module Targets
two(a::Int, b::Int) = a + b
rest(a::Int, xs::Int...) = a + length(xs)   # sum over a tuple of any length is a dynamic kwcall to the verifier
end

nir_body(f, at) = only(b for b in WT.build_nir(WT.check_subset(f, at, "functions"), "functions") if b.ci.def.def.name === nameof(f))

@testset "CallShape" begin
    local m = W.MethodCallShape(:two, 0, 2, Symbol[])
    local g = W.GetterCallShape(:x)
    local s = W.SetterCallShape(:x)
    @test (W.is_method(m), W.is_getter(m), W.is_setter(m)) == (true, false, false)
    @test (W.is_method(g), W.is_getter(g), W.is_setter(g)) == (false, true, false)
    @test (W.is_method(s), W.is_getter(s), W.is_setter(s)) == (false, false, true)
    @test W.total_argument_count(W.MethodCallShape(:f, 1, 2, [:a, :b])) == 5
    @test W.is_index_set(W.MethodCallShape(:setindex!, 0, 3, Symbol[])) && !W.is_index_set(m)

    @test m == W.MethodCallShape(:two, 0, 2, Symbol[]) && hash(m) == hash(W.MethodCallShape(:two, 0, 2, Symbol[]))
    @test m != W.MethodCallShape(:two, 0, 3, Symbol[]) && m != W.copy_with_name(m, :three)
    @test W.copy_with_name(m, :three) == W.MethodCallShape(:three, 0, 2, Symbol[])
    @test g == W.GetterCallShape(:x) && g != s && hash(g) != hash(s)      # a getter and a setter of one name differ
    @test length(Set{W.CallShape}([m, W.MethodCallShape(:two, 0, 2, Symbol[]), g, s])) == 3

    @test sprint(show, W.MethodCallShape(:f, 1, 2, [:a, :b])) == "MethodCallShape(f types:1 pos:2 names:a-b)"
    @test sprint(show, W.MethodCallShape(:f, 0, 0, Symbol[])) == "MethodCallShape(f)"
    @test sprint(show, g) == "GetterCallShape(x)" && sprint(show, s) == "SetterCallShape(x)"

    @test_throws WT.RejectionError W.CallShape(:f)                         # the sealed class itself

    local two = nir_body(Targets.two, (Int, Int))
    @test W.matches_target(W.MethodCallShape(:two, 0, 2, Symbol[]), two)
    @test !W.matches_target(W.MethodCallShape(:two, 0, 1, Symbol[]), two)   # too few
    @test !W.matches_target(W.MethodCallShape(:two, 0, 3, Symbol[]), two)   # too many
    @test !W.matches_target(W.MethodCallShape(:two, 1, 2, Symbol[]), two)   # a type argument
    @test !W.matches_target(W.MethodCallShape(:two, 0, 2, [:k]), two)       # a named argument
    local rest = nir_body(Targets.rest, (Int, Int, Int))
    @test W.matches_target(W.MethodCallShape(:rest, 0, 1, Symbol[]), rest)  # the vararg takes none
    @test W.matches_target(W.MethodCallShape(:rest, 0, 4, Symbol[]), rest)  # or any number
    @test !W.matches_target(W.MethodCallShape(:rest, 0, 0, Symbol[]), rest)
end

module Members
f(x::Int) = x + 1
end

@testset "FunctionCollector: names, selector uses, translated procedures" begin
    local data = W.build_module_output_data(W.DefaultModuleStrategy(W.WasmCompilerOptions_default_options()))
    local t = W.Translator(WT.check_subset(Members.f, (Int,), "functions"), data, W.TranslatorOptions())
    W._init_modules(t, nothing)
    collect(W.ClassInfoCollector(t))
    local fc = t.functions[]
    local mi = only(b.ci.def for b in t.component if b.ci.def.def.name === :f)
    local shape = W.MethodCallShape(:f, 0, 1, Symbol[])
    @test W.get_dynamic_forwarder_name(fc, mi, shape) == W.get_function_name(fc, mi) * " (MethodCallShape(f pos:1))"
    @test W.get_invocation_creator_stub_name(fc, shape) == "Invocation creator (MethodCallShape(f pos:1))"
    @test !W.has_dynamic_selector_call(fc, shape)
    push!(fc._called_dynamic_selectors, shape)
    @test W.has_dynamic_selector_call(fc, shape)
    @test isempty(W.translated_procedures(fc))
    # a selector whose targets cover class ids 3..4 for `mi`: neither class is allocated, so the
    # member waits for each; the class's allocation then makes its function, once
    local s = W.SelectorInfo__(t.dispatch_table[], 0, "f", 1; is_setter = false, is_index_setter = false)
    s.use_multiple_entry_points[] = false
    s._normal = W.SelectorTargets([(range = W.Range(3, 4), target = mi)], [(range = W.Range(3, 4), target = mi)], NamedTuple{(:range, :target),Tuple{W.Range,Core.MethodInstance}}[])
    W.record_selector_use(fc, s, false)
    @test 0 in fc._called_selectors && fc._pending_allocation[3] == [mi] && fc._pending_allocation[4] == [mi]
    @test W.get_existing_function(fc, mi) === nothing
    W.record_selector_use(fc, s, false)                     # a selector already used: nothing again
    @test fc._pending_allocation[3] == [mi]
    W.record_class_allocation(fc, 3)
    @test W.get_existing_function(fc, mi) !== nothing && W.translated_procedures(fc) == [mi]

    # a dynamic call's signature by its shape: the top type throughout, the receiver nullable for a
    # dispatcher, no result for a setter or an index set
    local top = t.top_type[]
    local nn = W.WasmBuilder.with_nullability(top, false)
    local g = W.make_dynamic_dispatcher_signature(t, W.GetterCallShape(:x))
    @test g.inputs == [top] && g.outputs == [top]
    @test W.make_dynamic_forwarder_signature(t, W.GetterCallShape(:x)).inputs == [nn]
    local st = W.make_dynamic_forwarder_signature(t, W.SetterCallShape(:x))
    @test st.inputs == [nn, top] && isempty(st.outputs)
    local mt = W.make_dynamic_dispatcher_signature(t, W.MethodCallShape(:f, 0, 2, [:k]))
    @test mt.inputs == [top, top, top, top] && mt.outputs == [top]
    # a type argument is a Type, which this program's classes lack: a located rejection
    @test_throws WT.RejectionError W.make_dynamic_dispatcher_signature(t, W.MethodCallShape(:f, 1, 0, Symbol[]))
    @test isempty(W.make_dynamic_dispatcher_signature(t, W.MethodCallShape(:setindex!, 0, 2, Symbol[])).outputs)
    @test W.make_dynamic_dispatcher_signature(t, W.GetterCallShape(:y)) === g     # one type per signature

    # a dynamic selector's targets wait for their classes; an allocated class makes the forwarder,
    # whose code generator (code_generator.dart's, unported) is reached and rejects, located
    local dshape = W.GetterCallShape(:f)                   # a shape no call has used yet
    local ds = W.DynamicSelector(Val(:_), dshape, W.make_dynamic_forwarder_signature(t, dshape))
    ds.targets[] = W.LinkedHashMap{Int,Core.MethodInstance}()
    ds.targets[][7] = mi
    W.record_dynamic_selector_use(fc, ds)
    @test fc._pending_allocation_dynamic[7] == [(dshape, mi)] && W.get_existing_dynamic_forwarder(fc, mi, dshape) === nothing
    W.record_dynamic_selector_use(fc, ds)                   # the shape already called: nothing again
    @test length(fc._pending_allocation_dynamic[7]) == 1
    local e = try; W.record_class_allocation(fc, 7); nothing; catch x; x; end
    @test e isa WT.RejectionError && e.rejection isa WT.Unported && occursin("DynamicForwarderCodeGenerator", e.rejection.anchor)

    # an Invocation is noSuchMethod's, which Julia lacks: the invocation creator's path rejects
    local e2 = try; W.get_invocation_creator_stub(fc, shape); nothing; catch x; x; end
    @test e2 isa WT.RejectionError && e2.rejection isa WT.Unquarantined && occursin("noSuchMethod", e2.rejection.row)
end

module Callables
struct Adder
    k::Int
end
@noinline (a::Adder)(x::Int32) = a.k + Int(x)
use(k::Int, x::Int32) = Adder(k)(x)
end

@testset "makeFunctionTypeForBody and typeOfCheckedParameterVariable" begin
    local data = W.build_module_output_data(W.DefaultModuleStrategy(W.WasmCompilerOptions_default_options()))
    local t = W.Translator(WT.check_subset(Callables.use, (Int, Int32), "functions"), data, W.TranslatorOptions())
    W._init_modules(t, nothing)
    collect(W.ClassInfoCollector(t))
    local call = only(b.ci.def for b in t.component if b.ci.def.specTypes <: Tuple{Callables.Adder,Vararg})
    local use = only(b.ci.def for b in t.component if b.ci.def.def.name === :use)
    # a parameter's checked type is the specialization's, counting the callee as 1
    @test W.type_of_checked_parameter_variable(t, call, 2) === Int32
    @test_throws WT.RejectionError W.type_of_checked_parameter_variable(t, call, 3)
    # the body's signature: the receiver (the callable's value), then the parameters, then the return
    local ft = W.make_function_type_for_body(t, call, false, false)
    @test ft.inputs == [W.translate_type(t, Callables.Adder), W.translate_type(t, Int32)] && ft.outputs == [W.translate_return_type(t, Int)]
    @test isempty(W.make_function_type_for_body(t, call, true, false).outputs)
    # a member whose callee is a singleton function has no receiver: dart's assert, located
    @test_throws WT.RejectionError W.make_function_type_for_body(t, use, false, false)
end

module Lambdas
@noinline apply(f, x::Int) = f(x)
function use(k::Int, x::Int)
    @noinline inner(y) = y * k
    return apply(inner, x) + apply(@noinline(y -> y + k), x)
end
end

@testset "a closure's function type and name; a tear-off's type" begin
    local data = W.build_module_output_data(W.DefaultModuleStrategy(W.WasmCompilerOptions_default_options()))
    local t = W.Translator(WT.check_subset(Lambdas.use, (Int, Int), "functions"), data, W.TranslatorOptions())
    W._init_modules(t, nothing)
    collect(W.ClassInfoCollector(t))
    local fc = t.functions[]
    local use = only(b.ci.def for b in t.component if b.ci.def.def.name === :use)
    local c = W.Closures(t, use; find_captures = true)
    local bodies = [b for b in t.component if (Base.unwrap_unionall(b.ci.def.specTypes).parameters[1]) <: Function && !Base.issingletontype(Base.unwrap_unionall(b.ci.def.specTypes).parameters[1])]
    local named = only(b for b in bodies if occursin("inner", string(nameof(Base.unwrap_unionall(b.ci.def.specTypes).parameters[1]))))
    local anon = only(b for b in bodies if b !== named)
    local lam = W.Lambda__(named, :functions, use, c, 0)
    local ft = W.get_lambda_function_type(fc, lam)
    @test ft.inputs == [W.closure_context_field_type(), W.translate_type(t, Int)] && ft.outputs == [W.translate_type(t, Int)]
    local where_ = string(named.ci.def.def.file, ":", named.ci.def.def.line)
    @test W.get_lambda_function_name(fc, lam) == W.get_function_name(fc, use) * " closure inner at " * where_
    @test W.get_lambda_function_name(fc, W.Lambda__(anon, :functions, use, c, 1)) == W.get_function_name(fc, use) * " closure at " * string(anon.ci.def.def.file, ":", anon.ci.def.def.line)
    # a tear-off returns the closure's value, the type of its callee
    local callee = Base.unwrap_unionall(named.ci.def.specTypes).parameters[1]
    local tt = W.make_tear_off_function_type(t, named, nothing)
    @test isempty(tt.inputs) && tt.outputs == [W.translate_type(t, callee)]
    @test W.make_tear_off_function_type(t, named, t.top_type[]).inputs == [t.top_type[]]
end

end # module FunctionsTest
