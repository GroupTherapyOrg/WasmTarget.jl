# The interpreter the closed world is inferred with (dev/LEDGER.md D3, D42): Julia's own trim inference
# (src/julia/subset.jl) run over WasmTarget's method table. dart2wasm compiles dart:core through the
# wasm target's patch libraries (sdk/lib/libraries.yaml names them for target.dart's `name`, and the CFE
# merges each `@patch` member over the platform's); Julia's counterpart is an overlay method table,
# consulted before Base's, which GPUCompiler.jl uses to compile Base for a device without touching the
# host's Base. Every overlay lives in src/patch/; this file holds the table and the interpreter that
# applies it.

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
@quarantine "Julia replaces a Base method for one compiler by an overlay method table, its own @MethodTable" Base.Experimental.var"@MethodTable" Base.Experimental.@MethodTable METHOD_TABLE

"""
    WasmCacheOwner

The owner of every `CodeInstance` WasmTarget's inference makes: Julia's integrated cache keeps the
code inferred over `METHOD_TABLE` apart from the native code inferred over Base's alone (owner
`nothing`), so neither is ever taken for the other.

precedent(julia: GPUCompiler.jl's GPUCompilerCacheToken, the cache_owner of its interpreter).
"""
@quarantine "Julia's integrated code cache is partitioned by an interpreter's cache owner" Core.DataType struct WasmCacheOwner end

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
@quarantine "Julia folds a call natively only through a method table view that answers isoverlayed false" Core.Compiler.MethodTableView struct WasmMethodTable <: Core.Compiler.MethodTableView
    overlay::Core.Compiler.OverlayMethodTable
    WasmMethodTable(world::UInt) = new(Core.Compiler.OverlayMethodTable(world, METHOD_TABLE))
end
@quarantine "a method table view answers its matches, here the overlay's" Core.Compiler.findall Core.Compiler.findall(@nospecialize(sig::Type), table::WasmMethodTable; limit::Int = -1) = Core.Compiler.findall(sig, table.overlay; limit)
@quarantine "a method table view answers its unique match, here the overlay's" Core.Compiler.findsup Core.Compiler.findsup(@nospecialize(sig::Type), table::WasmMethodTable) = Core.Compiler.findsup(sig, table.overlay)
@quarantine "a method table view answers whether Julia may fold its calls natively; every overlay is consistent" Core.Compiler.isoverlayed Core.Compiler.isoverlayed(::WasmMethodTable) = false

"""
    WasmInterpreter(world; inf_params)

Julia's `NativeInterpreter` with GPUCompiler's `GPUInterpreter`'s two changes: its method table is
`METHOD_TABLE` overlaid on Base's at `world` (`WasmMethodTable`, cached as the native one's is),
and its cache owner is `WasmCacheOwner()`. Every other answer, its parameters, its inference cache,
its codegen cache of inferred sources (`Compiler.compile!` reads the field `codegen`) and its
compilation signatures, is the native interpreter's.

precedent(julia: GPUCompiler.jl's GPUInterpreter, Core.Compiler.NativeInterpreter).
"""
@quarantine "Julia's inference runs over an overlay method table only through an AbstractInterpreter of its own" Core.Compiler.AbstractInterpreter struct WasmInterpreter <: Core.Compiler.AbstractInterpreter
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
@quarantine "an AbstractInterpreter answers its inference parameters, NativeInterpreter's" Core.Compiler.InferenceParams Core.Compiler.InferenceParams(interp::WasmInterpreter) = interp.inf_params
@quarantine "an AbstractInterpreter answers its optimization parameters, NativeInterpreter's" Core.Compiler.OptimizationParams Core.Compiler.OptimizationParams(interp::WasmInterpreter) = interp.opt_params
@quarantine "an AbstractInterpreter answers the world it infers in" Core.Compiler.get_inference_world Core.Compiler.get_inference_world(interp::WasmInterpreter) = interp.world
@quarantine "an AbstractInterpreter keeps its local inference cache" Core.Compiler.get_inference_cache Core.Compiler.get_inference_cache(interp::WasmInterpreter) = interp.inf_cache
@quarantine "an AbstractInterpreter keeps the sources it infers for codegen; Compiler.compile! reads them" Core.Compiler.codegen_cache Core.Compiler.codegen_cache(interp::WasmInterpreter) = interp.codegen
@quarantine "the overlay is applied by the interpreter's method table, GPUInterpreter's method_table" Core.Compiler.method_table Core.Compiler.method_table(interp::WasmInterpreter) = interp.method_table
@quarantine "the overlaid code is cached under its own owner, GPUInterpreter's cache_owner" Core.Compiler.cache_owner Core.Compiler.cache_owner(::WasmInterpreter) = WasmCacheOwner()
@quarantine "NativeInterpreter infers each call's compilation signature too, as the closed world needs" Core.Compiler.infer_compilation_signature Core.Compiler.infer_compilation_signature(::WasmInterpreter) = true

# Julia 1.13 keeps a NativeInterpreter's trees when the runtime asks it to (its flag); 1.12 discards them
@quarantine "NativeInterpreter keeps its trees on the runtime's flag from Julia 1.13" Core.Compiler.may_discard_trees function Core.Compiler.may_discard_trees(::WasmInterpreter)::Bool
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
@quarantine "Julia's ci_has_source reads a stored source into the codegen cache for the native owner alone" Core.Compiler.ci_has_source function Core.Compiler.ci_has_source(interp::WasmInterpreter, code::Core.CodeInstance)::Bool
    local codegen = Core.Compiler.codegen_cache(interp)
    Core.Compiler.use_const_api(code) && return true
    haskey(codegen, code) && return true
    local inf = @atomic :monotonic code.inferred
    inf isa String && (inf = Core.Compiler._uncompressed_ir(code, inf))
    inf isa Core.CodeInfo || return false
    codegen[code] = inf
    return true
end
