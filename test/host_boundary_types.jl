using Test
using WasmTarget

const HBT = WasmTarget

# ── fixtures ────────────────────────────────────────────────────────────────
# Same pattern as module_builder_validation.jl: @noinline + inferencebarrier
# keeps the stub's `:invoke` alive so the closed-world compiler's function
# registry can swap the call for the pre-declared import (WasmPlot/WasmMakie
# canvas-provider pattern; the real-world caller this validator protects).
@noinline function _hbt_stub(x::Int64, y::Float64, z::WasmTarget.JSValue)::Nothing
    Base.donotdelete(x, y, z)
    return nothing
end
_hbt_caller(x::Int64, y::Float64, z::WasmTarget.JSValue) = _hbt_stub(x, y, z)

@noinline function _hbt_void_stub()::Nothing
    return nothing
end
_hbt_void_caller() = _hbt_void_stub()

struct _HBTPoint
    x::Float64
    y::Float64
end
@noinline function _hbt_struct_stub(p::_HBTPoint)::Nothing
    Base.donotdelete(p)
    return nothing
end
_hbt_struct_caller(p::_HBTPoint) = _hbt_struct_stub(p)

@testset "host boundary type translator" begin

    @testset "translate_external_type — pure mapping (parity(translator.dart:1239))" begin
        m = HBT.WasmModule()
        r = HBT.TypeRegistry()
        # non-nullable primitive builtins map to the wasm numeric type, exactly
        # like dart's builtinTypes[cls] arm.
        @test HBT.translate_external_type(Int32, m, r) == HBT.I32
        @test HBT.translate_external_type(UInt32, m, r) == HBT.I32
        @test HBT.translate_external_type(Int64, m, r) == HBT.I64
        @test HBT.translate_external_type(UInt64, m, r) == HBT.I64
        @test HBT.translate_external_type(Float32, m, r) == HBT.F32
        @test HBT.translate_external_type(Float64, m, r) == HBT.F64
        @test HBT.translate_external_type(Bool, m, r) == HBT.I32
        @test HBT.translate_external_type(Int8, m, r) == HBT.I32
        @test HBT.translate_external_type(UInt16, m, r) == HBT.I32
        # WT's one Julia-level marker for an opaque host reference — dart's
        # `cls == wasmExternRefClass` arm.
        @test HBT.translate_external_type(WasmTarget.JSValue, m, r) == HBT.ExternRef
        # potentially-nullable primitives cannot cross as the bare machine type
        # (dart: `!isPotentiallyNullable` guards the builtin arm) — widen to anyref.
        @test HBT.translate_external_type(Union{Nothing,Int64}, m, r) == HBT.AnyRef
        @test HBT.translate_external_type(Nothing, m, r) == HBT.AnyRef
        # dart's fallback: ordinary boxed objects (structs, Any, arrays, unions)
        # widen to the anyref top type rather than being rejected.
        @test HBT.translate_external_type(Any, m, r) == HBT.AnyRef
        @test HBT.translate_external_type(_HBTPoint, m, r) == HBT.AnyRef
        @test HBT.translate_external_type(Vector{Float64}, m, r) == HBT.AnyRef
        @test HBT.translate_external_type(Union{Int64,Float64}, m, r) == HBT.AnyRef
    end

    @testset "a host-safe import signature compiles" begin
        mod = HBT.WasmModule()
        idx = HBT.add_import!(mod, "host", "stub",
            HBT.WasmValType[HBT.I64, HBT.F64, HBT.ExternRef], HBT.WasmValType[])
        bytes = HBT.compile_multi(
            Any[(_hbt_caller, (Int64, Float64, WasmTarget.JSValue), "caller")];
            existing_module=mod,
            import_stubs=Any[(_hbt_stub, "stub", (Int64, Float64, WasmTarget.JSValue),
                              idx, Nothing)],
            validate=false)
        @test bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
    end

    @testset "a void/no-arg import signature compiles" begin
        mod = HBT.WasmModule()
        idx = HBT.add_import!(mod, "host", "void_stub", HBT.WasmValType[], HBT.WasmValType[])
        bytes = HBT.compile_multi(Any[(_hbt_void_caller, (), "void_caller")];
            existing_module=mod,
            import_stubs=Any[(_hbt_void_stub, "void_stub", (), idx, Nothing)],
            validate=false)
        @test bytes[1:4] == UInt8[0x00, 0x61, 0x73, 0x6d]
    end

    @testset "a struct-typed parameter that leaks its concrete ref is rejected loudly" begin
        # No real host import could ever declare a concrete struct ref at the
        # boundary — dart2wasm's translateExternalType would widen `_HBTPoint`
        # to anyref (its InterfaceType fallback, translator.dart:1266). A host
        # that instead reuses the struct's own internal representation (the
        # mistake this validator exists to catch, since the coercion at every
        # call site to this import derives its target from these same Julia
        # arg types) must be rejected before any call is compiled.
        mod = HBT.WasmModule()
        registry = HBT.TypeRegistry()
        HBT.get_base_struct_type!(mod, registry)
        struct_wasm_type = HBT.get_concrete_wasm_type(_HBTPoint, mod, registry)
        @test struct_wasm_type isa HBT.ConcreteRef
        idx = HBT.add_import!(mod, "host", "struct_stub",
            HBT.WasmValType[struct_wasm_type], HBT.WasmValType[])

        err = try
            HBT.compile_multi(Any[(_hbt_struct_caller, (_HBTPoint,), "struct_caller")];
                existing_module=mod,
                import_stubs=Any[(_hbt_struct_stub, "struct_stub", (_HBTPoint,), idx, Nothing)],
                validate=false)
            nothing
        catch e
            e
        end
        @test err isa HBT.WasmCompileError
        @test err.diag.kind === :unsupported_type
        msg = sprint(showerror, err)
        @test occursin("struct_stub", msg)
        @test occursin("parameter 1", msg)
        @test occursin("_HBTPoint", msg)
    end

    @testset "a declared-vs-required arity mismatch is rejected loudly" begin
        mod = HBT.WasmModule()
        # The Julia stub signature (matching the real call site exactly, so this
        # isolates the arity check from call-site/registration consistency) is
        # 3 params; the host only declares 2 on the actual wasm import.
        idx = HBT.add_import!(mod, "host", "arity_stub",
            HBT.WasmValType[HBT.I64, HBT.F64], HBT.WasmValType[])
        err = try
            HBT.compile_multi(
                Any[(_hbt_caller, (Int64, Float64, WasmTarget.JSValue), "arity_caller")];
                existing_module=mod,
                import_stubs=Any[(_hbt_stub, "arity_stub",
                                  (Int64, Float64, WasmTarget.JSValue), idx, Nothing)],
                validate=false)
            nothing
        catch e
            e
        end
        @test err isa HBT.WasmCompileError
        @test err.diag.kind === :unsupported_type
        @test occursin("arity_stub", sprint(showerror, err))
    end

    @testset "a declared-vs-required return type mismatch is rejected loudly" begin
        mod = HBT.WasmModule()
        # Host declares an F64 result; the Julia stub return type is Int64 (I64).
        idx = HBT.add_import!(mod, "host", "ret_stub", HBT.WasmValType[], HBT.WasmValType[HBT.F64])
        @noinline _hbt_ret_stub()::Int64 = (Base.inferencebarrier(0)::Int64)
        _hbt_ret_caller() = _hbt_ret_stub()
        err = try
            HBT.compile_multi(Any[(_hbt_ret_caller, (), "ret_caller")];
                existing_module=mod,
                import_stubs=Any[(_hbt_ret_stub, "ret_stub", (), idx, Int64)],
                validate=false)
            nothing
        catch e
            e
        end
        @test err isa HBT.WasmCompileError
        @test err.diag.kind === :unsupported_type
        @test occursin("ret_stub", sprint(showerror, err))
    end
end
