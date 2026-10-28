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
    local t = D.Translator(W.check_subset(ClosuresCases.kg, (Int,), "closures"), D.TranslatorOptions())
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
