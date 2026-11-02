# wasm_builder's barrel files (src/julia/exports.jl): each export directive is ported at its dart line,
# the names it shows are public, and dart2wasm's `w.` prefix reaches only what wasm_builder.dart
# exports, so a reference from Dart2Wasm to a name it hides, such as ir's Catch, refuses.

module BarrelExportsTest

using Test
using WasmTarget

const WT = WasmTarget
const W = WT.WasmBuilder
const I = W.IR

violation(f) = try
    f()
    ""
catch e
    e isa WT.ConstructionViolation ? e.what : rethrow()
end

@testset "wasm_builder's export directives" begin
    local sdk = WT._pin_sdk()
    @test sdk !== nothing
    if sdk !== nothing
        @testset "the names a directive shows are public" begin
            @test Base.ispublic(I, :RefType) && Base.ispublic(I, :Module)
            @test Base.ispublic(I, :Table) && Base.ispublic(I, :AbstractTable)    # dart's Table, both parts
            @test Base.ispublic(I, :I32Add) && Base.ispublic(I, :V128Instruction) # instruction.dart, all of it
            @test !Base.ispublic(I, :write_type_index)                            # an unnamed extension's member
            @test Base.ispublic(W, :TypeSection) && Base.ispublic(W, :Serializer) # sections.dart, serializer.dart
            @test Base.ispublic(W, :ModuleBuilder) && Base.ispublic(W, :Catch)    # the builder's Catch
            @test !Base.ispublic(W, :ActiveFunctionSegmentBuilder)                # builder.dart shows it not
        end

        local reach = WT.wasm_builder_reach(WT.visible_names(sdk, "wasm_builder/lib/wasm_builder.dart"))
        @testset "what `w.` reaches" begin
            @test (I, :RefType) in reach && (I, :RefType_def) in reach && (I, :NumType_i32) in reach
            @test (W, :Catch) in reach && (W, :define_struct) in reach && (W, :i32_add) in reach
            @test (W, :set_function_at) in reach      # an instance member of a class `w.` cannot name
            @test !((I, :Catch) in reach) && !((I, :TryTableCatch) in reach)   # hidden by wasm_builder.dart
            @test !((W, :ActiveFunctionSegmentBuilder) in reach)
        end

        @testset "a reference from Dart2Wasm to a name `w.` cannot reach refuses" begin
            local planted = Core.eval(WT.Dart2Wasm, :(_planted_ir_catch() = WasmBuilder.IR.Catch))
            local why = violation(() -> WT.check_wasm_builder_references(collect(methods(planted)), reach))
            @test occursin("refers to WasmTarget.WasmBuilder.IR.Catch, which wasm_builder.dart does not export", why)
            local typed = Core.eval(WT.Dart2Wasm, :(_planted_segment(s::WasmBuilder.ActiveFunctionSegmentBuilder) = nothing))
            @test occursin("WasmBuilder.ActiveFunctionSegmentBuilder", violation(() -> WT.check_wasm_builder_references(collect(methods(typed)), reach)))
            local fine = Core.eval(WT.Dart2Wasm, :(_planted_fine() = (WasmBuilder.IR.RefType_def, WasmBuilder.Catch, WasmBuilder.IR.I32Add)))
            @test WT.check_wasm_builder_references(collect(methods(fine)), reach) == 0
            @test WT.check_wasm_builder_references(WT._dart2wasm_methods(), reach) == 0
        end

        @testset "a directive ported unlike dart's refuses" begin
            local ir_jl = WT._jl_path("wasm_builder/lib/src/ir/ir.dart")
            push!(WT.DART_EXPORTS, (I, ir_jl, "type.dart", :show, [:RefType]))
            local why = try
                violation(() -> WT.check_dart_exports(sdk))
            finally
                pop!(WT.DART_EXPORTS)
            end
            @test occursin("@dart_export \"type.dart\" reads show RefType", why)
            @test WT.check_dart_exports(sdk) == 0
        end
    end
end

end # module BarrelExportsTest
