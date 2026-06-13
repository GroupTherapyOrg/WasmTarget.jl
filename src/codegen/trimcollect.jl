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

function collect_closed_world(entries::Vector{Any}; verify::Bool=false)
    # Fresh cache partition per collection: see cache_token in WasmInterpreter.
    interp = WasmInterpreter(Base.RefValue(0))
    invokelatest_queue = CC.CompilationQueue(; interp)
    codeinfos = Any[]
    workqueue = CC.CompilationQueue(; interp)
    append!(workqueue, entries)
    CC.compile!(codeinfos, workqueue; invokelatest_queue)
    CC.compile!(codeinfos, invokelatest_queue; invokelatest_queue)
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
    # Pre-seed with entry names: a discovered function processed before its
    # same-named entry must not claim the entry's export name (duplicate-export
    # validation failure in multi-function modules).
    used_names = Set{String}(values(entry_keys))
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
        end
        if f === nothing
            @debug "trim_compile_plan: skipping non-singleton callable" sig
            continue
        end
        arg_types = Tuple(sig.parameters[2:end])
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
    end
    return functions, ir_cache
end
