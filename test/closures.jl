# dart2wasm's closures.dart, ported (src/closures.jl): the representations' name combinations and
# clusters, each answer dart's on fixed inputs, Julia's keyword arguments the named parameters.
using Test
using WasmTarget

const D = WasmTarget.Dart2Wasm
const IR = WasmTarget.WasmBuilder.IR

module ClosuresCases
kf(x; a = 1, b = 2) = x + a + b
kg(x; c = 1) = x + c
kh(x; b = 1, d = 2) = x + b + d
mk(a::Int) = (b -> a + b)
function mbox(n::Int)
    x::Int = n
    f = () -> (x += 1)
    return f
end
end

@testset "closures.dart: NameCombination" begin
    local W = WasmTarget
    local N = D.NameCombination
    @test sprint(show, N(["a", "b"])) == "[a, b]" && sprint(show, N(String[])) == "[]"
    # compareTo: name by name, then the shorter first
    @test D.compare_to(N(["a"]), N(["b"])) < 0 && D.compare_to(N(["b"]), N(["a"])) > 0
    @test D.compare_to(N(["a"]), N(["a", "b"])) < 0 && D.compare_to(N(["a", "b"]), N(["a", "b"])) == 0
    # dart asserts the names are sorted: a located rejection
    local e = try; N(["b", "a"]); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Internal
end

@testset "closures.dart: the clusters of named parameters" begin
    local W = WasmTarget
    local r = D.ClosureRepresentationsForParameterCount()
    # each method's keyword arguments are one union: kf's a and b, kh's b and d, kg's c alone
    for f in (ClosuresCases.kf, ClosuresCases.kg, ClosuresCases.kh)
        D.register_function(r, only(methods(f)))
    end
    @test first.(r.name_ids) == ["a", "b", "c", "d"]
    # the calls' keyword names, a NamedTuple's names: each combination once, in compareTo order
    for names in ((:b, :a), (:a,), (:c,), (:a, :c), (:a, :b), ())
        D.register_call(r, names)
    end
    @test [c.names for c in r.call_combinations] == [["a"], ["a", "b"], ["a", "c"], ["c"]]
    local other = D.ClosureRepresentationsForParameterCount()
    D.register_call(other, (:d,))
    D.inherit_combinations_from(r, other)
    @test [c.names for c in r.call_combinations] == [["a"], ["a", "b"], ["a", "c"], ["c"], ["d"]]
    D.compute_clusters(r)
    local abd = r.cluster_for_name["a"]
    @test abd.names == ["a", "b", "d"] && r.cluster_for_name["d"] === abd && r.cluster_for_name["c"].names == ["c"]
    # a combination within one cluster gets its index there; one across clusters none
    @test [(c.names, i) for (c, i) in abd.index_of_combination] == [(["a"], 0), (["a", "b"], 1), (["d"], 2)]
    @test [(c.names, i) for (c, i) in r.cluster_for_name["c"].index_of_combination] == [(["c"], 0)]
    @test D.cluster_for_names(r, ["a", "c"]) === nothing && D.cluster_for_names(r, ["b", "d"]) === abd

    # the representation's vtable index of a call: positional entries first, then one per combination
    local vt = IR.StructType("vtable"); local cl = IR.StructType("closure")
    local t = D.Translator(W.check_subset(ClosuresCases.kg, (Int,), "closures"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    local rep = D.ClosureRepresentation(t, 2, 0, 3, vt, cl, abd.index_of_combination, nothing)
    @test D.has_named(rep) && !D.is_generic(rep)
    @test D.field_index_for_signature(rep, 1, String[]) == 3
    @test D.field_index_for_signature(rep, 1, ["a", "b"]) == 2 + 2 + 1
    @test [c.names for c in D.name_combinations(rep)] == [["a"], ["a", "b"], ["d"]]
    local e = try; D.field_index_for_signature(rep, 1, ["c"]); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Internal
    local plain = D.ClosureRepresentation(t, 1, 0, 2, vt, cl, nothing, nothing)
    @test !D.has_named(plain) && isempty(D.name_combinations(plain))
    # a vtable entry is a reference to a function type; another field type rejects, located
    local ft = IR.FunctionType(IR.ValueType[], IR.ValueType[])
    local v2 = IR.StructType("vtable2"; fields = [IR.FieldType(IR.RefType_def(ft; nullable = false); mutable = false), IR.FieldType(IR.NumType_i32; mutable = false)])
    @test D.get_vtable_entry_at(v2, 0) === ft
    local e3 = try; D.get_vtable_entry_at(v2, 1); nothing; catch x; x; end
    @test e3 isa W.RejectionError && e3.rejection isa W.Internal
end

@testset "closures.dart: a member's closures, Julia's lowering the answer" begin
    local W = WasmTarget
    local t = D.Translator(W.check_subset(ClosuresCases.mk, (Int,), "closures"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    local mi = t.component[1].ci.def
    # Julia's lowering made the closure a type of its own, its fields the captures: the member's NIR
    # allocates it and holds no nested function, so no lambda, capture or context is left to find
    local c = D.Closures(t, mi; find_captures = true)
    @test isempty(c.lambdas) && isempty(c.captures) && isempty(c.contexts) && isempty(c.closurized_functions)
    @test !c._is_this_captured && c._nullable_this_type === nothing
    @test any(st -> st isa W.NirNew, t.component[1].stmts)
    local closure_type = typeof(ClosuresCases.mk(1))
    @test closure_type <: Function && fieldnames(closure_type) == (:a,) && fieldtypes(closure_type) == (Int,)
    # a captured variable that is assigned is a Core.Box, Julia's written capture
    local tb = D.Translator(W.check_subset(ClosuresCases.mbox, (Int,), "closures"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    local b1 = tb.component[1]
    @test any(k -> b1.stmts[k] isa W.NirNew && b1.types[k] === Core.Box, eachindex(b1.stmts))
    @test fieldtypes(typeof(ClosuresCases.mbox(1))) == (Core.Box,)
    @test isempty(D.Closures(tb, tb.component[1].ci.def; find_captures = true).captures)

    # a context: empty without variables, type parameters or `this`; its parent first, then `this`
    local ctx = D.Context(mi, nothing, false)
    @test D.is_empty(ctx)
    for f in (D.parent_field_index, D.this_field_index)
        local e = try; f(ctx); nothing; catch x; x; end
        @test e isa W.RejectionError && e.rejection isa W.Internal
    end
    local with_this = D.Context(mi, nothing, true)
    @test !D.is_empty(with_this) && D.this_field_index(with_this) == 0
    local child = D.Context(mi, with_this, true)
    @test D.parent_field_index(child) == 0 && D.this_field_index(child) == 1
    local cap = D.Capture(W.ClassField(closure_type, 1, "a", Int, false), false)
    @test !cap.written && !cap.is_in_initializer
    local lam = D.Lambda__(only(methods(ClosuresCases.mk(1))), :closures, mi, c, 0)
    @test lam.enclosing_member_closures === c && lam.index == 0
end

@testset "closures.dart: ClosureLayouter's counts, no closure called through a vtable" begin
    local W = WasmTarget
    local t = D.Translator(W.check_subset(ClosuresCases.mk, (Int,), "closures"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    local l = D.ClosureLayouter(t)
    # Julia's verifier admits no unresolved call: the walk registers nothing
    collect(l)
    @test D.max_type_argument_count(l) == 0 && !l.uses_function_apply_with_named_arguments[]
    # a method's signature: its positional arguments after the function object, its keyword names
    D._visit_function_node(l, only(methods(ClosuresCases.kf)))
    D._visit_function_node(l, only(methods(ClosuresCases.kh)))
    @test D.max_type_argument_count(l) == 1 && D.max_positional_count_for(l, 0) == 2
    local seen = Int[]
    D.for_each_positional_argument_count(l, 0, n -> push!(seen, n))
    @test seen == [0, 1]
    D.register_call(D._representations_for_counts(l, 0, 1), (:a, :d))
    D.compute_clusters(l)
    local r = D._representations_for_counts(l, 0, 1)
    @test r.cluster_for_name["a"] === r.cluster_for_name["d"] && r.cluster_for_name["a"].names == ["a", "b", "d"]
    # building a representation reaches the unported vtable layout, a located rejection
    local e = try; D.get_closure_representation(l, 0, 1, String[]); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Unported
    # Julia has no function types and no generic instantiation: those paths reject as Internal
    local e2 = try; l.function_type_type[]; nothing; catch x; x; end
    @test e2 isa W.RejectionError && e2.rejection isa W.Internal
end
