#!/usr/bin/env julia
#
# PURE-600: IR Audit Script — Catalog All Patterns JuliaLowering Needs
#
# Walks the full dependency graph of to_lowered_expr(SyntaxTree) using
# Base.code_typed, and catalogs every IR pattern the compiler encounters.
# Then compiles with WasmTarget to detect which patterns are stubbed.
#
# Output: scripts/lowering_audit_results.json
#
# Usage: julia +1.12 --project=WasmTarget.jl WasmTarget.jl/scripts/audit_lowering_patterns.jl

using JSON, JuliaLowering, JuliaSyntax, Logging, WasmTarget

# ============================================================================
# Pattern Counters
# ============================================================================

const CALLS = Dict{String, Dict{String, Int}}()
const INVOKES = Dict{String, Dict{String, Int}}()
const INTRINSICS = Dict{String, Int}()
const FOREIGNCALLS = Dict{String, Int}()
const NEW_TYPES = Dict{String, Int}()
const PHI_PATTERNS = Dict{String, Int}()
const STUBS = Dict{String, String}()  # func_name => reason

const FUNCTIONS_PROCESSED = Ref(0)
const TOTAL_STATEMENTS = Ref(0)
const SEEN_FUNCTIONS = Set{UInt64}()

# ============================================================================
# IR Walking (same as audit_ir_patterns.jl)
# ============================================================================

function type_str(@nospecialize T)
    try
        string(T)
    catch
        "???"
    end
end

function record_call(func, arg_types)
    fname = try
        if func isa GlobalRef
            "$(func.mod).$(func.name)"
        elseif func isa Core.IntrinsicFunction
            name = string(func)
            INTRINSICS[name] = get(INTRINSICS, name, 0) + 1
            return
        else
            string(func)
        end
    catch
        "unknown"
    end

    args_str = join(map(type_str, arg_types), ", ")
    if !haskey(CALLS, fname)
        CALLS[fname] = Dict{String, Int}()
    end
    CALLS[fname][args_str] = get(CALLS[fname], args_str, 0) + 1
end

function record_invoke(mi_or_ci, arg_types)
    mi = if mi_or_ci isa Core.MethodInstance
        mi_or_ci
    elseif isdefined(Core, :CodeInstance) && mi_or_ci isa Core.CodeInstance
        mi_or_ci.def
    else
        nothing
    end
    mi === nothing && return

    name = try
        string(mi.def.name)
    catch
        "unknown"
    end

    sig = try
        string(mi.specTypes)
    catch
        join(map(type_str, arg_types), ", ")
    end

    if !haskey(INVOKES, name)
        INVOKES[name] = Dict{String, Int}()
    end
    INVOKES[name][sig] = get(INVOKES[name], sig, 0) + 1
end

function record_new(@nospecialize T)
    NEW_TYPES[type_str(T)] = get(NEW_TYPES, type_str(T), 0) + 1
end

function record_foreigncall(name)
    fname = string(name)
    FOREIGNCALLS[fname] = get(FOREIGNCALLS, fname, 0) + 1
end

function record_phi(types)
    key = join(sort(map(type_str, unique(types))), " | ")
    PHI_PATTERNS[key] = get(PHI_PATTERNS, key, 0) + 1
end

# ============================================================================
# Walk a CodeInfo's statements
# ============================================================================

function audit_codeinfo!(ci::Core.CodeInfo)
    ssavaluetypes = ci.ssavaluetypes
    for (i, stmt) in enumerate(ci.code)
        TOTAL_STATEMENTS[] += 1
        audit_statement!(stmt, i, ci, ssavaluetypes)
    end
end

function audit_statement!(stmt::Expr, idx, ci, ssavaluetypes)
    head = stmt.head
    args = stmt.args

    if head === :call && length(args) >= 1
        func = args[1]
        arg_types = infer_arg_types(args[2:end], ci, ssavaluetypes)
        record_call(func, arg_types)

    elseif head === :invoke && length(args) >= 2
        mi = args[1]
        arg_types = infer_arg_types(args[3:end], ci, ssavaluetypes)
        record_invoke(mi, arg_types)

    elseif head === :new && length(args) >= 1
        T = args[1]
        if T isa Type
            record_new(T)
        elseif T isa GlobalRef
            try
                actual = getfield(T.mod, T.name)
                if actual isa Type
                    record_new(actual)
                end
            catch; end
        end

    elseif head === :foreigncall && length(args) >= 1
        record_foreigncall(args[1])

    elseif head === :splatnew && length(args) >= 1
        T = args[1]
        if T isa Type
            record_new(T)
        end
    end
end

function audit_statement!(stmt::Core.PhiNode, idx, ci, ssavaluetypes)
    types = []
    vals = stmt.values
    for i in 1:length(vals)
        if isassigned(vals, i)
            push!(types, infer_value_type(vals[i], ci, ssavaluetypes))
        end
    end
    !isempty(types) && record_phi(types)
end

function audit_statement!(stmt, idx, ci, ssavaluetypes)
    # GotoNode, GotoIfNot, ReturnNode, etc.
end

# ============================================================================
# Type Inference Helpers
# ============================================================================

function infer_arg_types(args, ci, ssavaluetypes)
    map(a -> infer_value_type(a, ci, ssavaluetypes), args)
end

function infer_value_type(@nospecialize(val), ci, ssavaluetypes)
    if val isa Core.SSAValue
        idx = val.id
        if ssavaluetypes isa Vector && 1 <= idx <= length(ssavaluetypes)
            return ssavaluetypes[idx]
        end
        return Any
    elseif val isa Core.Argument
        n = val.n
        if hasfield(typeof(ci), :slottypes) && ci.slottypes !== nothing && 1 <= n <= length(ci.slottypes)
            return ci.slottypes[n]
        end
        return Any
    elseif val isa GlobalRef
        try
            return typeof(getfield(val.mod, val.name))
        catch
            return Any
        end
    elseif val isa QuoteNode
        return typeof(val.value)
    else
        return typeof(val)
    end
end

# ============================================================================
# Dependency Walking (mirrors discover_dependencies in codegen.jl)
# ============================================================================

function walk_dependencies!(entry_func, entry_argtypes)
    queue = Tuple{Any, Any}[(entry_func, entry_argtypes)]

    while !isempty(queue)
        f, argtypes = popfirst!(queue)

        key = hash((f, argtypes))
        key in SEEN_FUNCTIONS && continue
        push!(SEEN_FUNCTIONS, key)

        results = try
            Base.code_typed(f, argtypes; optimize=true)
        catch
            continue
        end
        isempty(results) && continue
        ci, ret_type = results[1]

        FUNCTIONS_PROCESSED[] += 1

        audit_codeinfo!(ci)

        for stmt in ci.code
            if stmt isa Expr
                discover_from_expr!(stmt, queue)
            end
        end
    end
end

function discover_from_expr!(expr::Expr, queue)
    if expr.head === :invoke && length(expr.args) >= 2
        mi_or_ci = expr.args[1]
        mi = if mi_or_ci isa Core.MethodInstance
            mi_or_ci
        elseif isdefined(Core, :CodeInstance) && mi_or_ci isa Core.CodeInstance
            mi_or_ci.def
        else
            nothing
        end

        if mi !== nothing
            try
                spec = mi.specTypes
                if spec isa DataType && spec <: Tuple && length(spec.parameters) >= 1
                    func_type = spec.parameters[1]
                    if func_type isa DataType && func_type != Union{} && isdefined(func_type, :instance)
                        func = func_type.instance
                        arg_types = Tuple{spec.parameters[2:end]...}
                        push!(queue, (func, arg_types))
                    end
                end
            catch; end
        end
    end

    for arg in expr.args
        if arg isa Expr
            discover_from_expr!(arg, queue)
        end
    end
end

# ============================================================================
# Stub Detection via WasmTarget compilation
# ============================================================================

struct StubLogger <: AbstractLogger
    captured::Vector{String}
    inner::AbstractLogger
end

Logging.min_enabled_level(l::StubLogger) = Logging.Warn
Logging.shouldlog(l::StubLogger, level, _module, group, id) = true
Logging.catch_exceptions(l::StubLogger) = true

function Logging.handle_message(l::StubLogger, level, message, _module, group, id,
                                filepath, line; kwargs...)
    msg = string(message)
    if occursin("Stubbing", msg) || occursin("CROSS-CALL UNREACHABLE", msg)
        push!(l.captured, msg)
    end
    Logging.handle_message(l.inner, level, message, _module, group, id, filepath, line; kwargs...)
end

function detect_stubs!()
    stub_warnings = String[]
    logger = StubLogger(stub_warnings, current_logger())

    ConcreteTree = JuliaLowering.SyntaxTree{JuliaLowering.SyntaxGraph{Dict{Symbol,Any}}}

    with_logger(logger) do
        # Try abstract type first (always succeeds)
        try
            bytes = WasmTarget.compile(JuliaLowering._to_lowered_expr, (JuliaLowering.SyntaxTree, Int64))
            println("Compiled _to_lowered_expr (abstract): $(length(bytes)) bytes")
        catch e
            println("Abstract compilation note: $e")
        end

        # Try concrete type (may crash due to codegen bugs)
        try
            bytes2 = WasmTarget.compile(JuliaLowering._to_lowered_expr, (ConcreteTree, Int64))
            println("Compiled _to_lowered_expr (concrete): $(length(bytes2)) bytes")
        catch e
            println("Concrete compilation note: $e")
        end
    end

    for msg in stub_warnings
        m = match(r"Stubbing unsupported (?:call|method): (.+?) \(will trap", msg)
        if m !== nothing
            name = m.captures[1]
            reason = occursin("call", msg) ? "unsupported call" : "unsupported method"
            STUBS[name] = reason
        end
        # Also capture CROSS-CALL UNREACHABLE
        m2 = match(r"CROSS-CALL UNREACHABLE: (.+?) with", msg)
        if m2 !== nothing
            name = m2.captures[1]
            STUBS[name] = "cross-call unreachable"
        end
    end
end

# ============================================================================
# Output Generation
# ============================================================================

function flatten_calls(d)
    result = []
    for (func, sigs) in sort(collect(d); by=x -> -sum(values(x.second)))
        for (sig, count) in sort(collect(sigs); by=x -> -x.second)
            push!(result, Dict(
                "func" => func,
                "arg_types" => sig == "" ? String[] : [String(s) for s in split(sig, ", ")],
                "count" => count,
                "status" => "unknown"
            ))
        end
    end
    result
end

function flatten_invokes(d)
    result = []
    for (name, sigs) in sort(collect(d); by=x -> -sum(values(x.second)))
        for (sig, count) in sort(collect(sigs); by=x -> -x.second)
            push!(result, Dict(
                "name" => name,
                "spec_types" => sig,
                "count" => count,
                "status" => "unknown"
            ))
        end
    end
    result
end

function flatten_simple(d)
    [Dict("name" => k, "count" => v) for (k, v) in sort(collect(d); by=x -> -x.second)]
end

function flatten_stubs(d)
    [Dict("func" => k, "reason" => v, "count" => 1) for (k, v) in sort(collect(d))]
end

function flatten_phi(d)
    [Dict("types" => [String(s) for s in split(k, " | ")], "count" => v) for (k, v) in sort(collect(d); by=x -> -x.second)]
end

function generate_output()
    result = Dict(
        "entry_point" => "JuliaLowering.to_lowered_expr(::SyntaxTree)",
        "total_functions" => FUNCTIONS_PROCESSED[],
        "total_statements" => TOTAL_STATEMENTS[],
        "patterns" => Dict(
            "calls" => flatten_calls(CALLS),
            "invokes" => flatten_invokes(INVOKES),
            "intrinsics" => flatten_simple(INTRINSICS),
            "stubs" => flatten_stubs(STUBS),
            "foreigncalls" => flatten_simple(FOREIGNCALLS),
            "new_types" => flatten_simple(NEW_TYPES),
            "phi_patterns" => flatten_phi(PHI_PATTERNS)
        )
    )

    outpath = joinpath(@__DIR__, "lowering_audit_results.json")
    open(outpath, "w") do io
        JSON.print(io, result, 2)
    end
    println("Wrote: $outpath")
    println()
    println("=== Summary ===")
    println("  Functions:   $(FUNCTIONS_PROCESSED[])")
    println("  Statements:  $(TOTAL_STATEMENTS[])")
    println("  Unique calls: $(length(CALLS))")
    println("  Unique invokes: $(length(INVOKES))")
    println("  Intrinsics:  $(length(INTRINSICS))")
    println("  Foreigncalls: $(length(FOREIGNCALLS))")
    println("  New types:   $(length(NEW_TYPES))")
    println("  Phi patterns: $(length(PHI_PATTERNS))")
    println("  Stubs:       $(length(STUBS))")
end

# ============================================================================
# Main
# ============================================================================

function main()
    println("=== PURE-600: IR Audit Script for JuliaLowering ===")
    println("Auditing IR patterns for to_lowered_expr(SyntaxTree)...")
    println()

    # Phase 1: Walk IR dependency graph via code_typed
    # Start from _to_lowered_expr (the real implementation) since to_lowered_expr
    # is just a thin wrapper that calls it via invoke
    # Use CONCRETE type for better type inference (2023 stmts vs 609 for abstract)
    ConcreteTree = JuliaLowering.SyntaxTree{JuliaLowering.SyntaxGraph{Dict{Symbol,Any}}}
    println("Phase 1: Walking IR dependency graph via code_typed...")
    println("  Entry: _to_lowered_expr($(ConcreteTree), Int64)")
    walk_dependencies!(JuliaLowering._to_lowered_expr, (ConcreteTree, Int64))
    println("  Found $(FUNCTIONS_PROCESSED[]) functions, $(TOTAL_STATEMENTS[]) statements")
    println()

    # Phase 2: Detect stubs via WasmTarget compilation
    println("Phase 2: Detecting stubs via WasmTarget compilation...")
    detect_stubs!()
    println("  Found $(length(STUBS)) stubbed methods")
    println()

    # Phase 3: Generate output
    println("Phase 3: Generating output...")
    generate_output()
end

main()
