# PHASE-1M-003: Test GlobalRef pre-resolution for codegen functions
# Verifies that all GlobalRef values can be pre-resolved at build time
# and that compilation with pre-resolved CodeInfo produces correct WASM.
#
# Ground truth: pre-resolved compilation must produce identical WASM bytes
# as standard compilation, and execution must match native Julia output.

using Test

# Load WasmTarget
include(joinpath(@__DIR__, "..", "utils.jl"))
using WasmTarget
using WasmTarget: get_typed_ir, compile_module_from_ir, to_bytes

# ============================================================================
# GlobalRef collection and pre-resolution
# ============================================================================

"""
    collect_globalrefs(code_info::Core.CodeInfo) -> Set{GlobalRef}

Walk a CodeInfo and collect all unique GlobalRef values from statements and
expression arguments.
"""
function collect_globalrefs(code_info::Core.CodeInfo)
    refs = Set{GlobalRef}()
    for stmt in code_info.code
        _scan_globalrefs!(refs, stmt)
    end
    return refs
end

function _scan_globalrefs!(refs::Set{GlobalRef}, val)
    if val isa GlobalRef
        push!(refs, val)
    elseif val isa Expr
        for arg in val.args
            _scan_globalrefs!(refs, arg)
        end
    end
end

"""
    resolve_globalrefs(refs::Set{GlobalRef}) -> Dict{GlobalRef, Any}

Resolve each GlobalRef to its build-time value using getfield.
Returns a Dict mapping each GlobalRef to its resolved value.
Unresolvable refs are skipped (they may be forward declarations etc).
"""
function resolve_globalrefs(refs::Set{GlobalRef})
    resolved = Dict{GlobalRef, Any}()
    for ref in refs
        try
            resolved[ref] = getfield(ref.mod, ref.name)
        catch
            # Skip unresolvable refs
        end
    end
    return resolved
end

"""
    collect_and_resolve_all(ir_entries::Vector) -> Dict{GlobalRef, Any}

Collect and resolve ALL GlobalRefs across multiple IR entries.
"""
function collect_and_resolve_all(ir_entries::Vector)
    all_refs = Set{GlobalRef}()
    for (code_info, _, _, _) in ir_entries
        union!(all_refs, collect_globalrefs(code_info))
    end
    return resolve_globalrefs(all_refs)
end

"""
    substitute_globalrefs(code_info::Core.CodeInfo, resolved::Dict{GlobalRef, Any}) -> Core.CodeInfo

Create a copy of CodeInfo with all GlobalRef values replaced by their
pre-resolved values (as QuoteNode-wrapped constants).
"""
function substitute_globalrefs(code_info::Core.CodeInfo, resolved::Dict{GlobalRef, Any})
    new_ci = copy(code_info)
    new_code = Any[]
    for stmt in new_ci.code
        push!(new_code, _substitute_stmt(stmt, resolved))
    end
    new_ci.code = new_code
    return new_ci
end

function _substitute_stmt(val, resolved::Dict{GlobalRef, Any})
    if val isa GlobalRef
        if haskey(resolved, val)
            return resolved[val]
        end
        return val
    elseif val isa Expr
        new_args = Any[_substitute_stmt(arg, resolved) for arg in val.args]
        return Expr(val.head, new_args...)
    end
    return val
end

# ============================================================================
# Test functions
# ============================================================================

test_add(x::Int64, y::Int64)::Int64 = x + y

function test_max(a::Int64, b::Int64)::Int64
    a > b ? a : b
end

function test_sum_to(n::Int64)::Int64
    s = Int64(0)
    i = Int64(1)
    while i <= n
        s += i
        i += Int64(1)
    end
    s
end

test_circle_area(r::Float64)::Float64 = 3.14159265358979 * r * r

function test_poly(x::Int64)::Int64
    x * x + Int64(2) * x + Int64(1)
end

# ============================================================================
# Helper
# ============================================================================
function make_ir_entries(funcs)
    entries = []
    for (f, arg_types, name) in funcs
        code_info, return_type = get_typed_ir(f, arg_types)
        push!(entries, (code_info, return_type, arg_types, name))
    end
    return entries
end

# ============================================================================
# Test 1: GlobalRef collection finds all references
# ============================================================================
@testset "GlobalRef collection" begin
    ci_add, _ = get_typed_ir(test_add, (Int64, Int64))
    refs = collect_globalrefs(ci_add)
    @test length(refs) > 0
    println("  test_add: $(length(refs)) GlobalRefs found")
    for ref in refs
        println("    $(ref.mod).$(ref.name)")
    end

    ci_sum, _ = get_typed_ir(test_sum_to, (Int64,))
    refs_sum = collect_globalrefs(ci_sum)
    @test length(refs_sum) > 0
    println("  test_sum_to: $(length(refs_sum)) GlobalRefs found")
end

# ============================================================================
# Test 2: All GlobalRefs are resolvable
# ============================================================================
@testset "GlobalRef resolution" begin
    funcs = [
        (test_add, (Int64, Int64), "test_add"),
        (test_max, (Int64, Int64), "test_max"),
        (test_sum_to, (Int64,), "test_sum_to"),
        (test_circle_area, (Float64,), "test_circle_area"),
        (test_poly, (Int64,), "test_poly"),
    ]
    ir_entries = make_ir_entries(funcs)
    resolved = collect_and_resolve_all(ir_entries)

    @test length(resolved) > 0
    println("  Resolved $(length(resolved)) unique GlobalRefs across $(length(funcs)) functions:")

    unresolved = 0
    for (ref, val) in resolved
        println("    $(ref.mod).$(ref.name) → $(val) ($(typeof(val)))")
    end

    # All refs should be resolvable for these simple functions
    all_refs = Set{GlobalRef}()
    for (ci, _, _, _) in ir_entries
        union!(all_refs, collect_globalrefs(ci))
    end
    @test length(resolved) == length(all_refs)
    println("  All $(length(all_refs)) GlobalRefs resolved — no getfield(Module, Symbol) needed")
end

# ============================================================================
# Test 3: Substituted CodeInfo compiles identically
# ============================================================================
@testset "Substituted CodeInfo — identical WASM" begin
    funcs = [
        (test_add, (Int64, Int64), "test_add"),
        (test_max, (Int64, Int64), "test_max"),
        (test_sum_to, (Int64,), "test_sum_to"),
        (test_circle_area, (Float64,), "test_circle_area"),
        (test_poly, (Int64,), "test_poly"),
    ]
    ir_entries = make_ir_entries(funcs)
    resolved = collect_and_resolve_all(ir_entries)

    # Build substituted IR entries
    sub_entries = []
    for (ci, rt, at, name) in ir_entries
        sub_ci = substitute_globalrefs(ci, resolved)
        push!(sub_entries, (sub_ci, rt, at, name))
    end

    # Verify substituted CodeInfo has no GlobalRefs
    for (sub_ci, _, _, name) in sub_entries
        remaining = collect_globalrefs(sub_ci)
        @test length(remaining) == 0
        println("  $name: $(length(remaining)) GlobalRefs remaining after substitution")
    end

    # Compile both and compare WASM bytes
    bytes_original = to_bytes(compile_module_from_ir(ir_entries))
    bytes_substituted = to_bytes(compile_module_from_ir(sub_entries))

    @test bytes_original == bytes_substituted
    println("  WASM bytes: original=$(length(bytes_original)), substituted=$(length(bytes_substituted)) — IDENTICAL=$(bytes_original == bytes_substituted)")

    # Verify execution correctness
    if NODE_CMD !== nothing
        result_add = run_wasm(bytes_substituted, "test_add", Int64(10), Int64(20))
        result_max = run_wasm(bytes_substituted, "test_max", Int64(5), Int64(3))
        result_sum = run_wasm(bytes_substituted, "test_sum_to", Int64(10))
        result_poly = run_wasm(bytes_substituted, "test_poly", Int64(5))
        @test result_add == 30
        @test result_max == 5
        @test result_sum == 55
        @test result_poly == 36
        println("  Native: test_add(10,20) = $(test_add(Int64(10),Int64(20)))")
        println("  Wasm:   test_add(10,20) = $result_add — CORRECT")
        println("  Native: test_max(5,3) = $(test_max(Int64(5),Int64(3)))")
        println("  Wasm:   test_max(5,3) = $result_max — CORRECT")
        println("  Native: test_sum_to(10) = $(test_sum_to(Int64(10)))")
        println("  Wasm:   test_sum_to(10) = $result_sum — CORRECT")
        println("  Native: test_poly(5) = $(test_poly(Int64(5)))")
        println("  Wasm:   test_poly(5) = $result_poly — CORRECT")
    end
end

# ============================================================================
# Test 4: Pre-resolved + frozen context works together
# ============================================================================
@testset "Pre-resolved + frozen context" begin
    funcs = [
        (test_add, (Int64, Int64), "test_add"),
        (test_sum_to, (Int64,), "test_sum_to"),
    ]
    ir_entries = make_ir_entries(funcs)
    resolved = collect_and_resolve_all(ir_entries)

    # Substitute GlobalRefs
    sub_entries = []
    for (ci, rt, at, name) in ir_entries
        sub_ci = substitute_globalrefs(ci, resolved)
        push!(sub_entries, (sub_ci, rt, at, name))
    end

    # Build frozen state from substituted entries (no GlobalRef resolution needed)
    frozen = build_frozen_state(sub_entries)
    mod = compile_module_from_ir_frozen(sub_entries, frozen)
    bytes = to_bytes(mod)
    @test length(bytes) > 0
    println("  Pre-resolved + frozen: $(length(bytes)) bytes")

    if NODE_CMD !== nothing
        result = run_wasm(bytes, "test_add", Int64(100), Int64(200))
        @test result == 300
        result2 = run_wasm(bytes, "test_sum_to", Int64(100))
        @test result2 == 5050
        println("  test_add(100,200) = $result — CORRECT")
        println("  test_sum_to(100) = $result2 — CORRECT")
    end
end

println("\n=== PHASE-1M-003: All GlobalRef pre-resolution tests complete ===")
