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
function _missing_explicit_invoke_mis(codeinfos::Vector{Any}, seen::Set{Any},
                                      superseded::Set{Any})
    out = Any[]
    numeric_types = IdDict{Core.CodeInfo,Dict{Int,Type}}()
    lookup_table = CC.method_table(WasmInterpreter(Base.RefValue(0)))
    ir_arg_type = function(arg, src)
        joins = get!(numeric_types, src) do
            propagate_numeric_value_types(src.code, src.ssavaluetypes)
        end
        T = if arg isa Core.SSAValue && haskey(joins, arg.id)
            joins[arg.id]
        elseif arg isa Core.SSAValue && src.ssavaluetypes isa Vector &&
               1 <= arg.id <= length(src.ssavaluetypes)
            src.ssavaluetypes[arg.id]
        elseif arg isa Core.Argument && src.slottypes isa Vector &&
               1 <= arg.n <= length(src.slottypes)
            src.slottypes[arg.n]
        elseif arg isa GlobalRef && isdefined(arg.mod, arg.name)
            Core.Const(getfield(arg.mod, arg.name))
        elseif arg isa QuoteNode
            Core.Const(arg.value)
        else
            Core.Const(arg)
        end
        T = CC.widenconst(T)
        return T isa Type ? T : nothing
    end
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
                original_mi = mi
                # Explicit invoke records the selected Method, but Julia may leave
                # its MethodInstance abstract. WT's subset monomorphizes: rebuild
                # the MI from the concrete call-site SSA types, exactly as the
                # compiler would for an ordinary specialized call.
                if mi isa Core.MethodInstance && length(stmt.args) >= 2
                    fref = stmt.args[2]
                    f = fref isa GlobalRef && isdefined(fref.mod, fref.name) ?
                        getfield(fref.mod, fref.name) : fref
                    arg_types = Any[ir_arg_type(arg, src) for arg in stmt.args[3:end]]
                    if f isa Function && all(T -> T isa Type && isconcretetype(T), arg_types)
                        ftype = Tuple{Core.Typeof(f), arg_types...}
                        # Re-resolve with the same overlay table used by the
                        # closed-world compiler. An explicit invoke can retain
                        # Base's abstract Vararg MI even though the concrete
                        # call must dispatch to a Wasm overlay specialization.
                        matches = CC.findall(ftype, lookup_table; limit=-1)
                        if matches !== nothing && !isempty(matches)
                            mi = CC.specialize_method(matches[1])
                        end
                    end
                end
                if mi isa Core.MethodInstance && original_mi isa Core.MethodInstance &&
                   mi !== original_mi
                    # Keep the optimized IR valid Julia while making its edge agree
                    # with the Wasm overlay dispatch selected for the concrete call.
                    # The superseded abstract/native subtree is pruned below.
                    stmt.args[1] = mi
                    push!(superseded, original_mi)
                end
            elseif stmt.head === :call && length(stmt.args) >= 3 &&
                   stmt.args[1] === Core.invoke_in_world
                target = stmt.args[3]
                f = target isa GlobalRef && isdefined(target.mod, target.name) ?
                    getfield(target.mod, target.name) : target
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
                    m = hasmethod(f, ats) ? which(f, ats) : nothing
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
    observed_type_nodes = Set{Any}()
    function observe_type!(@nospecialize(T))
        T in observed_type_nodes && return
        push!(observed_type_nodes, T)
        if T isa Union
            foreach(observe_type!, Base.uniontypes(T))
        elseif T isa DataType
            isconcretetype(T) && push!(runtime_types, T)
            # Instantiated generic fields encode runtime classes in their type
            # arguments (for example DateFormat's Tuple of DatePart{'y'}/Delim
            # nodes). They are part of the closed component even when inference
            # never exposes each nested class as a standalone SSA type.
            foreach(observe_type!, T.parameters)
        elseif T isa UnionAll
            observe_type!(Base.unwrap_unionall(T))
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
                local T = nt isa GlobalRef && isdefined(nt.mod, nt.name) ?
                          getfield(nt.mod, nt.name) : nt
                observe_type!(T)
            end
        end
    end
    # march16: OBSERVED dynamic-call signatures (SSA callee, inferred arg types) —
    # closure bodies specialize against these (dart's typed vtable entries; Julia's
    # inference makes the body REAL instead of an any-erased stub).
    callable_invocations = Set{Tuple{DataType,Tuple}}()
    i = 1
    _fn_callables = Set{DataType}()   # per-function staging (folded on co-occurrence)
    _fn_dyn_sigs = Set{Tuple}()
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
    function flush_callable_invocations!()
        for T in _fn_callables, sig in _fn_dyn_sigs
            push!(callable_invocations, (T, sig))
        end
        empty!(_fn_callables)
        empty!(_fn_dyn_sigs)
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
        flush_callable_invocations!()
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
                local _T = _nt isa GlobalRef && isdefined(_nt.mod, _nt.name) ? getfield(_nt.mod, _nt.name) :
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
                    push!(_fn_dyn_sigs, Tuple(_dargs))
                end
            end
            (stmt isa Expr && stmt.head === :call && length(stmt.args) >= 2) || continue
            cref = stmt.args[1]
            cref isa GlobalRef || continue
            isdefined(cref.mod, cref.name) || continue
            g = getfield(cref.mod, cref.name)
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
                elseif a isa GlobalRef && isdefined(a.mod, a.name)
                    Core.Typeof(getfield(a.mod, a.name))
                elseif a isa GlobalRef
                    Any
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
            ms = collect(methods(g, Tuple{atypes...}))
            # march13 (dart: ALL targetCount>1 dispatch through the table,
            # dispatch_table.dart:401-403): the old ≤8 cap CIRCULARLY ABANDONED
            # ≥9-method dynamic sites — it "left them to the dispatch table", but the
            # table only builds from registered specializations, which only register
            # through THIS discovery → nothing registered, no table, unreachable stub
            # (the pinned two-arg megamorphic bug). Discovery now feeds BOTH mechanisms;
            # the inline-vs-table split happens downstream by count (threshold=9).
            isempty(ms) && continue
            for m in ms
                unwrapped_sig = Base.unwrap_unionall(m.sig)
                unwrapped_sig isa DataType || continue
                msig = collect(unwrapped_sig.parameters)
                isempty(msig) && continue
                last_param = msig[end]
                is_vararg = last_param isa Core.TypeofVararg
                fixed_args = length(msig) - 1 - (is_vararg ? 1 : 0)
                (!is_vararg && length(msig) != length(atypes) + 1) && continue
                (is_vararg && length(atypes) < fixed_args) && continue
                declared = if p <= fixed_args
                    msig[p + 1]
                elseif is_vararg
                    last_param.T
                else
                    continue
                end
                declared_bound = declared isa TypeVar ? declared.ub : declared
                declared_bound isa Type || continue

                # A generic method (`Any`, abstract, or TypeVar parameter) is still a
                # selector target for every observed closed-world class admitted by
                # both the call-site type and the method bound. Dart constructs the
                # same target set from instantiated classes, not merely from concrete
                # parameter annotations on source methods.
                candidates = DataType[]
                for runtime_type in runtime_types
                    (runtime_type isa DataType && isconcretetype(runtime_type) &&
                     isstructtype(runtime_type) && !(runtime_type <: Tuple) &&
                     runtime_type !== String && runtime_type !== Symbol) || continue
                    (runtime_type <: atypes[p] && runtime_type <: declared_bound) || continue
                    push!(candidates, runtime_type)
                end
                for target_type in candidates
                    spec = ntuple(j -> j == p ? target_type : atypes[j], length(atypes))
                    ssig = Tuple{Core.Typeof(g), spec...}
                    ssig <: m.sig || continue
                    cmi = CC.specialize_method(m, ssig, Core.svec())
                    cmi in seen && continue
                    push!(seen, cmi)
                    push!(out, cmi)
                end
            end
        end
    end

    flush_callable_invocations!()
    # Each function-local callable/signature pair becomes one typed body
    # specialization. Never form a component-wide Cartesian product: dart's
    # selector rows are call-site scoped, and unrelated same-arity signatures
    # must not enroll new bodies.
    for (_T, ds) in callable_invocations
        local _mms2 = Base._methods_by_ftype(
            Tuple{_T, Vararg{Any}}, nothing, -1, Base.get_world_counter())
        for mm in (_mms2 === nothing ? () : _mms2)
            local m = mm.method
            local msig = Base.unwrap_unionall(m.sig)
            msig isa DataType || continue
            local mps = collect(msig.parameters)
            (length(mps) >= 1 && _T <: mps[1]) || continue
            local marity = length(mps) - 1
            length(ds) == marity || continue
            local ssig = Tuple{_T, ds...}
            # the observed args must be admissible for the method
            (ssig <: m.sig) || continue
            local cmi = CC.specialize_method(m, ssig, Core.svec())
            cmi === nothing && continue
            cmi in seen && continue
            push!(seen, cmi)
            push!(out, cmi)
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

"""Keep only code reachable from roots when declared imports are external leaves."""
function _prune_external_leaf_subgraphs(codeinfos::Vector{Any}, entries::Vector{Any},
                                        external_leaves::Set{Any})
    isempty(external_leaves) && return codeinfos
    pairs = Dict{Any,Tuple{Any,Core.CodeInfo}}()
    for i in 1:2:length(codeinfos)
        (i + 1 <= length(codeinfos) && codeinfos[i] isa Core.CodeInstance &&
         codeinfos[i + 1] isa Core.CodeInfo) || continue
        mi = codeinfos[i].def isa Core.MethodInstance ? codeinfos[i].def : codeinfos[i].def.def
        pairs[mi] = (codeinfos[i], codeinfos[i + 1])
    end
    reachable = Set{Any}()
    queue = Any[entries...]
    while !isempty(queue)
        mi = pop!(queue)
        mi in reachable && continue
        push!(reachable, mi)
        mi in external_leaves && continue
        pair = get(pairs, mi, nothing)
        pair === nothing && continue
        for stmt in pair[2].code
            stmt isa Expr || continue
            if stmt.head === :invoke && !isempty(stmt.args)
                target = stmt.args[1]
                target_mi = target isa Core.MethodInstance ? target :
                            target isa Core.CodeInstance ? target.def : nothing
                target_mi isa Core.MethodInstance && push!(queue, target_mi)
            end
        end
    end
    out = Any[]
    for i in 1:2:length(codeinfos)
        (i + 1 <= length(codeinfos) && codeinfos[i] isa Core.CodeInstance &&
         codeinfos[i + 1] isa Core.CodeInfo) || continue
        mi = codeinfos[i].def isa Core.MethodInstance ? codeinfos[i].def : codeinfos[i].def.def
        mi in reachable || continue
        mi in external_leaves && continue
        push!(out, codeinfos[i], codeinfos[i + 1])
    end
    return out
end

function collect_closed_world(entries::Vector{Any}; verify::Bool=false,
                              external_leaves::Set{Any}=Set{Any}())
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
    # Imports are typed call-graph leaves. Julia inference may inspect their
    # native fallback bodies, but those bodies and their dependencies do not
    # belong to the Wasm component. Cut them before invoke completion and
    # dynamic-dispatch discovery so external implementation details can never
    # contaminate the closed world.
    codeinfos = _prune_external_leaf_subgraphs(codeinfos, entries, external_leaves)
    # Julia's queue may leave an explicit invoke with an abstract callable slot
    # as an IR edge without materializing its body (e.g. Base.with_output_color's
    # `Function` argument). A closed world cannot defer that edge to codegen.
    # Enroll every explicit invoke to a fixpoint before selector discovery.
    base_mis = Set{Any}()
    for k in 1:2:length(codeinfos)
        codeinfos[k] isa Core.CodeInstance && push!(base_mis, codeinfos[k].def)
    end
    invoke_seen = union(copy(base_mis), external_leaves)
    superseded_invokes = Set{Any}()
    while true
        extra_invokes = _missing_explicit_invoke_mis(codeinfos, invoke_seen,
                                                       superseded_invokes)
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
    if !isempty(superseded_invokes)
        codeinfos = _prune_external_leaf_subgraphs(
            codeinfos, entries, union(external_leaves, superseded_invokes))
        empty!(base_mis)
        for k in 1:2:length(codeinfos)
            codeinfos[k] isa Core.CodeInstance && push!(base_mis, codeinfos[k].def)
        end
    end
    # WASMTARGET dynamic dispatch: discover every target admitted by the closed
    # component, to a real fixpoint. This is part of compilation correctness and
    # therefore has no environment opt-out or arbitrary round/method ceiling.
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
    # whether or not discovery runs.
    let
        seen_disp = Set{Any}()   # dedup candidate MIs across fixpoint rounds
        while true
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
function trim_compile_plan(entries_named::Vector; external_entries::Vector=Any[])
    entry_mis = Any[]
    entry_keys = Dict{Any, String}()   # mi → requested name
    entry_values = Dict{Any,Any}()     # explicit capturing-closure instances
    for (f, arg_types, name) in entries_named
        mi = entry_method_instance(f, arg_types)
        push!(entry_mis, mi)
        entry_keys[mi] = name
        entry_values[mi] = f
    end
    external_mis = Set{Any}()
    for entry in external_entries
        f, arg_types = entry[1], entry[2]
        push!(external_mis, entry_method_instance(f, arg_types))
    end
    codeinfos = collect_closed_world(entry_mis; external_leaves=external_mis)

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
        f = get(entry_values, mi, nothing)
        if f !== nothing
            # Explicit roots retain their actual value. This is load-bearing for
            # capturing closures: the type has no singleton instance, while root
            # bindings may validly substitute every captured field and elide the
            # runtime closure context.
        elseif ftyp isa DataType && isdefined(ftyp, :instance)
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
        # `check_world_bounded(::TypeName)` is a closed-world metadata operation,
        # lowered directly at its call site from TypeName constants. Enrolling
        # Base's mutable BindingPartition walker would create a second runtime
        # route and require Julia-internal mutable-world objects WT does not own.
        ((f === Base.check_world_bounded || f === _closed_world_type_bounds) &&
         arg_types == (Core.TypeName,)) && continue
        ((f === Base.isvisible || f === _closed_world_isvisible) &&
         arg_types == (Symbol, Module, Module)) && continue
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
