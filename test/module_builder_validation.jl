using Test
using WasmTarget

const MBV = WasmTarget

@noinline _mbv_imported_measure() = Base.inferencebarrier(0.0)::Float64
_mbv_import_caller() = _mbv_imported_measure()
@noinline _mbv_imported_mix(x::Float64, n::Int64) =
    Base.inferencebarrier(x + Float64(n))::Float64
_mbv_import_mix_caller() = _mbv_imported_mix(2.5, Int64(4))
@noinline function _mbv_native_only_dependency(x::Int64)
    native_offset = ccall(:jl_get_field_offset, Csize_t, (Any, Cint), Int, 0)
    Base.donotdelete(native_offset)
    return x
end
@noinline _mbv_external_leaf(x::Int64) = _mbv_native_only_dependency(x)
_mbv_external_leaf_caller(x::Int64) = _mbv_external_leaf(x)
_mbv_unsigned_i128(x::Int128)::UInt128 = unsigned(x)

@testset "module builder rejects invalid modules at construction" begin
    @testset "start signature" begin
        m = MBV.WasmModule()
        good = MBV.add_function!(m, MBV.WasmValType[], MBV.WasmValType[], MBV.WasmValType[], UInt8[MBV.Opcode.END])
        MBV.add_start_function!(m, good)
        bad = MBV.add_function!(m, MBV.WasmValType[MBV.I32], MBV.WasmValType[], MBV.WasmValType[], UInt8[MBV.Opcode.END])
        @test_throws MBV.ModuleValidationError MBV.add_start_function!(m, bad)
        @test_throws MBV.ModuleValidationError MBV.add_start_function!(m, 99)
    end

    @testset "indices and limits" begin
        m = MBV.WasmModule()
        @test_throws MBV.ModuleValidationError MBV.add_export!(m, "missing", 0, 0)
        @test_throws MBV.ModuleValidationError MBV.add_export!(m, "bad-kind", 4, 0)
        f = MBV.add_function!(m, MBV.WasmValType[], MBV.WasmValType[], MBV.WasmValType[], UInt8[MBV.Opcode.END])
        MBV.add_export!(m, "f", 0, f)
        @test_throws MBV.ModuleValidationError MBV.add_export!(m, "f", 0, f)
        @test_throws MBV.ModuleValidationError MBV.add_table!(m, MBV.FuncRef, 2, 1)
        @test_throws MBV.ModuleValidationError MBV.add_memory!(m, 2, 1)
        @test_throws MBV.ModuleValidationError MBV.add_elem_segment!(m, 0, 0, Int[])
        @test_throws MBV.ModuleValidationError MBV.add_data_segment!(m, 0, 0, UInt8[])
        @test_throws MBV.ModuleValidationError MBV.declare_funcs!(m, UInt32[1])
    end

    @testset "tags and recursive groups" begin
        m = MBV.WasmModule()
        structidx = MBV.add_struct_type!(m, MBV.FieldType[])
        result_ft = MBV.add_type!(m, MBV.FuncType(MBV.WasmValType[], MBV.WasmValType[MBV.I32]))
        tag_ft = MBV.add_type!(m, MBV.FuncType(MBV.WasmValType[MBV.AnyRef], MBV.WasmValType[]))
        @test_throws MBV.ModuleValidationError MBV.add_tag!(m, structidx)
        @test_throws MBV.ModuleValidationError MBV.add_tag!(m, result_ft)
        @test MBV.add_tag!(m, tag_ft) == 0
        @test_throws MBV.ModuleValidationError MBV.add_rec_group!(m, UInt32[structidx, structidx])
        @test_throws MBV.ModuleValidationError MBV.add_rec_group!(m, UInt32[99])
        @test_throws MBV.ModuleValidationError MBV.add_rec_group!(m, UInt32[tag_ft, result_ft])
        late = MBV.add_struct_type!(m, MBV.FieldType[])
        @test_throws MBV.ModuleValidationError MBV.add_rec_group!(m, UInt32[structidx, late])
    end

    @testset "GC struct subtype prefix" begin
        m = MBV.WasmModule()
        base = MBV.add_type!(m, MBV.StructType([MBV.FieldType(MBV.I32, false)]))
        @test_throws MBV.ModuleValidationError MBV.add_type!(m, MBV.StructType(MBV.FieldType[], base))
        @test_throws MBV.ModuleValidationError MBV.add_type!(m,
            MBV.StructType([MBV.FieldType(MBV.I64, false)], base))
        @test_throws MBV.ModuleValidationError MBV.add_type!(m,
            MBV.StructType([MBV.FieldType(MBV.I32, true)], base))
        sub = MBV.add_type!(m, MBV.StructType([
            MBV.FieldType(MBV.I32, false), MBV.FieldType(MBV.I64, true)], base))
        @test sub == 1
    end

    @testset "calls derive imported signatures from the module" begin
        m = MBV.WasmModule()
        imported = MBV.add_import!(m, "host", "measure", MBV.WasmValType[],
                                   MBV.WasmValType[MBV.F64])
        b = MBV.InstrBuilder(MBV.WasmValType[], MBV.WasmValType[MBV.F64]; mod=m)
        # A call site cannot erase or misstate an import result: the module's
        # declared function type is the sole stack contract.
        MBV.call!(b, imported, MBV.WasmValType[], MBV.WasmValType[])
        MBV.finish_function!(b)
        @test MBV.builder_code(b) == UInt8[MBV.Opcode.CALL, 0x00, MBV.Opcode.END]

        host = MBV.WasmModule()
        host_idx = MBV.add_import!(host, "host", "measure", MBV.WasmValType[],
                                   MBV.WasmValType[MBV.F64])
        bytes = MBV.compile_multi(Any[(_mbv_import_caller, (), "caller")];
            existing_module=host,
            import_stubs=Any[(_mbv_imported_measure, "measure", (), host_idx, Float64)],
            validate=false)
        @test bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]

        mixed = MBV.WasmModule()
        mixed_idx = MBV.add_import!(mixed, "host", "mix",
            MBV.WasmValType[MBV.F64, MBV.I64], MBV.WasmValType[MBV.F64])
        mixed_bytes = MBV.compile_multi(Any[(_mbv_import_mix_caller, (), "mix_caller")];
            existing_module=mixed,
            import_stubs=Any[(_mbv_imported_mix, "mix", (Float64, Int64),
                              mixed_idx, Float64)],
            validate=false)
        @test mixed_bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]

        leafmod = MBV.WasmModule()
        leafidx = MBV.add_import!(leafmod, "host", "external_leaf",
            MBV.WasmValType[MBV.I64], MBV.WasmValType[MBV.I64])
        leafbytes = MBV.compile_multi(
            Any[(_mbv_external_leaf_caller, (Int64,), "leaf_caller")];
            existing_module=leafmod,
            import_stubs=Any[(_mbv_external_leaf, "external_leaf", (Int64,),
                              leafidx, Int64)],
            validate=false)
        @test leafbytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
    end

    @testset "signed-width unsigned overlays stay inside the closed world" begin
        plan, cache = MBV.trim_compile_plan(
            Any[(_mbv_unsigned_i128, (Int128,), "unsigned_i128")])
        @test !any(e -> e[1] === unsigned && e[2] == (Int128,) &&
                       any(stmt -> stmt isa Expr && stmt.head === :foreigncall,
                           cache[(e[1], e[2])][1].code), plan)
        bytes = MBV.compile_multi(Any[(_mbv_unsigned_i128, (Int128,), "unsigned_i128")];
                                  validate=false)
        @test bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
    end

    @testset "symbolic control labels" begin
        b = MBV.InstrBuilder()
        done = MBV.block!(b)
        again = MBV.loop!(b)
        @test done isa MBV.ControlLabel
        @test again isa MBV.ControlLabel
        MBV.i32_const!(b, 0)
        MBV.br_if!(b, done)
        # The public builder API cannot accept a fabricated numeric depth.
        @test_throws MethodError MBV.br!(b, 0)
        MBV.br!(b, again)
        MBV.end_block!(b)
        MBV.end_block!(b)
        MBV.finish_function!(b)

        closed = MBV.InstrBuilder()
        stale = MBV.block!(closed)
        MBV.end_block!(closed)
        @test_throws ArgumentError MBV.br!(closed, stale)

        m = MBV.WasmModule()
        tag_type = MBV.add_type!(m, MBV.FuncType(
            MBV.WasmValType[MBV.AnyRef, MBV.ExternRef], MBV.WasmValType[]))
        tag = MBV.add_tag!(m, tag_type)
        catches = MBV.InstrBuilder(; mod=m)
        landing = MBV.block!(catches; results=MBV.WasmValType[MBV.AnyRef, MBV.ExternRef])
        MBV.try_table!(catches, [MBV.catch_clause(tag, landing)])
        MBV.end_block!(catches)
        MBV.unreachable!(catches)
        MBV.end_block!(catches)
        MBV.drop!(catches)
        MBV.drop!(catches)
        MBV.finish_function!(catches)

        bad_catch = MBV.InstrBuilder(; mod=m)
        wrong = MBV.block!(bad_catch; results=MBV.WasmValType[MBV.I32])
        @test_throws MBV.StackImbalanceError MBV.try_table!(
            bad_catch, [MBV.catch_clause(tag, wrong)])
    end
end
