#!/usr/bin/env julia
# PURE-3117: Batch verify 25 COMPILES_NOW functions (reclassified from COMPILE_ERROR — Union signatures, first variant selected)
# Same procedure as PURE-3115/3116: compile → validate → record status

using WasmTarget

# Helper: try to compile, validate, return status
function try_compile_validate(f, argtypes; label="")
    local bytes
    try
        bytes = compile(f, argtypes)
    catch e
        return (status="COMPILE_ERROR", bytes=0, error=sprint(showerror, e))
    end

    # Write to temp file and validate
    tmpf = tempname() * ".wasm"
    write(tmpf, bytes)
    try
        run(`wasm-tools validate --features=gc $tmpf`)
        return (status="VALIDATES", bytes=length(bytes), error="")
    catch e
        return (status="VALIDATE_ERROR", bytes=length(bytes), error=sprint(showerror, e))
    finally
        rm(tmpf, force=true)
    end
end

function unwrap_unionall_top(t)
    while t isa UnionAll
        t = t.body
    end
    return t
end

# Results table
results = []

println("=" ^ 80)
println("PURE-3117: Batch 3 Verification — Reclassified + Remaining (25 functions)")
println("=" ^ 80)

# Generic function tester — tries Core.Compiler first, then Base
function test_function(name_str, sym; modules=[Core.Compiler, Base], specific_sigs=nothing, max_methods=5)
    println("\n[$name_str]")

    if specific_sigs !== nothing
        for (i, (f, argtypes)) in enumerate(specific_sigs)
            label = length(specific_sigs) > 1 ? "$name_str(v$i)" : name_str
            println("  Testing: $f with $argtypes")
            r = try_compile_validate(f, argtypes)
            push!(results, (name=label, sig="$argtypes", r...))
            println("  $(r.status) ($(r.bytes) bytes) $(r.error)")
        end
        return
    end

    for mod in modules
        if isdefined(mod, sym)
            f = getfield(mod, sym)
            ms = collect(methods(f))
            if length(ms) == 0
                continue
            end
            println("  Found in $mod: $(length(ms)) methods")

            # For functions with many methods, just try a representative subset
            test_ms = length(ms) > max_methods ? ms[1:min(max_methods, length(ms))] : ms
            for (i, m) in enumerate(test_ms)
                sig_unwrapped = unwrap_unionall_top(m.sig)
                argtypes = Tuple(sig_unwrapped.parameters[2:end])
                # Skip methods with TypeVar parameters — can't compile those
                has_typevar = any(t -> t isa TypeVar, argtypes)
                if has_typevar
                    label = length(test_ms) > 1 ? "$name_str(v$i)" : name_str
                    println("  Method $i: $argtypes (SKIP — has TypeVar)")
                    push!(results, (name=label, sig="$argtypes", status="SKIP_TYPEVAR", bytes=0, error="Has TypeVar parameter"))
                    continue
                end
                label = length(test_ms) > 1 ? "$name_str(v$i)" : name_str
                println("  Method $i: $argtypes")
                r = try_compile_validate(f, argtypes)
                push!(results, (name=label, sig="$argtypes", r...))
                println("  $(r.status) ($(r.bytes) bytes) $(r.error)")
            end
            return
        end
    end

    push!(results, (name=name_str, sig="N/A", status="NOT_FOUND", bytes=0, error="Not found in any module"))
    println("  NOT_FOUND")
end

# === 25 functions to verify ===
# These were reclassified from COMPILE_ERROR — Union signatures, first variant selected

# 1. InliningState — Core.Compiler constructor
println("\n[1/25] InliningState")
try
    if isdefined(Core.Compiler, :InliningState)
        f = Core.Compiler.InliningState
        ms = collect(methods(f))
        println("  Found $(length(ms)) methods")
        for (i, m) in enumerate(ms[1:min(5, length(ms))])
            sig_unwrapped = unwrap_unionall_top(m.sig)
            argtypes = Tuple(sig_unwrapped.parameters[2:end])
            has_typevar = any(t -> t isa TypeVar, argtypes)
            label = "InliningState(v$i)"
            if has_typevar
                println("  Method $i: $argtypes (SKIP — has TypeVar)")
                push!(results, (name=label, sig="$argtypes", status="SKIP_TYPEVAR", bytes=0, error="Has TypeVar parameter"))
            else
                println("  Method $i: $argtypes")
                r = try_compile_validate(f, argtypes)
                push!(results, (name=label, sig="$argtypes", r...))
                println("  $(r.status) ($(r.bytes) bytes) $(r.error)")
            end
        end
    else
        push!(results, (name="InliningState", sig="N/A", status="NOT_FOUND", bytes=0, error="Not defined"))
        println("  NOT_FOUND")
    end
catch e
    push!(results, (name="InliningState", sig="N/A", status="ERROR", bytes=0, error=sprint(showerror, e)))
    println("  ERROR: $e")
end

# 2. _issubconditional
test_function("2. _issubconditional", :_issubconditional)

# 3. _typename
test_function("3. _typename", :_typename)

# 4. abstract_call
test_function("4. abstract_call", :abstract_call)

# 5. add_invoke_edge!
test_function("5. add_invoke_edge!", Symbol("add_invoke_edge!"))

# 6. assign_parentchild!
test_function("6. assign_parentchild!", Symbol("assign_parentchild!"); modules=[Base.JuliaSyntax, Base])

# 7. instanceof_tfunc
test_function("7. instanceof_tfunc", :instanceof_tfunc)

# 8. issubconditional
test_function("8. issubconditional", :issubconditional)

# 9. ndigits0zpb
test_function("9. ndigits0zpb", :ndigits0zpb; modules=[Base])

# 10. resize!
test_function("10. resize!", Symbol("resize!"); specific_sigs=[
    (resize!, (Vector{Int64}, Int64)),
])

# 11. throw_boundserror
test_function("11. throw_boundserror", :throw_boundserror; modules=[Base])

# 12. throw_inexacterror
test_function("12. throw_inexacterror", :throw_inexacterror; modules=[Base])

# 13. widenconst
test_function("13. widenconst", :widenconst)

# 14. widenreturn
test_function("14. widenreturn", :widenreturn)

# 15. widenreturn_noslotwrapper
test_function("15. widenreturn_noslotwrapper", :widenreturn_noslotwrapper)

# 16. ⊑ (isless-or-equal in type lattice)
test_function("16. ⊑", :⊑)

# 17. apply_refinement!
test_function("17. apply_refinement!", Symbol("apply_refinement!"))

# 18. #string#403 — internal string method (try to find it)
println("\n[18/25] #string#403")
try
    # These internal methods are generated by Julia; look for string-related methods
    # Try to find the exact method by searching Base string functions
    found = false
    for sym_str in ["#string#403", "#string#404", "#string#402"]
        sym = Symbol(sym_str)
        for mod in [Base, Core]
            if isdefined(mod, sym)
                f = getfield(mod, sym)
                ms = collect(methods(f))
                if length(ms) > 0
                    println("  Found $sym in $mod: $(length(ms)) methods")
                    for (i, m) in enumerate(ms[1:min(3, length(ms))])
                        sig_unwrapped = unwrap_unionall_top(m.sig)
                        argtypes = Tuple(sig_unwrapped.parameters[2:end])
                        has_typevar = any(t -> t isa TypeVar, argtypes)
                        label = "#string#(v$i)"
                        if has_typevar
                            println("  Method $i: $argtypes (SKIP — has TypeVar)")
                            push!(results, (name=label, sig="$argtypes", status="SKIP_TYPEVAR", bytes=0, error="Has TypeVar parameter"))
                        else
                            println("  Method $i: $argtypes")
                            r = try_compile_validate(f, argtypes)
                            push!(results, (name=label, sig="$argtypes", r...))
                            println("  $(r.status) ($(r.bytes) bytes) $(r.error)")
                        end
                    end
                    found = true
                    break
                end
            end
        end
        if found; break; end
    end
    if !found
        # Try finding via string(::Int64) internal method
        push!(results, (name="#string#403", sig="N/A", status="NOT_FOUND", bytes=0, error="Internal method not found"))
        println("  NOT_FOUND — internal generated method")
    end
catch e
    push!(results, (name="#string#403", sig="N/A", status="ERROR", bytes=0, error=sprint(showerror, e)))
    println("  ERROR: $e")
end

# 19. append!
test_function("19. append!", Symbol("append!"); specific_sigs=[
    (append!, (Vector{Int64}, Vector{Int64})),
])

# 20. append_c_digits
test_function("20. append_c_digits", :append_c_digits; modules=[Base.Ryu])

# 21. append_c_digits_fast
test_function("21. append_c_digits_fast", :append_c_digits_fast; modules=[Base.Ryu])

# 22. append_nine_digits
test_function("22. append_nine_digits", :append_nine_digits; modules=[Base.Ryu])

# 23. union!
test_function("23. union!", Symbol("union!"); specific_sigs=[
    (union!, (BitSet, BitSet)),
])

# 24. unionlen
test_function("24. unionlen", :unionlen)

# 25. widenwrappedslotwrapper
test_function("25. widenwrappedslotwrapper", :widenwrappedslotwrapper)

# Print summary
println("\n" * "=" ^ 80)
println("SUMMARY")
println("=" ^ 80)
validates = count(r -> r.status == "VALIDATES", results)
compile_errors = count(r -> r.status == "COMPILE_ERROR", results)
validate_errors = count(r -> r.status == "VALIDATE_ERROR", results)
not_found = count(r -> r.status == "NOT_FOUND", results)
skip_typevar = count(r -> r.status == "SKIP_TYPEVAR", results)
other = length(results) - validates - compile_errors - validate_errors - not_found - skip_typevar

println("Total test cases: $(length(results))")
println("  VALIDATES:      $validates")
println("  COMPILE_ERROR:  $compile_errors")
println("  VALIDATE_ERROR: $validate_errors")
println("  SKIP_TYPEVAR:   $skip_typevar")
println("  NOT_FOUND:      $not_found")
if other > 0
    println("  OTHER:          $other")
end

println("\nDetailed results:")
println("-" ^ 100)
for r in results
    status_str = rpad(r.status, 15)
    bytes_str = r.bytes > 0 ? "$(r.bytes)B" : "-"
    error_short = length(r.error) > 60 ? r.error[1:60] * "..." : r.error
    println("  $(rpad(r.name, 35)) $status_str $(rpad(bytes_str, 10)) $error_short")
end
