#!/usr/bin/env julia
# PURE-603: Which GlobalRef :call expressions are actually reachable (non-Union{} return type)?
using JuliaLowering

function diagnose()
    CT = JuliaLowering.SyntaxTree{JuliaLowering.SyntaxGraph{Dict{Symbol,Any}}}
    ci, rt = code_typed(JuliaLowering._to_lowered_expr, (CT, Int64))[1]

    dead_count = 0
    reachable_count = 0

    for (i, stmt) in enumerate(ci.code)
        if !(stmt isa Expr && stmt.head === :call && length(stmt.args) >= 1)
            continue
        end
        f = stmt.args[1]
        if !(f isa GlobalRef)
            continue
        end
        if f.mod === Core || f.mod === Base
            continue
        end

        ret_type = ci.ssavaluetypes[i]
        if ret_type === Union{}
            dead_count += 1
        else
            reachable_count += 1
            arg_types = []
            for a in stmt.args[2:end]
                if a isa Core.SSAValue
                    push!(arg_types, ci.ssavaluetypes[a.id])
                elseif a isa Core.Argument
                    push!(arg_types, ci.slottypes[a.n])
                else
                    push!(arg_types, typeof(a))
                end
            end
            println("REACHABLE stmt $i: $(f.mod).$(f.name)($(join(arg_types, ", "))) -> $ret_type")
        end
    end

    println("\nNon-Core/Base GlobalRef calls:")
    println("  Dead code (Union{} return): $dead_count")
    println("  Reachable (non-Union{} return): $reachable_count")
    println("\nNow checking CORE/BASE unhandled calls...")

    for (i, stmt) in enumerate(ci.code)
        if !(stmt isa Expr && stmt.head === :call && length(stmt.args) >= 1)
            continue
        end
        f = stmt.args[1]
        if !(f isa GlobalRef)
            continue
        end
        if f.mod !== Core && f.mod !== Base
            continue
        end

        # Only show non-handled Core/Base calls that would hit the cross-call path
        handled_names = Set([:getfield, :getproperty, :setfield!, :setproperty!,
            :isa, :typeof, :sizeof, :throw, :new, :tuple, :arrayref, :arrayset,
            :nfields, :fieldtype, :apply_type, :typeassert, :ifelse])

        if f.name in handled_names
            continue
        end

        ret_type = ci.ssavaluetypes[i]
        arg_types = []
        for a in stmt.args[2:end]
            if a isa Core.SSAValue
                push!(arg_types, ci.ssavaluetypes[a.id])
            elseif a isa Core.Argument
                push!(arg_types, ci.slottypes[a.n])
            else
                push!(arg_types, typeof(a))
            end
        end
        println("$(f.mod).$(f.name)($(join(arg_types, ", "))) -> $ret_type [stmt $i]")
    end
end

diagnose()
