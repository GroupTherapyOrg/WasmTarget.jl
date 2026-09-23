# Registry coverage lane (dev/MARCH.md §5): every entry of every lowering registry is
# exercised by the fast lanes — the differential smoke corpus or the byte-identity probe
# corpus. Without this, `dev/lanes.sh` green says nothing about an entry no case reaches:
# on 2026-09-08 a NIR conversion broke `jl_type_intersection`'s lowering (all 19 seeded
# Random differentials failed in the full suite) while smoke and probes stayed green.
#
# Measured from the test side only: each entry's function is wrapped to record the hit,
# then both corpora compile in this process. Production code is untouched. A smoke case
# that compiles is also run differentially by the smoke lane, and a probe's bytes are
# fingerprinted by the probe lane, so a hit here is exercised by a gate there.
#
#   julia --project=. test/registry_coverage.jl          # exit 1 on an unexercised entry
#   WT_COVERAGE_LIST=1 julia --project=. test/registry_coverage.jl   # also list covered
#
# Coverage unit: the key, for registries keyed by what the lowering matches (foreigncall
# symbol, builtin callee, numeric op/type tuple); the entry function, for registries keyed
# by Method (one entry registers every method of a generic function — `println`'s methods
# are one lowering, not forty).
using WasmTarget
const WT = WasmTarget

const HITS = Set{Tuple{Symbol,Any}}()
const UNITS = Dict{Tuple{Symbol,Any},String}()   # unit => display label

_rec(reg, unit, f) = (args...; kw...) -> (push!(HITS, (reg, unit)); f(args...; kw...))

# A callee key is labelled with its owning module: `Core.ifelse` and `Base.ifelse` (likewise
# `sizeof`) are different objects with the same name, and one ALLOWLIST line must name one unit.
_label(k) = (k isa Function || k isa Type) ? string(parentmodule(k), ".", nameof(k)) : string(k)

function _wrap_keyed!(reg::Symbol, d)
    for (k, v) in collect(d)
        UNITS[(reg, k)] = _label(k)
        d[k] = v isa Function ? _rec(reg, k, v) : typeof(v)(_rec(reg, k, v.emit!), v.result)
    end
end

function _wrap_by_fn!(reg::Symbol, d, getfn, rebuild)
    for (k, v) in collect(d)
        fn = getfn(v)
        UNITS[(reg, fn)] = string(nameof(fn))
        d[k] = rebuild(v, _rec(reg, fn, fn))
    end
end

_wrap_keyed!(:FOREIGN_LOWERINGS, WT.FOREIGN_LOWERINGS)
_wrap_keyed!(:BUILTIN_LOWERINGS, WT.BUILTIN_LOWERINGS)
_wrap_keyed!(:CHECKED_OPS, WT.CHECKED_OPS)
_wrap_keyed!(:SHIFT_OPS, WT.SHIFT_OPS)
_wrap_keyed!(:FMA_OPS, WT.FMA_OPS)
_wrap_keyed!(:MISC_OPS, WT.MISC_OPS)
_wrap_keyed!(:INTRINSIC_BINOPS, WT.INTRINSIC_BINOPS)
_wrap_keyed!(:INTRINSIC_UNOPS, WT.INTRINSIC_UNOPS)
_wrap_keyed!(:INTRINSIC_CONVERSIONS, WT.INTRINSIC_CONVERSIONS)
_wrap_by_fn!(:INVOKE_INTRINSICS, WT.INVOKE_INTRINSICS, e -> e.fn, (e, g) -> WT.InvokeIntrinsicEntry(g, e.mode))
_wrap_by_fn!(:STANDALONE_INTRINSIC_BODIES, WT.STANDALONE_INTRINSIC_BODIES, identity, (_, g) -> g)
let labels = [(reg, l) for ((reg, _), l) in UNITS]
    allunique(labels) || error("registry_coverage: two units share a label — ",
                               unique(filter(x -> count(==(x), labels) > 1, labels)))
end

# ---- the two corpora, compiled exactly as their lanes compile them ----
include(joinpath(@__DIR__, "probe_corpus.jl"))
const _SMOKE = joinpath(@__DIR__, "smoke.jl")
include(_SMOKE)   # defines GROUPS; main() runs only when smoke.jl is the program

failed = String[]
for (name, (f, argtypes)) in CASES
    try
        WT.compile_multi([(f, argtypes, name)]; validate=false)
    catch e
        push!(failed, "probe $name: $(first(sprint(showerror, e), 100))")
    end
end
for (group, cases) in GROUPS, case in cases
    name, f, args = case[1], case[2], case[3:end]
    try
        WT.compile(f, Tuple(map(typeof, args)))
    catch e
        push!(failed, "smoke $group/$name: $(first(sprint(showerror, e), 100))")
    end
end

# Entries no gate exercised when this lane was created. Each leaves the list by getting a
# smoke or probe case, or by being deleted as unreachable (Phase 12 item M). Exact: an entry
# listed here that IS covered fails the lane too, so the list only shrinks; a NEW registry
# entry without a case fails immediately.
const ALLOWLIST = Dict{Tuple{Symbol,String},String}(
    (:BUILTIN_LOWERINGS, "Core.!==") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:BUILTIN_LOWERINGS, "WasmTarget._closed_world_isvisible") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:BUILTIN_LOWERINGS, "WasmTarget._closed_world_type_bounds") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:BUILTIN_LOWERINGS, "Core.apply_type") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:BUILTIN_LOWERINGS, "Base.check_world_bounded") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:BUILTIN_LOWERINGS, "Base.getproperty") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:BUILTIN_LOWERINGS, "Base.ifelse") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:BUILTIN_LOWERINGS, "Core.invoke_in_world") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:BUILTIN_LOWERINGS, "Core.isdefinedglobal") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:BUILTIN_LOWERINGS, "Base.isvisible") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:BUILTIN_LOWERINGS, "Core.memoryref") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:BUILTIN_LOWERINGS, "Base.ncodeunits") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:BUILTIN_LOWERINGS, "Base.setproperty!") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:BUILTIN_LOWERINGS, "Base.sizeof") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:FOREIGN_LOWERINGS, "jl_is_binding_deprecated") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:FOREIGN_LOWERINGS, "jl_is_const") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:FOREIGN_LOWERINGS, "jl_ptr_to_array_1d") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:FOREIGN_LOWERINGS, "jl_type_unionall") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:FOREIGN_LOWERINGS, "jl_value_ptr") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:FOREIGN_LOWERINGS, "memcpy") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:FOREIGN_LOWERINGS, "utf8proc_grapheme_break_stateful") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INTRINSIC_BINOPS, "(F32, F32, :ge_float)") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INTRINSIC_BINOPS, "(F32, F32, :gt_float)") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INTRINSIC_BINOPS, "(F64, F64, :ge_float)") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INTRINSIC_BINOPS, "(F64, F64, :gt_float)") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INTRINSIC_CONVERSIONS, "(I32, I64, :sext_int)") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INTRINSIC_CONVERSIONS, "(I32, I64, :zext_int)") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INTRINSIC_CONVERSIONS, "(I64, I32, :trunc_int)") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_add_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_array_subpadding_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_error_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_getindex_continued_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_isascii_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_kwerr_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_length_str_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_mul_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_neg_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_nextind_continued_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_padding_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_parse_float_literal_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_parse_int_literal_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_print_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_println_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_rethrow_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_show_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_sizehint_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_sizehint_kwbody_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_star_concat_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_string_concat_or_reject_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_string_eq_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_string_generic_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_string_identity_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_string_int_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_sub_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_substring_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_symbol_from_string_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_thisind_continued_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_throw_inexacterror_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_throw_payload_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_truncate_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_tuple_error_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_typeintersect_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
    (:INVOKE_INTRINSICS, "_invoke_unalias_b") => "unexercised when the lane was created (2026-09-22) — Phase 12 item M",
)

uncovered = sort!([(reg, UNITS[(reg, u)]) for (reg, u) in keys(UNITS) if (reg, u) ∉ HITS])
unexpected = [x for x in uncovered if !haskey(ALLOWLIST, x)]
stale = [x for x in keys(ALLOWLIST) if x ∉ uncovered]

if get(ENV, "WT_COVERAGE_LIST", "") == "1"
    for (reg, u) in sort!([(reg, UNITS[(reg, u)]) for (reg, u) in HITS]); println("  covered    ", reg, "  ", u); end
end
for (reg, label) in unexpected; println("  UNEXERCISED ", reg, "  ", label); end
for (reg, label) in stale; println("  STALE allowlist entry (now covered — delete it): ", reg, "  ", label); end
for msg in failed; println("  (did not compile) ", msg); end
byreg = Dict{Symbol,Tuple{Int,Int}}()
for (reg, u) in keys(UNITS)
    c, t = get(byreg, reg, (0, 0)); byreg[reg] = (c + ((reg, u) in HITS), t + 1)
end
println(join(["$r $(c)/$(t)" for (r, (c, t)) in sort!(collect(byreg); by=first)], " · "))
println("registry_coverage: $(length(UNITS)) entries, $(length(unexpected)) unexercised, $(length(stale)) stale")
exit(isempty(unexpected) && isempty(stale) ? 0 : 1)
