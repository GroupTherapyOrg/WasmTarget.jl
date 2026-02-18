#!/usr/bin/env julia
# PURE-3116: Batch verify 27 COMPILES_NOW functions from type lattice + utility categories
# Same procedure as PURE-3115: compile → validate → record status

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
println("PURE-3116: Batch 2 Verification — Type Lattice + Utility Functions")
println("=" ^ 80)

# 1. PartialStruct — Core.Compiler constructor
println("\n[1/27] PartialStruct")
try
    r = try_compile_validate(Core.Compiler.PartialStruct, (Any, Vector{Any}))
    push!(results, (name="PartialStruct", sig="(Any, Vector{Any})", r...))
    println("  $(r.status) ($(r.bytes) bytes)")
catch e
    push!(results, (name="PartialStruct", sig="(Any, Vector{Any})", status="COMPILE_ERROR", bytes=0, error=sprint(showerror, e)))
    println("  COMPILE_ERROR: $e")
end

# 2. BestguessInfo — Core.Compiler constructor (if it exists)
println("\n[2/27] BestguessInfo")
try
    if isdefined(Core.Compiler, :BestguessInfo)
        f = Core.Compiler.BestguessInfo
        ms = collect(methods(f))
        if length(ms) > 0
            for (i, m) in enumerate(ms[1:min(3, length(ms))])
                sig_unwrapped = unwrap_unionall_top(m.sig)
                argtypes = Tuple(sig_unwrapped.parameters[2:end])
                has_typevar = any(t -> t isa TypeVar, argtypes)
                label = length(ms) > 1 ? "BestguessInfo(v$i)" : "BestguessInfo"
                if has_typevar
                    println("  Method $i: $argtypes (SKIP — has TypeVar)")
                    push!(results, (name=label, sig="$argtypes", status="SKIP_TYPEVAR", bytes=0, error="Has TypeVar parameter"))
                else
                    println("  Method $i: $argtypes")
                    r = try_compile_validate(f, argtypes)
                    push!(results, (name=label, sig="$argtypes", r...))
                    println("  $(r.status) ($(r.bytes) bytes)")
                end
            end
        else
            push!(results, (name="BestguessInfo", sig="N/A", status="NO_METHODS", bytes=0, error="No methods found"))
            println("  NO_METHODS")
        end
    else
        push!(results, (name="BestguessInfo", sig="N/A", status="NOT_FOUND", bytes=0, error="Not defined in Core.Compiler"))
        println("  NOT_FOUND in Core.Compiler")
    end
catch e
    push!(results, (name="BestguessInfo", sig="N/A", status="ERROR", bytes=0, error=sprint(showerror, e)))
    println("  ERROR: $e")
end

# 3. OptimizationState
println("\n[3/27] OptimizationState")
try
    if isdefined(Core.Compiler, :OptimizationState)
        f = Core.Compiler.OptimizationState
        ms = collect(methods(f))
        for (i, m) in enumerate(ms[1:min(5, length(ms))])
            sig_unwrapped = unwrap_unionall_top(m.sig)
            argtypes = Tuple(sig_unwrapped.parameters[2:end])
            has_typevar = any(t -> t isa TypeVar, argtypes)
            if has_typevar
                println("  Method $i: $argtypes (SKIP — has TypeVar)")
                push!(results, (name="OptimizationState(v$i)", sig="$argtypes", status="SKIP_TYPEVAR", bytes=0, error="Has TypeVar parameter"))
            else
                println("  Method $i: $argtypes")
                r = try_compile_validate(f, argtypes)
                push!(results, (name="OptimizationState(v$i)", sig="$argtypes", r...))
                println("  $(r.status) ($(r.bytes) bytes)")
            end
        end
    else
        push!(results, (name="OptimizationState", sig="N/A", status="NOT_FOUND", bytes=0, error=""))
        println("  NOT_FOUND")
    end
catch e
    push!(results, (name="OptimizationState", sig="N/A", status="ERROR", bytes=0, error=sprint(showerror, e)))
    println("  ERROR: $e")
end

# Generic function tester — tries Core.Compiler first, then Base
function test_function(name_str, sym; modules=[Core.Compiler, Base], specific_sigs=nothing)
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
            test_ms = length(ms) > 5 ? ms[1:min(3, length(ms))] : ms
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

# 4-27: Test remaining functions
test_function("4. _all", :_all)
test_function("5. _assert_tostring", :_assert_tostring)
test_function("6. _throw_argerror", :_throw_argerror; modules=[Base])
test_function("7. _unioncomplexity", :_unioncomplexity)
test_function("8. _uniontypes", :_uniontypes)

# _validate_val! needs special handling for the !
println("\n[9. _validate_val!]")
for mod in [Core.Compiler, Base]
    sym = Symbol("_validate_val!")
    if isdefined(mod, sym)
        f = getfield(mod, sym)
        ms = collect(methods(f))
        println("  Found in $mod: $(length(ms)) methods")
        for (i, m) in enumerate(ms[1:min(3, length(ms))])
            argtypes = Tuple(m.sig.parameters[2:end])
            println("  Method $i: $argtypes")
            r = try_compile_validate(f, argtypes)
            push!(results, (name="_validate_val!(v$i)", sig="$argtypes", r...))
            println("  $(r.status) ($(r.bytes) bytes) $(r.error)")
        end
        break
    end
end

# Simple utility functions — try with specific signatures for compare_julia_wasm potential
test_function("10. all", :all; specific_sigs=[
    (all, (typeof(iszero), Tuple{Int64, Int64, Int64})),
])
test_function("11. convert", :convert; specific_sigs=[
    (convert, (Type{Int64}, Int64)),
])
test_function("12. count_const_size", :count_const_size)
test_function("13. datatype_fieldcount", :datatype_fieldcount)
test_function("14. error", :error; modules=[Base, Core], specific_sigs=[
    (error, (String,)),
])

# fill! — try with Vector{Int64}
test_function("15. fill!", Symbol("fill!"); specific_sigs=[
    (fill!, (Vector{Int64}, Int64)),
])

# filter! — try with Vector{Int64}
test_function("16. filter!", Symbol("filter!"); specific_sigs=[
    (filter!, (typeof(iseven), Vector{Int64})),
])

test_function("17. intersect", :intersect)
test_function("18. invalid_wrap_err", :invalid_wrap_err; modules=[Base])

# length — try numeric and string
test_function("19. length", :length; specific_sigs=[
    (length, (Vector{Int64},)),
    (length, (String,)),
])

# ndigits0z — numeric, good for compare_julia_wasm
test_function("20. ndigits0z", :ndigits0z; modules=[Base], specific_sigs=[
    (Base.ndigits0z, (Int64, Int64)),
])

# ndigits0znb
test_function("21. ndigits0znb", :ndigits0znb; modules=[Base], specific_sigs=[
    (Base.ndigits0znb, (UInt64, Int64)),
])

# reverse!
test_function("22. reverse!", Symbol("reverse!"); specific_sigs=[
    (reverse!, (Vector{Int64}, Int64, Int64)),
])

test_function("23. scan_leaf_partitions", :scan_leaf_partitions)
test_function("24. ssa_def_slot", :ssa_def_slot)
test_function("25. sym_in", :sym_in)
test_function("26. tname_intersect", :tname_intersect)
test_function("27. type_more_complex", :type_more_complex)

# Print summary
println("\n" * "=" ^ 80)
println("SUMMARY")
println("=" ^ 80)
validates = count(r -> r.status == "VALIDATES", results)
compile_errors = count(r -> r.status == "COMPILE_ERROR", results)
validate_errors = count(r -> r.status == "VALIDATE_ERROR", results)
not_found = count(r -> r.status == "NOT_FOUND", results)
other = length(results) - validates - compile_errors - validate_errors - not_found

println("Total test cases: $(length(results))")
println("  VALIDATES:      $validates")
println("  COMPILE_ERROR:  $compile_errors")
println("  VALIDATE_ERROR: $validate_errors")
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
    println("  $(rpad(r.name, 30)) $status_str $(rpad(bytes_str, 10)) $error_short")
end
