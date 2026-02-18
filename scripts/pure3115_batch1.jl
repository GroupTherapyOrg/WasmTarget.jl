#!/usr/bin/env julia
# PURE-3115: Batch verification of 25 core COMPILES_NOW typeinf functions
# For each function: compile with WasmTarget.compile(), validate with wasm-tools

using WasmTarget
using Core.Compiler

CC = Core.Compiler

# Define function -> (args_tuple, description) mapping
# compile(f, arg_types::Tuple) expects a tuple of types like (Int32, Int32)
test_cases = [
    # 1. abstract_eval_call(interp, e, sstate, sv)
    (CC.abstract_eval_call, (CC.NativeInterpreter, Expr, CC.StatementState, CC.InferenceState), "abstract_eval_call"),
    # 2. abstract_eval_copyast(interp, e, sstate, sv)
    (CC.abstract_eval_copyast, (CC.NativeInterpreter, Expr, CC.StatementState, CC.InferenceState), "abstract_eval_copyast"),
    # 3. abstract_eval_globalref(interp, g, isc, sv)
    (CC.abstract_eval_globalref, (CC.NativeInterpreter, GlobalRef, Bool, CC.InferenceState), "abstract_eval_globalref"),
    # 4. abstract_eval_isdefined_expr(interp, e, sstate, sv)
    (CC.abstract_eval_isdefined_expr, (CC.NativeInterpreter, Expr, CC.StatementState, CC.InferenceState), "abstract_eval_isdefined_expr"),
    # 5. abstract_eval_special_value(interp, e, sstate, sv) - e::Any
    (CC.abstract_eval_special_value, (CC.NativeInterpreter, Any, CC.StatementState, CC.InferenceState), "abstract_eval_special_value"),
    # 6. abstract_eval_statement_expr(interp, e, sstate, sv)
    (CC.abstract_eval_statement_expr, (CC.NativeInterpreter, Expr, CC.StatementState, CC.InferenceState), "abstract_eval_statement_expr"),
    # 7. abstract_eval_value(interp, e, sstate, sv) - e::Any
    (CC.abstract_eval_value, (CC.NativeInterpreter, Any, CC.StatementState, CC.InferenceState), "abstract_eval_value"),
    # 8. add_edges!(edges, info::CallInfo)
    (CC.add_edges!, (Vector{Any}, CC.NoCallInfo), "add_edges!"),
    # 9. add_edges_impl(edges, info::NoCallInfo)
    (CC.add_edges_impl, (Vector{Any}, CC.NoCallInfo), "add_edges_impl(NoCallInfo)"),
    # 10. adjust_effects(sv::InferenceState)
    (CC.adjust_effects, (CC.InferenceState,), "adjust_effects(InferenceState)"),
    # 11. adjust_effects(effects, method, override)
    (CC.adjust_effects, (CC.Effects, Method, UInt64), "adjust_effects(Effects,Method,UInt64)"),
    # 12. argtypes_to_type(argtypes)
    (CC.argtypes_to_type, (Vector{Any},), "argtypes_to_type"),
    # 13. bool_rt_to_conditional(rt, slot_id, info) - 3-arg
    (CC.bool_rt_to_conditional, (Any, Int64, CC.BestguessInfo), "bool_rt_to_conditional(3-arg)"),
    # 14. bool_rt_to_conditional(rt, info) - 2-arg
    (CC.bool_rt_to_conditional, (Any, CC.BestguessInfo), "bool_rt_to_conditional(2-arg)"),
    # 15. code_cache(interp::NativeInterpreter)
    (CC.code_cache, (CC.NativeInterpreter,), "code_cache(NativeInterpreter)"),
    # 16. code_cache(interp::InliningState)
    (CC.code_cache, (CC.InliningState,), "code_cache(InliningState)"),
    # 17. collect_argtypes(interp, ea, sstate, sv)
    (CC.collect_argtypes, (CC.NativeInterpreter, Vector{Any}, CC.StatementState, CC.InferenceState), "collect_argtypes"),
    # 18. collect_const_args(argtypes::Vector, start)
    (CC.collect_const_args, (Vector{Any}, Int64), "collect_const_args(Vector)"),
    # 19. collect_const_args(info::ArgInfo, start)
    (CC.collect_const_args, (CC.ArgInfo, Int64), "collect_const_args(ArgInfo)"),
    # 20. compute_edges!(sv)
    (CC.compute_edges!, (CC.InferenceState,), "compute_edges!"),
    # 21. decode_effects(e::UInt32)
    (CC.decode_effects, (UInt32,), "decode_effects"),
    # 22. is_all_const_arg(argtypes::Vector, start)
    (CC.is_all_const_arg, (Vector{Any}, Int64), "is_all_const_arg(Vector)"),
    # 23. is_all_const_arg(info::ArgInfo, start)
    (CC.is_all_const_arg, (CC.ArgInfo, Int64), "is_all_const_arg(ArgInfo)"),
    # 24. is_identity_free_argtype(t)
    (CC.is_identity_free_argtype, (Any,), "is_identity_free_argtype"),
    # 25. is_mutation_free_argtype(t)
    (CC.is_mutation_free_argtype, (Any,), "is_mutation_free_argtype"),
    # 26. is_same_frame(interp, linfo, sv)
    (CC.is_same_frame, (CC.NativeInterpreter, Core.MethodInstance, CC.InferenceState), "is_same_frame"),
    # 27. isidentityfree(t) — Base function
    (Base.isidentityfree, (Any,), "isidentityfree"),
    # 28. ismutationfree(t) — Base function
    (Base.ismutationfree, (Any,), "ismutationfree"),
    # 29. merge_call_chain!(interp, parent, child)
    (CC.merge_call_chain!, (CC.NativeInterpreter, CC.InferenceState, CC.InferenceState), "merge_call_chain!"),
    # 30. resolve_call_cycle!(interp, mi, sv)
    (CC.resolve_call_cycle!, (CC.NativeInterpreter, Core.MethodInstance, CC.InferenceState), "resolve_call_cycle!"),
]

# Results
results = Tuple{String, String, Int, String}[]

for (i, (f, argtypes, label)) in enumerate(test_cases)
    print("[$i/$(length(test_cases))] $label ... ")
    flush(stdout)
    local status = "ERROR"
    local detail = ""
    local wasm_size = 0

    try
        bytes = compile(f, argtypes)
        wasm_size = length(bytes)
        tmpf = tempname() * ".wasm"
        write(tmpf, bytes)

        # Validate with wasm-tools
        local proc = run(pipeline(`wasm-tools validate --features=gc $tmpf`, stderr=devnull, stdout=devnull), wait=false)
        wait(proc)
        if proc.exitcode == 0
            status = "VALIDATES"
        else
            # Get error message
            local err_out = IOBuffer()
            local proc2 = run(pipeline(`wasm-tools validate --features=gc $tmpf`, stdout=devnull, stderr=err_out), wait=false)
            wait(proc2)
            local errmsg = String(take!(err_out))
            # Extract first line of error
            local first_line = split(errmsg, "\n")[1]
            if length(first_line) > 150
                first_line = first_line[1:150] * "..."
            end
            status = "VALIDATION_FAIL"
            detail = first_line
        end
        rm(tmpf, force=true)
    catch e
        status = "COMPILE_ERROR"
        detail = sprint(showerror, e)
        if length(detail) > 200
            detail = detail[1:200] * "..."
        end
    end

    println(status, wasm_size > 0 ? " ($(wasm_size) bytes)" : "", length(detail) > 0 ? " — $detail" : "")
    flush(stdout)
    push!(results, (label, status, wasm_size, detail))
end

println("\n\n=== RESULTS TABLE ===")
println("| # | Function | Status | Size | Notes |")
println("|---|----------|--------|------|-------|")
local v_count = 0
local c_count = 0
local f_count = 0
for (i, (label, status, sz, detail)) in enumerate(results)
    local size_str = sz > 0 ? "$(sz)B" : "-"
    local detail_short = length(detail) > 80 ? detail[1:80] * "..." : detail
    println("| $i | $label | $status | $size_str | $detail_short |")
    if status == "VALIDATES"
        v_count += 1
    elseif status == "COMPILE_ERROR"
        c_count += 1
    else
        f_count += 1
    end
end
println()
println("Total: $(length(results)) test cases")
println("VALIDATES: $v_count")
println("COMPILE_ERROR: $c_count")
println("VALIDATION_FAIL: $f_count")
