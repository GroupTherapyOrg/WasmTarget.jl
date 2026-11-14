# dart2wasm's constants.dart, ported (src/constants.jl), a constant a Julia value as the NIR holds a literal
# (NirConst): what answers without a module to build into, each expected value Julia's
# own (its values' types, ===, and the IR parts wasm_builder's port builds).
module ConstantsTest

using Test
using WasmTarget

const D = WasmTarget.Dart2Wasm
const W = WasmTarget.WasmBuilder
const I = W.IR

# a collaborator's translator: the options the constants' names read, and nothing else
struct ConstantsNodes <: D.KernelNodes
    options::D.TranslatorOptions
end

_rejection(f) = try; f(); nothing; catch x; x isa WasmTarget.RejectionError ? x.rejection : rethrow(); end
fidx(i::Int) = (f = I.Finalizable{Int}(); W.set_value!(f, i); f)
code() = I.Instructions(I.Local[], WasmTarget.LinkedHashMap{Int,String}(), I.Instruction[], nothing, String[], nothing)
kind(x) = WasmTarget.NirConst(Core.Const(x))

mutable struct Cell
    x::Int
end

@testset "constants are Julia's values" begin
    # one constant per value by Julia's identity: equal immutable values are one key, two mutable
    # objects with equal fields are two
    local d = Dict{Union{WasmTarget.NirConst,D.DummyValueConstant},Int}()
    d[kind((1, "a"))] = 1; d[kind((1, "a"))] = 2; d[kind(Cell(1))] = 3; d[kind(Cell(1))] = 4
    @test length(d) == 3 && d[kind((1, "a"))] == 2
    @test kind(0.0) != kind(-0.0)
end

@testset "constants.dart: the definitions and ConstantInfo" begin
    @test D.max_array_new_fixed_length() == 10000 && !D.force_delayed_constant_definition() && D.ConstantInfo_can_be_eager_bit() == 1
    local m = I.Module_uninitialized()
    local g = I.DefinedGlobal(m, code(), fidx(0), I.GlobalType(I.RefType_struct(nullable = true)))
    local eager = D.GlobalBasedConstantDefinition(g, nothing)
    @test !D.is_lazy(eager)
    local f = I.DefinedFunction(m, code(), fidx(0), I.FunctionType(I.ValueType[], I.ValueType[I.RefType_struct(nullable = false)]))
    local lazy = D.GlobalBasedConstantDefinition(g, f)
    @test D.is_lazy(lazy)
    local t = I.DefinedTable(m, fidx(0), I.RefType_struct(nullable = true), 1, nothing)
    local tb = D.TableBasedConstantDefinition(t, 0, WasmTarget.LinkedHashMap{W.ModuleBuilder,I.BaseFunction}())
    @test D.is_lazy(tb) && tb.table_index == 0
    # printInitializer: an eager global's initializer, a lazy one's function
    local info = D.ConstantInfo(kind(:s), D.ConstantInfo[], (_, _) -> false, true, I.RefType_struct(nullable = false), (_, _, _) -> nothing)
    local printed = Any[]
    D.print_initializer(info, fn -> push!(printed, fn), gl -> push!(printed, gl))
    @test isempty(printed)
    D.set_definition(info, eager)
    D.print_initializer(info, fn -> push!(printed, fn), gl -> push!(printed, gl))
    @test printed == Any[g]
    @test _rejection(() -> D.set_definition(info, lazy)) isa WasmTarget.Internal
    local info2 = D.ConstantInfo(kind(:t), D.ConstantInfo[], (_, _) -> false, true, I.RefType_struct(nullable = false), (_, _, _) -> nothing)
    D.set_definition(info2, lazy); empty!(printed)
    D.print_initializer(info2, fn -> push!(printed, fn), gl -> push!(printed, gl))
    @test printed == Any[f]
end

@testset "constants.dart: Constants, the creator and the accessor" begin
    local nodes = ConstantsNodes(D.TranslatorOptions())
    local cs = D.Constants(nodes)
    @test !cs.currently_creating && isempty(cs.constant_info)
    @test cs._cached_true_constant[] === kind(true)
    # the dummy values: one per heap type, eq and any taking struct's
    local ds = D.dummy_struct_constant(cs)
    @test ds isa D.DummyValueConstant && ds.name == "#DummyStruct" && ds.type === I.HeapType_struct
    @test D._get_dummy_value_constant(cs, I.HeapType_eq) === ds && D._get_dummy_value_constant(cs, I.HeapType_any) === ds
    @test D._get_dummy_value_constant(cs, I.HeapType_array).name == sprint(show, I.HeapType_array)
    @test D.DummyValueConstant(I.HeapType_array, "a") == D.DummyValueConstant(I.HeapType_array, "b")
    @test hash(D.DummyValueConstant(I.HeapType_array, "a")) == hash(D.DummyValueConstant(I.HeapType_array, "b"))
    @test sprint(io -> D.to_text_internal(ds, io)) == "Dummy value constant: #DummyStruct"
    # integers and floats have no identity: no info, instantiated where used
    @test D.ensure_constant(cs, kind(7)) === nothing && D.ensure_constant(cs, kind(2.5)) === nothing
    local cr = D.ConstantCreator(cs)
    @test D.translator(cr) === nodes && D.default_constant(cr, kind(nothing)) === nothing
    @test _rejection(() -> D.visit_int_constant(cr, 7)) isa WasmTarget.Internal
    @test _rejection(() -> D.visit_type_literal_constant(cr, Int)) isa WasmTarget.Internal
    # createConstant: eager only when every child is
    local gen = (_, _, _) -> nothing
    local child = D.create_constant(cr, kind(:a), D.ConstantInfo[], I.RefType_struct(nullable = false), gen; can_be_eager = false)
    local parent = D.create_constant(cr, kind(:b), [child], I.RefType_struct(nullable = false), gen; can_be_eager = true)
    @test !child.can_be_eager && !parent.can_be_eager && parent.children == [child]
    @test _rejection(() -> D.create_constant(cr, kind(:c), D.ConstantInfo[], I.RefType_struct(nullable = true), gen; can_be_eager = true)) isa WasmTarget.Internal
    # the accessor: the eager kinds, and each constant's name, numbered once per name
    local acc = cs._constant_accessor[]
    @test all(x -> D.constant_is_always_eager(acc, kind(x)), (nothing, true, 7, 2.5)) && !D.constant_is_always_eager(acc, kind("s"))
    local n0 = D._ConstantAccessor__next_global_id(acc)[]
    @test D._constant_name(acc, kind("hello\nworld")) == "C$n0 \"hello\""
    @test D._constant_name(acc, kind(repeat("x", 31))) == "C$(n0 + 1) \"$(repeat("x", 30))<...>\""
    @test D._constant_name(acc, kind(false)) == "C$(n0 + 2) false"
    @test D._constant_name(acc, kind(1 // 2)) == "C$(n0 + 3) Rational<Int64>"
    @test D._constant_name(acc, kind(Cell(1))) == "C$(n0 + 4) Cell"
    @test D._constant_name(acc, ds) == "C$(n0 + 5)  #Dummy($(I.HeapType_struct))"
    @test D._constant_name(D._ConstantAccessor(ConstantsNodes(D.TranslatorOptions(unique_constant_names = false))), kind(:s)) == ":s"
    @test D._name_type(acc, Vector{Tuple{Int,String}}) == "Array<Tuple<Int64, String>, 1>"
    # a type as a value lowers to its kind's instance, once per type (Julia's types are canonical)
    local u = D._lower_type_to_constant(cs, Union{Int,String})
    @test u === WasmTarget.NirConst(Core.Const(Union{String,Int})) && D._lower_type_to_constant(cs, Union{String,Int}) === u
    @test D._lower_type_to_constant(cs, Union{}) === WasmTarget.NirConst(Core.Const(Union{}))
    @test D._lower_type_to_constant(cs, Vector) === WasmTarget.NirConst(Core.Const(Vector))
    @test _rejection(() -> D._make_bottom_type_constant(cs, Int)) isa WasmTarget.Internal
end

@testset "constants.dart: the wasm array and WasmI32 constants" begin
    local cs = D.Constants(ConstantsNodes(D.TranslatorOptions()))
    # a WasmI32 is Julia's Int32; out of range rejects
    @test D.make_wasm_i32(cs, 7) === kind(Int32(7)) && D.make_wasm_i32(cs, -1) === kind(Int32(-1))
    @test _rejection(() -> D.make_wasm_i32(cs, 2^31)) isa WasmTarget.Internal
    # arrays compare field by field, as Kernel canonicalizes the InstanceConstants dart builds
    local a = D.make_array_of(cs, Int32, [D.make_wasm_i32(cs, 1), D.make_wasm_i32(cs, 2)])
    @test a === D.make_array_of(cs, Int32, [D.make_wasm_i32(cs, 1), D.make_wasm_i32(cs, 2)])
    @test a !== D.make_array_of(cs, Int32, [D.make_wasm_i32(cs, 1), D.make_wasm_i32(cs, 2)]; mutable_ = false)
    @test a.c.val isa WasmTarget.WasmArrayLiteral && a.c.val.mutable && a.c.val.element_type === Int32
    local d = Dict{WasmTarget.NirConst,Int}(a => 1)
    @test d[D.make_array_of(cs, Int32, [D.make_wasm_i32(cs, 1), D.make_wasm_i32(cs, 2)])] == 1
    # a type array: each type lowered to its kind's instance
    local ta = D.make_type_array(cs, Type[Union{Int,String}, Union{}])
    @test ta.c.val.element_type === Type && ta.c.val.entries === (kind(Union{Int,String}), kind(Union{}))
end

@testset "constants.dart: emitting into a module" begin
    local cs = D.Constants(ConstantsNodes(D.TranslatorOptions()))
    local mb = W.ModuleBuilder("m", nothing)
    # null: ref.null none, typed nullref, or the expected funcref's own null
    local b = W.InstructionsBuilder(mb, I.ValueType[], I.ValueType[I.RefType_none(nullable = true)])
    @test D.visit_null_constant(D.ConstantInstantiator(cs, b, I.RefType_any(nullable = true), nothing), nothing) == I.RefType_none(nullable = true)
    @test b._instructions == I.Instruction[I.RefNull(I.HeapType_none)]
    local bf = W.InstructionsBuilder(mb, I.ValueType[], I.ValueType[I.RefType_func(nullable = true)])
    @test D.visit_null_constant(D.ConstantInstantiator(cs, bf, I.RefType_func(nullable = true), nothing), nothing) == I.RefType_func(nullable = true)
    @test bf._instructions == I.Instruction[I.RefNull(I.HeapType_func)]
    # an unboxed Bool: i32.const 1
    local bb = W.InstructionsBuilder(mb, I.ValueType[], I.ValueType[I.NumType_i32])
    @test D.visit_bool_constant(D.ConstantInstantiator(cs, bb, I.NumType_i32, nothing), true) == I.NumType_i32
    @test bb._instructions == I.Instruction[I.I32Const(1)]
    # a lazy constant's global: nullable, initialized to ref.null none
    local info = D.ConstantInfo(kind(:s), D.ConstantInfo[], (_, _) -> false, true, I.RefType_struct(nullable = false), (_, _, _) -> nothing)
    local g = D._create_lazy_global(cs._constant_accessor[], mb, "C0 :s", info)
    @test g.type == I.GlobalType(I.RefType_struct(nullable = true)) && g.global_name == "C0 :s"
    @test g.initializer._instructions == I.Instruction[I.RefNull(I.HeapType_none), I.End()]
end

end

# a constant whose fields share heap objects keys the caches in linear time: objectid walks every path
# (2^40 here), so NirConst's hash takes the value's type, agreeing with ===
module ConstantsDagHash
using Test, WasmTarget
struct _DagHashNode; a::Any; b::Any; end
@testset "a shared-DAG constant hashes in linear time" begin
    local n = _DagHashNode(nothing, nothing)
    for _ in 1:40; n = _DagHashNode(n, n); end
    local k = WasmTarget.NirConst(Core.Const(n))
    @test (@elapsed hash(k)) < 1.0
    @test k == WasmTarget.NirConst(Core.Const(n))
    local d = Dict(k => 1)
    @test d[WasmTarget.NirConst(Core.Const(n))] == 1
    @test hash(WasmTarget.NirConst(Core.Const(Int32(3)))) == hash(WasmTarget.NirConst(Core.Const(Int32(3))))
    @test WasmTarget.NirConst(Core.Const(Int32(3))) != WasmTarget.NirConst(Core.Const(Int64(3)))
    # same-type structured literals hash apart by their values, so a cache of N of them stays linear
    @test length(Set(hash(WasmTarget.NirConst(Core.Const((i, "x")))) for i in 1:100)) == 100
    # a mutable leaf hashes by its address: a vector holding itself hashes, and mutating it keeps its hash
    local selfref = Any[1]; push!(selfref, selfref)
    local ks = WasmTarget.NirConst(Core.Const((selfref, 1)))
    local h0 = hash(ks); push!(selfref, 2)
    @test hash(ks) == h0
end
end

module ConstantsRest
using Test, WasmTarget
const D = WasmTarget.Dart2Wasm
const I = WasmTarget.WasmBuilder.IR
struct Nodes <: D.KernelNodes
    options::D.TranslatorOptions
end
k(x) = WasmTarget.NirConst(Core.Const(x))
rej(f) = try; f(); nothing; catch x; x isa WasmTarget.RejectionError ? x.rejection : rethrow(); end
@testset "constants.dart: the kinds Julia answers empty or as another" begin
    local cs = D.Constants(Nodes(D.TranslatorOptions()))
    local cr = D.ConstantCreator(cs)
    # a type variable is an instance of TypeVar; a function type has no named parameters
    local tv = TypeVar(:T)
    @test D._make_type_parameter_type_constant(cs, tv) === k(tv) && D._make_structural_parameter_type_constant(cs, tv) === k(tv)
    @test D.make_named_parameters_array(cs, typeof(sin)).c.val.entries === ()
    @test D.make_named_parameter_constant(cs, Pair{Symbol,Type}(:x, Int)) === k(Pair{Symbol,Type}(:x, Int))
    @test rej(() -> D._make_top_type_constant(cs, Union{Int,String})) isa WasmTarget.Internal
    # Julia has no constant map or set: the hash index rejects, Internal, naming the MapConstant row; a
    # constant Vector's class is its own Array{T,1}, dart's immutable list class
    local hi = rej(() -> D._uninitialized_hash_base_index_constant(cr))
    @test hi isa WasmTarget.Internal && occursin("MapConstant row", hi.site)
    @test D.immutable_list_class(Nodes(D.TranslatorOptions()), String) === Vector{String}
    @test rej(() -> D.core_types(cs)) isa WasmTarget.Internal
end
end

# a type as a value: lowered to its type object, an instance of its kind, its fields filled; a boxed Bool
# holds its class id and value, no identity hash (dart's visitBoolConstant)
module ConstantsTypeValue
using Test, WasmTarget
const D = WasmTarget.Dart2Wasm
const W = WasmTarget.WasmBuilder
const I = W.IR
is_int(r::Base.RefValue{Any}) = r[] isa Int64
k(x) = WasmTarget.NirConst(Core.Const(x))
@testset "constants.dart: a type literal is its lowered type object, an instance constant" begin
    local data = D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options()))
    local t = D.Translator(WasmTarget.build_nir(WasmTarget.check_subset(is_int, (Base.RefValue{Any},), "constants", Base.get_world_counter()), "test"), data, D.TranslatorOptions())
    D._init_modules(t, nothing)
    collect(t.closure_layouter[]); collect(t.class_info_collector[])
    t.globals[] = D.Globals(t); t.dart_globals[] = D.DartGlobals(t); t.constants[] = D.Constants(t)
    local cr = D.ConstantCreator(t.constants[])
    # Int64 as a value: the DataType instance whose classId is Int64's, created as an instance constant
    local info = D.ensure_constant(cr, k(Int64))
    @test info.constant === D._lower_type_to_constant(t.constants[], Int64)
    @test info.type == t.class_info[DataType].non_nullable_type
    # its parameters, an empty SimpleVector, an immutable wasm array of none
    @test any(c -> c.constant.c.val isa Core.SimpleVector, info.children)
    local sv = only(filter(c -> c.constant.c.val isa Core.SimpleVector, info.children))
    @test only(sv.children).constant.c.val isa WasmTarget.WasmArrayLiteral && !only(sv.children).constant.c.val.mutable
    # the visitor that never sees an unlowered type
    @test D.visit_instance_constant(D.TypeOfConstantVisitor(t), info.constant) == info.type
    # a boxed Bool: its class id and its value, accepted by the builder as the box's struct
    local bi = D.ensure_constant(cr, k(true))
    local b = W.InstructionsBuilder(D.main_module(t), I.ValueType[], I.ValueType[bi.type])
    bi._code_gen(bi, b, false)
    @test [typeof(x) for x in b._instructions] == [I.I32Const, I.I32Const, I.StructNew]
    W.var"end"(b)
end
end

# a record constant, Julia's Tuple: each field is instantiated at its struct field's own type (an Int64 an
# i64, a Bool an i32), never as the boxed constant's global, which the builder refuses at struct.new (b54115e0)
module RecordConstantCases
using Test, WasmTarget
records(n::Int64) = ((42, 42, 42), ((42,), true), n)
@testset "a record constant's fields at their own types" begin
    @test WasmTarget.compile(records, (Int64,); optimize = false) isa Vector{UInt8}
end
end

# a tuple constant passed as a value: each element at its field's own wasm type (an i64, never the
# boxed Int64's global), the module run against native Julia (test/runner.jl)
module ConstantsTupleValue
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const WTChild = Main.WTChild
@noinline Base.@constprop :none sum3(t::NTuple{3,Int64}) = getfield(t, 1) + getfield(t, 2) + getfield(t, 3)
f(n::Int64) = sum3((42, 42, 42)) + n
@testset "constants.dart: a tuple constant's fields at their own types, run against native" begin
    # the optimized IR passes the tuple itself, a literal, to the call
    @test any(st -> Meta.isexpr(st, :invoke) && (42, 42, 42) in st.args, Base.code_typed(f, (Int64,))[1][1].code)
    local results = WTChild.run_cases(first(WTChild.answer_cases("tuple constant", WasmTarget.compile, f, (Int64(1),))))
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test !isempty(results) && all(r -> r.ok, results)
end
end

module StringConstants
using Test, WasmTarget
const D = WasmTarget.Dart2Wasm
const I = WasmTarget.WasmBuilder.IR
const BIG = repeat("é", 6000)     # 12000 UTF-8 code units, past maxArrayNewFixedLength
lit(b::Bool) = b ? "héllo" : "ab"
big(b::Bool) = b ? BIG : "x"
translated(f) = (t = D.Translator(WasmTarget.build_nir(WasmTarget.check_subset(f, (Bool,), "constants", Base.get_world_counter()), "constants"),
    D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions()); D.translate(t, nothing); t)
@testset "constants.dart: a String literal, its UTF-8 code units as dart's literal path makes them" begin
    local t = translated(lit)
    # String's struct: the object header, then its code units as an i8 array, the field immutable
    local fields = t.class_info[String].struct_.fields
    @test length(fields) == 3 && !fields[3].mutable && fields[3].type isa I.RefType
    local arr = fields[3].type.heap_type
    @test arr isa I.ArrayType && arr.element_type[].type === I.PackedType_i8 && arr.element_type[].mutable
    # each literal an eager global: header, array.new_fixed of Julia's codeunits, struct.new
    for s in ("héllo", "ab")
        local ci = t.constants[].constant_info[WasmTarget.NirConst(Core.Const(s))]
        local ins = ci._definition.global_.initializer._instructions
        local consts = [x.value for x in ins if x isa I.I32Const]
        @test consts[3:end] == Int.(codeunits(s)) && !D.is_lazy(ci._definition)
        @test any(x -> x isa I.ArrayNewFixed && x.length == ncodeunits(s), ins)
    end
    # past maxArrayNewFixedLength: the bytes in the passive data segment, array.new_data, a lazy constant
    local tb = translated(big)
    local cb = tb.constants[].constant_info[WasmTarget.NirConst(Core.Const(BIG))]
    @test D.is_lazy(cb._definition)
    local seg = only(values(tb.constants[]._byte_segments))
    @test seg.content == Vector{UInt8}(codeunits(BIG))
end
end

# a Memory constant: an instance constant of its class (src/julia/classes.jl), its `data` a wasm array
# literal of its elements' storage beside Julia's `length`, as visitStringConstant builds a String's
# bytes into its struct; an unset reference element (#undef) the null; read through a phi so Julia
# folds nothing, run against native
module MemoryConstants
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const WTChild = Main.WTChild
# (a boxed element type: an isbits Memory reached through no owner is refused, spec v17 Y6, below)
const PRIMES = let m = Memory{Any}(undef, 4); m .= (2, 3, 5, 7); m end
const EMPTY = Memory{Any}(undef, 0)
const NAMES = let m = Memory{String}(undef, 3); m[1] = "a"; m[3] = "ccc"; m end
const NONE = Memory{String}(undef, 0)
# elements admitting nothing: a written nothing, an unset element (#undef, its set flag 0), a String
const MAYBE = let m = Memory{Union{Nothing,String}}(undef, 3); m[1] = nothing; m[3] = "x"; m end
plen(b::Bool) = length(b ? PRIMES : EMPTY)
nlen(b::Bool) = length(b ? NAMES : NONE)
maybe(i::Int64, read::Bool) = read ? Int64(MAYBE[i] === nothing) : Int64(isassigned(MAYBE, i))
# a constant Vector (visitListConstant, an instance of Array{T,1}: its MemoryRef and its size), one whose
# MemoryRef starts past its memory's first element, a Vector{String}, a Matrix (an Array of its class)
# and a constant Vector written then read: case k at i
const VEC = [2, 3, 5]
const OFF = let v = [1, 2, 3, 4]; popfirst!(v); v end
const STRS = ["a", "bcd"]
const MAT = [1 2; 3 4]
const CELL = [0]
function lists(k::Int64, i::Int64)
    k == 1 && return VEC[i]
    k == 2 && return OFF[i]
    k == 3 && return Int64(ncodeunits(STRS[i]))
    k == 4 && return MAT[i] + 10 * Int64(size(MAT, 1))
    k == 5 && return Int64(length(OFF))
    return (CELL[1] = i; CELL[1])
end
# every case in one program, case k at i (lists' cases from 11), so the family costs one program's two compiles
consts(k::Int64, i::Int64) =
    k == 1 ? plen(i == 1) : k == 2 ? nlen(i == 1) : k == 3 ? maybe(i, true) : k == 4 ? maybe(i, false) : lists(k - 10, i)
@testset "constants.dart: a Memory constant is its class's struct, its elements a wasm array literal; a list constant its Array" begin
    @test !isassigned(NAMES, 2)
    # one program, its two modules, then each argument set's native answer
    local own = WasmTarget.compile(consts, (Int64, Int64))
    local plain = WasmTarget.compile(consts, (Int64, Int64); optimize = false)
    # the lengths of each constant memory and its type's empty instance; the set flags of a constant
    # whose elements admit nothing, `data#isSet`: an unset element's read raises UndefRefError, a written
    # nothing reads as nothing; constant lists in range and past the end (BoundsError)
    @test Base.memoryrefoffset(OFF.ref) == 2
    local argsets = [(1, 1), (1, 0), (2, 1), (2, 0), (3, 1), (3, 2), (3, 3), (4, 2), (4, 3),
                     (11, 1), (11, 3), (11, 4), (12, 1), (12, 3), (12, 4), (13, 2), (14, 3), (15, 0), (16, 7)]
    local cases = [WTChild.RunCase("consts$a", plain, Int64.(a), WTChild.native_answer(consts, Int64.(a)); optimized = own) for a in argsets]
    @test count(c -> c.native isa WTChild.Throws, cases) == 3
    local results = WTChild.run_cases(cases)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test length(results) == 19 && all(r -> r.ok, results)
end
end

# a mutable constant reaching itself through its fields: ensureConstant rejects the cycle, located,
# where its recursion overflowed the stack (dev/formal/Constants.tla's CyclesReject)
module CyclicConstantCases
using Test, WasmTarget
mutable struct N
    next::Any
    v::Int
end
const n = N(nothing, 3)
n.next = n
f(x::Int) = n.v + x
@testset "constants.dart: a constant reaching itself rejects, located" begin
    local e = try; WasmTarget.compile(f, (Int,); optimize = false); nothing; catch x; x; end
    @test e isa WasmTarget.RejectionError && e.rejection isa WasmTarget.Unquarantined && occursin("reaches itself", e.rejection.row)
end
end

# a Module constant: an instance constant of its class (src/julia/classes.jl _module_instance_fields),
# its one field the module's name, the Symbol Julia's `nameof` reads (jl_module_t's name); two modules
# through a phi, so Julia folds no `===`, each its own canonical constant, run against native
module ModuleConstants
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const WTChild = Main.WTChild
which_module(x::Int64) = (x > 0 ? Base : Core) === Base ? Int64(1) : Int64(2)
@testset "constants.dart: a Module constant is its class's struct, its name its one field" begin
    @test Base.code_typed(which_module, (Int64,))[1][2] === Int64
    # each module a constant, its name, the Symbol, a sub-constant of it
    local D = WasmTarget.Dart2Wasm
    local t = D.Translator(WasmTarget.build_nir(WasmTarget.check_subset(which_module, (Int64,), "constants", Base.get_world_counter()), "constants"),
        D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    D.translate(t, nothing)
    local made = t.constants[].constant_info
    @test all(m -> haskey(made, WasmTarget.NirConst(Core.Const(m))), (Base, Core, :Base, :Core))
    local cases = reduce(vcat, [first(WTChild.answer_cases("module constant $x", WasmTarget.compile, which_module, (x,))) for x in (Int64(1), Int64(-1))])
    local results = WTChild.run_cases(cases)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test !isempty(results) && all(r -> r.ok, results)
end

# spec v15 W3: a Dict constant's unfilled slots hold no defined element, so its module is a function of its live pairs
# alone: one function over one Dict constant compiled, then the bytes in the Dict's unfilled `vals` slots changed (as a
# process's heap leaves them, addresses among them: v14/v7/dictvals2.out), then compiled again: byte-identical modules
const _DICT_CONST = Dict("a" => 1, "bb" => 2, "ccc" => 3)
_dict_const_bb() = _DICT_CONST["bb"]
@testset "a Dict constant's unfilled slots: its live elements alone (spec v15 W3)" begin
    local before = WasmTarget.compile(_dict_const_bb, ())
    local before_plain = WasmTarget.compile(_dict_const_bb, (); optimize = false)
    local dead = [i for i in eachindex(_DICT_CONST.vals) if !Base.isslotfilled(_DICT_CONST, i)]
    @test !isempty(dead)
    for i in dead
        _DICT_CONST.vals[i] = 4_650_992_688 + i   # heap bytes, an address among them
    end
    @test WasmTarget.compile(_dict_const_bb, ()) == before
    @test WasmTarget.compile(_dict_const_bb, (); optimize = false) == before_plain
    local results = Main.WTChild.run_cases([Main.WTChild.RunCase("dict_const_bb", before, (), _dict_const_bb())])
    @test all(r -> r.ok, results)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
end

# an isbits union's memory Julia always allocates zeroed (datatype.c:551 zi = 1, genericmemory.c:71 memset), so a Dict
# constant's unfilled slots of an isbits-union key type hold the value a zeroed allocation reads: its module is a
# function of its live pairs alone, the dead keys rewritten (as a delete! leaves the deleted key) byte-identical
const _DICT_UNION_CONST = Dict{Union{Int64,Float64},String}(1 => "a", 2 => "b", 3 => "c")
_dict_union_const(x::Int64) = Int64(_DICT_UNION_CONST == Dict{Union{Int64,Float64},String}(x => "a", 2 => "b", 3 => "c"))
@testset "a Dict constant of an isbits-union key: its unfilled slots are a zeroed allocation's" begin
    @test (Memory{Union{Int64,Float64}}.flags & 0x0010) == 0x0010   # julia.h:619 zeroinit
    local before = WasmTarget.compile(_dict_union_const, (Int64,))
    local dead = [i for i in eachindex(_DICT_UNION_CONST.keys) if !Base.isslotfilled(_DICT_UNION_CONST, i)]
    @test !isempty(dead)
    for i in dead
        _DICT_UNION_CONST.keys[i] = isodd(i) ? 7.5 : Int64(4_650_992_688 + i)
    end
    @test WasmTarget.compile(_dict_union_const, (Int64,)) == before
    local results = Main.WTChild.run_cases([Main.WTChild.RunCase("dict_union_const $x", before, (x,), _dict_union_const(x)) for x in (Int64(1), Int64(5))])
    @test all(r -> r.ok, results)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
end

# spec v16 X5: the constants' `C<id>` names are the compile's (a Translator field), so a module's bytes, its name section
# among them, are the same whatever the process compiled before it
_counter_g(x::Int64) = string(x) * "!"
@testset "a module's bytes are its own compile's: the constants' counter is the translator's" begin
    local first_ = WasmTarget.compile(_dict_const_bb, ())
    WasmTarget.compile(_counter_g, (Int64,))   # another program, its own constants named
    @test WasmTarget.compile(_dict_const_bb, ()) == first_
end

# spec v17 Y6: a constant's memory is its owner's to define (src/julia/classes.jl MEMORY_OWNERS: an Array's size, a Dict's
# filled slots); an isbits memory reached through no owner (a bare Memory, IOBuffer's data) is refused, located, never
# emitted with every element's bytes; an empty one, and a boxed one (#undef the null), are held whole
const _BARE_BITS = let m = Memory{Int64}(undef, 3); m[1] = 1; m[3] = 3; m end   # its second element: whatever bytes
_bare_bits(i::Int64) = _BARE_BITS[i]
const _BUFFER = IOBuffer(UInt8[0x61, 0x62])
_buffer(i::Int64) = Int64(_BUFFER.data[i])
const _BARE_EMPTY = Memory{Int64}(undef, 0)
_bare_empty(i::Int64) = Int64(length(_BARE_EMPTY)) + i
@testset "a constant's isbits memory is its owner's to define, else refused, located (spec v17 Y6)" begin
    local refusal(f) = try; WasmTarget.compile(f, (Int64,)); nothing; catch x; x isa WasmTarget.RejectionError ? x.rejection : rethrow(); end
    for f in (_bare_bits, _buffer)
        local r = refusal(f)
        @test r isa WasmTarget.ProgramError && occursin("reached through no owner MEMORY_OWNERS lists", r.text)
    end
    @test refusal(_bare_empty) === nothing
    @test WasmTarget.MEMORY_OWNERS isa Tuple && all(o -> o[1] isa Type && o[2] isa String, WasmTarget.MEMORY_OWNERS)
end

# spec v16 X5: an Array constant's memory past its size (a capacity tail sizehint! reserved, the bytes pop! left for an
# isbits element) holds no defined element: the module carries its size's elements alone, whatever the tail holds
const _VEC_TAIL = let v = UInt64[11, 22, 33]; sizehint!(v, 16); push!(v, 0x0123456789abcdef); pop!(v); v end
_vec_tail(i::Int64) = _VEC_TAIL[i] + UInt64(length(_VEC_TAIL))
const _VEC_SHARED = UInt64[1, 2, 3, 4]
const _VEC_PART = Base.wrap(Array, getfield(_VEC_SHARED, :ref).mem, (2,))   # its first two elements, the same memory
_vec_shared(i::Int64) = _VEC_SHARED[i] + _VEC_PART[1]
const _VEC_TAIL2 = let v = UInt64[5, 6]; sizehint!(v, 8); v end
const _VEC_ALIAS = Base.wrap(Array, getfield(_VEC_TAIL2, :ref).mem, (2,))   # the same memory, the same size
_vec_alias(i::Int64) = (_VEC_ALIAS[1] = UInt64(i); _VEC_TAIL2[1])
@testset "an Array constant's memory past its size: its size's elements alone (spec v16 X5)" begin
    local mem = getfield(_VEC_TAIL, :ref).mem
    @test length(mem) >= 16 && mem[4] == 0x0123456789abcdef   # the popped element's bytes, in the tail
    local before = WasmTarget.compile(_vec_tail, (Int64,))
    for k in 4:length(mem)
        mem[k] = 0x5a5a5a5a00000000 + UInt64(k)   # the tail as another process's heap leaves it
    end
    @test WasmTarget.compile(_vec_tail, (Int64,)) == before
    @test all(r -> r.ok, Main.WTChild.run_cases([Main.WTChild.RunCase("vec_tail$i", before, (Int64(i),), _vec_tail(Int64(i))) for i in 1:3]))
    # two Arrays of one Memory and different sizes: one constant cannot hold each one's elements, refused, located
    local refused = try; WasmTarget.compile(_vec_shared, (Int64,)); nothing; catch x; x isa WasmTarget.RejectionError ? x.rejection : rethrow(); end
    @test refused isa WasmTarget.ProgramError && occursin("one constant cannot hold", refused.text)
    # two of one Memory and one size share its one copy: a write through one is read through the other, as natively
    local alias = WasmTarget.compile(_vec_alias, (Int64,))
    @test all(r -> r.ok, Main.WTChild.run_cases([Main.WTChild.RunCase("vec_alias", alias, (Int64(9),), Int64(9))]))
end
end

# dart's _makeWasmArrayLiteral past maxArrayNewFixedLength (10,000 entries): an i16 or i32 array is initialised from the
# passive data segment, each entry its integer's bits, little-endian (dart's Uint16List and Uint32List); any other
# storage (an i8, i64 or f64 array) is dart's array.new of its commonest entry and array.set or array.fill of the
# rest; at 10,000 or fewer, array.new_fixed. Each constant Vector read at its first, a middle and its last index
# against native, at 10,000 and 10,001 entries alike, and each data segment's bytes the elements' own.
module LargeConstantArrays
using Test, WasmTarget
isdefined(Main, :WTChild) || Base.include(Main, joinpath(@__DIR__, "..", "run_child.jl"))
const WTChild = Main.WTChild
const D = WasmTarget.Dart2Wasm
const U16 = UInt16[(k * 40503) % 65536 for k in 1:46592]              # utf8proc's stage-2 length
const I16 = Int16[(k * 40503) % 65536 - 32768 for k in 1:12000]       # negative entries among them
const I32 = Int32[(k * 2654435761) % 4294967296 - 2147483648 for k in 1:12000]
const U32 = UInt32[(k * 2654435761) % 4294967296 for k in 1:12000]
const CHR = Char[Char(k % 0xd800) for k in 1:12000]                   # a Char's bits, its UTF-8 encoding
const U8 = UInt8[k % 251 for k in 1:12000]                            # i8: dart's array.new and array.set path
const I64 = Int64[k * 1_000_003 - 6_000_000_000 for k in 1:12000]      # i64: the same
const F64 = Float64[k / 7 for k in 1:12000]                           # f64: the same
const AT = UInt16[(k * 7919) % 65536 for k in 1:10000]                 # array.new_fixed, the limit itself
const PAST = UInt16[(k * 7919) % 65536 for k in 1:10001]               # the data segment, one past it
# entry i of array k as an Int64 (a Float64's bits)
function rd(k::Int64, i::Int64)::Int64
    k == 1 && return Int64(U16[i])
    k == 2 && return Int64(I16[i])
    k == 3 && return Int64(I32[i])
    k == 4 && return Int64(U32[i])
    k == 5 && return Int64(reinterpret(UInt32, CHR[i]))
    k == 6 && return Int64(U8[i])
    k == 7 && return I64[i]
    k == 8 && return reinterpret(Int64, F64[i])
    k == 9 && return Int64(AT[i])
    return Int64(PAST[i])
end
const LENGTHS = (46592, 12000, 12000, 12000, 12000, 12000, 12000, 12000, 10000, 10001)
# the first, a middle and the last entry, summed
sum3(k::Int64, n::Int64) = rd(k, Int64(1)) + rd(k, n ÷ 2) + rd(k, n)
u16(i::Int64) = Int64(U16[i])
# translated standalone, as WasmTarget.compile translates: a read that can throw BoundsError needs its stack trace class
translated(f) = (o = D.TranslatorOptions(; standalone = true);
    t = D.Translator(WasmTarget.build_nir(WasmTarget.check_subset(f, (Int64,), "constants", Base.get_world_counter()), "constants"),
    D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), o); D.translate(t, nothing); t)
@testset "constants.dart: a constant array past maxArrayNewFixedLength, each element kind, run against native" begin
    @test any(<(0), I16) && any(<(0), I32) && length(AT) == D.max_array_new_fixed_length()
    # each function one program, its two modules; sum3 at each array's length, rd at each index it sums
    local cases = WTChild.RunCase[]
    for (f, argsets) in ((sum3, [(k, n) for (k, n) in enumerate(LENGTHS)]),
                         (rd, [(k, i) for (k, n) in enumerate(LENGTHS) for i in (1, n ÷ 2, n)]))
        local own = WasmTarget.compile(f, (Int64, Int64))
        local plain = WasmTarget.compile(f, (Int64, Int64); optimize = false)
        for a in argsets
            push!(cases, WTChild.RunCase("$(nameof(f))$a", plain, Int64.(a), WTChild.native_answer(f, Int64.(a)); optimized = own))
        end
    end
    @test I16[12000 ÷ 2] < 0   # a negative Int16 among the entries read
    local results = WTChild.run_cases(cases)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    @test length(results) == length(cases) && all(r -> r.ok, results)
    # the 46,592-entry UInt16 table is one data segment of its 93,184 bytes, little-endian, read by array.new_data
    local t = translated(u16)
    local seg = only(values(t.constants[]._byte_segments))
    local bytes = Vector{UInt8}(reinterpret(UInt8, htol.(U16)))
    @test length(bytes) == 93184 && seg.content == bytes
end
end
