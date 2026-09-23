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
# entry without a case fails immediately. Each reason states what was measured for the entry:
# UNREACHED/UNREACHABLE (a deletion candidate) or the smoke xfail case that reaches it.
const ALLOWLIST = Dict{Tuple{Symbol,String},String}(
    (:BUILTIN_LOWERINGS, "Core.!==") => "UNREACHED (measured 2026-09-22: Core.:(!==) === Base.:(!==), whose one method !(x === y) inlines to === and not_int, Any operands included)",
    (:BUILTIN_LOWERINGS, "WasmTarget._closed_world_isvisible") => "UNREACHED (measured 2026-09-22: reached as an :invoke, answered at invoke.jl:1332; no :call form measured)",
    (:BUILTIN_LOWERINGS, "WasmTarget._closed_world_type_bounds") => "UNREACHED (measured 2026-09-22: reached as an :invoke, answered at invoke.jl:1306; no :call form measured)",
    (:BUILTIN_LOWERINGS, "Core.apply_type") => "fires for a runtime Union{T, Nothing}, which is not === the same Union constant (native 1, wasm 0) — smoke xfail apply_type_union (measured 2026-09-22)",
    (:BUILTIN_LOWERINGS, "Base.check_world_bounded") => "UNREACHED (measured 2026-09-22: Julia emits it as an :invoke, answered by method name at invoke.jl:1306; no :call form measured, and show_type_name's programs fail first on 1.12 — smoke xfail show_type)",
    (:BUILTIN_LOWERINGS, "Base.getproperty") => "fires on an Any receiver, then the compile rejects in the getproperty(::UInt64, ::Symbol) dispatch candidate — smoke xfail builtin_crashes/getproperty_any (measured 2026-09-22)",
    (:BUILTIN_LOWERINGS, "Base.ifelse") => "UNREACHED (measured 2026-09-22: Base.ifelse's one method inlines to Core.ifelse; with an Any condition the surviving :call is Core.ifelse)",
    (:BUILTIN_LOWERINGS, "Core.invoke_in_world") => "fires, then rejects the re-dispatched callee as an unresolved dynamic call — smoke xfail builtin_crashes/invoke_in_world (measured 2026-09-22)",
    (:BUILTIN_LOWERINGS, "Core.isdefinedglobal") => "UNREACHED (measured 2026-09-22: its TypeName shape comes only from show_function, which fails to compile first; isdefinedglobal(Main, runtime Symbol) rejects as an unresolved dynamic call without this entry firing)",
    (:BUILTIN_LOWERINGS, "Base.isvisible") => "UNREACHED (measured 2026-09-22: Julia emits it as an :invoke, answered at invoke.jl:1332; its caller show_function fails to compile first — raw ArgumentError from structs.jl:177 is_self_referential_type)",
    (:BUILTIN_LOWERINGS, "Core.memoryref") => "UNREACHED (measured 2026-09-22: Core.memoryref inlines to memoryrefnew; no :call survives)",
    (:BUILTIN_LOWERINGS, "Base.setproperty!") => "fires on an Any receiver, then the compile rejects — smoke xfail builtin_crashes/setproperty_any (measured 2026-09-22)",
    (:BUILTIN_LOWERINGS, "Base.sizeof") => "fires on an Any element, then WasmInternalError at getfield(Any, :layout) — smoke xfail builtin_crashes/sizeof_any (measured 2026-09-22)",
    (:FOREIGN_LOWERINGS, "jl_is_binding_deprecated") => "UNREACHED (measured 2026-09-22: its TypeName shape comes only from show_function/isvisible, which fail to compile first)",
    (:FOREIGN_LOWERINGS, "jl_is_const") => "UNREACHED (measured 2026-09-22: its TypeName shape comes only from show_function; isconst(Base, runtime Symbol) reaches it, it declines, and the call rejects 'no lowering')",
    (:FOREIGN_LOWERINGS, "jl_ptr_to_array_1d") => "fires for unsafe_wrap(Array, pointer(v), n) and declines (pointer not traced) — smoke xfail pointer_foreigncalls/unsafe_wrap_pointer (measured 2026-09-22)",
    (:FOREIGN_LOWERINGS, "jl_type_unionall") => "fires for UnionAll(v, t) and emits ref.test on the TypeVar in place of the constructed type (native 1, wasm 0) — smoke xfail unionall_constructor (measured 2026-09-22)",
    (:FOREIGN_LOWERINGS, "jl_value_ptr") => "every measured spelling (pointer_from_objref of a Ref, graphemes, isgraphemebreak!) rejects 'escapes storage-relative WasmGC operations' — smoke xfail pointer_foreigncalls/ref_pointer_load (measured 2026-09-22)",
    (:FOREIGN_LOWERINGS, "utf8proc_grapheme_break_stateful") => "a reject-only lowering (soundness_fatal); its one Base caller isgraphemebreak! stops earlier at jl_value_ptr — smoke xfail pointer_foreigncalls/grapheme_break_stateful (measured 2026-09-22)",
    (:INTRINSIC_BINOPS, "(F32, F32, :ge_float)") => "UNREACHABLE (measured 2026-09-22: Core.Intrinsics defines no ge_float on Julia 1.12.7 or 1.13.0)",
    (:INTRINSIC_BINOPS, "(F32, F32, :gt_float)") => "UNREACHABLE (measured 2026-09-22: Core.Intrinsics defines no gt_float on Julia 1.12.7 or 1.13.0)",
    (:INTRINSIC_BINOPS, "(F64, F64, :ge_float)") => "UNREACHABLE (measured 2026-09-22: Core.Intrinsics defines no ge_float on Julia 1.12.7 or 1.13.0)",
    (:INTRINSIC_BINOPS, "(F64, F64, :gt_float)") => "UNREACHABLE (measured 2026-09-22: Core.Intrinsics defines no gt_float on Julia 1.12.7 or 1.13.0)",
    (:INTRINSIC_CONVERSIONS, "(I32, I64, :sext_int)") => "UNREACHABLE (measured 2026-09-22: emit_conversion! emits sext_int inline, julia_numeric_tier.jl:413, and never looks this key up)",
    (:INTRINSIC_CONVERSIONS, "(I32, I64, :zext_int)") => "UNREACHABLE (measured 2026-09-22: emit_conversion! emits zext_int inline, julia_numeric_tier.jl:423, and never looks this key up)",
    (:INTRINSIC_CONVERSIONS, "(I64, I32, :trunc_int)") => "UNREACHABLE (measured 2026-09-22: emit_conversion! emits trunc_int inline, julia_numeric_tier.jl:436, and never looks this key up)",
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
