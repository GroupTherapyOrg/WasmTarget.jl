using WasmTarget, JuliaSyntax, JuliaLowering, Logging

function trace_main()
    CT = JuliaLowering.SyntaxTree{JuliaLowering.SyntaxGraph{Dict{Symbol,Any}}}

    normalized = [(JuliaLowering._to_lowered_expr, (CT, Int64), "_to_lowered_expr")]
    seen = Set{Tuple{Any,Tuple}}()
    for (f, at, _) in normalized
        push!(seen, (f, at))
    end
    to_add = Vector{Tuple{Any, Tuple, String}}()
    to_scan = Vector{Tuple{Any, Tuple, String}}(copy(normalized))

    while length(to_scan) > 0
        f, at, nm = popfirst!(to_scan)

        local ir
        try
            ir, _ = Base.code_ircode(f, at)[1]
        catch
            continue
        end

        if !hasproperty(ir, :stmts) || !hasproperty(ir.stmts, :stmt)
            continue
        end

        for (idx, stmt) in enumerate(ir.stmts.stmt)
            if stmt isa Expr && stmt.head === :invoke && length(stmt.args) >= 2
                mi_or_ci = stmt.args[1]
                mi = if mi_or_ci isa Core.MethodInstance
                    mi_or_ci
                elseif isdefined(Core, :CodeInstance) && mi_or_ci isa Core.CodeInstance
                    mi_or_ci.def
                else
                    nothing
                end

                if mi === nothing || !(mi.def isa Method)
                    continue
                end

                meth = mi.def
                mod = meth.module
                mname = string(meth.name)

                # Print node_to_expr discoveries
                if occursin("node_to_expr", mname)
                    println("FOUND $mname in function '$nm'")
                    println("  specTypes = $(mi.specTypes)")
                    println("  module = $mod")
                    sig = mi.specTypes
                    if sig <: Tuple
                        for (pi, p) in enumerate(sig.parameters)
                            wtype = WasmTarget.julia_to_wasm_type(p)
                            println("  param[$pi] = $p → $wtype")
                        end
                    end
                end

                # Replicate discovery logic
                mod_name = nameof(mod)
                if mod_name in WasmTarget.SKIP_AUTODISCOVER_MODULES || mod === Core || mod === Base
                    if !(mod === Base && meth.name in WasmTarget.AUTODISCOVER_BASE_METHODS)
                        continue
                    end
                end

                if meth.name in WasmTarget.SKIP_AUTODISCOVER_METHODS
                    continue
                end

                sig = mi.specTypes
                if sig <: Tuple && length(sig.parameters) >= 1
                    func_type = sig.parameters[1]
                    func_val = nothing
                    arg_types_val = nothing
                    try
                        if func_type isa DataType && func_type <: Function
                            func_val = getfield(mod, meth.name)
                            arg_types_val = Tuple(sig.parameters[2:end])
                        elseif func_type isa DataType && func_type <: Type
                            inner_type = func_type.parameters[1]
                            if inner_type isa DataType || inner_type isa UnionAll
                                func_val = inner_type
                                arg_types_val = Tuple(sig.parameters[2:end])
                            end
                        end
                    catch; end

                    if func_val !== nothing && arg_types_val !== nothing
                        key = (func_val, arg_types_val)
                        if !(key in seen)
                            push!(seen, key)
                            entry = (func_val, arg_types_val, string(meth.name))
                            push!(to_add, entry)
                            push!(to_scan, entry)
                        end
                    end
                end
            end
        end
    end

    println("\nTotal discovered: $(length(to_add) + length(normalized)) functions")
    println("\nAll discovered functions:")
    for (f, at, nm) in vcat(normalized, to_add)
        println("  $nm: $at")
    end
end

trace_main()
