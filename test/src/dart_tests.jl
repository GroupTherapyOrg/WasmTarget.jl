# dart2wasm's tests at the pin, ported with Julia as the ground truth (test/dart_tests.toml, dev/LEDGER.md
# D41): every case of test/smoke_corpus.jl's `dart_*` groups. Native Julia computes the answer recorded
# here (D3, never dart's value): one value, or the facts the dart test asserts as a tuple or a vector, each
# fact its own element so a wrong one names itself. Each case's compile is judged by a property, never by a
# snapshot of where it stops today: it compiles, or it rejects located (any Rejection but Internal, which is
# WT's own bug; a raw exception fails). A case recorded :compiled must keep compiling, the ratchet that a
# port never loses ground; a case recorded :rejects may stop anywhere, so one lane's progress never turns
# another lane's landing red (the snapshot form did, 2026-10-28, the loop's oscillation). The ratchet grows
# when the corpus owner records a newly compiling case. A case recorded :wt_bug is a known WT bug (it
# rejects as Internal), listed so the landing stays green while its owner fixes it; the list only shrinks. Native Julia's answer does not depend on
# WasmTarget's code, so it runs for each case whose group text or record the change adds or edits against
# CHECK_BASE (dev/check.sh's base, origin/wt2 by default; HEAD~1 under dev/ship.sh), proving a new or edited
# answer native when it is written. A base that holds no corpus runs every native answer.
#
# Under WT_LANDING_CORE=1 (dev/check.sh sets it) the landing compiles a fixed core, the first 5 cases of each
# group plus every case the change adds or edits, so the landing's cost does not grow with the port; the
# whole corpus runs beside the landings on wt2's head (without the variable), its red the next landing's
# first item.
using Test, WasmTarget

# the corpus's `dart_*` groups, read in a module of their own as test/smoke.jl reads the whole corpus
const DART_GROUPS = let m = Module(:DartCorpus), groups = Pair{String,Vector{Any}}[]
    Core.eval(m, :(_g(name, cases) = push!($groups, name => cases)))
    Core.eval(m, :(_xf(name, cases) = push!($groups, name => cases)))
    Base.include(m, joinpath(@__DIR__, "..", "smoke_corpus.jl"))
    filter(g -> startswith(first(g), "dart_"), groups)
end

# the text the change is measured against: the file at CHECK_BASE, followed across a rename by git's
# own rename detection (a move leaves its records unchanged), or "" where the base holds none
const _DART_BASE = get(ENV, "CHECK_BASE", "origin/wt2")
function _dart_at_base(path::String)::String
    local was = try
        local renames = read(pipeline(`git -C $(@__DIR__) diff -M --name-status $(_DART_BASE)`; stderr = devnull), String)
        local m = match(Regex("^R\\d*\\t(\\S+)\\t\\Q$(path)\\E\$", "m"), renames)
        m === nothing ? path : String(m[1])
    catch
        path
    end
    return try
        read(pipeline(`git -C $(@__DIR__) show $(_DART_BASE):$was`; stderr = devnull), String)
    catch
        ""
    end
end

# each dart group's text in the corpus: its definitions since the group before and its case list, every
# block of a group joined (a group may stand twice)
function _dart_group_texts(text::String)::Dict{String,String}
    local out = Dict{String,String}()
    local start = findfirst("# ---- dart2wasm's tests at the pin, tests/web/wasm", text)
    start === nothing && return out
    local block = IOBuffer()
    local group = ""
    for l in eachline(IOBuffer(SubString(text, first(start))))
        println(block, l)
        local m = match(r"^_g\(\"(dart_[^\"]+)\"", l)
        m === nothing || (group = m[1])
        if l == "])" && !isempty(group)
            out[group] = get(out, group, "") * String(take!(block))
            group = ""
        end
    end
    return out
end

# each record's line in this file's table, by its case
_dart_record_lines(text::String)::Dict{String,String} =
    Dict(String(m[1]) => String(m[2]) for m in eachmatch(r"^\s*\"(dart_[^\"]+)\" => (.*)$"m, text))

# the cases whose native answer the change can affect: its group's text or its record differs from the base's
const DART_NATIVE_DUE = let base_c = _dart_group_texts(_dart_at_base("test/smoke_corpus.jl")),
                            head_c = _dart_group_texts(read(joinpath(@__DIR__, "..", "smoke_corpus.jl"), String)),
                            base_r = _dart_record_lines(_dart_at_base("test/src/dart_tests.jl")),
                            head_r = _dart_record_lines(read(joinpath(@__DIR__, "dart_tests.jl"), String))
    Set{String}(key for (key, rec) in head_r
                if get(base_r, key, nothing) != rec || get(base_c, first(split(key, '/')), nothing) != get(head_c, first(split(key, '/')), ""))
end


# a case outside the strict subset (D32): Julia's verifier's verdict, recorded by the kind of each error
# it reports (WasmTarget.TrimErrorKind), which names no line of the corpus and no printed operand type
# (those vary with what inference cached before, `n::Int64` after a native run and `n::Any` before one)
const _Outside = Tuple{Symbol,Vector{WasmTarget.TrimErrorKind}}
_outside(kinds::WasmTarget.TrimErrorKind...) = (:outside, collect(kinds))

# each case: native Julia's answer and the rejection its compile gives today
# a case whose compile returns a module records :compiled (its run checked against native once the
# runner lands)
const DART_CASES = Dict{String,Tuple{Any,Symbol}}(
    # tests/web/wasm
    "dart_web_wasm/assertion_failure_message" => (1, :rejects),
    "dart_web_wasm/boxed_value_tearoff" => (4, :compiled),
    "dart_web_wasm/closure_hash_code" => (((true, true, true), (false, false, false), (true, true, true), (true, true, true), (false, false, false)), :rejects),
    "dart_web_wasm/constructor_tearoff" => ((true, true, true, true, true, true, true, true), :rejects),
    "dart_web_wasm/constructor" => ((true, true, true, true, true, true, true, true), :wt_bug),
    "dart_web_wasm/flutter_regress_152029" => (1, :rejects),
    "dart_web_wasm/inlining" => ((10, 5), :rejects),
    "dart_web_wasm/issue_54926" => ((true, true, true), :compiled),
    "dart_web_wasm/issue_56234" => (-1, :rejects),
    "dart_web_wasm/lazy_const_record" => ((10000, 10, 10001), :rejects),
    "dart_web_wasm/lazy_static_number_initializer_regression" => ((true, true, true), :compiled),
    "dart_web_wasm/no_omit_error_details" => (-1, :rejects),
    "dart_web_wasm/regress_54794" => ((true, true, true, true, true, true, false, false, false), :compiled),
    "dart_web_wasm/regress_59782" => ((true, true), :rejects),
    "dart_web_wasm/regress_59840" => ((2.0, 0.0), :compiled),
    "dart_web_wasm/regress_62273" => ((true, true), :rejects),
    "dart_web_wasm/regress_63454" => (0, :rejects),
    "dart_web_wasm/regress_63747" => ((UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], UInt8[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00], 16), :rejects),
    "dart_web_wasm/static_dispatch_pragma" => ([1, 2], :rejects),
    "dart_web_wasm/unreachable_selector_implementation" => (Bool[1, 1], :rejects),
    "dart_web_wasm/function_apply" => ((true, true, true, true, true), :rejects),
    # tests/language
    "dart_language/flutter_regession_151473" => ((true, true, true, true), :rejects),
    "dart_language/local_null_initialization" => (Union{Nothing, Int64}[1, nothing, 2], :rejects),
    "dart_language/record_literal" => (((1, 2), 3, 4, (42, 42, 42), 42, 42, 42, 42, ((42, 42), 42), 42, 42, (42,), (42,), true), :rejects),
    "dart_language/record_type" => (((1, 2), (1, 2, (a = 3, b = 4)), [(1, 2)], (1,), 1, (42, 42), (42, 42), 42, true), :rejects),
    "dart_language/regress_54994" => (((false, true, false, true, false, true), (true, true, false), (true, false, true)), :compiled),
    "dart_language/regression_55741" => ((true, false, false, true, true, false, true, true), :compiled),
    "dart_language/if_and" => (499, :compiled),
    "dart_language/if_dangling_else" => ((true, true, true, true), :rejects),
    "dart_language/if_if" => ([0, 1, 2, 1, 2, 2, 1, 1, 1, 1, 2, 1, 2, 2, 2], :rejects),
    "dart_language/if_nested_if" => ((10, 3), :rejects),
    "dart_language/return_in_loop" => (42, :compiled),
    "dart_language/return_skip_expression" => ((true, true, true, true, true), :compiled),
    "dart_language/return_this_type" => (true, :compiled),
    "dart_language/bool_bool" => (((true, false, true, true, true, true, true, true), (true, 0, -1, true, true, 1, -1), [(2, 0), (0, 1), (1, 1), (0, 2)]), :rejects),
    "dart_language/bool_check_strong" => ((-1, -1), :rejects),
    "dart_language/bool_condition_check_strong" => ((-1, true), :rejects),
    "dart_language/identity_closure2" => ((true, false, false, true), :compiled),
    "dart_language/identity_closure" => ((true, false, true, false, true, false, false, false, true, true, false, true), :rejects),
    "dart_language/identity_const" => ((true, true, false, false), :rejects),
    "dart_language/identity_identical" => (Tuple{Int64, Bool, Bool}[(1, 1, 0), (1, 1, 0), (1, 1, 0), (1, 1, 0), (1, 1, 0), (1, 1, 0), (1, 1, 0), (1, 1, 0), (1, 1, 0), (1, 1, 0), (1, 1, 0), (1, 1, 0), (1, 1, 0), (1, 1, 0), (1, 1, 0), (1, 1, 0), (1, 1, 0), (1, 1, 0), (1, 1, 0), (1, 1, 0)], :rejects),
    "dart_language/identity_mint_identical" => ((true, true, true, false), :compiled),
    "dart_language/identity_nan_identical" => ((false, true, true, false, true, true, false, false, false, false, true, true), :compiled),
    "dart_language/identity_strict_equal" => (((false, true, true, false, false, false, false), (true, false, false, true, false, false, false), (false, true, true, false, true, true, false)), :rejects),
    "dart_language/double_literals_double_literal_coercion" => (Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], :rejects),
    "dart_language/double_literals_implicit_double_context" => ((true, true, true, true, true), :rejects),
    # the structural tests of pkg/dart2wasm/test/ir_tests and tests/web/wasm
    "dart_structural/hello" => (0, :rejects),
    "dart_structural/always_throws" => (-1, :rejects),
    "dart_structural/constant_string_ops" => ((3, 102, true), :rejects),
    "dart_structural/math_min_max" => ((1, 2, 1.5, 2.5, 1.0, 1.5, 1, 2), :rejects),
    "dart_structural/globals" => ((true, true, true), :rejects),
    "dart_structural/try_blocks" => ((-1, -2, -4, 1), :rejects),
    "dart_structural/type_brand" => ([1, 2, 3, 4, 1, 2, 3, 4], :rejects),
    "dart_structural/large_const_set" => ((true, 10001, false, true), :rejects),
    "dart_structural/long_string_import" => ((100001, 121), :rejects),
    "dart_structural/source_map_simple" => (-1, :rejects),
    # tests/language/nnbd/
    "dart_nnbd/flow_analysis_boolean_parameter" => (((false, true, false, true, false, true), (false, false, false), (true, true, true)), :rejects),
    "dart_nnbd/flow_analysis_demotion_and_type_of_interest_promotion" => ((true, true, true, true, true), :rejects),
    "dart_nnbd/flow_analysis_expr_property_not_promoted" => ((true, true, true, true), :compiled),
    "dart_nnbd/flow_analysis_identical" => (((true, true, true, true, true), (true, true, true, true, false)), :compiled),
    "dart_nnbd/flow_analysis_issue43093" => ((true, true, true, true), :rejects),
    "dart_nnbd/flow_analysis_late_var_assigned_in_try" => ((true, true), :rejects),
    "dart_nnbd/flow_analysis_late_var_used_before_assignment_in_local_function_ok" => ((true, true, true, true), :compiled),
    "dart_nnbd/flow_analysis_late_var_used_before_assignment_in_loop" => ([10, 10, 10, 10], :rejects),
    "dart_nnbd/flow_analysis_late_var_used_before_assignment_in_switch" => ((10, -1), :rejects),
    "dart_nnbd/flow_analysis_local_boolean_defeated_by_assignment" => (((true, true, true), (false, false, true), (false, false, false), (true, false), (true, true), Bool[1, 0], Bool[0, 0], (false, true)), :rejects),
    "dart_nnbd/flow_analysis_local_boolean_defeated_by_capture" => (((true, true, true, false, false), (false, false, false, false, false)), :rejects),
    "dart_nnbd/flow_analysis_local_boolean_does_not_detect_aliases" => (((true, true, true, true), (true, true, true, false)), :compiled),
    "dart_nnbd/flow_analysis_local_boolean_expression_types" => (((-1, -1, -1, -1, false, -1, 1, -1, -1, -1, 3, 3, false, -1, -1), (2, 2, 2, 2, true, 2, 1, 2, 2, 2, -1, -1, true, 2, 2), (2, 2, 2, 2, true, 2, 1, 2, -1, -1, -1, -1, true, 2, 2), (-1, -1, -1, -1, false, -1, 1, -1, 2, 2, -1, -1, true, -1, -1)), :rejects),
    "dart_nnbd/flow_analysis_local_boolean_implicitly_typed_new" => (((-1, -1, -1, -1), (1, 1, -1, -1), (-1, -1, 1, 1), (1, 1, 1, 1)), :rejects),
    "dart_nnbd/flow_analysis_local_boolean_join_equivalent" => (((false, false, false, false, false), (false, false, false, false, false), (true, true, true, true, true), (true, true, true, true, true)), :rejects),
    "dart_nnbd/flow_analysis_local_boolean_logical_op" => (Bool[1, 1, 1, 1, 1, 1, 0, 1, 1, 0, 1, 1, 1, 1, 1, 0, 1, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], :rejects),
    "dart_nnbd/flow_analysis_local_boolean_null" => (((true, false), (true, true)), :compiled),
    "dart_nnbd/flow_analysis_local_boolean_promoted_on_assignment" => (((1, 1, 1), (-1, -1, -1)), :rejects),
    "dart_nnbd/flow_analysis_local_boolean_promoted" => ((2, 0), :compiled),
    "dart_nnbd/flow_analysis_local_boolean" => (((-1, -1, -1, -1, -1, -1, -1), (-1, -1, -1, -1, 1, 1, 1), (1, 1, 1, 1, -1, -1, -1), (1, 1, 1, 1, 1, 1, 1)), :rejects),
    "dart_nnbd/flow_analysis_local_boolean_try_finally" => (((-1, false, -1, -1, false, -1, -1), (-1, false, -1, -1, true, -1, -1), (1, true, 1, 1, false, 1, 1), (1, true, 1, 1, true, 1, 1)), :rejects),
    "dart_nnbd/flow_analysis_local_boolean_undefeated_by_assignment" => (((true, false, false), (false, false, false), (true, true, true), (false, false, false)), :rejects),
    "dart_nnbd/flow_analysis_null_shorting_in_cascade" => (([-1, 0, 0, -1, -1, 0], true), :rejects),
    "dart_nnbd/flow_analysis_null_shorting_in_conditional" => (((false, true, 1, -1), (false, false, 1, 0), (true, false, -1, 1), (false, false, 0, 1)), :compiled),
    "dart_nnbd/flow_analysis_postfix_increment_decrement" => ((true, false, true, true, false), :compiled),
    "dart_nnbd/flow_analysis_this_not_promoted" => (((false, true, false), (false, true, true), (false, true, true), (true, true, false)), :compiled),
    "dart_nnbd/flow_analysis_this_property_not_promoted" => ((true, true, true, true, true, true), :compiled),
    "dart_nnbd/flow_analysis_unreachable_via_expr_property" => (((true, false), (true, false), (false, true), (false, true)), :rejects),
    "dart_nnbd/flow_analysis_unreachable_via_getter_get" => ((true, true, false, true), :rejects),
    "dart_nnbd/flow_analysis_unreachable_via_invocation" => ((true, true, false, true), :rejects),
    "dart_nnbd/flow_analysis_unreachable_via_never" => ((1, 1, 1, (false, true), 1, (false, true), true), :rejects),
    "dart_nnbd/flow_analysis_unreachable_via_promotion" => ((true, true, true, true, false, false), :rejects),
    "dart_nnbd/flow_analysis_unreachable_via_this_property" => ((((true, false), (true, false), (false, true), (false, true)), ((true, false), (true, false), (false, true), (false, true))), :rejects),
    "dart_nnbd/flow_analysis_unreachable_via_this" => ((((false, true), (false, false), (false, true), (false, false)), ((false, true), (false, false), (false, true), (false, false)), ((true, false), (true, false), (false, true), (false, true))), :rejects),
    "dart_nnbd/flow_analysis_unreachable_via_variable_get" => ((true, false, true), :rejects),
    "dart_nnbd/flow_analysis_unreachable_via_variable_property" => (((true, false), (true, false), (false, true), (false, true)), :rejects),
    "dart_nnbd/flow_analysis_variable_property_not_promoted" => ((true, true, true, true, true, true), :compiled),
    "dart_nnbd/flow_analysis_write_promoted_value_in_loop" => (((true, true, true), (false, false, false)), :rejects),
    "dart_nnbd/flow_analysis_write_promoted_value_in_switch" => (((true, true, true, true), (false, false, false, false)), :compiled),
    "dart_nnbd/flow_analysis_write_promoted_value_in_try" => (((false, false), (false, false)), :rejects),
    "dart_nnbd/type_promotion_assignment_inference_after_null_check" => ((1, 2), :rejects),
    "dart_nnbd/type_promotion_conditional_both" => ((2, 3, true, true), :rejects),
    "dart_nnbd/type_promotion_do_condition_is_not_type" => ((3, 1), :rejects),
    "dart_nnbd/type_promotion_do_outer_is_type" => (((2, 2), (-1, -1)), :rejects),
    "dart_nnbd/type_promotion_for_outer_is_type" => (((2, 2), (-1, 3), (-1, -1)), :compiled),
    "dart_nnbd/type_promotion_function_expression_is_type_mutated_in_closure" => (((true, true, true), (false, false, true)), :rejects),
    "dart_nnbd/type_promotion_function_expression_is_type" => (((2, 42), (-1, 42)), :rejects),
    "dart_nnbd/type_promotion_function_expression_outer_is_type_assigned_outside" => (((2, 7), true), :rejects),
    "dart_nnbd/type_promotion_if_is_not_type" => ((2, -1), :compiled),
    "dart_nnbd/type_promotion_if_is_type" => ((2, -1), :compiled),
    "dart_nnbd/type_promotion_logical_or_throw" => ((3, true), :rejects),
    "dart_nnbd/type_promotion_promoted_lhs_used_as_assignment_context" => (((false, true, true), (false, false, false)), :compiled),
    "dart_nnbd/type_promotion_try_catch_assigned_body" => (((2, -1, false), (-1, -1, false)), :rejects),
    "dart_nnbd/type_promotion_try_catch_catch_finally_outer_is_type" => (((2, -1, 2, 2), (-1, -1, -1, -1)), :rejects),
    "dart_nnbd/type_promotion_try_catch_is_not_type_exit_body_catch" => (((2, -1, 2), (-2, -2, -2)), :rejects),
    "dart_nnbd/type_promotion_try_catch_is_not_type_exit_body" => ((2, -1), :compiled),
    "dart_nnbd/type_promotion_try_finally_outer_is_type_assigned_body" => (((2, true), (-1, false)), :compiled),
    "dart_nnbd/type_promotion_try_finally_outer_is_type_assigned_finally" => (((2, 2, true), (-1, -1, false)), :compiled),
    "dart_nnbd/type_promotion_while_condition_false" => (4, :rejects),
    "dart_nnbd/type_promotion_while_condition_true" => ((2, -1), :compiled),
    "dart_nnbd/static_errors_equals_parameter_made_nullable_at_invoke" => ((false, false, true, false, false), :rejects),
    "dart_nnbd/static_errors_implicit_downcasts" => ((true, true), :rejects),
    "dart_nnbd/static_errors_non_null_assertion" => ((true, 2), :rejects),
    "dart_nnbd/static_errors_not_assigned_local_if_then_else" => ((0, 1), :compiled),
    "dart_nnbd/static_errors_not_assigned_local_try_catch_body_catch" => ((0, 1), :rejects),
    "dart_nnbd/static_errors_not_assigned_local_while_true_break_after" => (0, :compiled),
    "dart_nnbd/static_errors_nullable_function_types" => ((7, true, -1), :compiled),
    "dart_nnbd/static_errors_super_equals_allows_null" => ((true, true, true, true, true, true), :rejects),
    "dart_nnbd/static_errors_this_reference_in_late_field" => ((true, true, true, true), :rejects),
    "dart_nnbd/static_errors_throw_of_invalid_type" => (5, :rejects),
    "dart_nnbd/static_errors_unchecked_use_of_nullable" => ((true, true, true, true, true, true, true, true, true), :rejects),
    "dart_nnbd/static_errors_unchecked_use_of_nullable_cascaded" => ((true, true, true, true), :rejects),
    "dart_nnbd/boolean_conversion_boolean_conversion_strong" => ([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1], :rejects),
    "dart_nnbd/const_potentially_constant_types" => (((true, true, false, false, true, true, true, false, false, false, false, false, false, false), (true, true, false, false, false, false, false, false, false, false, true, true, true, false, false), (true, false), (true, 1), (true, false, true, true, false, false, true, true, false, false, true, false, false, false, true, true, false, false, true, true)), :rejects),
    "dart_nnbd/const_regress43281" => ((4, true, false), :rejects),
    "dart_nnbd/constant_null_safety_mode" => ((false, 2, 0), :rejects),
    "dart_nnbd/inference_variables_initialized_to_null" => ((false, false, false, false), :rejects),
    "dart_nnbd/is_type_test_null_is" => ((false, true, true, true, false, true, false, true, false, true, false, true, false, true, false, true, false, true, false, true, false, true), :rejects),
    "dart_nnbd/late_chained_assignment" => ((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), :wt_bug),
    "dart_nnbd/late_covariant_instance_field" => ((true, true, true, true, true, 9), :rejects),
    "dart_nnbd/late_dynamic_instance_field" => (((true, true, true, true), (true, true), (true, true, true, true), (true, true, true, true)), :rejects),
    "dart_nnbd/late_generic_covariant_instance_field" => ((true, true, true, true, true, 9), :rejects),
    "dart_nnbd/late_instance_field_initializers" => ((((1, 2, 3, -2), 3, (100, 2, 102, true)), ((1, 2, -1, -2), 3, (100, 2, 102, true)), ((1, 2, 3, -2), 3, (100, 2, 102, true)), ((1, 2, -1, -2), 3, (100, 2, 102, true))), :rejects),
    "dart_nnbd/never_never_null_assignability_strong" => (((0, 3, 2, 3, 2, 0, 2, 2, 0, 2, 0, 0), (0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1), (0, 0, 2, 0, 2, 2, 2, 2, 2, 0, 2, 0)), :rejects),
    "dart_nnbd/normalization_type_object_normalization" => ((true, true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_nnbd/required_named_parameters_missing_required_argument_dynamic" => (((true, 6, true, 6, true, 6, true, 6), (7, 6, 55, 6, 20, 6, 666, 6)), :rejects),
    "dart_nnbd/required_named_parameters_required_named_args_strong" => ((1, 1, 6, 6), :rejects),
    "dart_nnbd/required_named_parameters_required_named_args" => ((7, 7, 8, 8), :rejects),
    "dart_nnbd/resolution_issue41479" => (true, :rejects),
    "dart_nnbd/resolution_null_assertion_null_type" => (8, :rejects),
    "dart_nnbd/subtyping_function_type_required_params" => (((true, false, true), (0, 6, 0, 0, 6), 2), :rejects),
    "dart_nnbd/subtyping_regress41272" => ([0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1], :rejects),
    "dart_nnbd/subtyping_type_casts_strong" => (((true, true, false, false, true, true, true, false, true, false, false, false, false, true, false, true, false, false, false, false, true, false, false, false, false, true, false, false), true), :rejects),
    "dart_nnbd/syntax_cascade_nullcheck" => (2, :rejects),
    "dart_nnbd/syntax_class_member_declarations" => (-1, :compiled),
    "dart_nnbd/syntax_late_modifier_bug_39658" => (((true, true, true, true, true, true, true, true, true, true, true), (true, true, true, true, true, true), (true, true, true), (true, true, true)), :rejects),
    "dart_nnbd/syntax_late_modifier_edge_cases" => (((true, true, true, true, true, true), ((true, true, true, true, true), (true, true, true, true, true), (true, true, true, true, true), (true, true, true)), (4, 4, 4, 4, 4, 4, 4, 456, 456)), :rejects),
    "dart_nnbd/syntax_late_modifier_final_field" => ((((true, true, true, true, true), (true, true, true, true, true, true, true), true, (true, true, true, true, true, true, true), true, (true, true, true)), true), :rejects),
    "dart_nnbd/syntax_late_modifier_final_local_var" => ((((true, true, true, true, true), true, (true, true, true)), true), :rejects),
    "dart_nnbd/syntax_late_modifier_global_var" => (((true, true, true, true, true, true, true, true, true, true, true), (true, true, true, true, true, true), (true, true, true), (true, true, true), (true, true, true, true, true, true, true, true), true, (true, true, true)), :rejects),
    "dart_nnbd/syntax_late_modifier_local_var" => ((((true, true, true, true, true, true, true, true, true, true, true), (true, true, true, true, true, true), true, (true, true, true), (true, true, true), (true, true, true), true), true), :rejects),
    "dart_nnbd/syntax_late_modifier_non_final_field" => ((((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), (true, true, true, true, true, true, true, true, true), (true, true, true), (true, true, true)), true), :rejects),
    "dart_nnbd/syntax_late_modifier_runtime_error" => ((7, 7, 3, 3, 7, 7, 3, 3, 5, 7, 3, 3), :rejects),
    "dart_nnbd/syntax_late_modifier_static_field" => (((true, true, true, true, true, true, true, true, true, true, true), (true, true, true, true, true, true), (true, true, true), (true, true, true)), :rejects),
    "dart_nnbd/syntax_late_modifier_static_final_field" => (((true, true, true, true, true, true, true, true, true), 7, (true, true, true)), :rejects),
    "dart_nnbd/syntax_late_modifier" => ((5, 6, 7, 8), :rejects),
    "dart_nnbd/syntax_non_null_assertion" => ((true, true, true, true, true, true, true, true, 8, 8, 8, true, 1), :rejects),
    "dart_nnbd/syntax_null_assertion_ambiguous" => ((8, 8, 8, 0, 8, true, true, 4, 8, -2, true), :rejects),
    "dart_nnbd/syntax_nullable_type_ambiguous" => ((true, true, true, true, true, true, true, true, true, 3), :rejects),
    "dart_nnbd/syntax_nullable_type" => ((true, false, true, false, true, false, true, false), :rejects),
    "dart_nnbd/syntax_required_modifier" => ((3, 9), :compiled),
    "dart_nnbd/syntax_required_modifier_dynamic_error" => ((8, 6, 6, 6), :rejects),
    "dart_nnbd/type_equality_function_type_equality" => ((true, true, true, true, true, true, true, true, true, true, false, 6), :rejects),
    "dart_nnbd/type_equality_generic_function_type_equality" => ((true, true, true, true, true, true, true, true, true, true, false, false, 6), :rejects),
    "dart_nnbd/type_equality_regress42246" => ((true, true, true, true, false, true), :rejects),
    "dart_nnbd/type_object_equality" => ((true, true, false, false, false, true, false, true, true, true, false, false, true), :rejects),
    # tests/language/patterns/
    "dart_patterns/call_tear_off" => ((true, false, true, true, true, true, true, true, true, true, true, false, false, false, false, true), :rejects),
    "dart_patterns/cast_from_dynamic" => ((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_patterns/exhaustiveness_cast" => ((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_patterns/exhaustiveness_extension_type" => ((0, 1, 2, 2, 3, 3, 0, 1, 2, 2, 3, 3, 0, 1, 2, 2, 3, 3, 0, 1, 2, 2, 3, 3), :rejects),
    "dart_patterns/exhaustiveness_fallback" => ((1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2), :compiled),
    "dart_patterns/exhaustiveness_issue52048" => (1, :rejects),
    "dart_patterns/exhaustiveness_list_constant" => (9, :rejects),
    "dart_patterns/exhaustiveness_nullable_cast" => ((true, true, true, true, true, true, true), :rejects),
    "dart_patterns/exhaustiveness_restrictive_cast_pattern_3_2" => ((2, 1, 0), :rejects),
    "dart_patterns/exhaustiveness_restrictive_cast_pattern_error" => (2, :rejects),
    "dart_patterns/exhaustiveness_sealed_cast_3_2" => ((1, 1, 2, 0), :rejects),
    "dart_patterns/exhaustiveness_sealed_cast_error" => ((1, 1, 2, 0), :rejects),
    "dart_patterns/exhaustiveness_unsound_cast_3_2" => ((true, 2), :rejects),
    "dart_patterns/flow_analysis_boolean_condition" => ((1, 1, 0, 0), :compiled),
    "dart_patterns/flow_analysis_list_pattern_with_nullable_list_scrutinee" => ((2, 1, 2), :rejects),
    "dart_patterns/flow_analysis_null_check_in_guard" => ((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_patterns/flow_analysis_pattern_assignment_lookahead" => (0, :rejects),
    "dart_patterns/guard_capture" => (((true, true, true, true), (true, true, true, true), (true, true, true, true)), :rejects),
    "dart_patterns/guard_scope" => ((true, true, true, true), :rejects),
    "dart_patterns/identifier_when_not" => (Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], :rejects),
    "dart_patterns/implicit_instantiation" => ((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_patterns/int_to_double" => ((true, true, true, true, true, true), :compiled),
    "dart_patterns/invalid_inside_unary_pattern_parentheses" => ((true, true, true, true, true, true, true, true, true, true, true, true), :compiled),
    "dart_patterns/issue_52439" => ((true, true), :rejects),
    "dart_patterns/issue52409" => (0, :rejects),
    "dart_patterns/issue54559" => (true, :rejects),
    "dart_patterns/non_interface_object_pattern" => ((1, 2, 3, 4, 0, 0, 4, 4, 5, 0, 6, 7), :compiled),
    "dart_patterns/nullable_object_pattern" => ((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_patterns/object_pattern_inference" => ((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_patterns/primitive_switch" => ([0, 1, 2, 0, 1, 2, 3, 4, 5, 3, 4, 5, 0, 1, 2, 3, 4, 5, 0, 1, 2, 3, 4, 5], :rejects),
    "dart_patterns/record_type_object_pattern" => ((true, true, true, true), :compiled),
    "dart_patterns/regress_59613" => ([1, 3, 5], :rejects),
    "dart_patterns/relational_pattern_expression_precedence" => ((((true, true, true, true, true, true, true, true, true, true, true, true, true, true), true, true), ((false, false, false, false, false, false, false, false, false, false, false, false, false, false), false, false), ((true, true, true, true, true, true, true, true, true, true, true, true, true, true), true), ((false, false, false, false, false, false, false, false, false, false, false, false, false, false), false), ((true, true, true, true, true, true, true, true, true, true, true, true, true, true), true), ((false, false, false, false, false, false, false, false, false, false, false, false, false, false), false)), :compiled),
    "dart_patterns/schema" => ((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_patterns/shared_case_variable" => ((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_patterns/switch_case_scope" => (((true, true, true), true, true, true), :rejects),
    "dart_patterns/type_question_before_when" => ((true, true, true, true, true, true, true, true), :rejects),
    "dart_patterns/version_2_29_changes" => ((true, true, true), :rejects),
    "dart_patterns/wildcard_in_matching_context" => ((true, true, true, true, true), :rejects),
    "dart_patterns/wildcard_in_pattern_assignment" => (0, :rejects),
    "dart_patterns/wildcard_in_pattern_variable_declaration" => ((true, true, true), :rejects),
    # tests/language/function_type/
    "dart_function_type/function_type0" => (((true, (true, true, true, true), 202, 1, (true, true)), (2, 3, (true, true, true)), (9, 9, (true, true, true)), (1, 1, (true, true, true), (true, true, true)), (true, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type1" => (((9, 9, (true, true, true)), (true, (true, true, true)), (1, 1, (true, true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type2" => (((2, 5, (true, true, true)), (3, 7, (true, true), (true, true, true)), (1, 1, (true, true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (1, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type3" => (((2, 5, (true, true, true)), (6, 11, (true, true), (true, true, true)), (1, 1, (true, true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type4" => (((2, 5, (true, true, true)), (true, (true, true, true, true), 202, 1, (true, true)), (0, 1, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (1, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type5" => (((0, 2, (true, true, true)), (true, (true, true, true)), (true, true, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type6" => (((2, 5, (true, true, true)), (true, (true, true, true)), (true, true, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type7" => (((2, 5, (true, true, true)), (true, (true, true, true)), (true, true, (true, true), (true, true, true)), (2, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type8" => (((0, 2, (true, true, true)), (1, (true, true, true)), (3, 4, (true, true), (true, true, true)), (true, true, (true, true, true), (true, true, true)), (1, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type9" => (((2, 5, (true, true, true)), (1, (true, true, true)), (6, 7, (true, true), (true, true, true)), (true, true, (true, true, true), (true, true, true)), (true, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type10" => (((2, 5, (true, true, true)), (1, (true, true, true)), (3, 4, (true, true), (true, true, true)), (true, true, (true, true, true), (true, true, true)), (1, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type11" => (((7, (true, true, true)), (1, (true, true, true)), (6, 7, (true, true), (true, true, true)), (true, true, (true, true, true), (true, true, true)), (true, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type12" => (((7, 7, (true, true, true)), (2, 3, (true, true, true)), (1, (true, true, true, true), 202, 1, (true, true)), (1, 1, (true, true, true), (true, true, true)), (true, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type13" => (((9, 9, (true, true, true)), (true, true, (true, true), (true, true, true)), (1, 1, (true, true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (2, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type14" => (((9, 9, (true, true, true)), (1, (true, true, true)), (1, 1, (true, true, true), (true, true, true)), (3, 4, (true, true), (true, true, true)), (true, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type15" => (((1, (true, true, true)), (true, true, (true, true), (true, true, true)), (1, 1, (true, true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (2, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type16" => (((7, 7, (true, true, true)), (2, 5, (true, true, true)), (1, 1, (true, true, true), (true, true, true)), (0, 3, (true, true), (true, true, true)), (true, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type17" => (((7, (true, true, true)), (1, 1, (true, true, true), (true, true, true)), (2, 6, (true, true), (true, true, true)), (1, (true, true), (true, true, true)), (true, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type18" => (((9, 9, (true, true, true)), (1, (true, true, true)), (1, 1, (true, true, true), (true, true, true)), (0, 3, (true, true), (true, true, true)), (true, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type19" => (((7, 7, (true, true, true)), (1, 1, (true, true, true), (true, true, true)), (2, 6, (true, true), (true, true, true)), (1, (true, true), (true, true, true)), (true, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type20" => (((9, 9, (true, true, true)), (0, 2, (true, true, true), 0, 1, (true,)), (true, true, (true, true), (true, true, true)), (3, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type21" => (((2, 5, (true, true, true), 202, 204, (true,)), (0, (true, true, true)), (true, true, (true, true), (true, true, true)), (6, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type22" => (((1, (true, true, true)), (1, 1, (true, true, true)), (2, 5, (true, true, true), 202, 204, (true,)), (true, true, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type23" => (((0, 1, (true, true, true)), (0, (true, true, true)), (1, 1, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type24" => (((1, 1, (true, true), (true, true, true)), (3, 7, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (1, (true, true), (true, true, true)), (1, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type25" => (((0, 2, (true, true, true, true), 202, 1, (true, true)), (1, 1, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (1, (true, true), (true, true, true)), (1, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type26" => (((2, 5, (true, true, true, true), 405, 205, (true, true)), (1, 1, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (1, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type27" => (((2, 5, (true, true, true, true), 405, 205, (true, true)), (1, 1, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (1, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type28" => (((1, 1, (true, true), (true, true, true)), (3, 7, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (7, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type29" => (((0, 2, (true, true, true, true), 202, 1, (true, true)), (1, 1, (true, true), (true, true, true)), (true, (true, true), (true, true, true)), (9, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type30" => (((2, 5, (true, true, true, true), 405, 205, (true, true)), (2, (true, true, true)), (1, 1, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (7, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type31" => (((2, 5, (true, true, true, true), 405, 205, (true, true)), (2, (true, true, true)), (1, 1, (true, true), (true, true, true)), (true, (true, true), (true, true, true)), (9, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type32" => (((2, (true, true, true)), (0, 3, (true, true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (1, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type33" => (((7, (true, true, true)), (1, (true, true), (true, true, true)), (2, 6, (true, true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type34" => (((0, 2, (true, true, true)), (1, (true, true, true)), (2, 5, (true, true, true), 202, 204, (true,)), (true, true, (true, true), (true, true, true)), (1, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type35" => (((0, (true, true, true)), (2, (true, true, true)), (2, 6, (true, true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type36" => (((2, 5, (true, true, true)), (2, (true, true, true, true), 202, 1, (true, true)), (true, true, (true, true), (true, true, true)), (3, (true, true), (true, true, true)), (true, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type37" => (((9, 9, (true, true, true)), (0, (true, true, true)), (true, true, (true, true), (true, true, true)), (6, (true, true), (true, true, true)), (true, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type38" => (((0, 2, (true, true, true)), (9, 9, (true, true, true)), (2, (true, true, true)), (true, true, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type39" => (((2, 5, (true, true, true)), (2, (true, true, true)), (6, 11, (true, true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type40" => (((1, 1, (true, true), (true, true, true)), (10, 10, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (3, (true, true, true), (true, true, true)), (7, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type41" => (((1, 1, (true, true), (true, true, true)), (13, 13, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (6, (true, true, true), (true, true, true)), (9, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type42" => (((2, 5, (true, true, true)), (1, 1, (true, true), (true, true, true)), (10, 10, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (3, (true, true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type43" => (((2, 5, (true, true, true)), (1, 1, (true, true), (true, true, true)), (13, 13, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (6, (true, true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type44" => (((true, true, (true, true, true)), (2, (true, true, true, true), 202, 1, (true, true)), (0, 1, (true, true), (true, true, true)), (10, 10, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type45" => (((true, true, (true, true, true)), (0, (true, true, true)), (2, 3, (true, true), (true, true, true)), (13, 13, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type46" => (((1, 1, (true, true, true)), (true, true, (true, true, true)), (2, (true, true, true)), (10, 10, (true, true), (true, true, true)), (7, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type47" => (((1, 1, (true, true, true)), (true, (true, true, true)), (2, (true, true, true)), (13, 13, (true, true), (true, true, true)), (9, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type48" => (((2, 3, (true, true, true)), (true, true, (true, true, true)), (2, (true, true, true)), (1, 1, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type49" => (((0, 2, (true, true, true, true), 202, 1, (true, true)), (true, true, (true, true, true)), (7, (true, true, true)), (1, 1, (true, true), (true, true, true)), (2, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type50" => (((2, 5, (true, true, true, true), 405, 205, (true, true)), (true, true, (true, true, true)), (1, (true, true, true)), (1, 1, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type51" => (((2, 5, (true, true, true, true), 405, 205, (true, true)), (true, (true, true, true)), (2, (true, true, true)), (1, 1, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type52" => (((true, true, (true, true, true)), (2, (true, true, true, true), 202, 1, (true, true)), (1, 1, (true, true), (true, true, true)), (10, 10, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type53" => (((true, true, (true, true, true)), (0, (true, true, true)), (2, 3, (true, true), (true, true, true)), (6, 11, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type54" => (((2, 5, (true, true, true), 202, 204, (true,)), (true, true, (true, true, true)), (1, 1, (true, true), (true, true, true)), (10, 10, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type55" => (((0, (true, true, true)), (true, true, (true, true, true)), (2, 3, (true, true), (true, true, true)), (13, 13, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type56" => (((1, (true, true, true, true), 202, 1, (true, true)), (true, true, (true, true, true)), (3, 4, (true, true), (true, true, true)), (10, 10, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type57" => (((true, (true, true, true)), (2, (true, true), (true, true, true)), (6, 7, (true, true), (true, true, true)), (6, 11, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type58" => (((true, true, (true, true, true)), (true, (true, true, true)), (3, 4, (true, true), (true, true, true)), (3, 7, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type59" => (((true, (true, true, true)), (2, (true, true), (true, true, true)), (6, 7, (true, true), (true, true, true)), (6, 11, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type60" => (((2, 5, (true, true, true)), (true, (true, true, true, true), 202, 1, (true, true)), (3, 4, (true, true), (true, true, true)), (7, 7, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type61" => (((true, true, (true, true, true)), (true, (true, true, true)), (6, 7, (true, true), (true, true, true)), (9, 9, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type62" => (((true, true, (true, true, true)), (true, (true, true, true)), (3, 4, (true, true), (true, true, true)), (7, 7, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type63" => (((true, true, (true, true, true)), (true, (true, true, true)), (6, 7, (true, true), (true, true, true)), (9, 9, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type64" => (((true, true, (true, true, true)), (true, true, (true, true, true)), (3, 4, (true, true), (true, true, true)), (0, 3, (true, true, true), (true, true, true)), (1, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type65" => (((true, true, (true, true, true)), (true, true, (true, true, true)), (6, 7, (true, true), (true, true, true)), (2, 6, (true, true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type66" => (((true, true, (true, true, true)), (true, true, (true, true, true)), (3, 4, (true, true), (true, true, true)), (0, 3, (true, true, true), (true, true, true)), (1, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type67" => (((1, (true, true, true)), (true, true, (true, true, true)), (6, 7, (true, true), (true, true, true)), (2, 6, (true, true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type68" => (((true, true, (true, true, true)), (10, 10, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (1, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type69" => (((true, true, (true, true, true)), (true, (true, true, true)), (2, 3, (true, true), (true, true, true)), (13, 13, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type70" => (((true, true, (true, true, true)), (true, true, (true, true, true)), (10, 10, (true, true), (true, true, true)), (1, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type71" => (((true, (true, true, true)), (true, true, (true, true, true)), (2, 3, (true, true), (true, true, true)), (13, 13, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type72" => (((true, true, (true, true, true)), (3, 4, (true, true), (true, true, true)), (1, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (3, (true, true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type73" => (((true, true, (true, true, true)), (6, 7, (true, true), (true, true, true)), (3, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (6, (true, true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type74" => (((true, true, (true, true, true)), (3, 4, (true, true), (true, true, true)), (1, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (3, (true, true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type75" => (((true, true, (true, true, true)), (6, 7, (true, true), (true, true, true)), (3, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (6, (true, true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type76" => (((true, true, (true, true, true)), (3, 4, (true, true), (true, true, true)), (3, (true, true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (0, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type77" => (((true, true, (true, true, true)), (true, true, (true, true, true)), (6, 7, (true, true), (true, true, true)), (6, (true, true, true), (true, true, true)), (2, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type78" => (((true, (true, true, true)), (true, true, (true, true, true)), (3, 4, (true, true), (true, true, true)), (3, (true, true, true), (true, true, true)), (0, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type79" => (((true, true, (true, true, true)), (true, true, (true, true, true)), (6, 7, (true, true), (true, true, true)), (6, (true, true, true), (true, true, true)), (2, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type80" => (((true, true, (true, true, true)), (3, 4, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (true, (true, true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type81" => (((true, true, (true, true, true)), (6, 7, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (2, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type82" => (((true, (true, true, true)), (true, true, (true, true, true, true), 405, 205, (true, true)), (3, 7, (true, true), (true, true, true)), (3, 4, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type83" => (((true, true, (true, true, true)), (6, 7, (true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (2, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type84" => (((true, true, (true, true, true)), (true, (true, true, true, true), 202, 1, (true, true)), (3, 4, (true, true), (true, true, true)), (3, 4, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type85" => (((0, 2, (true, true, true)), (true, true, (true, true, true, true), 202, 1, (true, true)), (2, (true, true), (true, true, true)), (6, 7, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type86" => (((true, true, (true, true, true)), (2, 5, (true, true, true)), (true, true, (true, true, true, true), 405, 205, (true, true)), (3, 4, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type87" => (((2, 5, (true, true, true)), (true, true, (true, true, true, true), 405, 205, (true, true)), (2, (true, true), (true, true, true)), (6, 7, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type88" => (((true, true, (true, true, true)), (true, true, (true, true, true), 0, 1, (true,)), (3, 4, (true, true), (true, true, true)), (0, 3, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type89" => (((true, (true, true, true)), (true, true, (true, true, true), 202, 204, (true,)), (6, 7, (true, true), (true, true, true)), (2, 6, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type90" => (((true, true, (true, true, true)), (true, true, (true, true, true), 202, 204, (true,)), (3, 4, (true, true), (true, true, true)), (0, 3, (true, true), (true, true, true)), (3, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type91" => (((true, true, (true, true, true)), (true, (true, true, true)), (6, 7, (true, true), (true, true, true)), (2, 6, (true, true), (true, true, true)), (6, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type92" => (((true, true, (true, true, true)), (7, 7, (true, true, true)), (3, 4, (true, true), (true, true, true)), (true, true, (true, true, true), (true, true, true)), (true, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type93" => (((9, 9, (true, true, true)), (7, (true, true, true)), (1, 1, (true, true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (true, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type94" => (((9, 9, (true, true, true)), (1, (true, true, true)), (3, 4, (true, true), (true, true, true)), (true, true, (true, true, true), (true, true, true)), (true, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type95" => (((7, (true, true, true)), (2, (true, true, true)), (1, 1, (true, true, true), (true, true, true)), (true, true, (true, true), (true, true, true)), (true, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type96" => (((true, true, (true, true, true)), (0, 3, (true, true), (true, true, true)), (1, 1, (true, true, true), (true, true, true)), (true, (true, true), (true, true, true)), (7, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type97" => (((true, true, (true, true, true)), (0, (true, true, true)), (1, 1, (true, true, true), (true, true, true)), (true, (true, true), (true, true, true)), (9, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type98" => (((true, true, (true, true, true)), (2, (true, true, true)), (1, 1, (true, true, true), (true, true, true)), (true, (true, true), (true, true, true)), (7, (true, true), (true, true, true))), :rejects),
    "dart_function_type/function_type99" => (((true, true, (true, true, true)), (7, 7, (true, true, true)), (2, (true, true, true)), (1, 1, (true, true, true), (true, true, true)), (true, (true, true), (true, true, true))), :rejects),
    # tests/language/super/
    "dart_super/abstract_method" => ((42, 42), :rejects),
    "dart_super/all_named_constructor" => (3, :wt_bug),
    "dart_super/assign_runtime" => ((37, 42), :compiled),
    "dart_super/bound_closure" => ((-4, -1, 500, 42, 117, -1, 468, 426, 502, -1, 1236, 1335, 1390, -1, 4291, 232, 199), :rejects),
    "dart_super/call" => ((2, 12), :compiled),
    "dart_super/call2" => (42, :wt_bug),
    "dart_super/call3_runtime" => ((499, 499, 499, 499, 499, 499), :compiled),
    "dart_super/call4" => ((false, false, false, false), :rejects),
    "dart_super/closure" => ((3, true, true, true), :rejects),
    "dart_super/conditional_operator_runtime" => ((true, 1, 1), :rejects),
    "dart_super/field_2" => ((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_super/field_access" => (((10, 10, 10, 100, 110), (10, 10, 10, 100, 110), (10, 10, 10, 100, 110)), :compiled),
    "dart_super/field" => (((true, true, true, true, true, true), true), :rejects),
    "dart_super/from_constructor" => ((true, true, true), :rejects),
    "dart_super/implicit_closure" => ((20, 10), :compiled),
    "dart_super/in_constructor" => ((true, true), :compiled),
    "dart_super/in_finally" => (42, :rejects),
    "dart_super/inferrer" => ((84, true), :rejects),
    "dart_super/mixin_legacy" => (42, :rejects),
    "dart_super/mixin" => (42, :rejects),
    "dart_super/no_such_method1" => (87, :rejects),
    "dart_super/no_such_method2" => (87, :rejects),
    "dart_super/no_such_method3" => (87, :wt_bug),
    "dart_super/no_such_method4_runtime_legacy" => (87, :rejects),
    "dart_super/no_such_method4_runtime" => ((42, 87), :rejects),
    "dart_super/no_such_method5_runtime_legacy" => (42, :rejects),
    "dart_super/no_such_method5_runtime" => ((42, 42), :rejects),
    "dart_super/operator_index" => ((true, true, true), :rejects),
    "dart_super/operator_index2" => ((42, 47), :rejects),
    "dart_super/operator_index3" => ((true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_super/operator_index4" => ((true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_super/operator_index5" => ((true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_super/operator_index6" => ((true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_super/operator_index7" => ((true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_super/operator_index8" => ((42, 2), :rejects),
    "dart_super/operator" => ((true, true, true, true, true, true), :rejects),
    "dart_super/regress47698" => ((111, 111, 111, 111), :compiled),
    "dart_super/setter_interceptor" => ((true, true, true, true, true, true, true, true), :rejects),
    "dart_super/setter" => (true, :rejects),
    "dart_super/super" => (((1, 2, 3, 1, 2, 3), (2, 3, 0, 1, 4, 5)), :wt_bug),
    # tests/language/switch/
    "dart_switch/aborting_switch_case" => (42, :rejects),
    "dart_switch/backward_jump" => ((true, true, true), :rejects),
    "dart_switch/bad_case_runtime" => ((true, true, true), :rejects),
    "dart_switch/case_expression_with_assignment_runtime" => ((true, true, true), :rejects),
    "dart_switch/case_fallthrough" => ([1, 1, 2, 3, 4, 5, 6, 7, 1008, 1009, 1, 1, 2, 3, 4, 5, 6, 17, 1018, 1019, 1, 2, 3, 4, 5, 6, 26, 1027, 1028, 29, 29, 29, 32, 330, 1000, 35, 36, 37, 380, 2000, 2000, 2000, 2000, 2000, 2000, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 99, -1], :rejects),
    "dart_switch/case_runtime" => ((true, true, true, true), :rejects),
    "dart_switch/case_static_const" => ((0, 1, 2, 3), :rejects),
    "dart_switch/enum_compare" => (Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], :rejects),
    "dart_switch/equality_side_effect" => ([1, 1, -1, 1, 2, 2, 2, -2, 1, 3, 2, 3, -3], :rejects),
    "dart_switch/infinite_switch_label" => ((true, true), :rejects),
    "dart_switch/issue_60375" => (((true, true, true, true), (true, true)), :rejects),
    "dart_switch/label" => ((100, 100, 300, 200, 200, 300, 100, 200, 400, 300, 400, 400, 500), :rejects),
    "dart_switch/label2" => ((true, true, true, true), :rejects),
    "dart_switch/label3" => ((1, 1, 2, 4, 3, 4), :rejects),
    "dart_switch/nested_switch_label" => ((true, true), :rejects),
    "dart_switch/non_primitive_equality" => ((true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_switch/null_int_case" => ((true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_switch/scope" => ((1, 2, 3), :compiled),
    "dart_switch/switch_comparisons_1" => ((true, true, true, true, true), :rejects),
    "dart_switch/switch_comparisons_2" => ((true, true, true, true, true, true, true, true), :rejects),
    "dart_switch/switch_dynamic" => (3, :rejects),
    "dart_switch/switch_legacy" => ((true, true, true, true, true, true), :compiled),
    "dart_switch/switch" => ((100, 200, 200, 400, 400, 200, 400, true, true, true, true, true, true, true, true, true, true, true), :compiled),
    "dart_switch/switch6" => (0, :compiled),
    "dart_switch/switch8" => (0, :rejects),
    "dart_switch/try_catch" => ((true, 3, true), :rejects),
    "dart_switch/type_compare" => ((true, true, true, true, true), :rejects),
    # tests/language/const/
    "dart_const/cast1" => (2, :compiled),
    "dart_const/cast2" => (2, :compiled),
    "dart_const/cast3" => ((true, true), :rejects),
    "dart_const/cast4" => ((true, true, true), :rejects),
    "dart_const/conditional" => ((true, true, true), :rejects),
    "dart_const/const" => ((3, 5, 5), :rejects),
    "dart_const/const2" => (((6, 6, 4, -4, 5, 5, 0, 0, 0, 132, 2048, 8, 32, 132, 5, 5, -241, -6, 122, -256, -240, -5, 118, -1275), (5.0, 0.2, 3.0, 3.0, 0.0, 0.0, 2.25, 2.25, 1.0, 1.0, 0.5, 1.5, 15.666666666666668, -1.5, 121.5, -382.5), (true, false, false, true, false, true, true, false, true, false, false, true, false, true, true, false, true, true, false, false, true, false, false, false, true, true, false), (1, 2, 3), (true, 5, 1, 3.3, 15, true, 2)), :wt_bug),
    "dart_const/const3" => ((true, true, true), :rejects),
    "dart_const/const4" => (1, :compiled),
    "dart_const/constant_dag" => ((40, 40), :rejects),
    "dart_const/constant_type_variable" => ((true, true, true, true), :rejects),
    "dart_const/constructor_mixin" => ((true, true), :rejects),
    "dart_const/constructor_mixin3" => ((true, true), :rejects),
    "dart_const/constructor_super2" => ((true, true, true), :rejects),
    "dart_const/constructor" => ((42, 42, -1), :compiled),
    "dart_const/constructor2" => ((true, true, true, true, true, true, true, true, true, true), :compiled),
    "dart_const/constructor3" => ((0.0, 0.0, true), :compiled),
    "dart_const/ct_const" => ((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_const/double_in_int_op" => ((18, 18), :compiled),
    "dart_const/dynamic_type_literal" => ((true, true, true, true), :rejects),
    "dart_const/escape_frog" => (true, :compiled),
    "dart_const/evaluation" => ((true, true, true, true, true, true, true, true, true, true, true, false), :rejects),
    "dart_const/factory_member" => ((true, true, true, true, true, true), :rejects),
    "dart_const/factory_redirection" => ((true, true, true, true, true), :rejects),
    "dart_const/for_in_variable" => (2, :compiled),
    "dart_const/global" => ((true, true, true), :rejects),
    "dart_const/inference" => ((true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_const/init" => ((true, true, true, true, true, true), :rejects),
    "dart_const/init2" => (1.0, :compiled),
    "dart_const/instantiated_function_constant" => ((true, true, true, true, true, true, true, true, true, true, true), :compiled),
    "dart_const/list" => ((true, false, true, false, false, true, true, false, true, false, true, false), :rejects),
    "dart_const/local" => ((true, true, true), :rejects),
    "dart_const/locals" => ((true, true, true, true, true, true, true), :rejects),
    "dart_const/map_hashcode_override_legacy" => ((false, true, true, false, true), :rejects),
    "dart_const/map_hashcode_override" => ((false, true, true, false, true), :rejects),
    "dart_const/map_hashcode_override2_legacy" => ((true, true, false, true, false, false, true, true, true, true, true, true, true), :rejects),
    "dart_const/map_hashcode_override2" => ((true, true, false, true, false, false, true, true, true, true, true, true, true), :rejects),
    "dart_const/map_null_lookup" => ((true, true, true, true), :rejects),
    "dart_const/map" => (((true, true, true, true), (true, true), (true, true, true, true), true), :rejects),
    "dart_const/map4" => ((true, true, true, true, true, false), :rejects),
    "dart_const/map5" => ((true, true, true, true, true, true, true, true, true, true, true, true, false), :rejects),
    "dart_const/named" => (499, :rejects),
    "dart_const/nested" => ((true, true, true, true, true, true, true), :rejects),
    "dart_const/objects_are_immutable" => ((true, true, true, true, true, true, true, true, true), :rejects),
    "dart_const/primitive_equality" => ((11, true, true, true, true), :rejects),
    "dart_const/qq" => ((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), :compiled),
    "dart_const/redirect_skips_supertype" => ((true, true), :rejects),
    "dart_const/redirecting_factory" => ((true, true, true, true, true, true, true, true, true, true, true, true), :compiled),
    "dart_const/set_hashcode_override2_legacy" => ((true, true, false, true, false, false, true), :rejects),
    "dart_const/set_hashcode_override2" => ((true, true, false, true, false, false, true), :rejects),
    "dart_const/set_null_lookup" => ((true, false), :rejects),
    "dart_const/set5" => ((true, true, true, true, true, true, true, false), :rejects),
    "dart_const/string" => ((true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_const/switch" => ([1, 2, 3, 4], :rejects),
    "dart_const/syntax" => ((true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_const/tree" => ((1, 0, true), :rejects),
    "dart_const/types" => ((true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_const/var" => ((true, true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    # tests/language/closure/
    "dart_closure/bound_closure_equality" => ((true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_closure/bound_closure_primitives" => ((true, true, true), :rejects),
    "dart_closure/break" => ((true, true), :compiled),
    "dart_closure/break1" => ((true, true, true), :compiled),
    "dart_closure/break2" => ((true, true), :compiled),
    "dart_closure/call_wrong_argument_count" => (-1, :rejects),
    "dart_closure/closure" => ((true, true), :compiled),
    "dart_closure/closure2" => (true, :rejects),
    "dart_closure/closure3" => (-1, :rejects),
    "dart_closure/closure4" => (499, :compiled),
    "dart_closure/closure5" => (499, :compiled),
    "dart_closure/closure6" => (499, :compiled),
    "dart_closure/closure7" => ((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_closure/closure8" => ([1, 2], :rejects),
    "dart_closure/closures_initializer" => ((true, false, true, true), :compiled),
    "dart_closure/closures_initializer2" => (Bool[1], :rejects),
    "dart_closure/closures_with_complex_params" => ((true, true, true, true, true, true, true, true, true), :compiled),
    "dart_closure/dynamic_closure_param" => ((true, (false, 3)), :compiled),
    "dart_closure/dynamic" => ((((10, 1, 1, 10, 2, 2), (10, 1, 1, 10, 2, 2), (10, 1, 1, 10, 2, 2), (10, 1, 1, 10, 2, 2), (10, 1, 1, 10, 2, 2), (10, 1, 1, 10, 2, 2), (10, 1, 1, 13, -1, -1)), (1, 1, 1, 1, 1, 2, 2, 2)), :rejects),
    "dart_closure/forwarding_stub_tearoff_generic" => (((true, true, true), (true, true, true), (true, true, true)), :rejects),
    "dart_closure/forwarding_stub_tearoff" => (((true, true, true), (true, true, true), (true, true, true)), :rejects),
    "dart_closure/identity_equality_nosuchmethod_tearoff" => ((true, true, true, true, true, true, true, true, true), :rejects),
    "dart_closure/identity_equality_tearoff" => ((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), :wt_bug),
    "dart_closure/identity_equality_tostring_tearoff" => ((true, true, true, true, true, true, true, true, true), :rejects),
    "dart_closure/implicit_closure" => ((true, true, true), :rejects),
    "dart_closure/implicit1" => ((1, 2), :compiled),
    "dart_closure/implicit2" => ((true, true), :compiled),
    "dart_closure/in_constructor" => ((true, true, true, true, false, false), :compiled),
    "dart_closure/in_field_initializer" => (6, :rejects),
    "dart_closure/in_initializer" => ((true, true, true, true, true, true, true, true, true, true, true, true, true, true), :compiled),
    "dart_closure/in_initializer2" => ((true, true, true), :compiled),
    "dart_closure/instantiation_closure_equality" => ((true, true), :rejects),
    "dart_closure/invoked_through_interface_target_field" => ((true, true), :rejects),
    "dart_closure/invoked_through_interface_target_getter" => ((true, true), :rejects),
    "dart_closure/minify_closure_variable_collision" => ((false, true), :rejects),
    "dart_closure/param_null_to_object" => ((true, true, true, false, true, false, true, false, false, 1, 1, 1), :rejects),
    "dart_closure/parameter_default_type_inference" => ((true, true, true, true, true, true, true), :rejects),
    "dart_closure/parameter_types" => ((true, true), :rejects),
    "dart_closure/parse_closures_in_initializers" => ((true, true, true, true, true, true, true), :rejects),
    "dart_closure/partial_instantiation_eager_bounds_check" => ((-1, true), :rejects),
    "dart_closure/partial_tearoff_instantiation" => ((true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_closure/regress46568" => ((true, true, true, true), :wt_bug),
    "dart_closure/regression_62319" => (true, :rejects),
    "dart_closure/self_reference" => ((0, 199), :rejects),
    "dart_closure/shared_state" => (((true, true, true, true, true), (true, true, true, true, true), (true, true, true, true, true)), :rejects),
    "dart_closure/side_effect" => ((true, true, true, true), :rejects),
    "dart_closure/tearoff_dynamic" => ((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_closure/tearoff_super_default" => ((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_closure/type_arguments" => ((true, true, true, true, true, true, true, true, true), :rejects),
    "dart_closure/type_test" => ((true, true), :rejects),
    "dart_closure/type_variable" => (true, :compiled),
    "dart_closure/type_variables" => ((true, true), :compiled),
    "dart_closure/unnamed_closure" => (42, :compiled),
    "dart_closure/variable_shadow" => (-10, :compiled),
    "dart_closure/with_super_field" => ((true, true, true), :compiled),
    "dart_closure/with_super_send" => ((true, true, true), :rejects),
    # tests/language/exception/
    "dart_exception/catch_liveness" => ((true, true, true), :rejects),
    "dart_exception/code_after_try_is_executed" => ((true, true), :rejects),
    "dart_exception/exception" => ((true, true), :rejects),
    "dart_exception/finally" => ((true, true), :compiled),
    "dart_exception/finally1" => (((1, 801), [1, 800]), :rejects),
    "dart_exception/finally2" => (((1, 1201), [1, 400, 800]), :rejects),
    "dart_exception/finally3" => (((1401, 3001), [1, 200, 400, 800, 1600]), :rejects),
    "dart_exception/finally4" => (((211, 11), [1, 10]), :rejects),
    "dart_exception/finally5" => (((1, 1201, 4, 304), [1, 400, 800], [4, 100, 200]), :rejects),
    "dart_exception/finally6" => (((201401, 203001), [1, 200000, 200, 400, 800, 1600]), :rejects),
    "dart_exception/finally7" => ((1171, [0, 1, 2, 3, 4, 100, 0, 1000, 0]), :rejects),
    "dart_exception/finally8" => ((true, true, true, true, true, true, true, true), :rejects),
    "dart_exception/finally9" => ((true, true, true, true), :rejects),
    "dart_exception/finally10" => (42, :rejects),
    "dart_exception/finally11" => (42, :rejects),
    "dart_exception/finally12" => (true, :rejects),
    "dart_exception/identity" => ((true, true, true, true), :rejects),
    "dart_exception/in_increment" => ((20, true), :rejects),
    "dart_exception/multiple_breaks_crossing_finally" => ((true, true), :rejects),
    "dart_exception/nested_catch_rethrow" => ((true, true, true, true), :rejects),
    "dart_exception/rethrow" => (((true, true), (true, true, true)), :rejects),
    "dart_exception/throw_expr" => ((false, true, true, true, true, true, true, false, true, true, true, true), :rejects),
    "dart_exception/throw" => (900, :rejects),
    "dart_exception/throw1" => (850, :rejects),
    "dart_exception/throw2" => (850, :rejects),
    "dart_exception/throw3" => (850, :rejects),
    "dart_exception/throw4" => (1900, :rejects),
    "dart_exception/throw5" => (900, :rejects),
    "dart_exception/throw6" => (1900, :rejects),
    "dart_exception/throw8" => ((true, true), :rejects),
    "dart_exception/try_catch_on_syntax" => ((2, true), :rejects),
    "dart_exception/try_catch_optimized1" => ((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_exception/try_catch_optimized2" => (6, :rejects),
    "dart_exception/try_catch_optimized3" => ((true, true), :rejects),
    "dart_exception/try_catch_optimized4" => ([5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5], :rejects),
    "dart_exception/try_catch_optimized5" => ((true, true, true, true, true, true), :rejects),
    "dart_exception/try_catch_osr" => ((true, true, true, true, true), :rejects),
    "dart_exception/try_catch_regress_27483" => ((true, true, true), :rejects),
    "dart_exception/try_catch" => ((true, true, true, true, true, true, true, true, true, true, true), :rejects),
    "dart_exception/try_catch2" => (3, :compiled),
    "dart_exception/try_catch3" => (900, :compiled),
    "dart_exception/try_catch4" => ((true, true, true, true, true, true, true, true, true), :rejects),
    "dart_exception/try_catch5" => (true, :compiled),
    "dart_exception/try_finally_regress_25333" => ((true, true, true), :rejects),
    "dart_exception/try_finally_regress_25654" => ((true, true), :rejects),
    # tests/language/generic/
    "dart_generic/cascaded_forwarding_stubs_generic" => ((true, true, true), :rejects),
    "dart_generic/closure" => ((true, true, true, true, true, true, true, true, true, true, true), :compiled),
    "dart_generic/conflicting_generic_interfaces_no_conflict" => ((true, true, false), :compiled),
    "dart_generic/constructor_mixin" => ((true, true), :rejects),
    "dart_generic/constructor_mixin2" => ((true, true), :rejects),
    "dart_generic/constructor_mixin3" => ((true, true), :rejects),
    "dart_generic/creation" => ((true, true, true, true, true, true, true, true), :compiled),
    "dart_generic/deep" => ((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), :compiled),
    "dart_generic/f_bounded_equality" => ((true, true, true, true, true, true), :rejects),
    "dart_generic/f_bounded_quantification2" => ((true, true, true), :compiled),
    "dart_generic/f_bounded_quantification3" => ((true, true, true, true), :compiled),
    "dart_generic/f_bounded_quantification4" => ((true, true, true), :rejects),
    "dart_generic/f_bounded_quantification5" => (true, :rejects),
    "dart_generic/field_mixin" => ((true, false, false, true, true, false, false, true), :compiled),
    "dart_generic/field_mixin2" => ((true, true, true, true), :compiled),
    "dart_generic/field_mixin3" => ((true, false, true, false), :compiled),
    "dart_generic/field_mixin4" => ((true, false, true, false), :rejects),
    "dart_generic/field_mixin5" => ((true, true, true, true), :compiled),
    "dart_generic/field_mixin6" => ((true, true, true, true), :rejects),
    "dart_generic/function_bounds" => ((true, true, true, true, true, true), :rejects),
    "dart_generic/function_dcall" => ((true, true, true, true, true, true, true, true, true), :rejects),
    "dart_generic/function_type_as_type_argument" => ((true, true, true), :rejects),
    "dart_generic/function_typedef" => ((true, true, true, false, true, false, true, true, true), :rejects),
    "dart_generic/functions" => (6, :rejects),
    "dart_generic/generic_function_type_argument" => ((true, true, true, true, true), :rejects),
    "dart_generic/generic" => ((true, true, true, true, true, true, true, true), :compiled),
    "dart_generic/generic2" => ((true, true, false, false, true, false, false, true, false, false, true, false), :compiled),
    "dart_generic/generics" => ((true, true, true, true), :rejects),
    "dart_generic/generics2" => ((true, true, true, true, true, true), :compiled),
    "dart_generic/generics3" => ((true, true, true), :compiled),
    "dart_generic/inheritance" => ((true, false, true, true, true, true, true, true, true, true, true), :compiled),
    "dart_generic/instanceof" => (((true, false, true, false, true, false, true, true, true, true, true, true, true, true, true, true, false, true, false, false, false, false, false, true, false, false, false, false, false, true, false, false, false, false, false, true, false, true, false, false, false, false, true, false, false, false, false, false, true, false, false, false, false, false, true, false, false, false, false, false, true), true), :rejects),
    "dart_generic/instanceof2" => (((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), true), :rejects),
    "dart_generic/instanceof3" => (((false, true, false, false, false, true, false, true, false, false, true), true), :rejects),
    "dart_generic/instanceof4" => (true, :compiled),
    "dart_generic/instanceof5" => (true, :compiled),
    "dart_generic/instantiate_tearoff_after_contravariance_check" => ((true, false), :rejects),
    "dart_generic/instantiate_tearoff_of_call" => ((true, true, true, true, true, true, true, true), :rejects),
    "dart_generic/instantiate_tearoff" => (((true, true, true, true, true, true, true, true), (true, true, true, true, true, true, true, true), (true, false)), :rejects),
    "dart_generic/is_check" => ((false, true, false), :compiled),
    "dart_generic/list_checked" => (-1, :rejects),
    "dart_generic/local_functions" => ((true, true), :rejects),
    "dart_generic/many_generic_instanceof" => (((true, false, true, false, true, false, true, true, true, true, true, true, true, true, true, true, false, true, false, false, false, false, false, true, false, false, false, false, false, true, false, false, false, false, false, true, false, true, false, false, false, false, true, false, false, false, false, false, true, false, false, false, false, false, true, false, false, false, false, false, true), true), :rejects),
    "dart_generic/method_types" => ((true, true, true, false, true, false), :rejects),
    "dart_generic/native" => ((true, false, true, true, false), :compiled),
    "dart_generic/no_such_method_dispatcher" => ((true, true, true, true, true, true, true, true, true, true), :wt_bug),
    "dart_generic/object_type" => (true, :compiled),
    "dart_generic/parameterized_extends" => ((true, false, true, true, true, false, true, true, true, false, true, true), :compiled),
    "dart_generic/recursive_generic" => ((true, true, true, true, true), :rejects),
    "dart_generic/regress_45767" => ((true, true, false), :compiled),
    "dart_generic/reify_typevar_static" => ((true, true, true, true), :compiled),
    "dart_generic/self_reference" => ((true, true), :rejects),
    "dart_generic/sends" => ((true, true, true, true, true, true, false, true, false), :compiled),
    "dart_generic/sync_star" => ((true, true), :compiled),
    "dart_generic/syntax" => (((true, true, true, true, true), true), :rejects),
    "dart_generic/tearoff" => (((true, true), (true, true), (true, true), (true, true), (true, true), (true, true)), :rejects),
    "dart_generic/type_argument_in_super_type" => ((true, true), :rejects),
    "dart_generic/type_argument_substitution" => (false, :compiled),
    "dart_generic/type_parameter" => ((true, true, true, false, true, false), :rejects),
    "dart_generic/type_parameter_literal" => (true, :compiled),
    "dart_generic/typedef" => (((true, true, true, true), (true, true, true, true, true), (true, true, true, true, true)), :rejects),
)

# a case's answer is native's: of its type, and isequal (a NaN equal to itself, -0.0 apart from 0.0)
_dart_same(got, native) = typeof(got) == typeof(native) && isequal(got, native)

# what a compile gives: its rejection (an OutsideSubset by its errors' kinds), or :compiled
_dart_outcome(f, args) = try
    isdefined(Main, :wt_progress) && Main.wt_progress("dart_tests.jl: compiling $(nameof(typeof(f))) $(typeof(args))")
    WasmTarget.compile(f, Tuple(map(typeof, args)))
    :compiled
catch e
    e isa WasmTarget.RejectionError || rethrow()
    local r = e.rejection
    r isa WasmTarget.OutsideSubset || return r
    return _outside((t.kind for t in r.errors)...)
end

# the landing's fixed core: the first 5 cases of each group plus every case the change adds or edits
const _DART_CORE_ONLY = get(ENV, "WT_LANDING_CORE", "") == "1"
const DART_CORE = Set{String}(vcat([["$(g)/$(c[1])" for c in cs[1:min(5, end)]] for (g, cs) in DART_GROUPS]...,
                                   collect(DART_NATIVE_DUE)))

@testset "dart2wasm's tests, Julia the ground truth" begin
    local seen = Set{String}()
    for (group, cases) in DART_GROUPS, case in cases
        local key = "$group/$(case[1])"
        push!(seen, key)
        @testset "$key" begin
            @test haskey(DART_CASES, key)
            if haskey(DART_CASES, key)
                local native, today = DART_CASES[key]
                local f, args = case[2], case[3:end]
                key in DART_NATIVE_DUE && @test _dart_same(f(args...), native)
                if !_DART_CORE_ONLY || key in DART_CORE
                    local got = _dart_outcome(f, args)
                    if today === :compiled
                        @test got === :compiled          # a compiling case never loses ground
                    elseif today === :wt_bug
                        # a known WT bug (an Internal rejection), each routed to its owner; this list only
                        # shrinks, and a NEW Internal anywhere else fails the landing
                        @test got === :compiled || got isa _Outside || got isa WasmTarget.Rejection
                    else
                        @test today === :rejects
                        @test got === :compiled || got isa _Outside ||
                              (got isa WasmTarget.Rejection && !(got isa WasmTarget.Internal))
                    end
                end
            end
        end
    end
    # every recorded case is a case of the corpus
    @test sort!(collect(setdiff(keys(DART_CASES), seen))) == String[]
end
println("dart tests: $(_DART_CORE_ONLY ? length(DART_CORE) : length(DART_CASES)) compiles checked$(_DART_CORE_ONLY ? " (the landing core)" : ""); native answers proven for the $(length(DART_NATIVE_DUE)) the change ",
        "adds or edits against $(_DART_BASE)")
