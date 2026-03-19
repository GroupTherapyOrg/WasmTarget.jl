# test_user_defined_types.jl — PHASE-2B-005: User-defined struct types at runtime
#
# Tests that the typeinf + codegen pipeline handles user-defined struct types:
# 1. TypeIDRegistry/TypeDataStore extensible at runtime for new types
# 2. Type inference correctly handles user struct functions (reimpl method matching)
# 3. Codegen compiles and executes user struct field access correctly
#
# Run: julia +1.12 --project=. test/selfhost/test_user_defined_types.jl

using Test
using WasmTarget

include(joinpath(@__DIR__, "..", "utils.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "ccall_stubs.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "subtype.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "matching.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "ccall_replacements.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "dict_method_table.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "typeid_registry.jl"))
include(joinpath(@__DIR__, "..", "..", "src", "typeinf", "type_data_store.jl"))

# ─── User-defined structs (simulating what a user would define) ──────────────

struct UDPoint
    x::Float64
    y::Float64
end

struct UDPointI
    x::Int64
    y::Int64
end

mutable struct UDCounter
    value::Int64
end

struct UDRect
    origin::UDPoint
    width::Float64
    height::Float64
end

# ─── Functions using user-defined structs ────────────────────────────────────

# Field access
ud_get_x(x::Float64, y::Float64)::Float64 = begin
    p = UDPoint(x, y)
    p.x
end

ud_get_y(x::Float64, y::Float64)::Float64 = begin
    p = UDPoint(x, y)
    p.y
end

# Arithmetic with fields
ud_point_sum(x::Float64, y::Float64)::Float64 = begin
    p = UDPoint(x, y)
    p.x + p.y
end

ud_point_dist_sq(x::Float64, y::Float64)::Float64 = begin
    p = UDPoint(x, y)
    p.x * p.x + p.y * p.y
end

# Int64 struct
ud_point_sum_i(x::Int64, y::Int64)::Int64 = begin
    p = UDPointI(x, y)
    p.x + p.y
end

ud_point_diff_i(x::Int64, y::Int64)::Int64 = begin
    p = UDPointI(x, y)
    p.x - p.y
end

# Nested struct
ud_rect_area(ox::Float64, oy::Float64, w::Float64, h::Float64)::Float64 = begin
    r = UDRect(UDPoint(ox, oy), w, h)
    r.width * r.height
end

ud_rect_origin_x(ox::Float64, oy::Float64, w::Float64, h::Float64)::Float64 = begin
    r = UDRect(UDPoint(ox, oy), w, h)
    r.origin.x
end

# ─── Tests ───────────────────────────────────────────────────────────────────

println("=== PHASE-2B-005: User-defined struct types at runtime ===\n")

@testset "PHASE-2B-005: User-defined struct types" begin

    # ── Test 1: TypeIDRegistry can register user types ──
    @testset "TypeIDRegistry runtime registration" begin
        registry = TypeIDRegistry()

        id_pt = assign_type!(registry, UDPoint)
        @test id_pt >= 0
        @test get_type(registry, id_pt) === UDPoint
        @test has_type(registry, UDPoint)

        # Register second user type
        id_pti = assign_type!(registry, UDPointI)
        @test id_pti >= 0
        @test id_pti != id_pt

        # Register method signature
        sig = Tuple{typeof(ud_get_x), Float64, Float64}
        sig_id = assign_type!(registry, sig)
        @test sig_id >= 0
        @test sig_id != id_pt
        @test sig_id != id_pti

        # Nested struct type
        id_rect = assign_type!(registry, UDRect)
        @test id_rect >= 0
        @test has_type(registry, UDRect)

        println("  ✓ TypeIDRegistry: 4 user types registered")
    end

    # ── Test 2: TypeDataStore can extract user type metadata ──
    @testset "TypeDataStore user type extraction" begin
        registry = TypeIDRegistry()
        # Register common base types first
        assign_type!(registry, Any)
        assign_type!(registry, Float64)
        assign_type!(registry, Int64)

        id_pt = assign_type!(registry, UDPoint)
        store = build_type_data_store(registry)
        td = get_type_data(store, id_pt)

        @test td.tag == TYPE_TAG_DATATYPE
        @test td.name_str == "UDPoint"
        @test td.n_fields == Int32(2)
        @test td.is_abstract == Int32(0)
        @test td.is_mutable == Int32(0)
        @test length(td.field_type_ids) == 2

        # Both fields are Float64
        f64_id = get_type_id(registry, Float64)
        @test td.field_type_ids[1] == f64_id
        @test td.field_type_ids[2] == f64_id

        println("  ✓ TypeDataStore: UDPoint metadata extracted correctly")
    end

    # ── Test 3: Runtime type registration (extensible store) ──
    @testset "Runtime type registration (register_runtime_types!)" begin
        # Start with a minimal registry + store
        registry = TypeIDRegistry()
        assign_type!(registry, Any)
        assign_type!(registry, Nothing)
        assign_type!(registry, Float64)
        assign_type!(registry, Int64)
        store = build_type_data_store(registry)

        initial_size = length(store.data)

        # Register user types at runtime
        ids = register_runtime_types!(store, UDPoint, UDPointI, UDRect)

        @test length(ids) == 3
        @test length(store.data) > initial_size

        # Verify UDPoint data
        td_pt = get_type_data(store, ids[1])
        @test td_pt.tag == TYPE_TAG_DATATYPE
        @test td_pt.name_str == "UDPoint"
        @test td_pt.n_fields == Int32(2)
        f64_id = get_type_id(registry, Float64)
        @test td_pt.field_type_ids[1] == f64_id
        @test td_pt.field_type_ids[2] == f64_id

        # Verify UDPointI data
        td_pti = get_type_data(store, ids[2])
        @test td_pti.tag == TYPE_TAG_DATATYPE
        @test td_pti.name_str == "UDPointI"
        @test td_pti.n_fields == Int32(2)
        i64_id = get_type_id(registry, Int64)
        @test td_pti.field_type_ids[1] == i64_id
        @test td_pti.field_type_ids[2] == i64_id

        # Verify UDRect data (nested struct — field types include UDPoint)
        td_rect = get_type_data(store, ids[3])
        @test td_rect.tag == TYPE_TAG_DATATYPE
        @test td_rect.name_str == "UDRect"
        @test td_rect.n_fields == Int32(3)
        @test td_rect.field_type_ids[1] == ids[1]  # origin is UDPoint
        @test td_rect.field_type_ids[2] == f64_id   # width is Float64
        @test td_rect.field_type_ids[3] == f64_id   # height is Float64

        # Verify all entries are consistent
        ok, fail, failures = verify_store(store)
        if fail > 0
            @warn "TypeDataStore verification failures" failures
        end
        @test fail == 0

        println("  ✓ Runtime registration: $(length(store.data)) types (was $initial_size)")
    end

    # ── Test 4: Type inference handles user struct functions via reimpl ──
    # Tests that code_typed (which now uses the reimpl method matching via
    # Base._methods_by_ftype override) correctly infers return types for
    # functions operating on user-defined structs. This verifies the reimpl
    # path (wasm_subtype + wasm_matching_methods) handles user types.
    @testset "Reimpl typeinf — user struct functions" begin
        test_cases = [
            (ud_get_x,        (Float64, Float64),                         Float64, "field access .x"),
            (ud_get_y,        (Float64, Float64),                         Float64, "field access .y"),
            (ud_point_sum,    (Float64, Float64),                         Float64, "field sum"),
            (ud_point_dist_sq,(Float64, Float64),                         Float64, "distance squared"),
            (ud_point_sum_i,  (Int64, Int64),                             Int64,   "Int64 struct sum"),
            (ud_point_diff_i, (Int64, Int64),                             Int64,   "Int64 struct diff"),
            (ud_rect_area,    (Float64, Float64, Float64, Float64),       Float64, "nested struct area"),
            (ud_rect_origin_x,(Float64, Float64, Float64, Float64),       Float64, "nested struct field"),
        ]

        for (f, atypes, expected_ret, desc) in test_cases
            # code_typed uses the reimpl method matching (Base._methods_by_ftype
            # is overridden to use wasm_matching_methods/wasm_subtype)
            results = Base.code_typed(f, atypes)
            @test !isempty(results)
            ci, ret_type = first(results)
            @test ret_type == expected_ret
            println("  ✓ typeinf $desc → $ret_type")
        end
    end

    # ── Test 5: Codegen + execute — user struct field access ──
    @testset "Codegen + execute — user struct field access" begin
        # Ground truth: run natively first
        @test ud_get_x(1.0, 2.0) == 1.0
        @test ud_get_y(1.0, 2.0) == 2.0
        @test ud_point_sum(3.0, 4.0) == 7.0
        @test ud_point_dist_sq(3.0, 4.0) == 25.0
        @test ud_point_sum_i(Int64(10), Int64(20)) == Int64(30)
        @test ud_point_diff_i(Int64(10), Int64(3)) == Int64(7)
        @test ud_rect_area(0.0, 0.0, 5.0, 3.0) == 15.0
        @test ud_rect_origin_x(7.0, 8.0, 1.0, 1.0) == 7.0

        # Compile + execute via Wasm
        test_cases = [
            (ud_get_x,         "ud_get_x",         [(1.0, 2.0)]),
            (ud_get_y,         "ud_get_y",         [(1.0, 2.0)]),
            (ud_point_sum,     "ud_point_sum",     [(3.0, 4.0), (0.0, 0.0)]),
            (ud_point_dist_sq, "ud_point_dist_sq", [(3.0, 4.0)]),
            (ud_point_sum_i,   "ud_point_sum_i",   [(Int64(10), Int64(20))]),
            (ud_point_diff_i,  "ud_point_diff_i",  [(Int64(10), Int64(3))]),
            (ud_rect_area,     "ud_rect_area",     [(0.0, 0.0, 5.0, 3.0)]),
            (ud_rect_origin_x, "ud_rect_origin_x", [(7.0, 8.0, 1.0, 1.0)]),
        ]

        for (f, name, args_list) in test_cases
            for args in args_list
                r = compare_julia_wasm(f, args...)
                @test r.pass
                if r.pass
                    println("  ✓ $name($(join(args, ", "))) = $(r.actual)")
                else
                    println("  ✗ $name($(join(args, ", "))) = $(r.actual) (expected $(r.expected))")
                end
            end
        end
    end

    # ── Test 6: Acceptance criteria — Point(1.0, 2.0).x returns 1.0 ──
    @testset "Acceptance: Point(1.0, 2.0).x returns 1.0" begin
        r = compare_julia_wasm(ud_get_x, 1.0, 2.0)
        @test r.pass
        @test r.expected == 1.0
        println("  ✓ Point(1.0, 2.0).x = $(r.actual) — ACCEPTANCE CRITERIA MET")
    end
end

println("\n=== PHASE-2B-005: Test complete ===")
