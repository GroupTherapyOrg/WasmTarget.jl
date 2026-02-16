#!/usr/bin/env julia
# PURE-3001: Reclassify COMPILE_ERROR functions with Union signatures
# These have multiple method specializations — try the first/most-common variant

using WasmTarget, Core.Compiler

multi_sigs = [
    ("InliningState", Core.Compiler, "Tuple{Vector{Any}, UInt64, Core.Compiler.AbstractInterpreter}"),
    ("_issubconditional", Core.Compiler, "Tuple{Core.Compiler.ConditionalsLattice{Core.Compiler.PartialsLattice{Core.Compiler.ConstsLattice}}, Core.Compiler.Conditional, Core.Compiler.Conditional, Bool}"),
    ("_typename", Core.Compiler, "Tuple{Any}"),
    ("abstract_call", Core.Compiler, "Tuple{Core.Compiler.AbstractInterpreter, Core.Compiler.ArgInfo, Core.Compiler.StmtInfo, Core.Compiler.InferenceState}"),
    ("add_invoke_edge!", Core.Compiler, "Tuple{Vector{Any}, Any, Core.CodeInstance}"),
    ("assign_parentchild!", Core.Compiler, "Tuple{Core.Compiler.InferenceState, Core.Compiler.InferenceState}"),
    ("getfield_tfunc", Core.Compiler, "Tuple{Core.Compiler.PartialsLattice{Core.Compiler.ConstsLattice}, Any, Any}"),
    ("instanceof_tfunc", Core.Compiler, "Tuple{Any}"),
    ("issubconditional", Core.Compiler, "Tuple{Core.Compiler.ConditionalsLattice{Core.Compiler.PartialsLattice{Core.Compiler.ConstsLattice}}, Core.Compiler.Conditional, Core.Compiler.Conditional}"),
    ("ndigits0zpb", Base, "Tuple{Int64, Int64}"),
    ("resize!", Base, "Tuple{Vector{Any}, Int64}"),
    ("return_cached_result", Core.Compiler, "Tuple{Core.Compiler.NativeInterpreter, Method, Core.CodeInstance, Core.Compiler.InferenceState, Bool, Bool}"),
    ("throw_boundserror", Base, "Tuple{Vector{Any}, Tuple{Int64}}"),
    ("throw_inexacterror", Core, "Tuple{Symbol, Type, Int64}"),
    ("tmerge_limited", Core.Compiler, "Tuple{Core.Compiler.InferenceLattice{Core.Compiler.ConditionalsLattice{Core.Compiler.PartialsLattice{Core.Compiler.ConstsLattice}}}, Any, Any}"),
    ("update_exc_bestguess!", Core.Compiler, "Tuple{Core.Compiler.AbstractInterpreter, Any, Core.Compiler.InferenceState}"),
    ("widenconst", Core.Compiler, "Tuple{Any}"),
    ("widenreturn", Core.Compiler, "Tuple{Core.Compiler.PartialsLattice{Core.Compiler.ConstsLattice}, Any, Core.Compiler.BestguessInfo}"),
    ("widenreturn_noslotwrapper", Core.Compiler, "Tuple{Core.Compiler.PartialsLattice{Core.Compiler.ConstsLattice}, Any, Core.Compiler.BestguessInfo}"),
    ("⊑", Core.Compiler, "Tuple{Core.Compiler.PartialsLattice{Core.Compiler.ConstsLattice}, Any, Any}"),
    ("apply_refinement!", Core.Compiler, "Tuple{Core.Compiler.InferenceLattice{Core.Compiler.ConditionalsLattice{Core.Compiler.PartialsLattice{Core.Compiler.ConstsLattice}}}, Core.SlotNumber, Any, Vector{Core.Compiler.VarState}, Nothing}"),
]

# Also try update_cycle_worklists! which takes closures — skip for now
# Also try __limit_type_size and limit_type_size — they have static params that fail

for (name, mod, sig_str) in multi_sigs
    sym = Symbol(name)

    f = try; getfield(mod, sym); catch; nothing; end
    if f === nothing
        println("$(nameof(mod)).$name: SKIP (cannot resolve)")
        continue
    end

    argtypes = try
        types = Core.eval(Main, Meta.parse(sig_str))
        fieldtypes(types)
    catch e
        println("$(nameof(mod)).$name: SKIP (cannot parse: $sig_str) — $e")
        nothing
    end

    if argtypes === nothing
        continue
    end

    result = try
        bytes = WasmTarget.compile(f, argtypes)
        if bytes !== nothing && !isempty(bytes)
            tmpf = tempname() * ".wasm"
            write(tmpf, bytes)
            validates = try
                run(pipeline(`wasm-tools validate $tmpf`, stdout=devnull, stderr=devnull))
                true
            catch
                false
            end
            func_count = try
                output = read(`wasm-tools print $tmpf`, String)
                count("(func ", output)
            catch
                -1
            end
            rm(tmpf, force=true)
            validates ? "COMPILES_NOW ($func_count funcs, $(length(bytes)) bytes)" : "NEEDS_PATTERN (validation fails)"
        else
            "ERROR (empty bytes)"
        end
    catch e
        msg = sprint(showerror, e)
        if length(msg) > 120; msg = msg[1:120] * "..."; end
        "ERROR ($msg)"
    end

    println("$(nameof(mod)).$name: $result")
end
