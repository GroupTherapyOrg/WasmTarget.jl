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
# retired curated dependency walk, and the integration
# point for a future juliac `--compiler=WasmTarget` plugin interface.
#
# Availability: the three-arg Compiler API exists on 1.12 and 1.13. The
# TRIM_SAFE verifier is materially stronger on 1.13 (1.12 inference leaves
# dead empty-reduce branches dynamic); collection itself (TRIM_UNSAFE
# semantics — what this function does) works on both.

"""Return explicit `:invoke` MethodInstances missing from a collected world."""
function _missing_explicit_invoke_mis(codeinfos::Vector{Any}, seen::Set{Any})
    out = Any[]
    for i in 2:2:length(codeinfos)
        src = codeinfos[i]
        src isa Core.CodeInfo || continue
        for stmt in src.code
            stmt isa Expr || continue
            mi = nothing
            if stmt.head === :invoke && !isempty(stmt.args)
                target = stmt.args[1]
                mi = target isa Core.MethodInstance ? target :
                     target isa Core.CodeInstance ? target.def : nothing
            elseif stmt.head === :call && length(stmt.args) >= 3 &&
                   stmt.args[1] === Core.invoke_in_world
                target = stmt.args[3]
                f = target isa GlobalRef ?
                    (try getfield(target.mod, target.name) catch; nothing end) : target
                f isa Function || continue
                arg_types = Any[]
                valid = true
                for arg in stmt.args[4:end]
                    T = if arg isa Core.SSAValue && src.ssavaluetypes isa Vector &&
                           arg.id <= length(src.ssavaluetypes)
                        CC.widenconst(src.ssavaluetypes[arg.id])
                    else
                        Core.Typeof(arg)
                    end
                    T isa Type || (valid = false; break)
                    push!(arg_types, T)
                end
                if valid
                    ats = Tuple(arg_types)
                    m = try which(f, ats) catch; nothing end
                    m === nothing || (mi = CC.specialize_method(
                        m, Tuple{Core.Typeof(f), arg_types...}, Core.svec()))
                end
            else
                continue
            end
            mi isa Core.MethodInstance || continue
            mi in seen && continue
            push!(seen, mi)
            push!(out, mi)
        end
    end
    return out
end

"""
    collect_closed_world(entries::Vector{Any}; verify::Bool=false)
        -> Vector{Any}   # alternating CodeInstance, CodeInfo pairs

Collect the closed transitive callgraph for the given entry
`MethodInstance`s under the WASM overlay interpreter. With `verify=true`,
run the upstream trim verifier (throws `Core.TrimFailure` with
source-located diagnostics when dynamic dispatch remains — the same
"abstract inference unsupported" boundary WasmTarget's diagnostics guard,
but reported far better).
"""
# WASMTARGET dynamic dispatch: trim/inference drops `dynamic` calls (open-world) —
# the applicable method specializations are never collected, so func_registry has
# nothing for the call site to dispatch over. Scan the collected IR for dynamic
# calls `g(…, x::abstract, …)` and return the MethodInstances of the applicable
# CONCRETE-STRUCT specializations, so a follow-up collection round compiles them
# (then `_try_inline_typeid_dispatch` builds a runtime typeId switch over them).
# Surfaced by Markdown.plain/show recursion over heterogeneous AST nodes.
function _dynamic_dispatch_candidate_mis(codeinfos::Vector{Any}, seen::Set{Any})
    out = Any[]
    # dart builds dispatch rows only for classes in the closed component. Mirror that
    # boundary: a Julia method's concrete dispatch type must occur in the collected
    # program's signatures/SSA types/allocations. Enumerating every method below an
    # abstract slot pulled unrelated BigFloat/MPFR code into integer-only modules and
    # forced the now-deleted trap-repair policy.
    runtime_types = Set{DataType}()
    function observe_type!(@nospecialize(T))
        if T isa Union
            foreach(observe_type!, Base.uniontypes(T))
        elseif T isa DataType
            isconcretetype(T) && push!(runtime_types, T)
        end
        return
    end
    for j in 1:2:length(codeinfos)
        (j + 1 <= length(codeinfos) && codeinfos[j] isa Core.CodeInstance &&
         codeinfos[j + 1] isa Core.CodeInfo) || continue
        local mi = codeinfos[j].def isa Core.MethodInstance ? codeinfos[j].def : codeinfos[j].def.def
        local sig = mi.specTypes
        sig isa DataType && foreach(observe_type!, sig.parameters)
        local src0 = codeinfos[j + 1]
        local ss0 = src0.ssavaluetypes
        ss0 isa Vector && foreach(t -> observe_type!(CC.widenconst(t)), ss0)
        for stmt0 in src0.code
            if stmt0 isa Expr && stmt0.head === :new && !isempty(stmt0.args)
                local nt = stmt0.args[1]
                local T = nt isa GlobalRef ? (try getfield(nt.mod, nt.name) catch; nothing end) : nt
                observe_type!(T)
            end
        end
    end
    # march16: OBSERVED dynamic-call signatures (SSA callee, inferred arg types) —
    # closure bodies specialize against these (dart's typed vtable entries; Julia's
    # inference makes the body REAL instead of an any-erased stub).
    dyn_sigs = Set{Tuple}()
    callable_types = Set{DataType}()
    i = 1
    _fn_callables = Set{DataType}()   # per-function staging (folded on co-occurrence)
    _fn_has_dyn = false
    function observe_callable!(@nospecialize(T))
        if T isa Union
            foreach(observe_callable!, Base.uniontypes(T))
        elseif T isa DataType && T <: Function
            if is_closure_type(T)
                local root = T.name.module
                while parentmodule(root) !== root
                    root = parentmodule(root)
                end
                (root === Main || T <: _RuntimeComposition) && push!(_fn_callables, T)
            elseif isdefined(T, :instance)
                # A named/generic function singleton is Dart's static tear-off
                # counterpart. Enrollment remains co-occurrence-gated below.
                push!(_fn_callables, T)
            end
        end
        return
    end
    while i + 1 <= length(codeinfos)
        ci, src = codeinfos[i], codeinfos[i + 1]
        i += 2
        (ci isa Core.CodeInstance && src isa Core.CodeInfo) || continue
        # march16 co-occurrence fold: a function's constructed closures enroll ONLY
        # if that function ALSO makes dynamic (SSA-callee) calls — enrolling every
        # userland closure perturbed modules with purely-static closures (the
        # randsubseq suite regression).
        if _fn_has_dyn
            union!(callable_types, _fn_callables)
        end
        empty!(_fn_callables); _fn_has_dyn = false
        host_mi = ci.def isa Core.MethodInstance ? ci.def : ci.def.def
        hsig = host_mi.specTypes
        hparams = (hsig isa DataType && hsig <: Tuple) ? collect(hsig.parameters) : Any[]
        ssat = src.ssavaluetypes
        # Optimized IR often folds `%new(closure, captures...)` into a constant
        # tuple followed by getfield. The concrete closure types still inhabit SSA
        # types, so collect from that semantic source as well as explicit :new.
        ssat isa Vector && foreach(t -> observe_callable!(CC.widenconst(t)), ssat)
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
                # scope: USERLAND closures only — Base/stdlib-internal closures are
                # statically called (never through the vtable); enrolling them all
                # exploded the blast radius (a _growend! trampoline mis-built).
                observe_callable!(_T)   # staged; folds only on co-occurrence
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
                if _dok && !isempty(_dargs)
                    push!(dyn_sigs, Tuple(_dargs))
                    _fn_has_dyn = true
                end
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
                 Tp in runtime_types && !(Tp <: Tuple) && Tp !== String && Tp !== Symbol) || continue
                spec = ntuple(j -> j == p ? Tp : atypes[j], length(atypes))
                ssig = try Tuple{Core.Typeof(g), spec...} catch; continue end
                cmi = try CC.specialize_method(m, ssig, Core.svec()) catch; continue end
                cmi in seen && continue
                push!(seen, cmi)
                push!(out, cmi)
            end
        end
    end

    _fn_has_dyn && union!(callable_types, _fn_callables)
    # cross-product: each runtime callable type × each observed dynamic-call
    # signature of matching arity → a TYPED body specialization (the vtable's
    # typed entry; inference compiles the body for real)
    for _T in callable_types
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
            end
        end
    end
    return out
end

# Dynamic-dispatch selector roots, distinct from the ordinary dependencies that
# their candidate compilation discovers transitively.
const _DYNAMIC_ROOT_MIS = Base.RefValue{Set{Any}}(Set{Any}())

# march16: the conversion-arm allowlist — callable types whose bodies the candidate
# fixpoint enrolled (threaded collect_closed_world → trim_compile_plan, the same
# lifecycle as TRIM_IR_CACHE; reset at each collect).
const _ENROLLED_CALLABLE_TYPES = Base.RefValue{Set{DataType}}(Set{DataType}())

function collect_closed_world(entries::Vector{Any}; verify::Bool=false)
    _ENROLLED_CALLABLE_TYPES[] = Set{DataType}()
    _DYNAMIC_ROOT_MIS[] = Set{Any}()
    # Fresh cache partition per collection: see cache_token in WasmInterpreter.
    interp = WasmInterpreter(Base.RefValue(0))
    invokelatest_queue = CC.CompilationQueue(; interp)
    codeinfos = Any[]
    workqueue = CC.CompilationQueue(; interp)
    append!(workqueue, entries)
    CC.compile!(codeinfos, workqueue; invokelatest_queue)
    CC.compile!(codeinfos, invokelatest_queue; invokelatest_queue)
    # Julia's queue may leave an explicit invoke with an abstract callable slot
    # as an IR edge without materializing its body (e.g. Base.with_output_color's
    # `Function` argument). A closed world cannot defer that edge to codegen.
    # Enroll every explicit invoke to a fixpoint before selector discovery.
    base_mis = Set{Any}()
    for k in 1:2:length(codeinfos)
        codeinfos[k] isa Core.CodeInstance && push!(base_mis, codeinfos[k].def)
    end
    invoke_seen = copy(base_mis)
    for _round in 1:8
        extra_invokes = _missing_explicit_invoke_mis(codeinfos, invoke_seen)
        isempty(extra_invokes) && break
        invoke_interp = WasmInterpreter(Base.RefValue(0))
        invoke_ci = Any[]
        invoke_wq = CC.CompilationQueue(; interp=invoke_interp)
        invoke_ilq = CC.CompilationQueue(; interp=invoke_interp)
        append!(invoke_wq, extra_invokes)
        CC.compile!(invoke_ci, invoke_wq; invokelatest_queue=invoke_ilq)
        CC.compile!(invoke_ci, invoke_ilq; invokelatest_queue=invoke_ilq)
        added = false
        for k in 1:2:length(invoke_ci)
            (invoke_ci[k] isa Core.CodeInstance && invoke_ci[k + 1] isa Core.CodeInfo) || continue
            mi = invoke_ci[k].def
            mi in base_mis && continue
            push!(base_mis, mi)
            push!(codeinfos, invoke_ci[k], invoke_ci[k + 1])
            added = true
        end
        added || break
    end
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
        seen_disp = Set{Any}()   # dedup candidate MIs across fixpoint rounds
        for _round in 1:8
            extra = _dynamic_dispatch_candidate_mis(codeinfos, seen_disp)
            extra = Any[mi for mi in extra if !(mi in base_mis)]
            union!(_DYNAMIC_ROOT_MIS[], extra)
            # march16: remember WHICH callable types were enrolled — the conversion
            # arm converts ONLY these (converting every userland closure pair changed
            # unrelated compiles: the randsubseq suite regression, bisect-certified).
            for mi in extra
                local st = mi.specTypes
                if st isa DataType && st <: Tuple && length(st.parameters) >= 1
                    local ft = st.parameters[1]
                    ft isa DataType && ft <: Function && push!(_ENROLLED_CALLABLE_TYPES[], ft)
                end
            end
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
    # Functions pulled in only by dispatch-candidate discovery are registered as
    # candidates rather than ordinary direct-call targets.
    dispatch_candidates = Set{Any}()
    # Pre-seed with entry names: a discovered function processed before its
    # same-named entry must not claim the entry's export name (duplicate-export
    # validation failure in multi-function modules).
    used_names = Set{String}(values(entry_keys))
    seen_sigs = Set{Tuple{Any, Any}}()   # T1.1 step 3: dedup the function list by (f, arg_types)
    i = 1
    while i + 1 <= length(codeinfos)
        ci, src = codeinfos[i], codeinfos[i + 1]
        i += 2
        (ci isa Core.CodeInstance && src isa Core.CodeInfo) || continue
        mi = ci.def isa Core.MethodInstance ? ci.def : ci.def.def
        sig = mi.specTypes
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
            # its target. USERLAND ONLY: converting Base-internal closure pairs
            # (previously skipped) changed unrelated compiles — randsubseq's
            # internals regressed in the suite context (the march-16 gate catch).
            (ftyp in _ENROLLED_CALLABLE_TYPES[] || ftyp <: _RuntimeComposition) && (f = ftyp)
        end
        if f === nothing
            @debug "trim_compile_plan: skipping non-singleton callable" sig
            continue
        end
        arg_types = Tuple(sig.parameters[2:end])
        # An unspecialized `Vararg{T}` is not a physical Wasm parameter. Calls
        # with a known arity are represented by their concrete specialization;
        # intrinsic/error constructors are lowered at the call site. Never let
        # the open-ended signature become a second, fake compilation route.
        any(T -> T isa Core.TypeofVararg, arg_types) && continue
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
        # Only discovery ROOTS are selector candidates. Dependencies compiled
        # transitively with a root remain ordinary cross-call-visible functions.
        if mi in _DYNAMIC_ROOT_MIS[] && !haskey(entry_keys, mi)
            push!(dispatch_candidates, (f, arg_types))
        end
    end
    _TRIM_DISPATCH_CANDIDATES[] = dispatch_candidates
    return functions, ir_cache
end

# (f, arg_types) keys discovered solely as dynamic-dispatch candidates.
const _TRIM_DISPATCH_CANDIDATES = Ref{Set{Any}}(Set{Any}())
