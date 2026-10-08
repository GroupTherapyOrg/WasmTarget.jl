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
function _mbv_signal_closures()
    state = Ref{Int64}(0)
    getter = () -> state[]
    setter = x -> (state[] = x)
    handler = () -> setter(getter() + Int64(1))
    return getter, setter, handler
end
function _mbv_constant_closure()
    offset = Int64(7)
    return (x::Int64) -> x + offset
end
Base.@noinline _mbv_root_link_leaf(x::Int64) = x + Int64(1)
_mbv_root_link_caller(x::Int64) = _mbv_root_link_leaf(x)
_mbv_void_numeric_root(x::Int64) = x + Int64(1)
_mbv_string_init() = "framework-seed"
Base.@noinline _mbv_io_receiver_print(io::IOBuffer, c::Char) = (print(io, '\\', c); nothing)

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
        # a type refers only to types defined before it, or to its own group
        nxt = UInt32(length(m.types))
        @test_throws MBV.ModuleValidationError MBV.add_type!(m,
            MBV.StructType([MBV.FieldType(MBV.ConcreteRef(nxt, true), true)]))
        @test_throws MBV.ModuleValidationError MBV.add_type!(m, MBV.ArrayType(MBV.ConcreteRef(UInt32(99), true)))
        # two types that refer to each other are one group, at consecutive indices
        a = MBV.StructType([MBV.FieldType(MBV.ConcreteRef(nxt + UInt32(1), true), true)])
        b = MBV.StructType([MBV.FieldType(MBV.ConcreteRef(nxt, true), true)])
        @test MBV.add_type_group!(m, MBV.CompositeType[a, b]) == nxt
        @test (Int(nxt):Int(nxt) + 1) in MBV.recursion_groups(m)
        @test_throws MBV.ModuleValidationError MBV.add_type_group!(m,
            MBV.CompositeType[MBV.StructType([MBV.FieldType(MBV.ConcreteRef(UInt32(99), true), true)])])
        # a recursion group's members are one strongly connected component (dev/AUDIT.md A7B1:
        # a struct{} added as a group's member and again alone got two indices for one type)
        @test_throws MBV.ModuleValidationError MBV.add_type_group!(m, MBV.CompositeType[
            MBV.StructType(MBV.FieldType[]),
            MBV.StructType([MBV.FieldType(MBV.ConcreteRef(UInt32(length(m.types)), true), true)])])
        # a packed array's element is read signed or unsigned, never plainly (dev/AUDIT.md A9B3:
        # a plain array.get of an i8 array made a module the engine refused)
        let pm = MBV.WasmModule()
            local i8arr = MBV.add_type!(pm, MBV.ArrayType(MBV.FieldType(0x78, true)))
            local i64arr = MBV.add_type!(pm, MBV.ArrayType(MBV.FieldType(MBV.I64, true)))
            @test_throws MBV.ModuleValidationError MBV.array_get!(MBV.InstrBuilder(; mod=pm), i8arr, MBV.I32)
            @test_throws MBV.ModuleValidationError MBV.array_get!(MBV.InstrBuilder(; mod=pm), i64arr, MBV.I64; signed=true)
            # a packed struct field is never read by struct.get (A11B9: dart asserts a value type)
            local i8st = MBV.add_type!(pm, MBV.StructType([MBV.FieldType(0x78, false)]))
            @test_throws MBV.ModuleValidationError MBV.struct_get!(MBV.InstrBuilder(; mod=pm), i8st, 0, MBV.I32)
        end
        # the writer checks the groups the builder recorded against the section's components
        # (dev/AUDIT.md A8B4: a record that disagrees is refused when the module is written)
        let w = MBV.WasmModule()
            MBV.add_type!(w, MBV.StructType(MBV.FieldType[]))
            MBV.add_type!(w, MBV.StructType([MBV.FieldType(MBV.I64, true)]))
            @test length(MBV.to_bytes(w)) > 0
            w.type_groups = UnitRange{Int}[0:1]          # one group recorded where there are two
            @test_throws MBV.ModuleValidationError MBV.to_bytes(w)
        end
        # formal(dev/formal/TypeIdentity.tla): a group equal to one in the section is that group
        # (wasm canonicalizes iso-recursive groups, so two indices would be one runtime type)
        local selfref(i, extra...) = MBV.StructType([MBV.FieldType(MBV.ConcreteRef(UInt32(i), true), true), extra...])
        local la_at = UInt32(length(m.types))
        @test MBV.add_type_group!(m, MBV.CompositeType[selfref(la_at, MBV.FieldType(MBV.I64, true))]) == la_at
        local lb_at = UInt32(length(m.types))
        @test MBV.add_type_group!(m, MBV.CompositeType[selfref(lb_at, MBV.FieldType(MBV.I64, true))]) == la_at
        @test length(m.types) == lb_at                       # nothing added
        # a lone type whose fields read like LA's (a reference to LA, an i64) is not LA: LA's
        # reference is inside its group (dev/formal/TypeIdentity.tla AnyMemberEqual)
        local w_at = MBV.add_type!(m, MBV.StructType([MBV.FieldType(MBV.ConcreteRef(la_at, true), true), MBV.FieldType(MBV.I64, true)]))
        @test w_at != la_at
        @test MBV.add_type!(m, MBV.StructType([MBV.FieldType(MBV.ConcreteRef(la_at, true), true), MBV.FieldType(MBV.I64, true)])) == w_at
        lb_at = UInt32(length(m.types))
        # another field: another type
        @test MBV.add_type_group!(m, MBV.CompositeType[selfref(lb_at, MBV.FieldType(MBV.I32, true))]) == lb_at
        # an outside reference into the equal group's range is not an inside reference
        local lc_at = UInt32(length(m.types))
        @test MBV.add_type_group!(m, MBV.CompositeType[MBV.StructType([MBV.FieldType(MBV.ConcreteRef(UInt32(length(m.types)), true), true),
                                                                     MBV.FieldType(MBV.ConcreteRef(UInt32(length(m.types)), true), true)])]) == lc_at
        local ld_at = UInt32(length(m.types))
        @test MBV.add_type_group!(m, MBV.CompositeType[MBV.StructType([MBV.FieldType(MBV.ConcreteRef(lc_at, true), true),
                                                                     MBV.FieldType(MBV.ConcreteRef(ld_at, true), true)])]) == ld_at
        # a section whose cycle is split by another type, or that refers forward outside a
        # cycle, has no valid recursion groups
        split = MBV.WasmModule()
        push!(split.types, MBV.StructType([MBV.FieldType(MBV.ConcreteRef(UInt32(2), true), true)]),
              MBV.StructType(MBV.FieldType[]),
              MBV.StructType([MBV.FieldType(MBV.ConcreteRef(UInt32(0), true), true)]))
        @test_throws MBV.ModuleValidationError MBV.recursion_groups(split)
        fwd = MBV.WasmModule()
        push!(fwd.types, MBV.StructType([MBV.FieldType(MBV.ConcreteRef(UInt32(1), true), true)]),
              MBV.StructType(MBV.FieldType[]))
        @test_throws MBV.ModuleValidationError MBV.recursion_groups(fwd)
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

    @testset "type definitions carry dart's subtyping prefix (DefType.serializeDefinition)" begin
        m = MBV.WasmModule()
        a = MBV.add_type!(m, MBV.StructType([MBV.FieldType(MBV.I32, false)]))
        MBV.add_type!(m, MBV.StructType([MBV.FieldType(MBV.I32, false), MBV.FieldType(MBV.I64, true)], a))
        MBV.add_type!(m, MBV.StructType([MBV.FieldType(MBV.I64, false)]))
        MBV.add_type!(m, MBV.ArrayType(MBV.FieldType(MBV.I32, true)))
        bytes = MBV.to_bytes(m)
        entries = UInt8[0x04,                                     # four singleton groups
                        0x50, 0x00, 0x5F, 0x01, 0x7F, 0x00,       # a parent: `sub`, no supertypes
                        0x4F, 0x01, 0x00, 0x5F, 0x02, 0x7F, 0x00, 0x7E, 0x01,  # a leaf: `sub final` a
                        0x5F, 0x01, 0x7E, 0x00,                   # no relatives: no prefix (final)
                        0x5E, 0x7F, 0x01]                         # an array: no prefix
        @test any(i -> bytes[i:i + length(entries) - 1] == entries, 1:length(bytes) - length(entries) + 1)
    end

    @testset "a branch carries its target label's types (dart _verifyBranchTypes)" begin
        m = MBV.WasmModule()
        s1 = MBV.add_type!(m, MBV.StructType([MBV.FieldType(MBV.I32, false)]))
        s2 = MBV.add_type!(m, MBV.StructType([MBV.FieldType(MBV.I64, false)]))
        r1, r2 = MBV.ConcreteRef(s1, true), MBV.ConcreteRef(s2, true)
        mk() = MBV.InstrBuilder(MBV.WasmValType[r1, r2], MBV.WasmValType[]; func_name = "branch", mod = m)
        # br_on_non_null carries its operand made non-null
        b = mk(); l = MBV.block!(b; results=MBV.WasmValType[MBV.ConcreteRef(s1, false)])
        MBV.local_get!(b, 0)
        @test MBV.br_on_non_null!(b, l) isa MBV.InstrBuilder
        b = mk(); l = MBV.block!(b; results=MBV.WasmValType[MBV.ConcreteRef(s1, false)])
        MBV.local_get!(b, 1)
        @test_throws MBV.StackImbalanceError MBV.br_on_non_null!(b, l)
        # br_on_null carries what lies under its operand
        b = mk(); l = MBV.block!(b; results=MBV.WasmValType[r1])
        MBV.local_get!(b, 0); MBV.local_get!(b, 1)
        @test MBV.br_on_null!(b, l) isa MBV.InstrBuilder
        b = mk(); l = MBV.block!(b; results=MBV.WasmValType[r1])
        MBV.local_get!(b, 1); MBV.local_get!(b, 1)
        @test_throws MBV.StackImbalanceError MBV.br_on_null!(b, l)
        # br and br_if carry the top of the stack to their target through the same check
        # (dart br / br_if → _verifyBranchTypes); a wrong-typed value is rejected at the branch
        b = mk(); l = MBV.block!(b; results=MBV.WasmValType[r1])
        MBV.local_get!(b, 0)
        @test MBV.br!(b, l) isa MBV.InstrBuilder
        b = mk(); l = MBV.block!(b; results=MBV.WasmValType[r1])
        MBV.local_get!(b, 1)
        @test_throws MBV.StackImbalanceError MBV.br!(b, l)
        b = mk(); l = MBV.block!(b; results=MBV.WasmValType[r1])
        MBV.local_get!(b, 1); MBV.i32_const!(b, 1)
        @test_throws MBV.StackImbalanceError MBV.br_if!(b, l)
        # the operand is a reference
        b = mk(); l = MBV.block!(b)
        MBV.i32_const!(b, 1)
        @test_throws MBV.StackImbalanceError MBV.br_on_null!(b, l)
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
        plan = MBV.trim_compile_plan(
            Any[(_mbv_unsigned_i128, (Int128,), "unsigned_i128")])
        @test !any(e -> e[1] === unsigned && e[2] == (Int128,) &&
                       any(stmt -> stmt isa Expr && stmt.head === :foreigncall,
                           plan.ir_cache[(e[1], e[2])][1].code), plan.functions)
        bytes = MBV.compile_multi(Any[(_mbv_unsigned_i128, (Int128,), "unsigned_i128")];
                                  validate=false)
        @test bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
    end

    @testset "singleton Type arguments are exact closed-world values" begin
        @test MBV._closed_world_exact_type(Int64)
        @test MBV._closed_world_exact_type(Type{Float64})
        @test !MBV._closed_world_exact_type(Type)
        @test !MBV._closed_world_exact_type(Function)
        @test MBV._canonical_type_object_arg(Type{Int64}, DataType) === DataType
        @test MBV._canonical_type_object_arg(Type{Float64}, Any) === Type{Float64}
        @test MBV._canonical_type_object_arg(Type{Float64}, Type) === Type{Float64}
    end

    @testset "Binaryen Windows scheduling is bounded" begin
        @test MBV._binaryen_worker_count(true) == "1"
        @test MBV._binaryen_worker_count(false) === nothing
    end

    @testset "the exception stack's top is found by its name, never by its type" begin
        # a framework's own mutable anyref global was once taken for WT's exception global
        # (the first mutable anyref global), so every throw wrote into it (dev/AUDIT.md N1)
        m = MBV.WasmModule()
        theirs = MBV.add_global!(m, MBV.AnyRef, true, nothing)
        top = MBV.ensure_exception_top_global!(m)
        @test top != theirs && m.globals[Int(top) + 1].name == "\$exc_top"
        @test MBV.ensure_exception_top_global!(m) == top
        @test m.globals[Int(top) + 1].valtype == MBV.ConcreteRef(MBV.exc_cell_type!(m), true)
        @test_throws MBV.ModuleValidationError MBV.add_global!(m, MBV.AnyRef, true, nothing; name="\$exc_top")
        # a typed null reference global names a type the module defines
        @test_throws MBV.ModuleValidationError MBV.add_global!(m, MBV.ConcreteRef(UInt32(999), true), true, nothing)
    end

    @testset "explicit IO formatting does not activate host-console imports" begin
        # `print(io, ...)` is an ordinary compiled formatting call: Julia's own body
        # compiles and the module declares no host-console import — only the runtime import
        # every module has
        compiled = MBV.compile_module(Any[(_mbv_io_receiver_print, (IOBuffer, Char), "p")])
        @test [(i.module_name, i.field_name) for i in compiled.imports] == [("wasmtarget", "stack_trace")]
    end

    @testset "closure roots use declared global substitutions" begin
        getter, setter, handler = _mbv_signal_closures()
        captured = Dict{Symbol,Tuple{Bool,UInt32}}()
        for field in fieldnames(typeof(handler))
            value = getfield(handler, field)
            value === getter && (captured[field] = (true, UInt32(0)))
            value === setter && (captured[field] = (false, UInt32(0)))
        end
        @test length(captured) == 2
        m = MBV.WasmModule()
        MBV.add_global!(m, MBV.I64, true, Int64(0))
        bindings = MBV.RootBindings(captured_globals=captured,
                                    bound_leaves=[(getter, ()),
                                                  (setter, (Int64,))],
                                    elide_closure_context=true,
                                    void_return=true)
        compiled = MBV.compile_module(Any[(handler, (), "handler")];
            existing_module=m, root_bindings=Dict("handler" => bindings))
        exported = only(e for e in compiled.exports if e.name == "handler")
        nimports = MBV.num_imported_funcs(compiled)
        fn = compiled.functions[Int(exported.idx) - nimports + 1]
        ft = compiled.types[Int(fn.type_idx) + 1]
        @test isempty(ft.params)
        @test isempty(ft.results)
        void_module = MBV.compile_module(Any[(_mbv_void_numeric_root, (Int64,), "void_numeric")];
            root_bindings=Dict("void_numeric" => MBV.RootBindings(void_return=true)))
        mktempdir() do dir
            wasm = joinpath(dir, "void-root.wasm")
            write(wasm, MBV.to_bytes(void_module))
            probe = "WebAssembly.instantiate(require('fs').readFileSync(process.argv[1]), $(WasmTarget.host_runtime_js())).then(m=>m.instance.exports.void_numeric(1n)).catch(e=>{console.error(e);process.exit(1)})"
            proc = run(ignorestatus(`node -e $probe $wasm`))
            @test proc.exitcode == 0
        end

        partial = MBV.RootBindings(captured_globals=Dict([first(captured)]),
                                   elide_closure_context=true)
        @test_throws ArgumentError MBV.compile_module(Any[(handler, (), "bad")];
            root_bindings=Dict("bad" => partial))
        missing_global = MBV.RootBindings(
            captured_globals=Dict(k => (v[1], UInt32(99)) for (k, v) in captured),
            elide_closure_context=true)
        @test_throws ArgumentError MBV.compile_module(Any[(handler, (), "bad_global")];
            root_bindings=Dict("bad_global" => missing_global))
        @test_throws ArgumentError MBV.compile_module(Any[(handler, (), "known")];
            root_bindings=Dict("unknown" => bindings))

        constant_root = _mbv_constant_closure()
        constant_bindings = MBV.RootBindings(
            captured_constants=Dict(:offset => Int64(7)),
            elide_closure_context=true)
        constant_bytes = MBV.compile_multi(
            Any[(constant_root, (Int64,), "constant_root")];
            root_bindings=Dict("constant_root" => constant_bindings))
        @test constant_bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]

        duplicate = MBV.RootBindings(
            captured_globals=Dict(:offset => (true, UInt32(0))),
            captured_constants=Dict(:offset => Int64(7)),
            elide_closure_context=true)
        @test_throws ArgumentError MBV.compile_module(
            Any[(constant_root, (Int64,), "duplicate")];
            existing_module=m, root_bindings=Dict("duplicate" => duplicate))

        leaf, caller = _mbv_root_link_leaf, _mbv_root_link_caller
        ci = only(Base.code_typed(caller, (Int64,)))[1]
        invoke_site = findfirst(stmt -> stmt isa Expr && stmt.head === :invoke &&
            ((stmt.args[1] isa Core.MethodInstance &&
              stmt.args[1].def.name === :_mbv_root_link_leaf) ||
             (stmt.args[1] isa Core.CodeInstance &&
              stmt.args[1].def.def.name === :_mbv_root_link_leaf)), ci.code)
        invoke_site === nothing && error("root-link fixture lost its linked invoke")
        linked = MBV.RootBindings(
            invoke_roots=Dict(invoke_site => "leaf"),
        )
        linked_bytes = MBV.compile_multi(Any[
            (leaf, (Int64,), "leaf"), (caller, (Int64,), "caller")];
            root_bindings=Dict("caller" => linked))
        @test linked_bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]

        # a framework's module declares WT's runtime imports before its own definitions
        late = MBV.WasmModule()
        MBV.add_function!(late, MBV.WasmValType[], MBV.WasmValType[], MBV.WasmValType[], UInt8[MBV.Opcode.END])
        @test_throws ArgumentError MBV.compile_multi(Any[(constant_root, (Int64,), "late")];
            existing_module=late, root_bindings=Dict("late" => constant_bindings))
        entry_module = MBV.WasmModule()
        MBV.ensure_provenance_imports!(entry_module)
        entry_idx = MBV.add_function!(entry_module, MBV.WasmValType[],
            MBV.WasmValType[], MBV.WasmValType[], UInt8[MBV.Opcode.END])
        with_entry = MBV.RootBindings(
            captured_constants=Dict(:offset => Int64(7)),
            entry_calls=UInt32[entry_idx], elide_closure_context=true)
        entry_bytes = MBV.compile_multi(
            Any[(constant_root, (Int64,), "entry_root")];
            existing_module=entry_module,
            root_bindings=Dict("entry_root" => with_entry))
        @test entry_bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]

        linked_indices = Ref{Dict{String,UInt32}}()
        linker_bytes = MBV.compile_multi(Any[
            (leaf, (Int64,), "linked_leaf"), (caller, (Int64,), "linked_caller")];
            link_roots=(linked_mod, roots, registry) -> begin
                linked_indices[] = copy(roots)
                @test registry isa MBV.TypeRegistry
                @test linked_mod isa MBV.WasmModule
            end)
        @test Set(keys(linked_indices[])) == Set(["linked_leaf", "linked_caller"])
        @test linker_bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]

        initialized_global = Ref{UInt32}()
        init_bytes = MBV.compile_multi(Any[(_mbv_string_init, (), "string_init")];
            link_roots=(linked_mod, roots, registry) -> begin
                string_type = MBV.get_string_struct_type!(linked_mod, registry)
                initialized_global[] = MBV.add_uninitialized_ref_global!(
                    linked_mod, string_type)
                MBV.add_root_global_initializer!(linked_mod, registry,
                    initialized_global[], roots["string_init"])
                eager = MBV.add_string_global!(linked_mod, registry, "eager")
                MBV.add_global_export!(linked_mod, "eager_string", eager)
            end)
        @test init_bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
        # an import from the linker would renumber the defined functions: the builder refuses it
        @test_throws MBV.ModuleValidationError MBV.compile_multi(
            Any[(leaf, (Int64,), "bad_linker")];
            link_roots=(linked_mod, _, _) -> MBV.add_import!(linked_mod,
                "late", "forbidden", MBV.WasmValType[], MBV.WasmValType[]))

        unknown_link = MBV.RootBindings(invoke_roots=Dict(invoke_site => "missing"))
        @test_throws ArgumentError MBV.compile_module(
            Any[(caller, (Int64,), "caller")];
            root_bindings=Dict("caller" => unknown_link))
        bad_entry = MBV.RootBindings(entry_calls=UInt32[99])
        @test_throws ArgumentError MBV.compile_module(
            Any[(_mbv_unsigned_i128, (Int128,), "bad_entry")];
            root_bindings=Dict("bad_entry" => bad_entry))
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

    @testset "throw_ref takes an exnref; a catch_all_ref's target takes exactly one (dart throw_ref, CatchAllRef)" begin
        # instructions.dart:836 throw_ref and :153 CatchAllRef; the spec types throw_ref's
        # operand as exnref and a catch's target as exactly what it catches (dart checks a suffix)
        m = MBV.WasmModule()
        b = MBV.InstrBuilder(; mod=m); MBV.ref_null!(b, MBV.AnyRef)
        @test_throws MBV.StackImbalanceError MBV.throw_ref!(b)
        b = MBV.InstrBuilder(; mod=m)
        none = MBV.block!(b)
        @test_throws MBV.StackImbalanceError MBV.try_table!(b, [MBV.catch_all_ref_clause(none)])
        # the export entry's shape: block (result exnref), a result-less try_table, throw_ref
        b = MBV.InstrBuilder(; mod=m)
        escaped = MBV.block!(b; results=MBV.WasmValType[MBV.ExnRef])
        MBV.try_table!(b, [MBV.catch_all_ref_clause(escaped)])
        MBV.end_block!(b)
        MBV.return_!(b)
        MBV.end_block!(b)
        @test MBV.throw_ref!(b) isa MBV.InstrBuilder
        MBV.finish_function!(b)
        @test b.instrs[2].catches == [MBV.InstrIR.TryCatch(MBV.Opcode.CATCH_ALL_REF, 0xffffffff, 0)]
        @test count(i -> i isa MBV.InstrIR.ThrowRef, b.instrs) == 1
    end

    @testset "a frame's encoded block type is derived from its signature (dart _beginBlock)" begin
        # A caller names only the frame's inputs and results and the builder derives the
        # encoding (instructions.dart:707), so the encoded type and the tracked frame are one
        # fact. A positional block type once let `try_table!(b, cs, I32)` track a void frame
        # and encode a result (dev/AUDIT.md B2).
        m = MBV.WasmModule()
        mk() = (b = MBV.InstrBuilder(MBV.WasmValType[MBV.I32], MBV.WasmValType[]; mod=m);
                MBV.local_get!(b, 0); b)
        enc(f) = (b = mk(); f(b); b.instrs[end].blocktype)
        @test enc(b -> MBV.if_!(b)) === 0x40
        @test enc(b -> MBV.if_!(b; results=MBV.WasmValType[MBV.I32])) === MBV.I32
        two = enc(b -> MBV.if_!(b; results=MBV.WasmValType[MBV.I32, MBV.I64]))
        @test two isa Int && m.types[two + 1].params == MBV.WasmValType[] &&
              m.types[two + 1].results == MBV.WasmValType[MBV.I32, MBV.I64]
        ins = enc(b -> MBV.block!(b; inputs=MBV.WasmValType[MBV.I32]))
        @test ins isa Int && m.types[ins + 1].params == MBV.WasmValType[MBV.I32] &&
              isempty(m.types[ins + 1].results)
        # no positional block type exists to disagree with the frame
        @test !hasmethod(MBV.if_!, Tuple{MBV.InstrBuilder, Any})
        @test !hasmethod(MBV.block!, Tuple{MBV.InstrBuilder, Any})
        @test !hasmethod(MBV.try_table!, Tuple{MBV.InstrBuilder, Vector, Any})
        ok = mk()
        MBV.if_!(ok; results=MBV.WasmValType[MBV.I32])
        MBV.i32_const!(ok, 1)
        MBV.else_!(ok)
        MBV.i32_const!(ok, 2)
        MBV.end_block!(ok)
        MBV.drop!(ok)
        MBV.finish_function!(ok)
        @test true
    end

    @testset "every operand is typed as dart types it (return, throw, globals, refs, select, else)" begin
        # each check below once took the operand untyped or the caller's claim (dev/AUDIT.md
        # A2B1, A2B4, A2B5, A2B7, B4): a wrong program reached the bytes and only the engine
        # or wasm-tools saw it
        m = MBV.WasmModule()
        g_mut = MBV.add_global!(m, MBV.I64, true, 0)
        g_imm = MBV.add_global!(m, MBV.I64, false, 0)
        arr = MBV.add_type!(m, MBV.ArrayType(MBV.FieldType(MBV.I32, true)))
        tag_t = MBV.add_type!(m, MBV.FuncType(MBV.WasmValType[MBV.I64], MBV.WasmValType[]))
        tag = MBV.add_tag!(m, tag_t)
        fn_t = MBV.add_type!(m, MBV.FuncType(MBV.WasmValType[MBV.I32], MBV.WasmValType[MBV.I32]))
        mk(ps=MBV.WasmValType[], rs=MBV.WasmValType[]) = MBV.InstrBuilder(ps, rs; mod=m)
        # return pops the function's results
        b = mk(MBV.WasmValType[], MBV.WasmValType[MBV.I64]); MBV.i32_const!(b, 1)
        @test_throws MBV.StackImbalanceError MBV.return_!(b)
        b = mk(MBV.WasmValType[], MBV.WasmValType[MBV.I64]); MBV.i64_const!(b, 1)
        @test MBV.return_!(b) isa MBV.InstrBuilder
        # throw takes its tag's inputs
        b = mk(); MBV.i32_const!(b, 1)
        @test_throws MBV.StackImbalanceError MBV.throw_!(b, tag)
        b = mk(); MBV.i64_const!(b, 1)
        @test MBV.throw_!(b, tag) isa MBV.InstrBuilder
        # global.set: a mutable global, and its own type
        b = mk(); MBV.i64_const!(b, 1)
        @test_throws MBV.ModuleValidationError MBV.global_set!(b, g_imm)
        b = mk(); MBV.i32_const!(b, 1)
        @test_throws MBV.StackImbalanceError MBV.global_set!(b, g_mut)
        # ref.is_null, array.len, select take the operands dart names
        b = mk(); MBV.i32_const!(b, 1)
        @test_throws MBV.StackImbalanceError MBV.ref_is_null!(b)
        b = mk(); MBV.i32_const!(b, 1)
        @test_throws MBV.StackImbalanceError MBV.array_len!(b)
        b = mk(); MBV.i64_const!(b, 1); MBV.i64_const!(b, 2); MBV.i32_const!(b, 1)
        @test_throws MBV.StackImbalanceError MBV.select!(b, MBV.I32)
        b = mk(); MBV.i64_const!(b, 1); MBV.i64_const!(b, 2); MBV.i32_const!(b, 1)
        @test MBV.select!(b, MBV.I64) isa MBV.InstrBuilder
        # call_ref's signature is its function type's
        b = mk(); MBV.i32_const!(b, 1); MBV.ref_null!(b, Int64(fn_t), MBV.ConcreteRef(UInt32(fn_t), true))
        @test_throws MBV.ModuleValidationError MBV.call_ref!(b, fn_t, MBV.WasmValType[MBV.I64], MBV.WasmValType[MBV.I32])
        # else gives its arm the if's inputs; an if with results needs an else
        b = mk(); MBV.i32_const!(b, 7); MBV.i32_const!(b, 1)
        MBV.if_!(b; inputs=MBV.WasmValType[MBV.I32], results=MBV.WasmValType[MBV.I32])
        MBV.else_!(b)
        @test MBV.end_block!(b) isa MBV.InstrBuilder      # both arms pass the input through
        b = mk(); MBV.i32_const!(b, 1)
        MBV.if_!(b; results=MBV.WasmValType[MBV.I32]); MBV.i32_const!(b, 2)
        @test_throws MBV.StackImbalanceError MBV.end_block!(b)
        # a field's storage type is a value type, never a raw byte standing for one
        @test_throws ArgumentError MBV.FieldType(0x70, false)
        @test MBV.FieldType(MBV.FuncRef, false).valtype === MBV.FuncRef
    end

    @testset "an if without else is typed by its implicit else: inputs that are subtypes of its results" begin
        # the spec types the implicit else [t1*] -> [t2*] as the empty sequence: valid iff the lengths
        # agree and each t1 <: t2 (A3B11; the equality rule rejected the first case)
        m = MBV.WasmModule()
        a = MBV.add_type!(m, MBV.StructType([MBV.FieldType(MBV.I32, false)]))
        nonnull, nullable = MBV.ConcreteRef(UInt32(a), false), MBV.ConcreteRef(UInt32(a), true)
        elseless(inputs, results) = (b = MBV.InstrBuilder(MBV.WasmValType[], MBV.WasmValType[]; mod=m);
            for t in inputs
                t === nonnull ? (MBV.i32_const!(b, 1); MBV.struct_new!(b, a)) : MBV.ref_null!(b, Int64(a), nullable)
            end;
            MBV.i32_const!(b, 1);
            MBV.if_!(b; inputs=MBV.WasmValType[inputs...], results=MBV.WasmValType[results...]);
            length(results) < length(inputs) && MBV.drop!(b);
            (results == [nonnull] && inputs == [nullable]) && MBV.ref_as_non_null!(b);
            b)
        rejection(b) = try; MBV.end_block!(b); ""; catch e; sprint(showerror, e); end
        # (i) a strict subtype passes through
        @test MBV.end_block!(elseless([nonnull], [nullable])) isa MBV.InstrBuilder
        # (ii) a supertype input does not: the implicit else would leave a nullable ref
        @test occursin("needs an else", rejection(elseless([nullable], [nonnull])))
        # (iii) unequal lengths
        @test occursin("needs an else", rejection(elseless([nullable], [])))
    end

    @testset "an if's then-branch is typed against the if's results at else" begin
        # dart else_ → _verifyEndOfBlock → _checkStackTypes(label.outputs): only the height was
        # checked, and a then-arm leaving a value of an unrelated type reached the module
        m = MBV.WasmModule()
        a = MBV.add_type!(m, MBV.StructType([MBV.FieldType(MBV.I32, false)]))
        c = MBV.add_type!(m, MBV.StructType([MBV.FieldType(MBV.I64, false)]))
        ra, rc = MBV.ConcreteRef(UInt32(a), true), MBV.ConcreteRef(UInt32(c), true)
        ok = MBV.InstrBuilder(MBV.WasmValType[MBV.I32], MBV.WasmValType[ra]; mod=m)
        MBV.local_get!(ok, 0)
        MBV.if_!(ok; results=MBV.WasmValType[ra])
        MBV.ref_null!(ok, Int64(a), ra)
        MBV.else_!(ok)
        MBV.ref_null!(ok, Int64(a), ra)
        MBV.end_block!(ok)
        MBV.finish_function!(ok)

        bad = MBV.InstrBuilder(MBV.WasmValType[MBV.I32], MBV.WasmValType[ra]; mod=m)
        MBV.local_get!(bad, 0)
        MBV.if_!(bad; results=MBV.WasmValType[ra])
        MBV.ref_null!(bad, Int64(c), rc)
        @test_throws MBV.StackImbalanceError MBV.else_!(bad)
    end
end
