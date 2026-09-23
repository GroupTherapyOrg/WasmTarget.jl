# Julia IR Handling
# Interface to Julia's typed intermediate representation

export get_typed_ir

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
question a box-capture join asks about a write's value. `Any` when inference fails.
parity(quarantine: a return-type query to Julia's own inference; dart reads a member's return
type off its Kernel FunctionNode.)
"""
function infer_return_type(@nospecialize(f), argtypes::Tuple;
                           interp::WasmInterpreter=get_wasm_interpreter())::Type
    return try
        Base.infer_return_type(f, Tuple{argtypes...}; interp=interp)
    catch
        Any
    end
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

# parity(quarantine: the transitive walk behind ir_reads_host_layout, one memo per compilation.)
function _ir_reads_host_layout(ci::Core.CodeInstance, depth::Int, memo::IdDict{Any, Bool})::Bool
    depth > 6 && return true
    local mi = ci.def
    local key = mi isa Core.MethodInstance ? mi.specTypes : ci
    haskey(memo, key) && return memo[key]
    memo[key] = false                            # cycle guard
    local src = isdefined(ci, :inferred) ? ci.inferred : nothing
    src isa String && (src = try Base._uncompressed_ir(ci, src) catch; nothing end)
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
                found = true; break
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

# ============================================================================
# Typed-IR transport — the input side of the NIR boundary, beside get_typed_ir.
#
# Self-hosting ships caller-supplied typed IR to the compiler: GlobalRefs pre-resolved on
# the host, then the CodeInfo serialized to JSON and rebuilt in the browser, where
# `compile_module_from_ir` installs it into the closed-world planner. Every function here
# reads or builds a `Core.CodeInfo`; codegen itself reads Julia's IR only through the NIR.
# ============================================================================
# GlobalRef Pre-Resolution — Self-hosting support
# ============================================================================

"""
    collect_globalrefs(code_info::Core.CodeInfo) -> Set{GlobalRef}

Walk a CodeInfo and collect all unique GlobalRef values from statements
and expression arguments. Used at build time to discover all module-level
references that need to be pre-resolved for self-hosting.
"""
function collect_globalrefs(code_info::Core.CodeInfo)
    refs = Set{GlobalRef}()
    for stmt in code_info.code
        _scan_globalrefs!(refs, stmt)
    end
    return refs
end

function _scan_globalrefs!(refs::Set{GlobalRef}, val)
    if val isa GlobalRef
        push!(refs, val)
    elseif val isa Expr
        for arg in val.args
            _scan_globalrefs!(refs, arg)
        end
    end
end

"""
    resolve_globalrefs(refs::Set{GlobalRef}) -> Dict{GlobalRef, Any}

Resolve each GlobalRef to its build-time value using getfield.
Unresolvable refs are skipped (they may be forward declarations, etc).
"""
function resolve_globalrefs(refs::Set{GlobalRef})
    resolved = Dict{GlobalRef, Any}()
    for ref in refs
        try
            resolved[ref] = getfield(ref.mod, ref.name)
        catch
            # Skip unresolvable refs
        end
    end
    return resolved
end

"""
    collect_and_resolve_all_globalrefs(ir_entries::Vector) -> Dict{GlobalRef, Any}

Collect and resolve ALL GlobalRefs across multiple IR entries at build time.
This is the main entry point for Phase 1 self-hosting: eliminates all
getfield(Module, Symbol) calls from the CodeInfo before it's sent to the browser.
"""
function collect_and_resolve_all_globalrefs(ir_entries::Vector)
    all_refs = Set{GlobalRef}()
    for entry in ir_entries
        code_info = entry[1]  # First element is CodeInfo
        union!(all_refs, collect_globalrefs(code_info))
    end
    return resolve_globalrefs(all_refs)
end

"""
    substitute_globalrefs(code_info::Core.CodeInfo, resolved::Dict{GlobalRef, Any}) -> Core.CodeInfo

Create a copy of CodeInfo with all GlobalRef values replaced by their
pre-resolved values. After substitution, the CodeInfo contains no
module-level references and can be compiled without access to Julia modules.
"""
function substitute_globalrefs(code_info::Core.CodeInfo, resolved::Dict{GlobalRef, Any})
    new_ci = copy(code_info)
    new_code = Any[]
    for stmt in new_ci.code
        push!(new_code, _substitute_globalref(stmt, resolved))
    end
    new_ci.code = new_code
    return new_ci
end

function _substitute_globalref(val, resolved::Dict{GlobalRef, Any})
    if val isa GlobalRef
        return get(resolved, val, val)
    elseif val isa Expr
        new_args = Any[_substitute_globalref(arg, resolved) for arg in val.args]
        return Expr(val.head, new_args...)
    end
    return val
end

"""
    preprocess_ir_entries(ir_entries::Vector) -> Vector

Pre-resolve all GlobalRefs in IR entries. Returns new entries with substituted
CodeInfo that contain no module-level references. This is the build-time
preprocessing step for self-hosted compilation.
"""
function preprocess_ir_entries(ir_entries::Vector)
    resolved = collect_and_resolve_all_globalrefs(ir_entries)
    result = []
    for (code_info, return_type, arg_types, name) in ir_entries
        sub_ci = substitute_globalrefs(code_info, resolved)
        push!(result, (sub_ci, return_type, arg_types, name))
    end
    return result
end

# ============================================================================
# CodeInfo Transport — Phase 1 self-hosting (PHASE-1-009)
# ============================================================================
# Serialize CodeInfo + metadata to JSON for server→browser transport.
# The browser deserializes and passes to compile_module_from_ir to produce WASM.
#
# Flow: server code_typed → preprocess_ir_entries → serialize → HTTP →
#       browser deserialize → compile_module_from_ir → to_bytes → execute

import JSON

"""
    serialize_ir_value(val) -> Any

Serialize a single IR value (Expr arg, PhiNode value, etc.) to a JSON-safe Dict.
"""
function serialize_ir_value(val)
    if val isa Core.SSAValue
        return Dict("_t" => "ssa", "id" => val.id)
    elseif val isa Core.Argument
        return Dict("_t" => "arg", "n" => val.n)
    elseif val isa Core.SlotNumber
        return Dict("_t" => "slot", "id" => val.id)
    elseif val isa Core.IntrinsicFunction
        return Dict("_t" => "intrinsic", "name" => string(nameof(val)))
    elseif val isa GlobalRef
        return Dict("_t" => "globalref", "mod" => string(val.mod), "name" => string(val.name))
    elseif val isa QuoteNode
        return Dict("_t" => "quote", "value" => serialize_ir_value(val.value))
    elseif val isa Symbol
        return Dict("_t" => "symbol", "name" => string(val))
    elseif val isa Bool
        # Bool before Int because Bool <: Integer
        return Dict("_t" => "lit", "jt" => "Bool", "v" => val)
    elseif val isa Int64
        return Dict("_t" => "lit", "jt" => "Int64", "v" => val)
    elseif val isa Int32
        return Dict("_t" => "lit", "jt" => "Int32", "v" => Int64(val))
    elseif val isa UInt64
        return Dict("_t" => "lit", "jt" => "UInt64", "v" => Int64(val))
    elseif val isa UInt32
        return Dict("_t" => "lit", "jt" => "UInt32", "v" => Int64(val))
    elseif val isa Float64
        return Dict("_t" => "lit", "jt" => "Float64", "v" => val)
    elseif val isa Float32
        return Dict("_t" => "lit", "jt" => "Float32", "v" => Float64(val))
    elseif val === nothing
        return Dict("_t" => "nothing")
    elseif val isa Type
        return Dict("_t" => "type", "name" => serialize_type_name(val))
    elseif val isa Expr
        return serialize_ir_stmt(val)
    elseif val isa Core.Builtin
        return Dict("_t" => "builtin", "name" => string(nameof(val)))
    elseif val isa Function
        mod = parentmodule(val)
        return Dict("_t" => "function", "name" => string(nameof(val)), "mod" => string(mod))
    elseif val isa Core.MethodInstance
        sig = val.specTypes
        func_name = string(sig.parameters[1].instance)
        arg_types = [serialize_type_name(p) for p in sig.parameters[2:end]]
        return Dict("_t" => "method_instance", "func" => func_name, "sig" => arg_types)
    elseif isdefined(Core, :CodeInstance) && val isa Core.CodeInstance
        mi = val.def
        sig = mi.specTypes
        func_name = string(sig.parameters[1].instance)
        arg_types = [serialize_type_name(p) for p in sig.parameters[2:end]]
        return Dict("_t" => "code_instance", "func" => func_name, "sig" => arg_types)
    else
        return Dict("_t" => "opaque", "repr" => repr(val), "jt" => string(typeof(val)))
    end
end

"""
    serialize_ir_stmt(stmt) -> Any

Serialize a single IR statement to a JSON-safe structure.
"""
function serialize_ir_stmt(stmt)
    if stmt isa Expr
        return Dict("_t" => "expr", "head" => string(stmt.head),
                     "args" => [serialize_ir_value(a) for a in stmt.args])
    elseif stmt isa Core.ReturnNode
        if isdefined(stmt, :val)
            return Dict("_t" => "return", "val" => serialize_ir_value(stmt.val))
        else
            return Dict("_t" => "return")
        end
    elseif stmt isa Core.GotoNode
        return Dict("_t" => "goto", "label" => stmt.label)
    elseif stmt isa Core.GotoIfNot
        return Dict("_t" => "gotoifnot", "cond" => serialize_ir_value(stmt.cond),
                     "dest" => stmt.dest)
    elseif stmt isa Core.PhiNode
        vals = []
        for i in 1:length(stmt.values)
            if isassigned(stmt.values, i)
                push!(vals, serialize_ir_value(stmt.values[i]))
            else
                push!(vals, Dict("_t" => "undef"))
            end
        end
        return Dict("_t" => "phi", "edges" => Int64.(stmt.edges), "values" => vals)
    elseif stmt isa Core.PiNode
        return Dict("_t" => "pi", "val" => serialize_ir_value(stmt.val),
                     "typ" => serialize_type_name(stmt.typ))
    elseif stmt isa Core.NewvarNode
        return Dict("_t" => "newvar", "slot" => stmt.slot.id)
    elseif stmt isa GlobalRef
        # PHASE-2-INT-001: GlobalRef appears as standalone stmt in lowered IR
        return Dict("_t" => "globalref_stmt", "mod" => string(stmt.mod), "name" => string(stmt.name))
    elseif stmt isa Core.SlotNumber
        # PHASE-2-INT-001: SlotNumber appears as standalone stmt in lowered IR
        return Dict("_t" => "slot", "id" => stmt.id)
    elseif stmt === nothing
        return Dict("_t" => "nothing")
    else
        return Dict("_t" => "opaque", "repr" => repr(stmt), "jt" => string(typeof(stmt)))
    end
end

"""
    serialize_type_name(T) -> String

Convert a Julia type to a string representation for JSON transport.
"""
function serialize_type_name(T)
    T === Int64 && return "Int64"
    T === Int32 && return "Int32"
    T === UInt64 && return "UInt64"
    T === UInt32 && return "UInt32"
    T === Float64 && return "Float64"
    T === Float32 && return "Float32"
    T === Bool && return "Bool"
    T === Nothing && return "Nothing"
    T === String && return "String"
    T === Symbol && return "Symbol"
    T === Any && return "Any"
    T === Union{} && return "Union{}"
    return string(T)
end

"""
    serialize_ssa_type(t) -> Any

Serialize an SSA value type or slot type entry (may be Type or Core.Const).
"""
function serialize_ssa_type(t)
    if t isa Core.Const
        val = t.val
        if val isa Core.IntrinsicFunction
            return Dict("_t" => "const", "val" => Dict("_t" => "intrinsic", "name" => string(nameof(val))),
                         "jt" => "Core.IntrinsicFunction")
        elseif val isa Core.Builtin
            return Dict("_t" => "const", "val" => Dict("_t" => "builtin", "name" => string(nameof(val))),
                         "jt" => "Core.Builtin")
        elseif val isa Function
            # User-defined functions: store just the type (codegen only needs the type)
            return serialize_type_name(typeof(val))
        else
            return Dict("_t" => "const", "val" => serialize_ir_value(val),
                         "jt" => serialize_type_name(typeof(val)))
        end
    elseif t isa Type
        return serialize_type_name(t)
    else
        return Dict("_t" => "opaque_type", "repr" => repr(t))
    end
end

"""
    serialize_ir_entries(ir_entries::Vector) -> String

Serialize preprocessed IR entries to a JSON string for transport.
Each entry is (code_info, return_type, arg_types, func_name).

Call preprocess_ir_entries FIRST to resolve GlobalRefs before serialization.
"""
function serialize_ir_entries(ir_entries::Vector)::String
    entries = []
    for (code_info, return_type, arg_types, name) in ir_entries
        entry = Dict(
            "name" => name,
            "arg_types" => [serialize_type_name(T) for T in arg_types],
            "return_type" => serialize_type_name(return_type),
            "code" => [serialize_ir_stmt(stmt) for stmt in code_info.code],
            # PHASE-2-INT-001: Handle lowered IR where ssavaluetypes is an Int (count)
            "ssavaluetypes" => code_info.ssavaluetypes isa Integer ?
                code_info.ssavaluetypes :
                [serialize_ssa_type(t) for t in code_info.ssavaluetypes],
            "slottypes" => code_info.slottypes !== nothing ?
                [serialize_ssa_type(t) for t in code_info.slottypes] : nothing,
            "slotnames" => [string(s) for s in code_info.slotnames],
            "ssaflags" => Int64.(code_info.ssaflags),
            "slotflags" => Int64.(code_info.slotflags),
        )
        push!(entries, entry)
    end
    return JSON.json(Dict("version" => 1, "entries" => entries))
end

# ---- Deserialization ----

const _TYPE_MAP = Dict{String, Type}(
    "Int64" => Int64, "Int32" => Int32, "UInt64" => UInt64, "UInt32" => UInt32,
    "Float64" => Float64, "Float32" => Float32, "Bool" => Bool,
    "Nothing" => Nothing, "String" => String, "Symbol" => Symbol,
    "Any" => Any, "Union{}" => Union{},
)

"""
    deserialize_type_name(s::AbstractString) -> Type

Reconstruct a Julia type from its serialized string name.
"""
function deserialize_type_name(s::AbstractString)::Type
    haskey(_TYPE_MAP, s) && return _TYPE_MAP[s]
    try
        return Core.eval(Main, Meta.parse(s))
    catch
        return Any
    end
end

"""
    deserialize_ir_value(d) -> Any

Reconstruct a Julia IR value from its JSON representation.
"""
function deserialize_ir_value(d)
    d isa Bool && return d
    d isa AbstractString && return d
    d isa Number && return d
    !isa(d, Dict) && return d

    tag = get(d, "_t", "")
    if tag == "ssa"
        return Core.SSAValue(d["id"])
    elseif tag == "arg"
        return Core.Argument(d["n"])
    elseif tag == "intrinsic"
        return getfield(Core.Intrinsics, Symbol(d["name"]))
    elseif tag == "builtin"
        return getfield(Core, Symbol(d["name"]))
    elseif tag == "function"
        mod_str = get(d, "mod", "Main")
        mod = mod_str == "Core" ? Core : mod_str == "Base" ? Base : Main
        name = Symbol(d["name"])
        try
            return getfield(mod, name)
        catch
            # Fallback: try Base then Main
            for m in (Base, Main)
                try return getfield(m, name) catch end
            end
            return GlobalRef(mod, name)
        end
    elseif tag == "globalref"
        mod = d["mod"] == "Core" ? Core : d["mod"] == "Base" ? Base : Main
        return GlobalRef(mod, Symbol(d["name"]))
    elseif tag == "quote"
        return QuoteNode(deserialize_ir_value(d["value"]))
    elseif tag == "symbol"
        return Symbol(d["name"])
    elseif tag == "lit"
        jt = d["jt"]
        v = d["v"]
        jt == "Int64" && return Int64(v)
        jt == "Int32" && return Int32(v)
        jt == "UInt64" && return UInt64(v)
        jt == "UInt32" && return UInt32(v)
        jt == "Float64" && return Float64(v)
        jt == "Float32" && return Float32(v)
        jt == "Bool" && return Bool(v)
        return v
    elseif tag == "nothing"
        return nothing
    elseif tag == "type"
        return deserialize_type_name(d["name"])
    elseif tag == "expr"
        return deserialize_ir_stmt(d)
    elseif tag == "slot"
        return Core.SlotNumber(d["id"])
    elseif tag == "method_instance" || tag == "code_instance"
        # Reconstruct MethodInstance from function name + arg types
        func_name = d["func"]
        arg_types = Tuple(deserialize_type_name.(d["sig"]))
        try
            func = Core.eval(Main, Meta.parse(func_name))
            sig = Tuple{typeof(func), arg_types...}
            mi = Base.method_instances(func, arg_types)[1]
            # a CodeInstance tag deserializes to its MI as well — codegen handles both
            return mi
        catch
            # If we can't reconstruct the MI, return nothing — codegen will handle
            return nothing
        end
    elseif tag == "undef"
        return nothing
    else
        error("Unknown IR value tag: $tag")
    end
end

"""
    deserialize_ir_stmt(d::Dict) -> Any

Reconstruct a Julia IR statement from its JSON representation.
"""
function deserialize_ir_stmt(d::Dict)
    tag = d["_t"]
    if tag == "expr"
        head = Symbol(d["head"])
        args = Any[deserialize_ir_value(a) for a in d["args"]]
        return Expr(head, args...)
    elseif tag == "return"
        if haskey(d, "val")
            return Core.ReturnNode(deserialize_ir_value(d["val"]))
        else
            return Core.ReturnNode()
        end
    elseif tag == "goto"
        return Core.GotoNode(d["label"])
    elseif tag == "gotoifnot"
        return Core.GotoIfNot(deserialize_ir_value(d["cond"]), d["dest"])
    elseif tag == "phi"
        edges = Int32.(d["edges"])
        vals = Any[deserialize_ir_value(v) for v in d["values"]]
        return Core.PhiNode(edges, vals)
    elseif tag == "pi"
        return Core.PiNode(deserialize_ir_value(d["val"]),
                           deserialize_type_name(d["typ"]))
    elseif tag == "newvar"
        return Core.NewvarNode(Core.SlotNumber(d["slot"]))
    elseif tag == "globalref_stmt"
        # PHASE-2-INT-001: GlobalRef as standalone stmt (lowered IR)
        mod = d["mod"] == "Core" ? Core : d["mod"] == "Base" ? Base : Main
        return GlobalRef(mod, Symbol(d["name"]))
    elseif tag == "slot"
        # PHASE-2-INT-001: SlotNumber as standalone stmt (lowered IR)
        return Core.SlotNumber(d["id"])
    elseif tag == "nothing"
        return nothing
    else
        error("Unknown IR statement tag: $tag")
    end
end

"""
    deserialize_ssa_type(d) -> Any

Reconstruct an SSA/slot type entry from its JSON representation.
"""
function deserialize_ssa_type(d)
    if d isa AbstractString
        return deserialize_type_name(d)
    elseif d isa Dict
        tag = get(d, "_t", "")
        if tag == "const"
            val = deserialize_ir_value(d["val"])
            return Core.Const(val)
        end
    end
    return Any
end

"""
    _make_template_codeinfo() -> Core.CodeInfo

Get a template CodeInfo that can be copied and modified for deserialization.
"""
function _make_template_codeinfo()
    _noop() = nothing
    ci, _ = get_typed_ir(_noop, ())
    return ci
end

"""
    deserialize_ir_entries(json_str::String) -> Vector{Tuple}

Deserialize a JSON string back to IR entries for compile_module_from_ir.
Returns Vector of (CodeInfo, return_type, arg_types, name) tuples.
"""
function deserialize_ir_entries(json_str::String)
    data = JSON.parse(json_str)
    version = get(data, "version", 0)
    version == 1 || error("Unsupported CodeInfo transport version: $version")

    template = _make_template_codeinfo()
    result = []

    for entry in data["entries"]
        ci = copy(template)
        ci.code = Any[deserialize_ir_stmt(s) for s in entry["code"]]
        # PHASE-2-INT-001: Handle lowered IR where ssavaluetypes is an Int (count)
        if entry["ssavaluetypes"] isa Integer
            ci.ssavaluetypes = entry["ssavaluetypes"]
        else
            ci.ssavaluetypes = Any[deserialize_ssa_type(t) for t in entry["ssavaluetypes"]]
        end
        if entry["slottypes"] !== nothing
            ci.slottypes = Any[deserialize_ssa_type(t) for t in entry["slottypes"]]
        end
        ci.slotnames = Symbol[Symbol(s) for s in entry["slotnames"]]
        ci.ssaflags = UInt32.(entry["ssaflags"])
        ci.slotflags = UInt8.(entry["slotflags"])

        return_type = deserialize_type_name(entry["return_type"])
        arg_types = Tuple(deserialize_type_name.(entry["arg_types"]))
        name = entry["name"]

        push!(result, (ci, return_type, arg_types, name))
    end

    return result
end
