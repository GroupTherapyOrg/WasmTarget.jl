# WasmInterpreter: the interpreter WasmTarget infers a program's closed world with, kept in a package of
# its own so that its compiled code (Julia's Compiler, specialized for this interpreter, tens of seconds
# to compile) is built into this package's image once, when this package changes, and never again when
# WasmTarget's sources change (WasmTarget's landing check precompiles WasmTarget on every change: the
# interpreter in WasmTarget's own image added about 19 CPU-s to each, a precompile workload compiling
# it lazily instead about 70 s to every process's first compile, 2026-10-29).
#
# precedent(julia: GPUCompiler.jl, the package holding GPUInterpreter, its method table and its
# precompiled Compiler code, which CUDA.jl's frequently changing sources build on; dart: the wasm
# target's @patch libraries, sdk/lib/_internal/wasm, which the overlay table is the counterpart of).
# It holds exactly the interpreter, its method table and the closed-world walk (WasmTarget's
# test/src/interpreter.jl reads its names); every overlay lives in WasmTarget's src/patch/, and
# WasmTarget's src/julia/subset.jl, which runs the walk, is the one place that calls it.
module WasmInterpreter


"""
    METHOD_TABLE

WasmTarget's overlay method table: the methods that replace a Base method for a wasm program, each
an `Base.Experimental.@overlay METHOD_TABLE` definition in src/patch/. Inference of a program
(`WasmInterpreter`) finds a method here before Base's; the host's Base is never changed.

precedent(julia: GPUCompiler.jl's GLOBAL_METHOD_TABLE, CUDA.jl's method_table; dart: the wasm target's
patch libraries, sdk/lib/libraries.yaml). Julia's differs: dart merges a patch into its library before
compiling, where Julia keeps the overlay in a table of its own, which only an interpreter that asks
for it consults.
"""
# Julia replaces a Base method for one compiler by an overlay method table, its own @MethodTable (Julia API: Base.Experimental.var"@MethodTable")
Base.Experimental.@MethodTable METHOD_TABLE

"""
    WasmCacheOwner

The owner of every `CodeInstance` WasmTarget's inference makes: Julia's integrated cache keeps the
code inferred over `METHOD_TABLE` apart from the native code inferred over Base's alone (owner
`nothing`), so neither is ever taken for the other.

precedent(julia: GPUCompiler.jl's GPUCompilerCacheToken, the cache_owner of its interpreter).
"""
# Julia's integrated code cache is partitioned by an interpreter's cache owner (Julia API: Core.DataType)
struct WasmCacheOwner end

"""
    WasmMethodTable(world)

The method table inference reads: `METHOD_TABLE` overlaid on Base's at `world`, Julia's
`OverlayMethodTable`, each query answered by it. It answers `isoverlayed` false, which Julia's
interface asks of a view so that it may evaluate a call natively at compile time (concrete and
semi-concrete evaluation run the native method): every overlay is a consistent one, its answers and
its errors the native method's (`Base.Experimental.@consistent_overlay`, each checked against native
Julia), so a call evaluated natively folds to the value the overlay computes, and the closed world of
a program no overlay reaches is the native one.

precedent(julia: Core.Compiler's MethodTableView interface, its `isoverlayed`, and
`:consistent_overlay`, under which Julia folds an overlaid call by the native method). Julia's
differs: it reads the consistency of one overlay where the call resolves to it, and treats a call it
cannot resolve as possibly reaching an overlay that is not consistent, so an OverlayMethodTable folds
less than the native table even when empty; here every overlay is consistent by construction.
"""
# Julia folds a call natively only through a method table view that answers isoverlayed false (Julia API: Core.Compiler.MethodTableView)
struct WasmMethodTable <: Core.Compiler.MethodTableView
    overlay::Core.Compiler.OverlayMethodTable
    WasmMethodTable(world::UInt) = new(Core.Compiler.OverlayMethodTable(world, METHOD_TABLE))
end
# a method table view answers its matches, here the overlay's (Julia API: Core.Compiler.findall)
Core.Compiler.findall(@nospecialize(sig::Type), table::WasmMethodTable; limit::Int = -1) = Core.Compiler.findall(sig, table.overlay; limit)
# a method table view answers its unique match, here the overlay's (Julia API: Core.Compiler.findsup)
Core.Compiler.findsup(@nospecialize(sig::Type), table::WasmMethodTable) = Core.Compiler.findsup(sig, table.overlay)
# a method table view answers whether Julia may fold its calls natively; every overlay is consistent (Julia API: Core.Compiler.isoverlayed)
Core.Compiler.isoverlayed(::WasmMethodTable) = false

"""
    WasmInterpreter(world; inf_params)

Julia's `NativeInterpreter` with GPUCompiler's `GPUInterpreter`'s two changes: its method table is
`METHOD_TABLE` overlaid on Base's at `world` (`WasmMethodTable`, cached as the native one's is),
and its cache owner is `WasmCacheOwner()`. Every other answer, its parameters, its inference cache,
its codegen cache of inferred sources (`Compiler.compile!` reads the field `codegen`) and its
compilation signatures, is the native interpreter's.

precedent(julia: GPUCompiler.jl's GPUInterpreter, Core.Compiler.NativeInterpreter).
"""
# Julia's inference runs over an overlay method table only through an AbstractInterpreter of its own (Julia API: Core.Compiler.AbstractInterpreter)
struct WasmInterpreter <: Core.Compiler.AbstractInterpreter
    world::UInt
    method_table::Core.Compiler.CachedMethodTable{WasmMethodTable}
    inf_cache::Vector{Core.Compiler.InferenceResult}
    codegen::IdDict{Core.CodeInstance,Core.CodeInfo}
    inf_params::Core.Compiler.InferenceParams
    opt_params::Core.Compiler.OptimizationParams
    WasmInterpreter(world::UInt; inf_params::Core.Compiler.InferenceParams) =
        new(world, Core.Compiler.CachedMethodTable(WasmMethodTable(world)),
            Core.Compiler.InferenceResult[], IdDict{Core.CodeInstance,Core.CodeInfo}(), inf_params,
            Core.Compiler.OptimizationParams())
end

# the AbstractInterpreter interface, each answer NativeInterpreter's but the method table and the owner
# an AbstractInterpreter answers its inference parameters, NativeInterpreter's (Julia API: Core.Compiler.InferenceParams)
Core.Compiler.InferenceParams(interp::WasmInterpreter) = interp.inf_params
# an AbstractInterpreter answers its optimization parameters, NativeInterpreter's (Julia API: Core.Compiler.OptimizationParams)
Core.Compiler.OptimizationParams(interp::WasmInterpreter) = interp.opt_params
# an AbstractInterpreter answers the world it infers in (Julia API: Core.Compiler.get_inference_world)
Core.Compiler.get_inference_world(interp::WasmInterpreter) = interp.world
# an AbstractInterpreter keeps its local inference cache (Julia API: Core.Compiler.get_inference_cache)
Core.Compiler.get_inference_cache(interp::WasmInterpreter) = interp.inf_cache
# an AbstractInterpreter keeps the sources it infers for codegen; Compiler.compile! reads them (Julia API: Core.Compiler.codegen_cache)
Core.Compiler.codegen_cache(interp::WasmInterpreter) = interp.codegen
# the overlay is applied by the interpreter's method table, GPUInterpreter's method_table (Julia API: Core.Compiler.method_table)
Core.Compiler.method_table(interp::WasmInterpreter) = interp.method_table
# the overlaid code is cached under its own owner, GPUInterpreter's cache_owner (Julia API: Core.Compiler.cache_owner)
Core.Compiler.cache_owner(::WasmInterpreter) = WasmCacheOwner()
# NativeInterpreter infers each call's compilation signature too, as the closed world needs (Julia API: Core.Compiler.infer_compilation_signature)
Core.Compiler.infer_compilation_signature(::WasmInterpreter) = true

# Julia 1.13 keeps a NativeInterpreter's trees when the runtime asks it to (its flag); 1.12 discards them
# NativeInterpreter keeps its trees on the runtime's flag from Julia 1.13 (Julia API: Core.Compiler.may_discard_trees)
function Core.Compiler.may_discard_trees(::WasmInterpreter)::Bool
    @static if VERSION >= v"1.13-"
        return ccall(:jl_get_type_infer_preserve_ir, Int8, ()) == 0
    else
        return true   # 1.12's NativeInterpreter takes AbstractInterpreter's answer
    end
end

# A cached CodeInstance has source when Julia's codegen cache or its stored inferred code holds it:
# Julia's own ci_has_source, its branch for a native CodeInstance (owner nothing) taken for
# WasmTarget's owner, whose code is kept as the native code is. Julia's branch for another owner
# assumes the owner keeps its sources itself, which would leave Compiler.compile! with none.
# Julia's ci_has_source reads a stored source into the codegen cache for the native owner alone (Julia API: Core.Compiler.ci_has_source)
function Core.Compiler.ci_has_source(interp::WasmInterpreter, code::Core.CodeInstance)::Bool
    local codegen = Core.Compiler.codegen_cache(interp)
    Core.Compiler.use_const_api(code) && return true
    haskey(codegen, code) && return true
    local inf = @atomic :monotonic code.inferred
    inf isa String && (inf = Core.Compiler._uncompressed_ir(code, inf))
    inf isa Core.CodeInfo || return false
    codegen[code] = inf
    return true
end


# Julia's closed-world inference for trimming at `world`, of its queue: the entry's MethodInstance and
# each @ccallable as `svec(rettype, signature)`, the item juliac queues for one
# (juliac-buildscript.jl's jl_add_ccallable_entrypoints), whose specialization the inference compiles
# and whose record it keeps for the verifier. It is typeinf_ext_toplevel's trim entry with its
# NativeInterpreters WasmInterpreters, so the closed world is inferred over
# WasmTarget's overlays, walked by Julia's own Compiler.compile!: the queue, then the queue of calls
# made at the latest world (a finalizer, a ccallable's adapter), aliased as Julia aliases it. Julia
# 1.13 adds external_linkage: false, so every body the queue reaches is inferred and none is taken as
# already compiled into a package image (WasmTarget compiles every body to wasm). A call the optimizer
# left to a bare MethodInstance (`_resolve_invokes!`) is inferred and walked too, until none is left.
# the closed world is inferred by Julia's trim entry over WasmTarget's interpreter; the entry builds a NativeInterpreter (Julia API: Core.Compiler.compile!)
function infer_closed_world(queue::Vector{Any}, world::UInt)::Vector{Any}
    local inf_params = Core.Compiler.InferenceParams(; force_enable_inference = true)
    local invokelatest_queue = Core.Compiler.CompilationQueue(; interp = WasmInterpreter(Base.get_world_counter(); inf_params))
    local workqueue = Core.Compiler.CompilationQueue(; interp = WasmInterpreter(world; inf_params))
    local codeinfos = Any[]
    foreach(item -> push!(workqueue, item), queue)
    local walked = 0
    while !isempty(workqueue)
        @static if VERSION >= v"1.13-"
            Core.Compiler.compile!(codeinfos, workqueue; invokelatest_queue, external_linkage = false)
            Core.Compiler.compile!(codeinfos, invokelatest_queue; invokelatest_queue, external_linkage = false)
        else
            Core.Compiler.compile!(codeinfos, workqueue; invokelatest_queue)
            Core.Compiler.compile!(codeinfos, invokelatest_queue; invokelatest_queue)
        end
        local from = walked + 1
        walked = length(codeinfos)
        _resolve_invokes!(codeinfos, from, workqueue)
    end
    return codeinfos
end

# CompilerCaching.jl's resolve_invoke_targets (GPUCompiler's closed-world walk): Julia's inliner leaves
# a call as an :invoke of a bare MethodInstance where the compileable specialization had no
# CodeInstance cached when its caller was optimized, so whether a body holds one depends on what an
# earlier inference happened to cache. Each such call whose specialization a native ABI can call (a
# dispatch tuple, its static parameters resolved) is inferred by the queue's interpreter, the statement
# rewritten in a copy of the body to invoke the CodeInstance, and the CodeInstance queued to be walked.
# A body is never mutated in Julia's cache.
# Julia's inliner leaves a call uncached at optimization as a bare MethodInstance invoke, which CompilerCaching.jl resolves (Julia API: Core.Compiler.typeinf_ext)
function _resolve_invokes!(codeinfos::Vector{Any}, from::Int, workqueue::Core.Compiler.CompilationQueue)::Nothing
    local interp = workqueue.interp
    # the walked entries, each a CodeInstance followed by its CodeInfo or a ccallable's svec alone
    local i = from
    while i <= length(codeinfos)
        local item = codeinfos[i]
        if !(item isa Core.CodeInstance)
            i += 1
            continue
        end
        local src = codeinfos[i + 1]
        if !(src isa Core.CodeInfo)
            i += 2
            continue
        end
        local resolved = src
        for pc in eachindex(resolved.code)
            local stmt = resolved.code[pc]
            local rhs = Meta.isexpr(stmt, :(=)) ? stmt.args[2] : stmt
            (Meta.isexpr(rhs, :invoke) || Meta.isexpr(rhs, :invoke_modify)) && rhs.args[1] isa Core.MethodInstance || continue
            local callee = rhs.args[1]::Core.MethodInstance
            callee.def isa Method && Base.isdispatchtuple(callee.specTypes) &&
                !any(sp -> sp isa TypeVar || sp isa Core.SimpleVector || Core.Compiler.isvarargtype(sp), callee.sparam_vals) || continue
            local ci = Core.Compiler.typeinf_ext(interp, callee, Core.Compiler.SOURCE_MODE_GET_SOURCE)
            ci isa Core.CodeInstance || continue
            resolved === src && (resolved = copy(src))
            local call = Expr(rhs.head, ci, rhs.args[2:end]...)
            resolved.code[pc] = stmt === rhs ? call : Expr(:(=), stmt.args[1], call)
            push!(workqueue, ci)
        end
        codeinfos[i + 1] = resolved
        i += 2
    end
    return nothing
end

# Julia's Compiler is compiled into the system image for NativeInterpreter alone; inferring a program's
# closed world while this package's image is written keeps the code compiled for WasmInterpreter in the
# image, as a package's precompile workload does (GPUCompiler's own)
if Base.generating_output()
    let f = n::Int64 -> (v = Int64[]; for i in 1:n; push!(v, i * i); end; sum(v)),
        mi = Core.Compiler.specialize_method(Base._which(Base.signature_type(f, (Int64,))))
        infer_closed_world(Any[mi], Base.get_world_counter())
    end
end

end # module
