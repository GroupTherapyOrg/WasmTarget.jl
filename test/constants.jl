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
    local n0 = D._ConstantAccessor__next_global_id[]
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
