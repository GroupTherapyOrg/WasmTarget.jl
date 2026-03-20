# trace_archb_critical_path.jl — F-001: Trace parse+lower critical paths
#
# Run: julia +1.12 --project=. scripts/trace_archb_critical_path.jl

using JuliaSyntax
using JuliaLowering
using JSON
using Dates

println("=" ^ 70)
println("F-001: Trace parse+lower critical paths")
println("  Target: f(x::Int64)=x*x+1")
println("=" ^ 70)

source = "f(x::Int64)=x*x+1"

# ═══════════════════════════════════════════════════════════════════════════════
# PART 1: PARSING
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- PART 1: JuliaSyntax Parsing ---")

tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source)
println("  Parse result kind: $(JuliaSyntax.kind(tree))")

# Print tree structure
function print_tree(node, indent=0)
    k = JuliaSyntax.kind(node)
    s = JuliaSyntax.span(node)
    prefix = " " ^ indent
    children = try JuliaSyntax.children(node) catch; nothing end
    if children !== nothing && !isempty(children)
        println("$(prefix)$(k) [span=$(s)]")
        for c in children; print_tree(c, indent + 2); end
    else
        println("$(prefix)$(k) [span=$(s)] (leaf)")
    end
end
print_tree(tree)

# Analyze parser function call graph
PS = JuliaSyntax.ParseState

parse_names = Symbol[
    :parse_and, :parse_arrow, :parse_atom, :parse_block, :parse_call,
    :parse_catch, :parse_comma, :parse_comparison, :parse_cond, :parse_do,
    :parse_docstring, :parse_eq, :parse_eq_star, :parse_expr, :parse_factor,
    :parse_factor_after, :parse_global_local_const_vars, :parse_if_elseif,
    :parse_import_atsym, :parse_import_path, :parse_imports, :parse_invalid_ops,
    :parse_iteration_spec, :parse_iteration_specs, :parse_juxtapose,
    :parse_macro_name, :parse_or, :parse_pair, :parse_paren, :parse_pipe_gt,
    :parse_pipe_lt, :parse_public, :parse_range, :parse_rational, :parse_resword,
    :parse_shift, :parse_space_separated_exprs, :parse_stmts, :parse_struct_field,
    :parse_subtype_spec, :parse_term, :parse_toplevel, :parse_try,
    :parse_unary, :parse_unary_prefix, :parse_unary_subtype,
]

function extract_callees(ci)
    callees = Dict{String,Set{String}}()
    for stmt in ci.code
        if stmt isa Expr
            callee = nothing
            if stmt.head === :invoke && length(stmt.args) >= 2
                callee = stmt.args[2]
            elseif stmt.head === :call && length(stmt.args) >= 1
                callee = stmt.args[1]
            end
            if callee isa GlobalRef
                mod = string(callee.mod)
                name = string(callee.name)
                if !haskey(callees, mod); callees[mod] = Set{String}(); end
                push!(callees[mod], name)
            end
        end
    end
    return callees
end

parser_call_graph = Dict{String, Dict{String,Set{String}}}()
parser_ir_sizes = Dict{String, Int}()

for fname in parse_names
    f = getfield(JuliaSyntax, fname)
    try
        ci, rt = Base.code_typed(f, (PS,); optimize=true)[1]
        parser_call_graph[string(fname)] = extract_callees(ci)
        parser_ir_sizes[string(fname)] = length(ci.code)
    catch e
        println("  Warning: $(fname) failed: $(typeof(e))")
    end
end

# Collect ALL JuliaSyntax callees
all_js_callees = Set{String}()
for (fname, callees) in parser_call_graph
    for (mod, names) in callees
        if occursin("JuliaSyntax", mod)
            union!(all_js_callees, names)
        end
    end
end

println("\n  $(length(all_js_callees)) unique JuliaSyntax callees from parse_* functions:")

# Categorize: which are parse_*, which are internal helpers
parse_fn_callees = filter(n -> startswith(n, "parse_"), all_js_callees)
internal_callees = filter(n -> !startswith(n, "parse_"), all_js_callees)

println("\n  Parse function callees ($(length(parse_fn_callees))):")
for c in sort(collect(parse_fn_callees))
    in_module = Symbol(c) in parse_names
    println("    $(rpad(c, 45)) $(in_module ? "✓ compiled" : "✗ NOT in module")")
end

println("\n  Internal helper callees ($(length(internal_callees))):")
for c in sort(collect(internal_callees))
    println("    $c")
end

# ═══════════════════════════════════════════════════════════════════════════════
# PART 2: Key internal helpers — deeper analysis
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- PART 2: Internal helper analysis ---")

# The internal helpers are the REAL gap. Let's check each one.
# Some are kwarg method bodies (#bump#29 etc), some are real functions
important_internals = [
    :parse_LtoR, :parse_Nary, :parse_RtoL, 
    :parse_brackets, :parse_call_chain, :parse_block_inner,
    :parse_comma_separated, :parse_function_signature,
    :parse_lazy_cond, :parse_where_chain, :parse_with_chains,
    :parse_assignment, :parse_assignment_with_initial_ex,
    :parse_factor_with_initial_ex, :parse_import,
]

println("\n  Key internal parser functions:")
for fname in important_internals
    if isdefined(JuliaSyntax, fname)
        f = getfield(JuliaSyntax, fname)
        try
            ci, rt = Base.code_typed(f, (PS,); optimize=true)[1]
            println("    $(rpad(string(fname), 45)) $(length(ci.code)) stmts")
        catch
            # Try with different arg types
            found = false
            for m in methods(f)
                try
                    # Get the arg types from the method
                    sig = m.sig
                    if sig isa DataType
                        arg_types = Tuple(sig.parameters[2:end])
                        ci, rt = Base.code_typed(f, arg_types; optimize=true)[1]
                        println("    $(rpad(string(fname), 45)) $(length(ci.code)) stmts ($(arg_types))")
                        found = true
                        break
                    end
                catch; end
            end
            if !found
                println("    $(rpad(string(fname), 45)) FAILED to code_typed")
            end
        end
    else
        println("    $(rpad(string(fname), 45)) NOT DEFINED in JuliaSyntax")
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# PART 3: LOWERING
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- PART 3: JuliaLowering ---")

lowering_public = String[]
lowering_all = String[]
for name in names(JuliaLowering; all=true)
    sname = string(name)
    (startswith(sname, "#") || sname == "JuliaLowering") && continue
    try
        f = getfield(JuliaLowering, name)
        if f isa Function
            push!(lowering_all, sname)
            if name in names(JuliaLowering; all=false)
                push!(lowering_public, sname)
            end
        end
    catch; end
end

println("  Public: $(length(lowering_public)): $(sort(lowering_public))")
println("  All:    $(length(lowering_all))")

# Try lowering with include_string
println("\n  Attempting lowering:")
try
    result = JuliaLowering.include_string(Main, source)
    println("    include_string result: $result ($(typeof(result)))")
catch e
    println("    include_string: $(typeof(e))")
end

# Get CodeInfo via standard Julia pipeline
println("\n  Standard Julia pipeline (Meta.parse → code_typed):")
m = Module()
Base.eval(m, Meta.parse(source))
ci, rt = Base.code_typed(getfield(m, :f), (Int64,); optimize=true)[1]
println("    $(length(ci.code)) stmts, returns $rt")
for (i, stmt) in enumerate(ci.code)
    println("      %$i = $stmt  :: $(ci.ssavaluetypes[i])")
end

# Also get unoptimized IR
ci_unopt, rt_unopt = Base.code_typed(getfield(m, :f), (Int64,); optimize=false)[1]
println("\n    Unoptimized: $(length(ci_unopt.code)) stmts")
for (i, stmt) in enumerate(ci_unopt.code)
    println("      %$i = $stmt  :: $(ci_unopt.ssavaluetypes[i])")
end

# ═══════════════════════════════════════════════════════════════════════════════
# PART 4: Module export check
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- PART 4: Module exports ---")

wasm_path = joinpath(@__DIR__, "..", "test", "selfhost", "self-hosted-julia.wasm")
if isfile(wasm_path)
    println("  self-hosted-julia.wasm: $(round(filesize(wasm_path)/1024, digits=1)) KB")
    try
        exports_raw = read(`wasm-tools print --skeleton $wasm_path`, String)
        export_names = String[]
        for line in split(exports_raw, '\n')
            m = match(r"\(export \"([^\"]+)\"", line)
            if m !== nothing; push!(export_names, m[1]); end
        end
        println("  $(length(export_names)) exports")
    catch e
        println("  wasm-tools: $e")
    end
end

archc_path = joinpath(@__DIR__, "..", "arch-c-e2e.wasm")
if isfile(archc_path)
    println("  arch-c-e2e.wasm: $(round(filesize(archc_path)/1024, digits=1)) KB")
    try
        exports_raw = read(`wasm-tools print --skeleton $archc_path`, String)
        export_names = String[]
        for line in split(exports_raw, '\n')
            m = match(r"\(export \"([^\"]+)\"", line)
            if m !== nothing; push!(export_names, m[1]); end
        end
        println("  $(length(export_names)) exports: $(sort(export_names))")
    catch e
        println("  wasm-tools: $e")
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# PART 5: GAP ANALYSIS — what's actually needed for Architecture B
# ═══════════════════════════════════════════════════════════════════════════════

println("\n--- PART 5: Gap Analysis for Architecture B ---")

# The REAL question: for Architecture B, we need compile_source(source::String)::Vector{UInt8}
# This chains: parse → lower → typeinf → codegen → to_bytes
# 
# Steps 3 (typeinf via thin_typeinf) and 4 (codegen via wasm_compile_flat) are DONE.
# The gap is steps 1 (parse) and 2 (lower).
#
# For parsing, we need:
#   1. ParseStream constructor (creates lexer, tokenizes)
#   2. parse_toplevel (recursive descent)
#   3. Tree building (GreenNode construction)
#
# For lowering, we need:
#   1. AST → CodeInfo conversion
#   2. Scope resolution
#   3. Variable binding
#
# But BOTH are massive - 100s of functions. The realistic approach for MVP is:
# Option A: Compile the full JuliaSyntax parser to WASM (hard, many stubs)
# Option B: Write a mini-parser for the MVP subset (simpler, but "cheating"?)
# Option C: Run parse+lower on SERVER, only typeinf+codegen in browser (= Arch C, already done)
# Option D: Ship pre-compiled CodeInfo as JSON, parse+lower at build time

# Count functions needed for each approach
println("\n  APPROACH ANALYSIS:")
println()
println("  Approach A: Full JuliaSyntax + JuliaLowering in WASM")
println("    Parser functions to compile: 46 parse_* + ~15 internal helpers + stream/lexer")
println("    Internal helpers NOT compiled: $(length(internal_callees)) (stream ops, kwarg bodies, etc)")

# List the missing internal callees grouped
kwarg_bodies = filter(n -> startswith(n, "#"), internal_callees)
real_functions = filter(n -> !startswith(n, "#") && !startswith(n, "parse_"), internal_callees)
println("    Kwarg body functions: $(length(kwarg_bodies)) — $(sort(collect(kwarg_bodies)))")
println("    Other internal: $(length(real_functions)) — $(sort(collect(real_functions)))")

# Estimate stub impact
println()
println("  Approach B: Minimal WASM-native parser for MVP subset")
println("    For f(x::Int64)=x*x+1, we need to recognize:")
println("      - Function definition (name = body)")
println("      - Call syntax f(args...)")
println("      - Type annotations x::T")
println("      - Binary operators (+, *, -, /)")
println("      - Integer literals")
println("      - Identifiers")
println("    This is ~200 lines of Julia, fully WASM-compilable")
println("    NO stubs, NO complex dependencies")

println()
println("  Approach C: Already done (Arch C = server parse+lower, browser typeinf+codegen)")
println("    f(5n)===26n passes via e2e_demo_arch_c.cjs")

# ═══════════════════════════════════════════════════════════════════════════════
# PART 6: Save gap analysis
# ═══════════════════════════════════════════════════════════════════════════════

gap = Dict{String,Any}(
    "target" => source,
    "timestamp" => string(Dates.now()),
    "parse_tree" => Dict(
        "kind" => "toplevel → function → (call, call)",
        "structure" => "short-form function definition with binary ops",
    ),
    "parser" => Dict{String,Any}(
        "compiled_parse_functions" => length(parse_names),
        "parse_fn_callees_not_in_module" => sort(collect(filter(n -> !(Symbol(n) in parse_names), parse_fn_callees))),
        "internal_callees_count" => length(internal_callees),
        "internal_callees" => sort(collect(internal_callees)),
        "kwarg_body_callees" => sort(collect(kwarg_bodies)),
        "real_internal_callees" => sort(collect(real_functions)),
        "ir_sizes" => parser_ir_sizes,
    ),
    "lowerer" => Dict{String,Any}(
        "compiled_count" => 9,
        "total_functions" => length(lowering_all),
        "public_functions" => sort(lowering_public),
    ),
    "codegen_already_done" => Dict(
        "thin_typeinf" => "DONE — wasm_thin_typeinf in arch-c-e2e.wasm",
        "wasm_compile_flat" => "DONE — wasm_compile_flat in arch-c-e2e.wasm",
        "byte_extraction" => "DONE — wasm_bytes_length/get",
        "string_constructors" => "DONE — create_wasm_string/set_string_char!",
    ),
    "architecture_b_gap" => Dict{String,Any}(
        "parse_gap" => "46 parse_* compiled but call ~55 internal helpers, most stubbed. ParseStream constructor + Lexer NOT compiled.",
        "lower_gap" => "9/$(length(lowering_all)) lowerer functions compiled. Most lowering infrastructure missing.",
        "typeinf_gap" => "NONE — thin_typeinf works in WASM",
        "codegen_gap" => "NONE — wasm_compile_flat works in WASM",
    ),
    "recommended_approach" => Dict{String,Any}(
        "approach" => "Write WASM-native mini-parser for MVP expression subset",
        "rationale" => "Full JuliaSyntax has 55+ internal helpers with deep dependencies (Lexer, tokenizer, IO). Writing a focused ~200-line parser for arithmetic expressions avoids all stubs.",
        "scope" => "Function definitions, binary ops (+,-,*,/), type annotations (::Int64), identifiers, integer literals",
        "output" => "Flat CodeInfo-compatible representation (same format as wasm_compile_flat expects)",
    ),
    "summary" => Dict{String,Any}(
        "parser_compiled" => length(parse_names),
        "parser_internal_missing" => length(internal_callees),
        "lowerer_compiled" => 9,
        "lowerer_total" => length(lowering_all),
        "typeinf_status" => "COMPLETE",
        "codegen_status" => "COMPLETE",
    ),
)

output_path = joinpath(@__DIR__, "gap_analysis_f001.json")
open(output_path, "w") do io
    JSON.print(io, gap, 2)
end
println("\n  Saved to: $output_path")

println("\n" * "=" ^ 70)
println("FINAL SUMMARY")
println("=" ^ 70)
println()
println("  PARSING GAP:")
println("    46 parse_* functions compiled BUT call 55 internal helpers")
println("    Internal helpers are stubbed → parse_* will trap on real data")
println("    ParseStream constructor + Lexer not compiled")
println("    Approach: Write WASM-native mini-parser (~200 lines Julia)")
println()
println("  LOWERING GAP:")
println("    9/$(length(lowering_all)) functions compiled")
println("    Full lowering requires scope analysis, binding resolution, etc.")
println("    Approach: For MVP, convert parsed AST to flat CodeInfo directly")
println("    (short-form f(x)=expr → 3-4 IR stmts for simple arithmetic)")
println()
println("  TYPEINF: COMPLETE (thin_typeinf in WASM)")
println("  CODEGEN: COMPLETE (wasm_compile_flat in WASM)")
println()
println("  RECOMMENDED ARCHITECTURE B PLAN:")
println("    1. Write wasm_mini_parse(source::String) → flat Int32 buffer")
println("    2. This mini-parser handles MVP expressions directly")
println("    3. Output format matches what wasm_compile_flat expects")
println("    4. Compile mini_parse to WASM alongside existing codegen")
println("    5. JS: toWasmString → wasm_mini_parse → wasm_compile_flat → bytes")
println("=" ^ 70)
