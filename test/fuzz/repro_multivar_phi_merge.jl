# REGRESSION GUARD — multivar if/else phi-merge (was: silent miscompile; FIXED 2026-06-28).
#
# Discovered 2026-06-28 by the cleanup loop (writing the fix_consecutive_local_sets backfill);
# native-vs-Node differential + WAT confirmed it. FIXED the same day at the ROOT (per Dale's
# root-cause mandate): the dispatcher routed multi-phi merges to value-block generators that
# could only carry ONE phi out of an `if (result T)` block; now ANY merge with ≥2 phi nodes is
# routed to generate_stackified_flow, which stores EVERY live phi local at the edge via
# set_phi_locals_for_edge!. Guards both dispatch paths: generate_complex_flow (stackified.jl,
# `n_phi_nodes >= 2`) and is_simple_conditional (flow.jl). Full suite + diff fuzzer GREEN.
# The cases below now PASS (were @test_broken pre-fix); they stay as a permanent regression guard.
# NOT a fuzzer gap (no hash id); a cross-cutting flow-codegen bug → also noted in FINDINGS.md.
#
# THE BUG
# An `if/else` whose branches assign 2+ variables that are STILL LIVE after the merge keeps
# only ONE of them (the one routed through the `if (result T)` block value); every other
# phi-local assignment is silently dropped, so those variables read back as 0 (their default).
#
#   g1(n) = (a=0; b=0; if n>0; a=n; b=n+1; else; a=1; b=2; end; a*1000 + b)
#   g1(7) → native 7008, wasm 8   (a dropped: 0*1000 + 8)
#
# WAT of the merge (a = local 2, b = local 1):
#   local.get 3                 ;; cond
#   if (result i64)
#     local.get 0; i64.const 1; i64.add; local.set 4; local.get 4   ;; computes b's value
#   else
#     i64.const 2                                                    ;; b's else value
#   end
#   local.set 1                 ;; b = block result          <-- only b is stored
#   local.get 2                 ;; a  ── NEVER ASSIGNED → 0   <-- a's store was dropped
#   ...
#
# SCOPE (confirmed):
#   - FAILS: ≥2 vars assigned in branches AND ≥2 live after the merge (g1, g3 keeps only the
#     LAST of 3; sort2 lo lost; twoUse p lost). Independent of same-vs-distinct edge values.
#   - WORKS: single live var out of a branch (pick1); 2 assigned but only 1 live (oneLive);
#     the TERNARY form (a = c ? x : y; b = c ? p : q) — it lowers each var to its own select.
#
# ROOT: a diamond merge lowered as a VALUE-PRODUCING `if (result T)` block carries exactly ONE
# value out of the merge, so when ≥2 phi locals are live across it, only one is stored. This is
# shared by BOTH flow generators:
#   - generate_if_then_else (src/codegen/flow.jl:1845) — confirmed by code read: it scans for the
#     FIRST PhiNode (`break`, ~:1882-1888) and routes only that one through the block result.
#   - generate_complex_flow/generate_stackified_flow (src/codegen/stackified.jl) — the path g1
#     actually takes (g1 has 4 basic blocks → not "simple" → routed here); its WAT shows the same
#     single-`if (result i64)` carrying only `b`, with `a`'s store never emitted.
# PROPER FIX (emit site): for a multi-phi diamond, emit a VOID if-block and store EVERY live phi
# local inside each branch (push value; local.set phi_local — what set_phi_locals_for_edge! already
# does on the general loop path) instead of carrying a single block result. HIGH-risk flow-generator
# work (the ledger's Loop-2 dual-lowering + Loop-4 merge-coercion territory) — gate on the
# differential oracle, not byte-identity (the fix INTENTIONALLY changes bytes for multi-phi fns).
#
# RELATION TO fix_consecutive_local_sets: NONE. That pass converts consecutive `local.set`
# (same pushed value → ≥2 locals) into `local.tee; local.set`. Here the extra store is not
# emitted AT ALL, so the pass cannot fix this (and is disabled in prod anyway, WBUILD-1011).
# The pass remains genuinely dead; this is a separate, deeper flow-codegen defect.
#
# Run: julia --project=. -e 'using WasmTarget; include("test/utils.jl"); include("test/fuzz/repro_multivar_phi_merge.jl")'

using Test

g1(n::Int64) = (a = 0; b = 0; if n > 0; a = n; b = n + 1; else; a = 1; b = 2; end; a * 1000 + b)
g3(n::Int64) = (a = 0; b = 0; c = 0; if n > 0; a = n; b = 2n; c = 3n; else; a = 1; b = 2; c = 3; end; a * 1_000_000 + b * 1000 + c)
sort2(x::Int64, y::Int64) = (lo = 0; hi = 0; if x < y; lo = x; hi = y; else; lo = y; hi = x; end; hi * 1000 + lo)
twoUse(x::Int64) = (p = 0; q = 0; if x > 0; p = x; q = x * 2; else; p = -x; q = -x * 2; end; p + q)
# controls that MUST stay correct (single live var / dead extra / ternary):
pick1(x::Int64, y::Int64) = (m = 0; if x < y; m = y; else; m = x; end; m)
ternary2(n::Int64) = (a = n > 0 ? n : -n; b = n > 0 ? n + 1 : -n - 1; a * 1000 + b)

@testset "multivar phi-merge — FIXED (root-caused: multi-phi → stackifier per-edge phi store)" begin
    @test compare_julia_wasm(g1, Int64(7)).pass
    @test compare_julia_wasm(g1, Int64(-3)).pass
    @test compare_julia_wasm(g3, Int64(7)).pass
    @test compare_julia_wasm(g3, Int64(-2)).pass
    @test compare_julia_wasm(sort2, Int64(3), Int64(8)).pass
    @test compare_julia_wasm(sort2, Int64(9), Int64(2)).pass
    @test compare_julia_wasm(twoUse, Int64(5)).pass
    @test compare_julia_wasm(twoUse, Int64(-4)).pass
    # controls (must stay green — single live var / ternary form, never miscompiled):
    @test compare_julia_wasm(pick1, Int64(3), Int64(8)).pass
    @test compare_julia_wasm(ternary2, Int64(7)).pass
end
