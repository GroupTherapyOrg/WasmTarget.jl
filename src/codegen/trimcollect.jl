# ============================================================================
# P5-trim: closed-world collection via the upstream juliac --trim machinery
# ============================================================================
#
# JuliaLang/julia#62087 (Keno's WasmGC strategy) proposes that static-compiler
# plugins receive "the list of MethodInstances to compile" from the juliac
# pipeline. The underlying machinery is `Compiler.typeinf_ext_toplevel` /
# `CompilationQueue` / `compile!`: a worklist-driven collection that infers
# the ENTIRE closed transitive callgraph at a consistent world and returns
# alternating (CodeInstance, CodeInfo) pairs, optionally trim-VERIFIED (no
# dynamic dispatch / runtime ccalls remain — with source-located diagnostics).
#
# `collect_closed_world` is that collection run under the WASM overlay
# interpreter, so @overlay methods replace their natives during inference
# (verified: the sinh overlay inlines and only its `exp` callee is
# collected). This is the intended replacement for the homegrown
# discover_dependencies walk + AUTODISCOVER whitelist, and the integration
# point for a future juliac `--compiler=WasmTarget` plugin interface.
#
# Availability: the three-arg Compiler API exists on 1.12 and 1.13. The
# TRIM_SAFE verifier is materially stronger on 1.13 (1.12 inference leaves
# dead empty-reduce branches dynamic); collection itself (TRIM_UNSAFE
# semantics — what this function does) works on both.

"""
    collect_closed_world(entries::Vector{Any}; verify::Bool=false)
        -> Vector{Any}   # alternating CodeInstance, CodeInfo pairs

Collect the closed transitive callgraph for the given entry
`MethodInstance`s under the WASM overlay interpreter. With `verify=true`,
run the upstream trim verifier (throws `Core.TrimFailure` with
source-located diagnostics when dynamic dispatch remains — the same
"abstract inference unsupported" boundary WasmTarget's strict mode guards,
but reported far better).
"""
# P5-trim: entry names for strict-mode scoping (see record_unsupported!).
const TRIM_ENTRY_NAMES = Ref{Union{Nothing, Set{String}}}(nothing)

# WASMTARGET dynamic dispatch: trim/inference drops `dynamic` calls (open-world) —
# the applicable method specializations are never collected, so func_registry has
# nothing for the call site to dispatch over. Scan the collected IR for dynamic
# calls `g(…, x::abstract, …)` and return the MethodInstances of the applicable
# CONCRETE-STRUCT specializations, so a follow-up collection round compiles them
# (then `_try_inline_typeid_dispatch` builds a runtime typeId switch over them).
# Surfaced by Markdown.plain/show recursion over heterogeneous AST nodes.
function _dynamic_dispatch_candidate_mis(codeinfos::Vector{Any}, seen::Set{Any})
    out = Any[]
    # march16: OBSERVED dynamic-call signatures (SSA callee, inferred arg types) —
    # closure bodies specialize against these (dart's typed vtable entries; Julia's
    # inference makes the body REAL instead of an any-erased stub).
    dyn_sigs = Set{Tuple}()
    closure_types = Set{DataType}()
    i = 1
    while i + 1 <= length(codeinfos)
        ci, src = codeinfos[i], codeinfos[i + 1]
        i += 2
        (ci isa Core.CodeInstance && src isa Core.CodeInfo) || continue
        host_mi = ci.def isa Core.MethodInstance ? ci.def : ci.def.def
        hsig = host_mi.specTypes
        hparams = (hsig isa DataType && hsig <: Tuple) ? collect(hsig.parameters) : Any[]
        ssat = src.ssavaluetypes
        for stmt in src.code
            # march16 (dart: creating a Lambda compiles its target): a CONSTRUCTED
            # closure enrolls its callable body — the erased/dynamic call site rides
            # the vtable trampoline, which needs the body compiled. Specialized with
            # the method's own sig (abstract slots stay erased; the trampoline passes
            # anyref and the body's funnel machinery narrows internally).
            if stmt isa Expr && stmt.head === :new && !isempty(stmt.args)
                local _nt = stmt.args[1]
                local _T = _nt isa GlobalRef ? (try getfield(_nt.mod, _nt.name) catch; nothing end) :
                           _nt isa DataType ? _nt : nothing
                haskey(ENV, "WT_DBG_DYN") && _T isa DataType && println(stderr, "NEW-SCAN T=", _T, " closure=", is_closure_type(_T))
                # scope: USERLAND closures only — Base/stdlib-internal closures are
                # statically called (never through the vtable); enrolling them all
                # exploded the blast radius (a _growend! trampoline mis-built).
                local _T_user = _T isa DataType && begin
                    local _r = _T.name.module
                    while parentmodule(_r) !== _r; _r = parentmodule(_r); end
                    _r === Main
                end
                if _T isa DataType && is_closure_type(_T) && _T_user
                    push!(closure_types, _T)
                end
                continue
            end
            # OBSERVED dynamic-call signature: an SSA/erased callee with inferrable args
            if stmt isa Expr && stmt.head === :call && stmt.args[1] isa Core.SSAValue
                local _dargs = Any[]
                local _dok = true
                for a in stmt.args[2:end]
                    local t = a isa Core.SSAValue ?
                                ((ssat isa Vector && a.id <= length(ssat)) ? CC.widenconst(ssat[a.id]) : Any) :
                              a isa Core.Argument ?
                                ((a.n >= 1 && a.n <= length(hparams)) ? hparams[a.n] : Any) :
                                Core.Typeof(a)
                    (t isa DataType && isconcretetype(t)) || (_dok = false; break)
                    push!(_dargs, t)
                end
                _dok && !isempty(_dargs) && push!(dyn_sigs, Tuple(_dargs))
            end
            (stmt isa Expr && stmt.head === :call && length(stmt.args) >= 2) || continue
            cref = stmt.args[1]
            cref isa GlobalRef || continue
            g = try getfield(cref.mod, cref.name) catch; continue end
            (g isa Function && !(g isa Core.Builtin) && !(g isa Core.IntrinsicFunction)) || continue
            # Resolve arg types from the optimized IR.
            cargs = stmt.args[2:end]
            atypes = Any[]
            bad = false
            for a in cargs
                t = if a isa Core.SSAValue
                    (ssat isa Vector && a.id <= length(ssat)) ? CC.widenconst(ssat[a.id]) : Any
                elseif a isa Core.Argument
                    (a.n >= 1 && a.n <= length(hparams)) ? hparams[a.n] : Any
                elseif a isa GlobalRef
                    try Core.Typeof(getfield(a.mod, a.name)) catch; Any end
                else
                    Core.Typeof(a)
                end
                t isa Type || (bad = true; break)
                push!(atypes, t)
            end
            bad && continue
            # Exactly one abstract dispatch position.
            absp = Int[j for j in 1:length(atypes) if !(atypes[j] isa DataType && isconcretetype(atypes[j]))]
            length(absp) == 1 || continue
            p = absp[1]
            ms = try collect(methods(g, Tuple{atypes...})) catch; Method[] end
            # march13 (dart: ALL targetCount>1 dispatch through the table,
            # dispatch_table.dart:401-403): the old ≤8 cap CIRCULARLY ABANDONED
            # ≥9-method dynamic sites — it "left them to the dispatch table", but the
            # table only builds from registered specializations, which only register
            # through THIS discovery → nothing registered, no table, unreachable stub
            # (the pinned two-arg megamorphic bug). Discovery now feeds BOTH mechanisms;
            # the inline-vs-table split happens downstream by count (threshold=9).
            # 64 = an explosion sanity guard, not a mechanism cliff.
            (0 < length(ms) <= 64) || continue
            for m in ms
                msig = try collect(Base.unwrap_unionall(m.sig).parameters) catch; continue end
                length(msig) == length(atypes) + 1 || continue
                Tp = msig[p + 1]
                (Tp isa DataType && isconcretetype(Tp) && isstructtype(Tp) &&
                 !(Tp <: Tuple) && Tp !== String && Tp !== Symbol) || continue
                spec = ntuple(j -> j == p ? Tp : atypes[j], length(atypes))
                ssig = try Tuple{Core.Typeof(g), spec...} catch; continue end
                cmi = try CC.specialize_method(m, ssig, Core.svec()) catch; continue end
                cmi in seen && continue
                push!(seen, cmi)
                push!(out, cmi)
            end
        end
    end

    # cross-product: each userland closure type × each observed dynamic-call
    # signature of matching arity → a TYPED body specialization (the vtable's
    # typed entry; inference compiles the body for real)
    for _T in closure_types
        local _mms2 = try
            Base._methods_by_ftype(Tuple{_T, Vararg{Any}}, nothing, -1, Base.get_world_counter())
        catch; nothing end
        for mm in (_mms2 === nothing ? () : _mms2)
            local m = mm.method
            local msig = try Base.unwrap_unionall(m.sig) catch; nothing end
            msig isa DataType || continue
            local mps = collect(msig.parameters)
            (length(mps) >= 1 && _T <: mps[1]) || continue
            local marity = length(mps) - 1
            for ds in dyn_sigs
                length(ds) == marity || continue
                local ssig = try Tuple{_T, ds...} catch; continue end
                # the observed args must be admissible for the method
                (ssig <: m.sig) || continue
                local cmi = try CC.specialize_method(m, ssig, Core.svec()) catch; continue end
                cmi === nothing && continue
                cmi in seen && continue
                push!(seen, cmi)
                push!(out, cmi)
                haskey(ENV, "WT_DBG_DYN") && println(stderr, "ENROLLED-TYPED cmi=", cmi.specTypes)
            end
        end
    end
    return out
end

# WASMTARGET dynamic dispatch: number of (CodeInstance, CodeInfo) PAIRS collected by
# the BASE (pre-dynamic-dispatch) closed-world pass. Pairs beyond this are pulled in
# ONLY by the dispatch-candidate discovery below; trim_compile_plan marks them so
# compile_module can ISOLATE their codegen (a latent-bug crash in discovery-added code
# stubs that one function instead of breaking the whole module). 0 = no discovery ran.
const _TRIM_BASE_PAIRS = Ref{Int}(0)

function collect_closed_world(entries::Vector{Any}; verify::Bool=false)
    # Fresh cache partition per collection: see cache_token in WasmInterpreter.
    interp = WasmInterpreter(Base.RefValue(0))
    invokelatest_queue = CC.CompilationQueue(; interp)
    codeinfos = Any[]
    workqueue = CC.CompilationQueue(; interp)
    append!(workqueue, entries)
    CC.compile!(codeinfos, workqueue; invokelatest_queue)
    CC.compile!(codeinfos, invokelatest_queue; invokelatest_queue)
    _TRIM_BASE_PAIRS[] = length(codeinfos) ÷ 2   # everything after this is discovery-added
    # WASMTARGET dynamic dispatch — GATED OFF BY DEFAULT (set WT_DYNDISPATCH=1 to enable).
    # T1.1 step 1 (NON-PERTURBING collection): specializations reached only via `dynamic`
    # calls (markdown plain/show over heterogeneous AST nodes, abstract-keyed Dict
    # hash/isequal, …) are collected in a SEPARATE interpreter + collection, then only the
    # NEW (CodeInstance, CodeInfo) pairs are MERGED into `codeinfos` (deduped by
    # MethodInstance). The previous approach re-ran CC.compile! on the SHARED `interp`
    # after the base pass, which perturbed base inference (re-collected already-present MIs
    # with different IR → order-dependent codegen bugs in unrelated code). A fresh interp
    # (distinct cache_owner) + merge leaves every base pair byte-identical, so enabling
    # discovery cannot change how base functions compile (the COLLECTION layer). Registry
    # isolation — so candidates don't perturb base get_function cross-call resolution — is
    # step 2 (FunctionInfo.is_candidate). With layers 1+2 in place, plus discovery yielding
    # to PURE-9060 for megamorphic (≥9-method) functions, the base pass is byte-identical
    # whether or not discovery runs — so dynamic dispatch is ON BY DEFAULT (WT_DYNDISPATCH=0
    # to disable).
    if get(ENV, "WT_DYNDISPATCH", "1") != "0"
        base_mis = Set{Any}()
        for k in 1:2:length(codeinfos)
            codeinfos[k] isa Core.CodeInstance && push!(base_mis, codeinfos[k].def)
        end
        seen_disp = Set{Any}()   # dedup candidate MIs across fixpoint rounds
        for _round in 1:8
            extra = _dynamic_dispatch_candidate_mis(codeinfos, seen_disp)
            extra = Any[mi for mi in extra if !(mi in base_mis)]
            isempty(extra) && break
            # Fresh interpreter (its own cache_owner) — never touches the base partition.
            cand_interp = WasmInterpreter(Base.RefValue(0))
            cand_ci = Any[]
            cand_wq = CC.CompilationQueue(; interp = cand_interp)
            cand_ilq = CC.CompilationQueue(; interp = cand_interp)
            append!(cand_wq, extra)
            CC.compile!(cand_ci, cand_wq; invokelatest_queue = cand_ilq)
            CC.compile!(cand_ci, cand_ilq; invokelatest_queue = cand_ilq)
            # Merge only NEW pairs (dedup by MI) so base pairs are never duplicated.
            added = false
            for k in 1:2:length(cand_ci)
                (cand_ci[k] isa Core.CodeInstance && cand_ci[k + 1] isa Core.CodeInfo) || continue
                mi = cand_ci[k].def
                mi in base_mis && continue
                push!(base_mis, mi)
                push!(codeinfos, cand_ci[k], cand_ci[k + 1])
                added = true
            end
            added || break
        end
    end
    if verify
        CC.verify_typeinf_trim(codeinfos, #= onlywarn =# false)
    end
    return codeinfos
end

"""
    entry_method_instance(f, arg_types::Tuple) -> MethodInstance

Resolve the `MethodInstance` for `f(::arg_types...)` — the entry handle
`collect_closed_world` consumes.
"""
function entry_method_instance(f, arg_types::Tuple)
    tt = Tuple{Core.Typeof(f), arg_types...}
    m = which(f, arg_types)
    return CC.specialize_method(m, tt, Core.svec())
end


"""
    trim_compile_plan(entries_named) -> (functions, ir_cache)

Run `collect_closed_world` over the named entry points and derive the
compile_module inputs: the full (func, arg_types, name) list (entries keep
their given names; discovered functions get deduped names) and the
(f, arg_types) → (CodeInfo, rettype) cache that get_typed_ir serves —
every function compiles from the collection's consistent-world IR.

Skipped (with a debug note): non-singleton callables (stateful closures —
their call sites inline or carry the closure value; no module-level
function entry to register) and Core/internal entries without a usable
function object.
"""
function trim_compile_plan(entries_named::Vector)
    entry_mis = Any[]
    entry_keys = Dict{Any, String}()   # mi → requested name
    for (f, arg_types, name) in entries_named
        mi = entry_method_instance(f, arg_types)
        push!(entry_mis, mi)
        entry_keys[mi] = name
    end
    codeinfos = collect_closed_world(entry_mis)

    functions = Any[]
    ir_cache = IdDict{Any, Tuple{Core.CodeInfo, Any}}()
    # WASMTARGET dynamic dispatch: (f, arg_types) of functions pulled in ONLY by the
    # dispatch-candidate discovery (pairs beyond the base collection). compile_module
    # isolates their codegen so a latent-bug crash stubs that one function instead of
    # breaking the whole module (entries + their normal deps stay strict).
    isolated_funcs = Set{Any}()
    base_pairs = _TRIM_BASE_PAIRS[]
    # Pre-seed with entry names: a discovered function processed before its
    # same-named entry must not claim the entry's export name (duplicate-export
    # validation failure in multi-function modules).
    used_names = Set{String}(values(entry_keys))
    seen_sigs = Set{Tuple{Any, Any}}()   # T1.1 step 3: dedup the function list by (f, arg_types)
    i = 1
    pair_no = 0
    while i + 1 <= length(codeinfos)
        ci, src = codeinfos[i], codeinfos[i + 1]
        i += 2
        pair_no += 1
        (ci isa Core.CodeInstance && src isa Core.CodeInfo) || continue
        mi = ci.def isa Core.MethodInstance ? ci.def : ci.def.def
        sig = mi.specTypes
        haskey(ENV, "WT_DBG_DYN") && occursin("f_dyn4##", string(sig)) && println(stderr, "PAIR-SEEN sig=", sig)
        (sig isa DataType && sig <: Tuple && length(sig.parameters) >= 1) || continue
        ftyp = sig.parameters[1]
        f = nothing
        if ftyp isa DataType && isdefined(ftyp, :instance)
            f = ftyp.instance            # singleton functions incl. Core.kwcall
        elseif ftyp isa DataType && ftyp <: Type && length(ftyp.parameters) >= 1
            f = ftyp.parameters[1]       # constructors: Type{T} → T
            (f isa DataType || f isa UnionAll) || (f = nothing)
        elseif ftyp isa DataType && is_closure_type(ftyp)
            # march16: a CAPTURING closure has no instance — key its body by the
            # closure TYPE (the vtable machinery resolves by type; no static
            # caller resolves these by value). dart: creating a Lambda compiles
            # its target.
            f = ftyp
        end
        if f === nothing
            @debug "trim_compile_plan: skipping non-singleton callable" sig
            continue
        end
        arg_types = Tuple(sig.parameters[2:end])
        # T1.1 step 3: a discovery candidate can duplicate an explicitly-listed
        # specialization (e.g. compile_multi entries + a megamorphic dynamic call's
        # candidates) → duplicate wasm export. Dedup by (f, arg_types); the first
        # occurrence wins (entries/base pairs are processed first).
        (f, arg_types) in seen_sigs && continue
        push!(seen_sigs, (f, arg_types))
        # name: requested for entries, deduped method name otherwise
        name = get(entry_keys, mi, nothing)
        if name === nothing
            base = mi.def isa Method ? string(mi.def.name) : string(nameof(f))
            name = base
            n = 1
            while name in used_names
                name = string(base, "_", n)
                n += 1
            end
        end
        push!(used_names, name)
        push!(functions, (f, arg_types, name))
        ir_cache[(f, arg_types)] = (src, ci.rettype)
        # Discovery-added (beyond the base collection) AND not also an entry → isolate.
        if base_pairs > 0 && pair_no > base_pairs && !haskey(entry_keys, mi)
            push!(isolated_funcs, (f, arg_types))
        end
    end
    _TRIM_ISOLATED_FUNCS[] = isolated_funcs
    return functions, ir_cache
end

# WASMTARGET dynamic dispatch: (f, arg_types) keys whose codegen compile_module should
# ISOLATE (try/catch → unreachable stub on failure) — the discovery-added functions.
# Set by trim_compile_plan; read+cleared by compile_module.
const _TRIM_ISOLATED_FUNCS = Ref{Set{Any}}(Set{Any}())
