# dart2wasm's code_generator.dart from getLambdaCodeGenerator (:3502) on, ported (src/code_generator.jl):
# the code generators of tear-offs, forwarders, constructors, fields and lambdas, and the helpers of
# the switch, try and call statements. Each case is a located rejection of its kind, or a module run
# against native Julia (test/runner.jl).

module CodeGeneratorSubTest

using Test
using WasmTarget

const W = WasmTarget
const D = WasmTarget.Dart2Wasm
const B = WasmTarget.WasmBuilder
const IR = WasmTarget.WasmBuilder.IR

isdefined(Main, :WTRunner) || Base.include(Main, joinpath(@__DIR__, "..", "runner.jl"))
const WTRunner = Main.WTRunner

# the rejection `f()` raises, or nothing
rejection(f) = try; f(); nothing; catch e; e isa W.RejectionError ? e : rethrow(); end

# node runs each case's module on its arguments, in one run: whether every answer is native Julia's
function answers_native(cases::Vector{WTRunner.RunCase})
    local results = WTRunner.run_cases(cases)
    foreach(r -> r.ok || println(r.label, ": ", r.why), results)
    return all(r -> r.ok, results)
end

@testset "code_generator.dart: BrTableInfo" begin
    local none = Dict{Int64,D.NoCounterpart}()
    local push = _ -> nothing
    # a table is too sparse past 50 entries under half occupied; up to 50 it is always taken
    @test D.BrTableInfo_build(none, push; min_value = 0, max_value = 49) isa D.BrTableInfo
    @test D.BrTableInfo_build(none, push; min_value = -10, max_value = 40) === nothing
    @test D.range_size(D.BrTableInfo_build(none, push; min_value = -3, max_value = 4)) == 8
    # the private constructor's assert: a sparse table is WasmTarget's own defect, located
    local e = rejection(() -> D.BrTableInfo__(0, 100, none, push))
    @test e.rejection isa W.Internal && occursin("BrTableInfo._", e.rejection.site)
    # the table's index, the switched i64 normalized on min and wrapped to i32, selects the case by a
    # br_table (emitDenseTableBranch); a value outside min..max takes the default; one node run
    local cases = WTRunner.RunCase[]
    for (lo, hi) in ((0, 5), (-3, 4), (7, 12))
        local mb = B.ModuleBuilder("m", nothing)
        local fb = B.define(mb.functions[], B.define_function(mb.types[], IR.ValueType[IR.NumType_i64], IR.ValueType[IR.NumType_i32]), "f")
        local b = B.body(fb)
        local x = B.locals(fb)[1]
        local table = D.BrTableInfo_build(none, l -> B.local_get(b, l); min_value = lo, max_value = hi)
        D.emit_dense_table_branch(b, IR.ValueType[IR.NumType_i32], D.range_size(table),
            () -> D.emit_br_table_expr(table, b, x), i -> B.i32_const(b, i), () -> B.i32_const(b, -1))
        B.var"end"(b)
        B.var"export"(mb.exports, "f", fb)
        local s = B.Serializer(); B.serialize(s, B.build(mb))
        append!(cases, [WTRunner.RunCase("br_table $lo..$hi ($v)", B.data(s), (Int64(v),), lo <= v <= hi ? Int32(v - lo) : Int32(-1)) for v in -6:15])
    end
    @test answers_native(cases)
end


# a program whose closed world holds DataType, the class of a closure's runtime type
is_int(r::Base.RefValue{Any}) = r[] isa Int64

@testset "code_generator.dart: MacroAssembler's closure accessors type as dart documents them" begin
    local t = D.Translator(W.check_subset(is_int, (Base.RefValue{Any},), "code_generator_sub"),
        D.build_module_output_data(D.DefaultModuleStrategy(D.WasmCompilerOptions_default_options())), D.TranslatorOptions())
    D._init_modules(t, nothing)
    collect(t.closure_layouter[]); collect(t.class_info_collector[])
    local layouter = t.closure_layouter[]
    local closure = IR.RefType(layouter.closure_base_struct[]; nullable = false)
    # each accessor's documented signature `[ref _Closure] -> [output]`: the builder, which refuses
    # invalid wasm at the emitting instruction (D10), takes its result as the function's output
    local mb = D.main_module(t)
    for (emit, output) in ((D.emit_instantiation_closure_check, IR.NumType_i32),
                           (D.emit_get_instantiated_closure, layouter.instantiation_context_base_struct[].fields[D.FieldIndex_instantiation_context_inner() + 1].type),
                           (D.emit_tear_off_check, IR.NumType_i32),
                           (D.emit_get_tear_off_receiver, t.top_type_non_nullable[]),
                           (D.emit_get_closure_vtable, layouter.closure_base_struct[].fields[D.FieldIndex_closure_vtable() + 1].type))
        local fb = B.define(mb.functions[], B.define_function(mb.types[], IR.ValueType[closure], IR.ValueType[B.unpacked(output)]), string(emit))
        local b = B.body(fb)
        B.local_get(b, B.locals(fb)[1])
        emit(b, t)
        @test B.var"end"(b) === nothing
    end
end

end
