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
    # a concrete Julia tuple type is a class of its own, Base's; the closed world's walk meets each
    # arity's record, so no Kernel visit fills the map
    local t = D.Translator(WasmTarget.build_nir(W.check_subset(x -> (x, x + 1), (Int,), "records", Base.get_world_counter()), "test"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    @test isempty(D.generate_record_classes(t.component))
    local g = D._RecordClassGenerator(Dict{D.RecordShape,DataType}())
    @test D.nullable_object_type(g) === Any && D.non_nullable_string_type(g) === String
    @test D.bool_type(g) === Bool && D.int_type(g) === Int64
    local e = try; D.visit_record_type(D._RecordVisitor(g), Tuple{Int,Int}); nothing; catch x; x; end
    @test e isa W.RejectionError && e.rejection isa W.Internal
    # a positional shape's class is the record of its arity, its fields \$1..\$N of dart's Object?, Any
    local rec = D._generate_class(g, D.RecordShape(2, String[]), Int64(0))
    @test rec === W.tuple_record_class(2) && W.tuple_record_arity(rec) == 2 && W.tuple_record_arity(Tuple{Int,Int}) === nothing
    # the empty shape's class is Julia's one empty tuple's, Tuple{}, no field to box
    @test W.tuple_record_class(0) === Tuple{} && W.tuple_record_arity(Tuple{}) == 0 && isempty(D._generate_fields(g, D.RecordShape(0, String[])))
    local fs = D._generate_fields(g, D.RecordShape(2, String[]))
    @test [(f.cls, f.index, f.name, f.type, f.mutable) for f in fs] == [(rec, 1, "\$1", Any, false), (rec, 2, "\$2", Any, false)]
    @test W.class_instance_fields(rec, "records") == fs
    # a named shape is a NamedTuple's, a class of its own, never a record
    local en = try; D._generate_class(g, D.RecordShape(1, ["a"]), Int64(0)); nothing; catch x; x; end
    @test en isa W.RejectionError && en.rejection isa W.Internal && occursin("NamedTuple", en.rejection.site)
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
    local t = D.Translator(WasmTarget.build_nir(W.check_subset(f, argtypes, "records", Base.get_world_counter()), "test"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    D._init_modules(t, nothing)
    collect(D.ClassInfoCollector(t))
    t.constants[] = D.Constants(t)
    local mb = D.main_module(t)
    local nb = only(nb for nb in t.component if nb.ci.def === t.component.entry)   # the program's body, beside the runtime's roots
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
    # a tuple's field by position, read behind Julia's bounds-check flag: the module builds
    local _, bytes3 = records_compile_one(RecordCodegenCases.fst, (Tuple{Int64, Float64},))
    @test bytes3[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
    # the visit itself: the shape's positional index agrees with the class layout, then the receiver
    # is read and its field
    local t3 = D.Translator(WasmTarget.build_nir(W.check_subset(RecordCodegenCases.fst, (Tuple{Int64, Float64},), "records", Base.get_world_counter()), "test"), D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    D._init_modules(t3, nothing)
    collect(D.ClassInfoCollector(t3))
    local nb = first(t3.component)
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

# tuples and Julia's bounds-check flag, each program run against native Julia (test/runner.jl)
module RecordRunCases
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const WTChild = Main.WTChild
@inline function checked(x::Int64)
    r = Int64(0)
    @boundscheck r = Int64(100)
    return r + x
end
plain(x::Int64) = checked(x)                  # the flag true: Julia's default --check-bounds
inb(x::Int64) = @inbounds checked(x)          # the flag false: @inbounds, resolved by the optimizer
@noinline Base.@constprop :none pick(t::Tuple{Int64, Float64}) = t[1] * Int64(2) + (t[2] > 2.0 ? Int64(1) : Int64(0))
idx(x::Int64) = pick((x, 2.5))
@noinline Base.@constprop :none pickin(t::Tuple{Int64, Float64}) = @inbounds t[1] - Int64(1)
idxin(x::Int64) = pickin((x, 2.5))
@noinline Base.@constprop :none nt(t::NamedTuple{(:b, :a), Tuple{Int64, Int64}}) = t.a - t.b
named(x::Int64) = nt((b = x, a = Int64(10)))
mk(x::Int64, y::Float64) = (x, y)
@testset "code_generator.dart: tuples and Julia's bounds-check flag, run against native" begin
    # Julia's answers: the flag is the @boundscheck block's guard, its value the compiling process's
    @test plain(1) == 101 && inb(1) == 1 && Base.JLOptions().check_bounds == 0
    local cases = WTChild.RunCase[]
    for (f, args) in ((plain, (Int64(1),)), (inb, (Int64(1),)), (idx, (Int64(7),)), (idxin, (Int64(7),)), (named, (Int64(3),)), (mk, (Int64(4), 1.5)))
        append!(cases, first(WTChild.answer_cases(string(nameof(f)), WasmTarget.compile, f, args)))
    end
    local results = WTChild.run_cases(cases)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test length(results) >= 7 && all(r -> r.ok, results)
end
end

# a tuple whose statement Julia widened (Tuple{Any, Any}) is still an instance of its operands' class,
# Tuple{Int64, Int64}: the closed world's classes hold it (nir_tuple_type), so its literal compiles, and
# a program testing and reading it answers as native Julia (test/runner.jl)
module RecordWidenedCases
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const WTChild = Main.WTChild
_facts(xs...) = xs
@noinline Base.@constprop :none function widened(n::Int64)
    a = Ref{Any}(nothing); a[] = 42n
    b = Ref{Any}(nothing); b[] = 42n
    return _facts(a[], b[])
end
sumfacts(n::Int64) = (t = widened(n); t isa Tuple{Int64, Int64} ? t[1] + t[2] : Int64(-1))
@testset "classes, code_generator.dart: a widened tuple statement's class is its operands'" begin
    # Julia's answers: the statement is widened, the object's class is not
    @test Base.code_typed(widened, (Int64,))[1][2] == Tuple{Any, Any} && typeof(widened(1)) === Tuple{Int64, Int64}
    local world = WasmTarget.build_nir(WasmTarget.check_subset(widened, (Int64,), "records", Base.get_world_counter()), "records")
    @test Tuple{Int64, Int64} in WasmTarget.closed_world_classes(world, "records")
    @test WasmTarget.compile(widened, (Int64,))[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
    local results = WTChild.run_cases(first(WTChild.answer_cases("sumfacts", WasmTarget.compile, sumfacts, (Int64(1),))))
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test !isempty(results) && all(r -> r.ok, results)
end
end

# a tuple's field at an index only run time knows (getfield(t, i), Julia's emit_getfield_unknownidx):
# a concrete tuple's bounds check and select chain, a homogeneous one (a vector literal's elements), a
# heterogeneous one (its field boxed), one under @inbounds, a one-field and a zero-field tuple; and a
# tuple whose length only run time knows (Tuple{String,Vararg{String}}), the class-id switch over the
# records of the arities it admits, at two lengths. Out of range each raises BoundsError, as native
module RecordIndexCases
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const WTChild = Main.WTChild
@noinline pick(t::Tuple, i::Int64) = t[i]
@noinline pickin(t::NTuple{3,Int64}, i::Int64) = @inbounds t[i]
@noinline nth(@nospecialize(t::Tuple{String,Vararg{String}}), i::Int64) = t[i]
const SQUARES = ntuple(k -> Int64(k * k), 36)
only_tuple(i::Int64) = SQUARES[i]
function tuple_index(k::Int64, i::Int64)
    k == 1 && return (v = Int64[10, 20, 30]; v[i])
    k == 2 && return (x = pick((Int64(1), "ab", 2.5), i); x isa Int64 ? x : x isa String ? Int64(ncodeunits(x)) : Int64(99))
    k == 3 && return pickin((Int64(4), Int64(5), Int64(6)), i)
    k == 4 && return Int64(ncodeunits(nth(("ab", "c"), i))) + 10 * Int64(ncodeunits(nth(("ab", "c", "def"), i)))
    k == 5 && return pick((Int64(7),), i)
    return (pick((), i); Int64(0))
end
@testset "codegen.cpp: a tuple's field at a run-time index, its bounds check and select chain, a Vararg tuple by its class" begin
    @test only(Base.code_typed(nth, (Tuple{String,Vararg{String}}, Int64)))[1].slottypes[2] === Tuple{String,Vararg{String}}
    local plain = WasmTarget.compile(tuple_index, (Int64, Int64); optimize = false)
    local argsets = [(1, 1), (1, 3), (1, 4), (1, 0), (2, 1), (2, 2), (2, 3), (2, 4), (3, 2), (4, 1), (4, 2), (4, 3),
                     (5, 1), (5, 2), (6, 1)]
    local cases = [WTChild.RunCase("tuple_index$a", plain, Int64.(a), WTChild.native_answer(tuple_index, Int64.(a))) for a in argsets]
    @test count(c -> c.native == WTChild.Throws(BoundsError), cases) == 6
    local results = WTChild.run_cases(cases)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test length(results) == 15 && all(r -> r.ok, results)
    # a program whose one read that can raise BoundsError is a tuple's at a run-time index (an NTuple of
    # 36, the corpus's case): its read calls the runtime's raise, a root of every closed world
    # (RUNTIME_ROOTS)
    local only_bytes = WasmTarget.compile(only_tuple, (Int64,); optimize = false)
    local only_cases = [WTChild.RunCase("only_tuple$a", only_bytes, a, WTChild.native_answer(only_tuple, a)) for a in ((Int64(1),), (Int64(36),), (Int64(37),))]
    @test only_cases[3].native == WTChild.Throws(BoundsError)
    local only_results = WTChild.run_cases(only_cases)
    foreach(r -> r.ok || println(r.label, ": ", r.why), only_results)
    @test all(r -> r.ok, only_results)
end
# a field at a constant index of a Union of tuple types, which has no layout: the class-id switch over
# its concrete tuple classes, each arm its own field, as at a run-time index
const UNION_TUPLES = Ref{Union{Tuple{Int64,Bool},Tuple{Nothing,Bool}}}((Int64(0), false))
function union_tuple_read(n::Int64)
    UNION_TUPLES[] = n > 0 ? (n, true) : (nothing, false)
    local t = UNION_TUPLES[]
    local a = getfield(t, 1)
    return (a === nothing ? Int64(-1) : a) * 10 + Int64(getfield(t, 2))
end
@testset "codegen.cpp: a field at a constant index of a Union of tuple types, by its class" begin
    local bytes = WasmTarget.compile(union_tuple_read, (Int64,); optimize = false)
    local results = WTChild.run_cases([WTChild.RunCase("union_tuple_read($n)", bytes, (n,), WTChild.native_answer(union_tuple_read, (n,))) for n in (Int64(4), Int64(-2))])
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test length(results) == 2 && all(r -> r.ok, results)
end
end

# a tuple literal whose operands' classes only run time knows, Julia's jl_f_tuple's: the record of its arity
# (src/julia/classes.jl TupleRecord, the varargs tuple's too), each operand boxed, read back at a run-time
# index, whatever classes its open operand has
module OpenLiteralCases
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const WTChild = Main.WTChild
const TS = Type[Int64, String, Union{Int64,String}]
const ANYS = Any[1, "s"]
@noinline pick(@nospecialize(t::Tuple), i::Int64) = t[i]
function open_literal(k::Int64, n::Int64)
    local t = (TS[n], n)                                   # a Tuple{Type, Int64}: DataType or Union first
    k == 1 && return pick(t, 2)::Int64
    return Int64(pick(t, 1) isa DataType)
end
over(n::Int64) = pick((ANYS[n], n), 2)::Int64            # Tuple{Any, Int64}: every class first
@testset "records.dart: a tuple literal of open operands is the record of its arity" begin
    @test Base.return_types(open_literal, (Int64, Int64)) == [Int64]
    local plain = WasmTarget.compile(open_literal, (Int64, Int64); optimize = false)
    local cases = [WTChild.RunCase("open_literal$a", plain, Int64.(a), WTChild.native_answer(open_literal, Int64.(a))) for a in ((k, n) for k in 1:2 for n in 1:3)]
    local results = WTChild.run_cases(cases)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test length(results) == 6 && all(r -> r.ok, results)
    # Tuple{Any, Int64}: an operand of every class the closed world has, one record, as native
    local over_bytes = WasmTarget.compile(over, (Int64,); optimize = false)
    local over_results = WTChild.run_cases([WTChild.RunCase("over($n)", over_bytes, (Int64(n),), WTChild.native_answer(over, (Int64(n),))) for n in 1:2])
    foreach(r -> r.ok || println(r.label, ": ", r.why), over_results)
    @test length(over_results) == 2 && all(r -> r.ok, over_results)
end
end

# the record model (src/julia/classes.jl TupleRecord): the same Tuple{Int64,String} value through an Any
# slot and back, read on both sides by isa, nfields, a run-time index and its fields (convertType's box
# into its arity's record, its unbox where Julia narrows it); and a tuple from each producer of an open
# tuple (an open literal, an open-count varargs call, a constant through an Any slot) tested by isa,
# nfields and a run-time index, each the record of its arity, so a producer that left a tuple of its own
# class in an open slot would answer false where native answers true; and Julia's === over them, the
# runtime's jl_egal (its class-id switch, builtins.c's arms): the producers' tuples against each other
# and through an Any slot, and values of every kind an open slot holds (a float's bits, a String's
# bytes, a boxed Bool, nothing, a nested tuple, a mutable object by identity)
module RecordModelCases
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const WTChild = Main.WTChild
const ANYS = Any[Int64(1), "s"]
const SLOT = Any[nothing]
const CT = (Int64(3), "ab")
@noinline vt(@nospecialize(xs...)) = xs
@noinline pick(@nospecialize(t::Tuple), i::Int64) = t[i]
@noinline nf(@nospecialize(t::Tuple)) = nfields(t)
function round_trip(k::Int64, n::Int64)
    local v = (n, "ab")
    SLOT[1] = v
    local a = SLOT[1]
    k == 1 && return Int64(a isa Tuple{Int64,String}) + 2 * Int64(v isa Tuple{Int64,String})
    k == 2 && return Int64(a isa Tuple{String,String})
    k == 3 && return Int64(a isa Tuple{Integer,Any}) + 2 * Int64(a isa Tuple) + 4 * Int64(a isa NTuple{3,Any})
    k == 4 && return nf(a::Tuple) + 10 * nfields(v)
    k == 5 && return (a::Tuple{Int64,String})[1] + 10 * v[1]
    k == 6 && return Int64(ncodeunits((a::Tuple{Int64,String})[2]))
    k == 7 && return (x = pick(a::Tuple, n); x isa Int64 ? x : Int64(ncodeunits(x::String)))
    return (x = pick(v, n); x isa Int64 ? x : Int64(ncodeunits(x::String)))
end
function producers(k::Int64, n::Int64)
    local lit = (ANYS[n], "ab")
    local va = vt(ANYS[n], "ab")
    SLOT[1] = CT
    local c = SLOT[1]
    k == 1 && return Int64(lit isa Tuple{Int64,String}) + 2 * Int64(va isa Tuple{Int64,String}) + 4 * Int64(c isa Tuple{Int64,String})
    k == 2 && return Int64(lit isa Tuple{String,String}) + 2 * Int64(va isa Tuple{String,String}) + 4 * Int64(c isa Tuple{String,String})
    k == 3 && return nf(lit) + nf(va) + nf(c::Tuple)
    k == 4 && return (x = pick(va, 1); x isa Int64 ? x : Int64(-1)) + 10 * (c::Tuple{Int64,String})[1]
    return Int64(ncodeunits(pick(lit, 2)::String))
end
mutable struct Cell; x::Int64; end
const CELL = Cell(1)
const MIXED = Any[NaN, -0.0, 0.0, "ab", "ab" * "", true, nothing, ((Int64(1), "a"), 2.5), CELL, Cell(1), Int64(3), Int32(3)]
function egal(k::Int64, n::Int64)
    local lit = (ANYS[n], "ab")
    local va = vt(ANYS[n], "ab")
    SLOT[1] = CT
    local c = SLOT[1]
    k == 1 && return Int64(lit === va) + 2 * Int64(c === lit) + 4 * Int64(c === va)
    k == 2 && return (v = (Int64(3), "ab"); SLOT[1] = v; Int64(SLOT[1] === v) + 2 * Int64(SLOT[1] === (n, "ab")))
    local i, j = divrem(k - 3, length(MIXED))
    return Int64(MIXED[i % length(MIXED) + 1] === MIXED[(j + n - 1) % length(MIXED) + 1])
end
@testset "records.dart: a tuple through an open slot is the record of its arity, read as native" begin
    for (f, ks) in ((round_trip, 1:8), (producers, 1:5))
        local bytes = WasmTarget.compile(f, (Int64, Int64); optimize = false)
        local cases = [WTChild.RunCase("$(nameof(f))($k, $n)", bytes, (Int64(k), Int64(n)), WTChild.native_answer(f, (Int64(k), Int64(n)))) for k in ks for n in 1:2]
        local results = WTChild.run_cases(cases)
        foreach(r -> r.ok || println(r.label, ": ", r.why), results)
        @test length(results) == 2 * length(ks) && all(r -> r.ok, results)
    end
    local bytes = WasmTarget.compile(egal, (Int64, Int64); optimize = false)
    local ks = 1:(2 + length(MIXED)^2)
    local cases = [WTChild.RunCase("egal($k, $n)", bytes, (Int64(k), Int64(n)), WTChild.native_answer(egal, (Int64(k), Int64(n)))) for k in ks for n in 1:2]
    @test count(c -> c.native == 1, cases) >= 2 * length(MIXED)
    local results = WTChild.run_cases(cases)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test length(results) == length(cases) && all(r -> r.ok, results)
end
end
