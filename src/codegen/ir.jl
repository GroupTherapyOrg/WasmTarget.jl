# Julia IR Handling
# Interface to Julia's typed intermediate representation

export get_typed_ir

# parity(quarantine: Julia's trim collection (juliac --trim) is the closed world; dart's comes from its front end's whole-program type flow analysis.)
const TRIM_IR_CACHE = Ref{Union{Nothing, IdDict{Any, Tuple{Core.CodeInfo, Any}}}}(nothing)

# ONE inference path. Every typed IR WasmTarget consumes comes from the
# WasmInterpreter (overlays applied, WT's constant-evaluation rule in force):
# the closed-world plan and any standalone query see the SAME IR for the same
# function. (A `nothing` default once ran Julia's native interpreter here, and
# a standalone dump differed from the plan's IR for the same function — hiding
# a branch the plan compiled.) `interp` exists to share one instance within a
# compilation; it is never a different kind of interpreter.
"""
    get_typed_ir(f, arg_types)

Get Julia's typed IR (SSA form) for a function with given argument types.
Returns the CodeInfo object from code_typed.
P5-trim: when a trim collection is active (compile_module discovery=:trim),
every (f, arg_types) the pipeline asks about is served the collection's
PAIRED CodeInfo — one consistent world, overlays applied, no re-inference.
A query the collection cannot answer is an error, never a second inference: a
re-inference ran a different WasmInterpreter (a fresh one at the current world
counter, in the shared `:wasm_target` cache partition, where the collection used
its own world and a fresh partition) and honored `optimize=false`, which the
collected IR — always optimized — cannot; either can give IR the collected world
never had (measured 2026-09-23: 0 such queries in the smoke and probe corpora).
parity(quarantine: Julia's typed IR is WT's frontend input, asked of Julia's own inference; dart2wasm
receives Kernel already built by the CFE.)
"""
function get_typed_ir(f, arg_types::Tuple; optimize::Bool=true,
                      interp::WasmInterpreter=get_wasm_interpreter())::Tuple{Core.CodeInfo, Any}
    cache = TRIM_IR_CACHE[]
    if cache !== nothing
        optimize || error("get_typed_ir: unoptimized IR for $f$(arg_types) requested inside a " *
                          "collected closed world, whose IR is optimized")
        hit = get(cache, (f, arg_types), nothing)
        hit === nothing && error("get_typed_ir: $f$(arg_types) is outside the collected closed " *
                                 "world; the collection must enroll it, codegen never re-infers")
        return hit[1], hit[2]
    end
    results = Base.code_typed(f, arg_types; optimize=optimize, interp=interp, debuginfo=:source)

    if isempty(results)
        error("No method found for $f with types $arg_types")
    end

    # Return the first (and usually only) result
    code_info, return_type = results[1]
    return code_info, return_type
end

"""
    get_typed_ir(mi::MethodInstance) -> (CodeInfo, return type)

The collected closed world's typed IR of one MethodInstance: the function a plan entry names
(two methods can share a specialization's argument types, so (f, arg_types) does not).
parity(quarantine: Julia's typed IR is WT's frontend input, asked of Julia's own inference; dart2wasm
receives Kernel already built by the CFE.)
"""
function get_typed_ir(mi::Core.MethodInstance)::Tuple{Core.CodeInfo, Any}
    cache = TRIM_IR_CACHE[]
    cache === nothing && error("get_typed_ir: $(mi) asked outside a collected closed world")
    hit = get(cache, mi, nothing)
    hit === nothing && error("get_typed_ir: $(mi) is outside the collected closed world")
    return hit[1], hit[2]
end

"""
    get_typed_ir(sig::Type{<:Tuple}) -> Vector{Pair{CodeInfo, Any}}

The same one path for a full signature (function type first), as a closure body reached
through an `invoke`'s `MethodInstance.specTypes` is: every match, inferred by the
WasmInterpreter. Outside a collected closed world only; inside one it is an error, as a
`get_typed_ir(f, arg_types)` miss is.
parity(quarantine: Julia's typed IR for a full signature, asked of Julia's own inference.)
"""
function get_typed_ir(sig::Type{<:Tuple}; optimize::Bool=true,
                      interp::WasmInterpreter=get_wasm_interpreter())::Vector
    TRIM_IR_CACHE[] === nothing || error("get_typed_ir: $sig queried by signature inside a " *
        "collected closed world; codegen reads the collection's IR, never a second inference")
    return Base.code_typed_by_type(sig; optimize=optimize, interp=interp, debuginfo=:source)
end

"""
    infer_return_type(f, argtypes) -> Type

The return type of `f(::argtypes...)` under the one inference path (overlays applied): the
question a box-capture join asks about a write's value. Julia's own answer: `Any` for a call
inference cannot analyze, `Union{}` for one no method matches.
parity(quarantine: a return-type query to Julia's own inference; dart reads a member's return
type off its Kernel FunctionNode.)
"""
function infer_return_type(@nospecialize(f), argtypes::Tuple;
                           interp::WasmInterpreter=get_wasm_interpreter())::Type
    return Base.infer_return_type(f, Tuple{argtypes...}; interp=interp)
end

# parity(quarantine: the memo of Julia's host-layout reads, per specialization, installed for
# one compilation.) A process-wide memo answered a later compilation with the body an earlier one
# saw: after a method was redefined in the same session, its specialization kept the stale
# answer and the module differed from the one a fresh session builds (measured 2026-09-23).
const _IR_LAYOUT_READ_MEMO = Ref{Union{Nothing, IdDict{Any, Bool}}}(nothing)

"""
    with_layout_read_memo(f)

Run `f()` — one compilation — with a fresh host-layout-read memo installed, and remove it
afterwards. Outside such a scope every `ir_reads_host_layout` query memoizes only within
itself, so no answer outlives the compilation that computed it.
parity(quarantine: the lifetime of the host-layout-read memo, one compilation, as
TRIM_IR_CACHE's.)
"""
function with_layout_read_memo(f::Function)::Any
    previous = _IR_LAYOUT_READ_MEMO[]
    _IR_LAYOUT_READ_MEMO[] = IdDict{Any, Bool}()
    try
        return f()
    finally
        _IR_LAYOUT_READ_MEMO[] = previous
    end
end
"""
    ir_reads_host_layout(ci::Core.CodeInstance) -> Bool

Whether the specialization's inferred source — transitively through its invokes — reads
`DataType.layout`, calls `Core.sizeof` on a type, or makes a foreigncall: the ways a
type-level computation can answer for the HOST's memory layout rather than for the
program (the constant-evaluation rule in interpreter.jl refuses to fold such a call).
Reads the CodeInstance's own `inferred` source (the result of the inference that just
ran — never a nested inference from inside an eligibility query); memoized per
specialization; a CodeInstance without retained source, or a chain deeper than six
invokes, counts as a read (never fold blind).
parity(quarantine: whether a Julia specialization reads the host's `DataType.layout`, `sizeof` or
a foreigncall — Julia's concrete evaluation would otherwise fold a host answer into the module.)
"""
function ir_reads_host_layout(ci::Core.CodeInstance)::Bool
    memo = _IR_LAYOUT_READ_MEMO[]
    return _ir_reads_host_layout(ci, 0, memo === nothing ? IdDict{Any, Bool}() : memo)
end

# parity(quarantine: Julia's type-structure predicates, answered by Julia at compile time.)
const _TYPE_STRUCTURE_FOREIGNCALLS = (:jl_has_free_typevars,)

# parity(quarantine: the transitive walk behind ir_reads_host_layout, one memo per compilation.)
function _ir_reads_host_layout(ci::Core.CodeInstance, depth::Int, memo::IdDict{Any, Bool})::Bool
    depth > 6 && return true
    local mi = ci.def
    local key = mi isa Core.MethodInstance ? mi.specTypes : ci
    haskey(memo, key) && return memo[key]
    memo[key] = false                            # cycle guard
    local src = isdefined(ci, :inferred) ? ci.inferred : nothing
    src isa String && (src = Base._uncompressed_ir(ci, src))
    local found = !(src isa Core.CodeInfo)
    if !found
        for rec in build_nir(src)
            local node = rec.node
            if node isa NirCall && length(node.operands) >= 2
                local callee = node.callee
                if callee === Core.getfield || callee === Base.getproperty
                    local fld = node.operands[2]
                    (fld isa NirLiteral && fld.value === :layout) && (found = true; break)
                elseif callee === Core.sizeof
                    found = true; break
                end
            elseif node isa NirForeignCall
                # a type-structure predicate answers the same in every process and on every
                # architecture (Core.has_free_typevars, which the frontend's
                # _typeof_captured_variable asks of a captured type); any other foreigncall
                # may read the host
                node.c_symbol in _TYPE_STRUCTURE_FOREIGNCALLS || (found = true; break)
            elseif node isa NirInvoke
                if node.ci !== nothing
                    _ir_reads_host_layout(node.ci, depth + 1, memo) && (found = true; break)
                else
                    found = true; break          # an invoke without its CodeInstance: unknown
                end
            end
        end
    end
    memo[key] = found
    return found
end
