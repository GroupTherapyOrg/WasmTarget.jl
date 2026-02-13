#!/usr/bin/env julia
# PURE-324: Debug func_registry lookup for #parse!#73
using WasmTarget
using JuliaSyntax

# Simulate what compile_invoke does

# The func_ref from the IR
func_ref = JuliaSyntax.:(var"#parse!#73")
called_func = getfield(JuliaSyntax, Symbol("#parse!#73"))
println("called_func = $called_func")
println("typeof(called_func) = $(typeof(called_func))")

# The args from IR: [:(:statement), JuliaSyntax.parse!, %6]
# arg types (what infer_value_type would return):
#   :statement → Symbol
#   JuliaSyntax.parse! → typeof(parse!)
#   %6 → ParseStream (from SSA)
call_arg_types = (Symbol, typeof(JuliaSyntax.parse!), JuliaSyntax.ParseStream)
println("call_arg_types = $call_arg_types")

# PURE-320 closure_arg_types attempt:
closure_arg_types = (typeof(called_func), call_arg_types...)
println("closure_arg_types = $closure_arg_types")

# What the function was registered with (from discover_dependencies/code_typed):
# specTypes = Tuple{typeof(#parse!#73), Symbol, typeof(parse!), ParseStream}
spec = Tuple{typeof(called_func), Symbol, typeof(JuliaSyntax.parse!), JuliaSyntax.ParseStream}
println("expected specTypes = $spec")

# Check if PURE-320 closure_arg_types matches:
println("\nclosure_arg_types matches specTypes[2:end]?")
reg_types = spec.parameters[2:end]
println("  registry arg_types = $reg_types")
println("  closure_arg_types = $(Tuple(closure_arg_types))")
println("  match = $(all(closure_arg_types[i] <: reg_types[i] for i in 1:length(reg_types)))")

# Now check how discover_dependencies registers this function
println("\n=== How discover_dependencies registers #parse!#73 ===")
# discover_dependencies processes code_typed output
# It finds :invoke statements and extracts (func, arg_types) pairs
# For parse_test → parse!(stream, rule=:statement):
#   IR: invoke CodeInstance for #parse!#73(Symbol, typeof(parse!), ParseStream)
#   func = #parse!#73
#   The code_typed for the OUTER parse!(::ParseStream) has:
#     invoke #parse!#73(:all, Core.Argument(1), Core.Argument(2))
# So from parse_test's IR, the invoke is:
#     invoke #parse!#73(:statement, parse!, %6)
#   with specTypes = Tuple{typeof(#parse!#73), Symbol, typeof(parse!), ParseStream}

# The REGISTRATION happens in compile_module:
# For each discovered function, it registers with arg_types from specTypes[2:end]
println("Registration arg_types = $(spec.parameters[2:end])")
println("These are: Symbol, typeof(parse!), ParseStream")

# The LOOKUP in compile_invoke happens with:
#   called_func = getfield(JuliaSyntax, :#parse!#73)
#   call_arg_types = (Symbol, typeof(parse!), ParseStream) ← from infer_value_type on args
# So the lookup should be: get_function(registry, #parse!#73, (Symbol, typeof(parse!), ParseStream))
# But what does infer_value_type return for `:(:statement)` (QuoteNode → Symbol)?

# Let's check: what does infer_value_type return for a QuoteNode?
println("\n=== infer_value_type for QuoteNode(:statement) ===")
# QuoteNode contains :statement which is a Symbol
# infer_value_type for QuoteNode should return typeof(val) = Symbol
println("typeof(:statement) = $(typeof(:statement))")

# But wait - the IR shows args = [:(:statement), parse!, %6]
# :(:statement) is a QuoteNode — infer_value_type likely returns Symbol
# parse! is a GlobalRef — infer_value_type returns typeof(parse!)
# %6 is SSAValue — infer_value_type returns ParseStream

# So call_arg_types = (Symbol, typeof(parse!), ParseStream)
# This SHOULD match the registered types!

# Unless infer_value_type returns something different for QuoteNode...
# Let me check if there's an issue with Symbol type inference

# Actually, the real question might be about the FUNCTION lookup itself
# Let me check what get_function does
println("\n=== Checking FunctionRegistry API ===")
end
