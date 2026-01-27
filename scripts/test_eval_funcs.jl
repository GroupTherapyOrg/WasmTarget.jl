using Pkg
Pkg.activate(dirname(@__DIR__))
using WasmTarget

# Test each eval function individually
eval_funcs = [
    ("eval_node", WasmTarget.eval_node, (WasmTarget.ASTNode, String, WasmTarget.Env)),
    ("eval_binary_node", WasmTarget.eval_binary_node, (WasmTarget.ASTNode, String, WasmTarget.Env)),
    ("eval_call", WasmTarget.eval_call, (WasmTarget.ASTNode, String, WasmTarget.Env)),
    ("eval_user_func", WasmTarget.eval_user_func, (WasmTarget.ASTNode, Vector{WasmTarget.Value}, Int32, String, WasmTarget.Env)),
    ("eval_assignment", WasmTarget.eval_assignment, (WasmTarget.ASTNode, String, WasmTarget.Env)),
    ("eval_if", WasmTarget.eval_if, (WasmTarget.ASTNode, String, WasmTarget.Env)),
    ("eval_while", WasmTarget.eval_while, (WasmTarget.ASTNode, String, WasmTarget.Env)),
    ("eval_for", WasmTarget.eval_for, (WasmTarget.ASTNode, String, WasmTarget.Env)),
    ("eval_func_def", WasmTarget.eval_func_def, (WasmTarget.ASTNode, String, WasmTarget.Env)),
    ("eval_return", WasmTarget.eval_return, (WasmTarget.ASTNode, String, WasmTarget.Env)),
    ("eval_block", WasmTarget.eval_block, (WasmTarget.ASTNode, String, WasmTarget.Env)),
    ("eval_program", WasmTarget.eval_program, (WasmTarget.ASTNode, String)),
]

# Base functions (all the working ones from earlier phases)
base_funcs = [
    (WasmTarget.digit_to_str, (Int32,)),
    (WasmTarget.int_to_string, (Int32,)),
    (WasmTarget.str_eq, (String, String)),
    (WasmTarget.str_len, (String,)),
    (WasmTarget.str_char, (String, Int32)),
    (WasmTarget.val_nothing, ()),
    (WasmTarget.val_int, (Int32,)),
    (WasmTarget.val_float, (Float32,)),
    (WasmTarget.val_bool, (Int32,)),
    (WasmTarget.val_string, (String,)),
    (WasmTarget.val_func, (WasmTarget.ASTNode,)),
    (WasmTarget.val_error, ()),
    (WasmTarget.val_is_truthy, (WasmTarget.Value,)),
    (WasmTarget.value_to_float, (WasmTarget.Value,)),
    (WasmTarget.value_to_string, (WasmTarget.Value,)),
    (WasmTarget.float_to_string, (Float32,)),
    (WasmTarget.cf_normal, ()),
    (WasmTarget.cf_return, (WasmTarget.Value,)),
    (WasmTarget.output_buffer_get, ()),
    (getfield(WasmTarget, Symbol("output_buffer_set!")), (String,)),
    (getfield(WasmTarget, Symbol("output_buffer_append!")), (String,)),
    (getfield(WasmTarget, Symbol("output_buffer_clear!")), ()),
    (WasmTarget.env_new, (Int32,)),
    (getfield(WasmTarget, Symbol("env_push_scope!")), (WasmTarget.Env,)),
    (getfield(WasmTarget, Symbol("env_pop_scope!")), (WasmTarget.Env,)),
    (WasmTarget.env_find, (WasmTarget.Env, String)),
    (WasmTarget.env_get, (WasmTarget.Env, String)),
    (getfield(WasmTarget, Symbol("env_set!")), (WasmTarget.Env, String, WasmTarget.Value)),
    (getfield(WasmTarget, Symbol("env_define!")), (WasmTarget.Env, String, WasmTarget.Value)),
    (WasmTarget.eval_binary, (Int32, WasmTarget.Value, WasmTarget.Value)),
    (WasmTarget.eval_binary_int_int, (Int32, Int32, Int32)),
    (WasmTarget.eval_binary_float_float, (Int32, Float32, Float32)),
    (WasmTarget.eval_equality, (WasmTarget.Value, WasmTarget.Value)),
    (WasmTarget.eval_unary, (Int32, WasmTarget.Value)),
    (WasmTarget.eval_builtin, (String, Vector{WasmTarget.Value}, Int32, WasmTarget.Env)),
    (WasmTarget.builtin_println, (Vector{WasmTarget.Value}, Int32, WasmTarget.Env)),
    (WasmTarget.builtin_print, (Vector{WasmTarget.Value}, Int32, WasmTarget.Env)),
    (WasmTarget.builtin_abs, (WasmTarget.Value,)),
    (WasmTarget.builtin_min, (WasmTarget.Value, WasmTarget.Value)),
    (WasmTarget.builtin_max, (WasmTarget.Value, WasmTarget.Value)),
    (WasmTarget.builtin_typeof, (WasmTarget.Value,)),
    (WasmTarget.builtin_string, (WasmTarget.Value,)),
    (WasmTarget.builtin_length, (WasmTarget.Value,)),
]

for (name, f, args) in eval_funcs
    try
        wasm = WasmTarget.compile_multi(vcat(base_funcs, [(f, args)]))
        println("PASS $name: $(length(wasm)) bytes")
    catch e
        println("FAIL $name: $(e isa ErrorException ? e.msg : sprint(showerror, e))")
    end
end
