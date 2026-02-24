# Print the Julia IR for construct_ssa! to find the pattern
# creating struct 69 (2 externref fields)
using WasmTarget

f = getfield(Core.Compiler, Symbol("construct_ssa!"))
sig = first(methods(f)).sig
arg_types = Tuple(sig.parameters[2:end])
full_sig = Tuple{typeof(f), arg_types...}

# Get typed IR
ci_list = code_typed(f, arg_types)
if !isempty(ci_list)
    ci, ret = ci_list[1]
    println("=== construct_ssa! typed IR ===")
    println("Return type: $ret")
    println("Number of statements: $(length(ci.code))")
    println()

    # Look for :new expressions that create structs with 2 fields
    for (i, stmt) in enumerate(ci.code)
        stmt_type = ci.ssavaluetypes[i]
        if stmt isa Expr && stmt.head === :new
            println("Statement $i: $stmt")
            println("  Type: $stmt_type")
            println("  Args: $(stmt.args)")
            println()
        end
        # Also look for isdefined checks (field null checks)
        if stmt isa Expr && stmt.head === :isdefined
            println("Statement $i: $stmt")
            println("  Type: $stmt_type")
            println()
        end
    end

    # Also look for conditional branches (GotoIfNot) related to struct field checks
    for (i, stmt) in enumerate(ci.code)
        if stmt isa Core.GotoIfNot
            cond = stmt.cond
            if cond isa Core.SSAValue
                cond_stmt = ci.code[cond.id]
                if cond_stmt isa Expr && (cond_stmt.head === :isdefined ||
                    (cond_stmt.head === :call && any(a -> a isa GlobalRef && a.name === :isdefined, cond_stmt.args)))
                    println("Conditional $i: GotoIfNot($cond, $(stmt.dest))")
                    println("  Condition (SSA $cond): $cond_stmt")
                    println()
                end
            end
        end
    end
end
