# Julia IR Handling
# Interface to Julia's typed intermediate representation

export get_typed_ir

"""
    get_typed_ir(f, arg_types)

Get Julia's typed IR (SSA form) for a function with given argument types.
Returns the CodeInfo object from code_typed.
"""
# P5-trim: when a trim collection is active (compile_module discovery=:trim),
# every (f, arg_types) the pipeline asks about is served the collection's
# PAIRED CodeInfo — one consistent world, overlays applied, no re-inference.
const TRIM_IR_CACHE = Ref{Union{Nothing, IdDict{Any, Tuple{Core.CodeInfo, Any}}}}(nothing)

# ONE inference path. Every typed IR WasmTarget consumes comes from the
# WasmInterpreter (overlays applied, WT's constant-evaluation rule in force):
# the closed-world plan and any standalone query see the SAME IR for the same
# function. (A `nothing` default once ran Julia's native interpreter here, and
# a standalone dump differed from the plan's IR for the same function — hiding
# a branch the plan compiled.) `interp` exists to share one instance within a
# compilation; it is never a different kind of interpreter.
function get_typed_ir(f, arg_types::Tuple; optimize::Bool=true,
                      interp::WasmInterpreter=get_wasm_interpreter())
    cache = TRIM_IR_CACHE[]
    if cache !== nothing
        hit = get(cache, (f, arg_types), nothing)
        hit !== nothing && return hit[1], hit[2]
    end
    results = Base.code_typed(f, arg_types; optimize=optimize, interp=interp)

    if isempty(results)
        error("No method found for $f with types $arg_types")
    end

    # Return the first (and usually only) result
    code_info, return_type = results[1]
    return code_info, return_type
end


