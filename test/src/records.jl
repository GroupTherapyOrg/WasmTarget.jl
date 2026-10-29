# dart2wasm's records.dart, ported (src/records.jl, dev/MARCH.md 1.C): RecordShape on fixed inputs.
using Test
using WasmTarget

const DR = WasmTarget.Dart2Wasm

@testset "records.dart: RecordShape" begin
    local s = DR.RecordShape(2, ["b", "a"])
    # names sorted, each indexed after the positionals in the order given
    @test names(s) == ["a", "b"] && DR.num_fields(s) == 4
    @test DR.get_name_index(s, "b") == DR.FieldIndex_record_field_base() + 2
    @test DR.get_name_index(s, "a") == DR.FieldIndex_record_field_base() + 3
    @test DR.get_positional_index(s, 1) == DR.FieldIndex_record_field_base() + 1
    @test sprint(show, s) == "Record(positionals: 2, names: {a: 3, b: 2})"
    # equal by positionals and names with their indices, hashed alike; another order of the names is
    # another shape, its fields at other indices, as Julia's NamedTuple orders are other types
    @test s == DR.RecordShape(2, ["b", "a"]) && hash(s) == hash(DR.RecordShape(2, ["b", "a"]))
    @test s != DR.RecordShape(2, ["a", "b"])
    local ba = DR.RecordShape_from_type(typeof((b = 1, a = 2))); local ab = DR.RecordShape_from_type(typeof((a = 2, b = 1)))
    @test ba != ab && DR.get_name_index(ba, "a") != DR.get_name_index(ab, "a")
    @test typeof((b = 1, a = 2)) != typeof((a = 2, b = 1))
    @test s != DR.RecordShape(1, ["a", "b"]) && s != DR.RecordShape(2, ["a"]) && s != DR.RecordShape(2, ["a", "c"])
    @test s != 2
    @test DR.num_fields(DR.RecordShape(3, String[])) == 3 && isempty(names(DR.RecordShape(3, String[])))
    local e = try; DR.get_name_index(s, "z"); nothing; catch x; x; end
    @test e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.Internal && occursin("name z not in record", e.rejection.site)
end

@testset "records.dart: a tuple type's shape, record_class_generator.dart" begin
    local W = WasmTarget
    local D = W.Dart2Wasm
    # a Tuple's fields are positional, a NamedTuple's named; a name's index is its field's place
    @test D.RecordShape_from_type(Tuple{Int,Float64}) == D.RecordShape(2, String[])
    @test D.RecordShape_from_type(Tuple{}) == D.RecordShape(0, String[])
    local NT = NamedTuple{(:b, :a), Tuple{Int,Float64}}
    local s = D.RecordShape_from_type(NT)
    @test names(s) == ["a", "b"] && D.num_fields(s) == fieldcount(NT)
    for n in (:a, :b)
        @test D.get_name_index(s, string(n)) - D.FieldIndex_record_field_base() == Base.fieldindex(NT, n) - 1
    end
    # a tuple type of open length or names has no shape
    for T in (Tuple{Vararg{Int}}, NamedTuple{(:a,)}, Vector{Int})
        local e = try; D.RecordShape_from_type(T); nothing; catch x; x; end
        @test e isa W.RejectionError && e.rejection isa W.Unquarantined
    end
    # a Julia tuple type is a class of its own, Base's: no class is generated per shape
    local t = D.Translator(WasmTarget.build_nir(W.check_subset(x -> (x, x + 1), (Int,), "records"), "test"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    @test isempty(D.generate_record_classes(t.component))
    local g = D._RecordClassGenerator(Dict{D.RecordShape,DataType}())
    @test D.nullable_object_type(g) === Any && D.non_nullable_string_type(g) === String
    @test D.bool_type(g) === Bool && D.int_type(g) === Int64
    local e = try; D.visit_record_type(D._RecordVisitor(g), Tuple{Int,Int}); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Internal
end

@testset "record_class_generator.dart: a shape's field names, a constant" begin
    local D = WasmTarget.Dart2Wasm
    local g = D._RecordClassGenerator(Dict{D.RecordShape,DataType}())
    @test D._field_names_constant(g, D.RecordShape(1, ["b", "a"])).c.val == ("a", "b")
    @test D.default_constant_reference(D._RecordVisitor(g), WasmTarget.NirConst(Core.Const((1, 2)))) === nothing
end

module RecordCodegenCases
mk(x::Int64, y::Float64) = (x, y)
sa(nt::NamedTuple{(:b, :a), Tuple{Int64, Int64}}) = nt.a - nt.b
fst(t::Tuple{Int64, Float64}) = t[1] * Int64(2)
end

# the module of one body, `f` at `argtypes`, built as the code generator builds a member
function records_compile_one(f, argtypes)
    local W = WasmTarget; local D = W.Dart2Wasm; local B = W.WasmBuilder; local IR = B.IR
    local t = D.Translator(WasmTarget.build_nir(W.check_subset(f, argtypes, "records"), "test"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
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
    return t, B.data(s)
end

@testset "code_generator.dart: a tuple's literal and its fields, Julia's tuple layout" begin
    local W = WasmTarget; local D = W.Dart2Wasm; local IR = W.WasmBuilder.IR
    # tuple(x, y) allocates its own class, Tuple{Int64, Float64}, each field Julia's own type, and the
    # builder accepts the module instruction by instruction
    local t, bytes = records_compile_one(RecordCodegenCases.mk, (Int64, Float64))
    @test bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
    local info = t.class_info[Tuple{Int64, Float64}]
    local fs = info.struct_.fields
    @test fs[D.get_positional_index(D.RecordShape_from_type(Tuple{Int64, Float64}), 0) + 1].type == IR.NumType_i64
    @test fs[D.get_positional_index(D.RecordShape_from_type(Tuple{Int64, Float64}), 1) + 1].type == IR.NumType_f64
    @test typeof(RecordCodegenCases.mk(1, 2.0)) === Tuple{Int64, Float64}
    # a NamedTuple's field by name reads the field at the name's place in Julia's declared order
    local t2, bytes2 = records_compile_one(RecordCodegenCases.sa, (NamedTuple{(:b, :a), Tuple{Int64, Int64}},))
    @test bytes2[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
    @test RecordCodegenCases.sa((b = 2, a = 7)) == 5
    # a tuple's field by position: Julia's IR reads it behind its bounds-check flag, a statement the
    # code generator does not translate yet, a located rejection there
    local e = try; records_compile_one(RecordCodegenCases.fst, (Tuple{Int64, Float64},)); nothing; catch x; x; end
    @test e isa W.RejectionError && occursin("bounds-check", sprint(show, e.rejection))
    # the visit itself: the shape's positional index agrees with the class layout, then the receiver
    # is read and its field
    local t3 = D.Translator(WasmTarget.build_nir(W.check_subset(RecordCodegenCases.fst, (Tuple{Int64, Float64},), "records"), "test"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    D._init_modules(t3, nothing)
    collect(D.ClassInfoCollector(t3))
    local nb = only(t3.component)
    local g = D.get_inlinable_member_code_generator(t3, IR.FunctionType(IR.ValueType[D.translate_type(t3, Tuple{Int64, Float64})], IR.ValueType[IR.NumType_i64]), nb.ci.def)
    local get1 = nb.stmts[findfirst(st -> st isa W.NirCall && W.nir_callee(st) === Core.getfield, nb.stmts)]
    local B = W.WasmBuilder
    local mb = D.main_module(t3)
    t3.constants[] = D.Constants(t3)
    local fb = B.define(mb.functions[], B.define_function(mb.types[], IR.ValueType[D.translate_type(t3, Tuple{Int64, Float64})], IR.ValueType[IR.NumType_i64]), "f")
    g.b[] = B.body(fb)
    g.param_locals[] = B.locals(fb)
    g.return_label[] = nothing
    D.setup_parameters_for_normal_entry(g, g.member)
    @test D.visit_record_index_get(g, get1, IR.NumType_i64) == IR.NumType_i64
    @test String[B.name(i) for i in g.b[]._instructions] == ["local.get", "struct.get"]
    # an index past the tuple's fields rejects at its own check
    local past = W.NirCall(W.NirValue[get1.args[1], get1.args[2], W.NirConst(Core.Const(3))])
    local e3 = try; D.visit_record_index_get(g, past, IR.NumType_i64); nothing; catch x; x; end
    @test e3 isa W.RejectionError && e3.rejection isa W.Internal && occursin("which has 2", e3.rejection.site)
end
