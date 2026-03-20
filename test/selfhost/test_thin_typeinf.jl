# METH-003: Test thin_typeinf — lightweight type inference via return-type lookup
#
# Run: julia +1.12 --project=. test/selfhost/test_thin_typeinf.jl

using WasmTarget
using Test

# Load typeinf infrastructure via unified entry point
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "typeinf_wasm.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "typeid_registry.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "return_type_table.jl"))
include(joinpath(dirname(dirname(@__DIR__)), "src", "typeinf", "thin_typeinf.jl"))

println("=" ^ 70)
println("METH-003: thin_typeinf Tests")
println("=" ^ 70)

# ─── Setup: build tables for common function signatures ─────────────────────

# Functions we'll test
f_mul_add(x::Int64) = x * x + Int64(1)
f_sub(x::Int64, y::Int64) = x - y
f_float(x::Float64) = x * 2.0
f_cmp(x::Int64, y::Int64) = x < y
f_identity(x::Int64) = x

test_sigs = Any[
    Tuple{typeof(*), Int64, Int64},
    Tuple{typeof(+), Int64, Int64},
    Tuple{typeof(-), Int64, Int64},
    Tuple{typeof(<), Int64, Int64},
    Tuple{typeof(*), Float64, Float64},
    Tuple{typeof(f_mul_add), Int64},
    Tuple{typeof(f_sub), Int64, Int64},
    Tuple{typeof(f_float), Float64},
    Tuple{typeof(f_cmp), Int64, Int64},
    Tuple{typeof(f_identity), Int64},
]

table = populate_transitive(test_sigs)
registry = build_typeid_registry(table)

# Build return type table WITH intrinsics
rt_table = build_return_type_table_with_intrinsics(table, registry)
stats = return_type_table_stats(rt_table)
println("  RT table: $(stats.n_entries) entries, $(stats.table_size) slots, load=$(round(stats.load_factor, digits=2))")

# Cache TypeIDs
tid_i64 = get_type_id(registry, Int64)
tid_f64 = get_type_id(registry, Float64)
tid_bool = get_type_id(registry, Bool)
println("  TypeIDs: Int64=$tid_i64, Float64=$tid_f64, Bool=$tid_bool")

@testset "thin_typeinf" begin

    @testset "f(x::Int64) = x * x + 1 — MVP function" begin
        ci, ret = Base.code_typed(f_mul_add, (Int64,); optimize=true)[1]
        println("\n  IR for f_mul_add ($(length(ci.code)) stmts):")
        for (i, stmt) in enumerate(ci.code)
            println("    [$i] $(typeof(stmt)): $stmt  (expected: $(ci.ssavaluetypes[i]))")
        end

        arg_typeids = Int32[
            get_type_id(registry, typeof(f_mul_add)),  # slot 1 = #self#
            tid_i64,                                     # slot 2 = x
        ]

        result = thin_typeinf(ci.code, arg_typeids, rt_table, registry)
        println("  Result TypeIDs: $result")

        # All call statements should return Int64
        for (i, stmt) in enumerate(ci.code)
            if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                expected = ci.ssavaluetypes[i]
                if expected === Int64
                    @test result[i] == tid_i64
                end
            end
        end

        # ReturnNode should propagate the type
        for (i, stmt) in enumerate(ci.code)
            if stmt isa Core.ReturnNode && isdefined(stmt, :val)
                @test result[i] == tid_i64
            end
        end
    end

    @testset "f(x, y) = x - y — two-arg function" begin
        ci, ret = Base.code_typed(f_sub, (Int64, Int64); optimize=true)[1]
        arg_typeids = Int32[
            get_type_id(registry, typeof(f_sub)),
            tid_i64,  # x
            tid_i64,  # y
        ]

        result = thin_typeinf(ci.code, arg_typeids, rt_table, registry)

        for (i, stmt) in enumerate(ci.code)
            if stmt isa Expr && stmt.head === :call && ci.ssavaluetypes[i] === Int64
                @test result[i] == tid_i64
            end
        end
    end

    @testset "f(x::Float64) = x * 2.0 — float arithmetic" begin
        ci, ret = Base.code_typed(f_float, (Float64,); optimize=true)[1]
        arg_typeids = Int32[
            get_type_id(registry, typeof(f_float)),
            tid_f64,
        ]

        result = thin_typeinf(ci.code, arg_typeids, rt_table, registry)

        for (i, stmt) in enumerate(ci.code)
            if stmt isa Expr && stmt.head === :call && ci.ssavaluetypes[i] === Float64
                @test result[i] == tid_f64
            end
        end
    end

    @testset "f(x, y) = x < y — comparison returns Bool" begin
        ci, ret = Base.code_typed(f_cmp, (Int64, Int64); optimize=true)[1]
        println("\n  IR for f_cmp ($(length(ci.code)) stmts):")
        for (i, stmt) in enumerate(ci.code)
            println("    [$i] $(typeof(stmt)): $stmt  (expected: $(ci.ssavaluetypes[i]))")
        end

        arg_typeids = Int32[
            get_type_id(registry, typeof(f_cmp)),
            tid_i64,
            tid_i64,
        ]

        result = thin_typeinf(ci.code, arg_typeids, rt_table, registry)
        println("  Result TypeIDs: $result")

        for (i, stmt) in enumerate(ci.code)
            if stmt isa Expr && stmt.head === :call && ci.ssavaluetypes[i] === Bool
                @test result[i] == tid_bool
            end
        end
    end

    @testset "f(x) = x — identity function" begin
        ci, ret = Base.code_typed(f_identity, (Int64,); optimize=true)[1]
        arg_typeids = Int32[
            get_type_id(registry, typeof(f_identity)),
            tid_i64,
        ]

        result = thin_typeinf(ci.code, arg_typeids, rt_table, registry)

        # ReturnNode should propagate argument type
        for (i, stmt) in enumerate(ci.code)
            if stmt isa Core.ReturnNode && isdefined(stmt, :val) && stmt.val isa Core.Argument
                @test result[i] == tid_i64
            end
        end
    end

    @testset "agreement with Julia's type inference" begin
        # For each test function, verify thin_typeinf agrees with code_typed
        test_cases = [
            (f_mul_add, (Int64,)),
            (f_sub, (Int64, Int64)),
            (f_float, (Float64,)),
            (f_cmp, (Int64, Int64)),
            (f_identity, (Int64,)),
        ]

        n_checked = 0
        n_correct = 0

        for (f, argtypes) in test_cases
            ci, ret = Base.code_typed(f, argtypes; optimize=true)[1]
            slot_typeids = Int32[get_type_id(registry, typeof(f))]
            for at in argtypes
                push!(slot_typeids, get_type_id(registry, at))
            end

            result = thin_typeinf(ci.code, slot_typeids, rt_table, registry)

            for (i, stmt) in enumerate(ci.code)
                if stmt isa Expr && (stmt.head === :call || stmt.head === :invoke)
                    expected_type = ci.ssavaluetypes[i]
                    if expected_type isa Type
                        expected_tid = get_type_id(registry, expected_type)
                        if expected_tid >= 0
                            n_checked += 1
                            if result[i] == expected_tid
                                n_correct += 1
                            else
                                println("  MISMATCH: $(nameof(f)) stmt $i: thin=$( result[i]) expected=$expected_tid ($expected_type)")
                            end
                        end
                    end
                end
            end
        end

        println("\n  Agreement: $n_correct/$n_checked correct")
        @test n_checked > 0
        @test n_correct == n_checked
    end
end

println("\nAll METH-003 tests complete.")
