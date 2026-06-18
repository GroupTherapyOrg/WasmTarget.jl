# ============================================================================
# In-WT PlutoIslands integration fixtures — real island cells, status-locked
# ============================================================================
#
# These fixtures are REAL PlutoIslands featured-corpus island cells, harvested
# from PI's live Pluto env by `PlutoIslands.jl/tools/harvest_wt_fixtures.jl` into
# `pi_island_fixtures.json` (vendored — no PI/Pluto dependency here). Each record
# carries the cell's synthesized fn source, its group preamble, arg types, sample
# bond inputs, and the GOLDEN native (Pluto) output.
#
# Every piece is tested directly against WT codegen via the in-package bit-exact
# bridge (`compare_julia_wasm_bridge`). A per-piece STATUS LOCK
# (`pi_island_status.json`) records each piece's expected status, so the suite
# catches regressions in BOTH directions:
#   * a `green` piece that breaks  → suite FAILS (codegen regression)
#   * a failing piece that goes green → suite FAILS ("promote me" — your fix landed)
# Known-failing pieces don't redden CI in steady state; any status FLIP is loud.
#
# This is the loop's product-grounded KPI: "PI pieces green: N / total". Failing
# pieces clustered by status (compile_fail / runtime_trap / outside_bridge /
# nonscalar_args / extract_fail) are the prioritized codegen work queue.
#
# Requires WasmTarget + test/utils.jl (compare_julia_wasm_bridge) + JSON loaded.

using JSON

const PI_FIX  = joinpath(@__DIR__, "pi_island_fixtures.json")
const PI_LOCK = joinpath(@__DIR__, "pi_island_status.json")

# arg types compare_julia_wasm_bridge can marshal today (scalar bridge args).
# Non-scalar bond inputs (String/Bool/DateTime/struct) need bridge_run_args-style
# arg bridging — tracked as `nonscalar_args` until that lands. Compared by NAME
# (string), not by eval'd Type, so classification is deterministic even when an
# exotic argtype (e.g. Dates.DateTime) can't be resolved in the sandbox.
const _PI_SCALAR_ARG_NAMES = ("Int64", "Int32", "Float64", "Float32")

# Faithful vendored copy of PI's cell-body renderers (PlutoIslands.jl/src/extract.jl
# `_plain_body`/`_html_body`) so harvested cells that call `PlutoIslands._plain_body`
# resolve WITHOUT a PI/Pluto dependency. Quoted Expr (not a string) to avoid escape
# hell. If PI ever changes these, the golden-drift guard in pi_classify (vendored-fn
# output vs captured native golden) fires.
const _PI_SHIM = :(
    module PlutoIslands
    _html_body(v::Base.Docs.HTML{String})::String = v.content
    _html_body(v::AbstractString)::String = String(v)
    _html_body(v) = error("text/html rendering of $(typeof(v)) unsupported")
    _plain_body(x)::String = string(x)
    _plain_body(s::String)::String = "\"" * replace(replace(s, "\\" => "\\\\"), "\"" => "\\\"") * "\""
    end
)

# Classify ONE harvested cell against current WT codegen → (status, detail).
# Kept free of @test so the lock generator and the testset share identical logic.
function pi_classify(group, cell)
    fn_src = get(cell, "fn_src", nothing)
    fn_src === nothing && return ("extract_fail", join(get(cell, "reasons", String[]), "; "))
    haskey(cell, "eval_err") && return ("harvest_eval_fail", String(cell["eval_err"]))
    # Decide nonscalar_args FIRST, from argtype NAMES — deterministic and free of
    # sandbox import state (the 6-bond Dates.DateTime group otherwise flips to
    # eval_fail when `using Dates` doesn't take in the sandbox).
    argnames = String.(get(group, "argtypes", String[]))
    all(a -> a in _PI_SCALAR_ARG_NAMES, argnames) || return ("nonscalar_args", join(argnames, ","))
    sb = Module(gensym(:pi))
    try Core.eval(sb, :(import Markdown)) catch end
    try Core.eval(sb, :(import Dates)) catch end
    try Core.eval(sb, _PI_SHIM) catch end   # vendored PlutoIslands._plain_body/_html_body
    for ex in get(group, "preamble", String[])
        try Core.eval(sb, Meta.parse(ex)) catch end
    end
    local f, rt
    try
        f = Core.eval(sb, Meta.parse(fn_src))
        rt = Core.eval(sb, Meta.parse(get(cell, "rettype", "Nothing")))
    catch e
        return ("eval_fail", first(sprint(showerror, e), 200))
    end
    WasmTarget.Bridge.descriptor(rt) === nothing && return ("outside_bridge", string(rt))
    samples = get(cell, "samples", Vector{Any}())
    golden  = get(cell, "golden", Vector{Any}())
    isempty(samples) && return ("no_samples", "")
    nb = replace(String(get(group, "notebook", "nb")), r"[^A-Za-z0-9]" => "_")
    cid = replace(String(get(cell, "cell_id", "c")), "-" => "")
    name = "pi_" * nb * "_" * cid[1:min(8, end)]
    for (si, srep) in enumerate(samples)
        local args
        try
            args = Tuple(Core.eval(sb, Meta.parse(x)) for x in srep)
        catch e
            return ("eval_fail", first(sprint(showerror, e), 200))
        end
        # drift guard: the vendored fn must reproduce PI's captured golden output.
        # invokelatest: `f` was just Core.eval'd, so it lives in a newer world age
        # than this function — a direct call would MethodError.
        nat = try Base.invokelatest(f, args...) catch e; return ("native_err", first(sprint(showerror, e), 200)) end
        if si <= length(golden) && repr(nat) != golden[si]
            return ("golden_drift", "sample $si: $(first(repr(nat), 80))")
        end
        local r
        try
            r = Base.invokelatest(compare_julia_wasm_bridge, f, args...; rettype = rt, name = name)
        catch e
            return ("compile_fail", first(sprint(showerror, e), 200))
        end
        r.skipped && return ("skipped_no_node", "")
        if !r.pass
            a = string(r.actual)
            return (startswith(a, "trap") ? "runtime_trap" : "mismatch", first(a, 160))
        end
    end
    return ("green", "")
end

# Stable per-piece key.
pi_key(group, cell) = string(get(group, "notebook", "?"), "#",
                             get(group, "group", 0), "#", get(cell, "cell_id", "?"))

# Classify every harvested piece → Vector{(key, status, detail, notebook, rettype)}.
function pi_all_statuses(; fixtures = PI_FIX)
    recs = JSON.parsefile(fixtures)
    out = NamedTuple[]
    for g in recs
        haskey(g, "error") && continue
        for c in get(g, "cells", [])
            st, detail = pi_classify(g, c)
            push!(out, (key = pi_key(g, c), status = st, detail = detail,
                        notebook = String(get(g, "notebook", "?")),
                        rettype = String(get(c, "rettype", ""))))
        end
    end
    return out
end

# Regenerate the status lock from current codegen. Run after a harvest or after a
# codegen fix that legitimately changes a piece's status:
#   julia --project=. test/integration/regen_pi_lock.jl
function regenerate_pi_lock!(; fixtures = PI_FIX, lockfile = PI_LOCK)
    sts = pi_all_statuses(; fixtures = fixtures)
    lock = Dict(s.key => Dict("status" => s.status, "notebook" => s.notebook) for s in sts)
    open(lockfile, "w") do io
        JSON.print(io, lock, 2)
    end
    counts = Dict{String,Int}()
    for s in sts; counts[s.status] = get(counts, s.status, 0) + 1; end
    println("PI status lock: ", length(sts), " pieces → ", lockfile)
    for (k, n) in sort(collect(counts); by = first)
        println("  ", rpad(k, 18), n)
    end
    return lock
end
