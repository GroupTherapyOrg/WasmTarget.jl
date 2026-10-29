# dart2wasm's tests at the pin, ported with Julia as the ground truth (test/dart_tests.toml, dev/LEDGER.md
# D41): every case of test/smoke_corpus.jl's `dart_*` groups. Native Julia computes the answer recorded
# here (D3, never dart's value): one value, or the facts the dart test asserts as a tuple or a vector, each
# fact its own element so a wrong one names itself. Each case's compile is judged by a property, never by a
# snapshot of where it stops today: it compiles, or it rejects located (Unported, Unquarantined or
# OutsideSubset; InvalidModule and Internal are WT's own bugs, and a raw exception fails). A case recorded :compiled must keep compiling, the ratchet that a
# port never loses ground; a case recorded :rejects may stop anywhere, so one lane's progress never turns
# another lane's landing red (the snapshot form did, 2026-10-28, the loop's oscillation), though it rejects at a
# definition not yet written, Unported or Unquarantined, located: it names its compile and the definition it
# reached stands in the pin table, where it points never pinned (A51E1); an InvalidModule or Internal there is
# WT's defect and fails. The ratchet grows
# when the corpus owner records a newly compiling case. A case whose compile gives a module runs it (the
# differential, test/runner.jl): both modules, codegen's and wasm-opt's, each fact of the answer === native
# Julia's, computed afresh; a module that answers otherwise is WT's bug, whatever the case's record. A case
# recorded :wt_bug is a known WT bug, a compile that rejects as Internal or InvalidModule, listed so the landing
# stays green while its owner fixes it, and it must stay one (A51E4): once fixed it fails until re-recorded; the
# list only shrinks, and grows only by a `Lowers-record:` line (L227). A :wt_bug never covers a module's
# answer: a module that answers otherwise than native always fails (A53E2, D9's why). A case recorded :outside stands outside the strict subset by Julia's verifier (D32), and
# must keep rejecting as OutsideSubset. A failing case prints its outcome, the rejection's own text among it
# (A51E9). Native Julia's answer does not depend on
# WasmTarget's code, so it runs for each case whose group text or record the change adds or edits against
# CHECK_BASE (dev/check.sh's base, origin/wt2 by default; HEAD~1 under dev/ship.sh), proving a new or edited
# answer native when it is written. A base that holds no corpus runs every native answer, and so does the
# whole run beside the landings: a change to a definition several groups share (a helper, a struct) edits
# other groups' answers while its group text alone differs, and the whole run proves them all.
#
# Under WT_LANDING_CORE=1 (dev/check.sh sets it) the landing compiles a fixed core, the first case of each
# group, proves the native answer of every case the change adds or edits without compiling it, and runs no
# module, so the landing's cost is fixed whatever a commit adds (the oscillation's rule 2: a batch of 220
# ported cases compiled in the landing put its shard at 121 s); the whole corpus, every module it compiles run in node, wasm-opt's beside codegen's, goes beside
# the landings on wt2's head (without the variable, dev/corpus.sh), its red the next landing's first item.
using Test, WasmTarget
isdefined(Main, :WTRunner) || Base.include(Main, joinpath(@__DIR__, "..", "runner.jl"))

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
# a case whose compile returns a module records :compiled, its modules run against native
const DART_CASES = Dict{String,Tuple{Any,Symbol}}(
    # tests/web/wasm
    "dart_web_wasm/assertion_failure_message" => (1, :rejects),
    "dart_web_wasm/boxed_value_tearoff" => (4, :compiled),
    "dart_web_wasm/closure_hash_code" => (((true, true, true), (false, false, false), (true, true, true), (true, true, true), (false, false, false)), :rejects),
    "dart_web_wasm/constructor_tearoff" => ((true, true, true, true, true, true, true, true), :rejects),
    "dart_web_wasm/constructor" => ((true, true, true, true, true, true, true, true), :rejects),
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
    "dart_nnbd/late_chained_assignment" => ((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
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
    "dart_super/all_named_constructor" => (3, :rejects),
    "dart_super/assign_runtime" => ((37, 42), :compiled),
    "dart_super/bound_closure" => ((-4, -1, 500, 42, 117, -1, 468, 426, 502, -1, 1236, 1335, 1390, -1, 4291, 232, 199), :rejects),
    "dart_super/call" => ((2, 12), :compiled),
    "dart_super/call2" => (42, :rejects),
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
    "dart_super/no_such_method3" => (87, :rejects),
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
    "dart_super/super" => (((1, 2, 3, 1, 2, 3), (2, 3, 0, 1, 4, 5)), :rejects),
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
    "dart_const/const2" => (((6, 6, 4, -4, 5, 5, 0, 0, 0, 132, 2048, 8, 32, 132, 5, 5, -241, -6, 122, -256, -240, -5, 118, -1275), (5.0, 0.2, 3.0, 3.0, 0.0, 0.0, 2.25, 2.25, 1.0, 1.0, 0.5, 1.5, 15.666666666666668, -1.5, 121.5, -382.5), (true, false, false, true, false, true, true, false, true, false, false, true, false, true, true, false, true, true, false, false, true, false, false, false, true, true, false), (1, 2, 3), (true, 5, 1, 3.3, 15, true, 2)), :rejects),
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
    "dart_closure/identity_equality_tearoff" => ((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true), :rejects),
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
    "dart_closure/regress46568" => ((true, true, true, true), :rejects),
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
    "dart_generic/no_such_method_dispatcher" => ((true, true, true, true, true, true, true, true, true, true), :rejects),
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
    # tests/language/operator/
    "dart_operator/and_operation_on_non_integer_operand" => ((true, 1), :rejects),
    "dart_operator/arithmetic_canonicalization" => ((Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], true, false), :rejects),
    "dart_operator/arithmetic_int64" => ((1234567890123456789, -1234567890123456789, 9223372036854775807, -9223372036854775808), :rejects),
    "dart_operator/arithmetic_smi_overflow" => ([1073741824, 4611686018427387904, 1073741824, 4611686018427387904, 1073741824, 4611686018427387904, 1073741824, 4611686018427387904, 1073741824, 4611686018427387904, 1073741824, 4611686018427387904, 1073741824, 4611686018427387904, 1073741824, 4611686018427387904, 1073741824, 4611686018427387904, 1073741824, 4611686018427387904], :rejects),
    "dart_operator/arithmetic" => (((26, 18, 88, 5, 5.5, 2.0, 2, 2), [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576, 2097152, 4194304, 8388608, 16777216, 33554432, 67108864, 134217728, 268435456, 536870912, 1073741824, 2147483648, 4294967296, 8589934592, 17179869184, 34359738368, 68719476736, 137438953472, 274877906944, 549755813888, 1099511627776, 2199023255552, 4398046511104, 8796093022208, 17592186044416, 35184372088832, 70368744177664, 140737488355328, 281474976710656, 562949953421312, 1125899906842624, 2251799813685248, 4503599627370496, 9007199254740992, 18014398509481984, 36028797018963968, 72057594037927936, 144115188075855872, 288230376151711744, 576460752303423488, 1152921504606846976, 2305843009213693952, 4611686018427387904, -1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], (26.0, 18.0, 88.0, 5.0, 5.5, 2.0, 2.0), (26.0, 18.0, 88.0, 5.0, 5.5, 2.0, 2.0), (26.0, 18.0, 88.0, 5.0, 5.5, 2.0, 2.0), (2, -2, 123456789012345, -123456789012345, -123456789012345), (false, true, true, false, true, true, true, false, true, false, false, true, false, true), (2, 123456789012345, false, 2.0), (1, 1, 1, 0, -2, 3), (0, -1, -3, -1, 2), (0, 0, -2, true), (3, -3, 2, -2, 0, 0, 2, -2, 1, 0), (1234567890123, -1234567890123, -1073741825, 1073741824, -1.0), (2.0, true, true), (12, -12, 9007199254740991, 1.2, false, true, true, false, true, true, true, true), (false, true, true, true), (1, 12, 1.0, 12.0, false, true), (false, true, false, true), (1073741824, 1073741824), (true, true, true, true), (2.0, -1), (false, true)), :rejects),
    "dart_operator/bit_operations" => (((3, 7, 4, 25, 400, -25, -101, 0, 0, 1073741824, 4611686018427387904, 0, -1, 0, -1), (1152921504606846977, 1, 1, 1152939161217400833, 1152939161217400849, 1152939161217400849, 1080863910568919040, 49, 1080863910568919089, 1080863910568919089, 15, 15, 1030792151040, 240, 64424509440), (true, false, false, false, true, true, true, false, false, true, true, false), (3, 1, 0, -1, -1, -1), (4294967295, 4294967295, 8589934590, 9223372034707292160, -9223372036854775808, 0, 0), (false, false, false, false, 1, 96), (Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]), Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], ((4, 7, 4, true, 1, 1, 16), (0, 5, 1, true, 9, 9, 0), (2320, 16212, 7488, true, 32040, 32040, 0)), (0, -1)), :rejects),
    "dart_operator/bit_shift" => (((0, 0, 0, 0), (0, 0, 0, 0), (0, 0, 0, 0)), :rejects),
    "dart_operator/comparison" => (((true, false, false, true, true), (true, false, true, true, false, true, false), NTuple{8, Bool}[(1, 0, 1, 0, 0, 1, 0, 1), (1, 0, 1, 0, 0, 1, 0, 1), (1, 0, 1, 0, 0, 1, 0, 1), (0, 1, 0, 1, 1, 1, 0, 0), (0, 1, 0, 1, 1, 1, 0, 0), (0, 1, 0, 1, 1, 1, 0, 0), (0, 1, 0, 1, 0, 0, 1, 1), (0, 1, 0, 1, 0, 0, 1, 1), (0, 1, 0, 1, 0, 0, 1, 1)], NTuple{8, Bool}[(1, 0, 1, 0, 0, 1, 0, 1), (1, 0, 1, 0, 0, 1, 0, 1), (1, 0, 1, 0, 0, 1, 0, 1), (0, 1, 0, 1, 1, 1, 0, 0), (0, 1, 0, 1, 1, 1, 0, 0), (0, 1, 0, 1, 1, 1, 0, 0), (0, 1, 0, 1, 0, 0, 1, 1), (0, 1, 0, 1, 0, 0, 1, 1), (0, 1, 0, 1, 0, 0, 1, 1)], (true, false, true, true, true), (false, true, true, false, true, true, true, true, true, true, true, true, true, true, false, false, true, true, true, true, false, false, true), (false, false, false, false, false)), :rejects),
    "dart_operator/compound_assignment" => (((0, 1, 100, 2, 100, 3, 101, 4, 5, 111, 2, 10), [0, 1, 2, 0, 1, 3], [0, 1, 2, 0, 1, 3], [0, 1, 2, 0, 1, 3]), :rejects),
    "dart_operator/cond_expr" => (((-1, -1, 0), (1, 0, 1)), :rejects),
    "dart_operator/div_by_zero" => ((true, true), :rejects),
    "dart_operator/div_with_power_of_two" => ([134217730, -134217730, 67108865, -67108865, 33554432, -33554432, 1, -1, -134217730, 134217730, -67108865, 67108865, -33554432, 33554432, -1, 1, 10, -10, 5, -5, 2, -2, 0, 0, -10, 10, -5, 5, -2, 2, 0, 0, 137438953497, -137438953497, 1, -1, -137438953497, 137438953497, -1, 1, 72057731476881408, -72057731476881408, 524289, -524289, -72057731476881408, 72057731476881408, -524289, 524289], :rejects),
    "dart_operator/div_with_power_of_two2" => (([134217730, -134217730, 67108865, -67108865, 33554432, -33554432, 1, -1, -134217730, 134217730, -67108865, 67108865, -33554432, 33554432, -1, 1, 10, -10, 5, -5, 2, -2, 0, 0, -10, 10, -5, 5, -2, 2, 0, 0, 137438953497, -137438953497, 1, -1, -137438953497, 137438953497, -1, 1, 72057731476881408, -72057731476881408, 524289, -524289, -72057731476881408, 72057731476881408, -524289, 524289], true), :rejects),
    "dart_operator/equality_covariant" => ((0, 0, -2, 0, 0, 0, 0, 0, 0, 0, -1, 0, -1), :rejects),
    "dart_operator/equality" => ((0, 1, 1, 1, 1, 0, 0, 1, 1, 0, -2, -2, 0, -2, 1, (true, false, false, true, true, false, false, true), (true, true, false, true)), :compiled),
    "dart_operator/incr_op" => ([4, 4, 5, 3, 3, 2, 5, 3, 100, 101, 102, 102, 103, 55, 56, 57, 57, 56, 55, 56, 57, 57, 56, 1, 2, 3, 4, 3, 3, 2, 1], :rejects),
    "dart_operator/index_evaluation_order" => ([-1, -2, -3, 42, 100, -4, 101, 37, -5, 42, 102], :rejects),
    "dart_operator/index" => ((10, Bool[1, 1, 1, 1, 1, 1, 1, 1], 515, 515), :rejects),
    "dart_operator/integer_division_by_zero" => (((-1, -1, 3, 3, 3, 3, 2, 2, 3, 2, 2, 3, 3, 3, 3, 3), true, 8.988465674311579e307, -8.988465674311579e307, 3.6893488147419103e19, -3.6893488147419103e19), :rejects),
    "dart_operator/left_shift" => ([1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576, 2097152, 4194304, 8388608, 16777216, 33554432, 67108864, 134217728, 268435456, 536870912, 1073741824, 2147483648, 4294967296, 8589934592, 17179869184, 34359738368, 68719476736, 137438953472, 274877906944, 549755813888, 1099511627776, 2199023255552, 4398046511104, 8796093022208, 17592186044416, 35184372088832, 70368744177664, 140737488355328, 281474976710656, 562949953421312, 1125899906842624, 2251799813685248, 4503599627370496, 9007199254740992, 18014398509481984, 36028797018963968, 72057594037927936, 144115188075855872, 288230376151711744, 576460752303423488, 1152921504606846976, 2305843009213693952, 4611686018427387904, -1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], :rejects),
    "dart_operator/logical_expression" => (((Int64[], 1, 2), [1, 2, 3], (Int64[], 1, 2), [1, 2, 3]), :rejects),
    "dart_operator/logical_expression2" => (1, :rejects),
    "dart_operator/logical_expression3" => (false, :rejects),
    "dart_operator/logical_expression4" => ((true, false), :rejects),
    "dart_operator/logical_expression5" => ((true, false, true), :rejects),
    "dart_operator/mint_arithmetic" => ((true, false, 4294967295, 1234, 4294967297, -1073741824, 1073741824, 1073741823, 0, true, true, 4294967295, -1, -1, 2.0), :compiled),
    "dart_operator/modulo" => (([226, -30, 224, -30, -3, -3, 1, 0, -1, 227, -29, 225, -29, -2, 0, 4, 0, -1, 228, -28, 226, -28, -2, 2, 6, 0, -1, 229, -27, 227, -27, -2, 4, 8, 0, -1, 230, -26, 228, -26, -2, 6, 10, 0, -1, 231, -25, 229, -25, -2, 8, 12, 0, -1, 232, -24, 230, -24, -2, 10, 2, 0, -1, 233, -23, 231, -23, -2, 12, 5, 0, -1, 234, -22, 232, -22, -2, 14, 7, 0, -1, 235, -21, 233, -21, -2, 16, 9, 0, -1, 236, -20, 234, -20, -2, -2, 1, 0, -1, 237, -19, 235, -19, -1, 1, 4, 0, -1, 238, -18, 236, -18, -1, 3, 6, 0, -1, 239, -17, 237, -17, -1, 5, 8, 0, -1, 240, -16, 238, -16, -1, 7, 10, 0, -1, 241, -15, 239, -15, -1, 9, 12, 0, -1, 242, -14, 240, -14, -1, 11, 14, 0, -1, 243, -13, 241, -13, -1, 13, 16, 0, -1, 244, -12, 242, -12, -1, 15, 6, 0, -1, 245, -11, 243, -11, -1, 17, 9, 0, -1, 246, -10, 244, -10, -1, -1, 1, 0, -1, 247, -9, 245, -9, 0, 2, 4, 0, -1, 248, -8, 246, -8, 0, 4, 6, 0, -1, 249, -7, 247, -7, 0, 6, 8, 0, -1, 250, -6, 248, -6, 0, 8, 10, 0, -1, 251, -5, 249, -5, 0, 10, 12, 0, -1, 252, -4, 250, -4, 0, 12, 14, 0, -1, 253, -3, 251, -3, 0, 14, 16, 0, -1, 254, -2, 252, -2, 0, 16, 18, 0, -1, 255, -1, 253, -1, 0, 18, 20, 0, -1, 0, 0, 0, 0, 0, 0, 0, 1, -255, 1, -253, 1, 2, 2, 0, 1, 2, -254, 2, -252, 2, 4, 4, 0, 1, 3, -253, 3, -251, 3, 6, 6, 0, 1, 4, -252, 4, -250, 4, 8, 8, 0, 1, 5, -251, 5, -249, 5, 10, 10, 0, 1, 6, -250, 6, -248, 6, 12, 12, 0, 1, 7, -249, 7, -247, 7, 14, 14, 0, 1, 8, -248, 8, -246, 8, 16, 16, 0, 1, 9, -247, 9, -245, 9, 18, 18, 0, 1, 10, -246, 10, -244, 0, 1, 11, 0, 1, 11, -245, 11, -243, 1, 3, 13, 0, 1, 12, -244, 12, -242, 2, 5, 4, 0, 1, 13, -243, 13, -241, 3, 7, 6, 0, 1, 14, -242, 14, -240, 4, 9, 8, 0, 1, 15, -241, 15, -239, 5, 11, 10, 0, 1, 16, -240, 16, -238, 6, 13, 12, 0, 1, 17, -239, 17, -237, 7, 15, 14, 0, 1, 18, -238, 18, -236, 8, 17, 16, 0, 1, 19, -237, 19, -235, 9, 19, 18, 0, 1, 20, -236, 20, -234, 0, 2, 11, 0, 1, 21, -235, 21, -233, 1, 4, 13, 0, 1, 22, -234, 22, -232, 2, 6, 15, 0, 1, 23, -233, 23, -231, 3, 8, 17, 0, 1, 24, -232, 24, -230, 4, 10, 8, 0, 1, 25, -231, 25, -229, 5, 12, 10, 0, 1, 26, -230, 26, -228, 6, 14, 12, 0, 1, 27, -229, 27, -227, 7, 16, 14, 0, 1, 28, -228, 28, -226, 8, 18, 16, 0, 1, 29, -227, 29, -225, 9, 20, 18, 0, 1], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], true, true), :rejects),
    "dart_operator/mul_recipr" => ((true, [4.0, 4.0, 4.0, 4.0, 4.0, 4.0, 4.0, 4.0, 4.0, 4.0], true), :rejects),
    "dart_operator/multi_assign" => (((11, 11, 11), (55, 55, 55)), :compiled),
    "dart_operator/negate_and_method_negate" => ((42, 87), :compiled),
    "dart_operator/number_operator_context" => (((2, 0, 1, 0, 0, 1, 1), 0, (2.0, 0.0, 1.0, 0.0, 0.0, 2.1, 2.1, 0.10000000000000009, 0.10000000000000009, 1.0, 1.0), 0.0, (true, true, true, true, true)), :rejects),
    "dart_operator/number_operator_typing" => (((2, 0, 1, 0, 0), (2.0, 0.0, 1.0, 0.0, 0.0), (2.0, 0.0, 1.0, 0.0, 0.0), (2.0, 0.0, 1.0, 0.0, 0.0), (true, true, true, true, true, true, true, true), (1, 1.0, true, true, true), (2, 2, 2, 2.0, 2.0, true, 2.0, 2.0, true, true)), :rejects),
    "dart_operator/operations_on_non_num_operand" => (((true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, 1), (true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, 1), (true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, 1)), :rejects),
    "dart_operator/operator" => (((3, -1, 0.5, 0, 2, 1, true, true, true, true, true, 3, 3, 0, 4, 0, -1), 3, 6, 6, (42, 42), (42, 42), 49, (66, 17), (86, 20)), :rejects),
    "dart_operator/operator_triple_shift" => (("(3:1>>>2)", "4", "(6:4>>>5)", ("(11:7+(10:8>>>9))", "(16:(14:12>>>13)+15)", "(23:(22:17+(20:18>>>19))+21)", "(28:(26:24>>>25)&27)", "(33:29&(32:30>>>31))", "(40:(38:34&(37:35>>>36))&39)", "(45:(43:41>>>42)>>44)", "(50:(48:46>>47)>>>49)", "(55:(53:51>>>52)<<54)", "(60:(58:56<<57)>>>59)", "(67:(65:(63:61<<62)>>>64)>>66)"), true, 5, true), :rejects),
    "dart_operator/operator2" => ((10, 30, true, 23, 123), :rejects),
    "dart_operator/operator3" => ((true, 1), :compiled),
    "dart_operator/operator4" => (499, :rejects),
    "dart_operator/operator5" => ((1, true, 499, "foo", 42), :rejects),
    "dart_operator/operator6" => ((-2, -2), :compiled),
    "dart_operator/positive_bit_operations" => (((2147483648, 2147483649, 2147483648, 4294967295, 2147483648, 2147483648, 2147483648, 2147483648, 2147483648, 4294967295, 4294967295, 4026531840, 2147483648, 4294967280, 2147483647, 4294967292), (2147483648, 2147483649, 4294967295, 2147483648, 2147483648, 4294967295, 4026531840, 2147483648, 4294967280, 2147483647, 4294967292), (2147483648, 2147483649, 2147483648, 2147483648, 2147483648, 4294967295, 4294967295, 2147483648, 2147483647, 4294967292), (2147483648, 2147483648, 2147483648, 2147483648)), :rejects),
    "dart_operator/precedence" => (((true, true, (false, 4), (false, 5)), [7, 4, 2, 5, 8, 4, -1, 3, 7, 4, -2, 5, 8, 4, 1, 3], [6, 4, 1, 5, 9, 4, 0, 3, 6, 4, -1, 5, 9, 4, 0, 3], true, [3, 2, 4, 2, 5, 2, 4, 2, 3], [7, 4, 2, 5, 8, 4, -1, 3, 7, 4, -2, 5, 8, 4, 1, 3], [6, 4, 1, 5, 9, 4, 0, 3, 6, 4, -1, 5, 9, 4, 0, 3], [12.0, 4.0, 1.0, 5.0, 12.0, 4.0, 0.75, 3.0, 12.0, 4.0, 1.0, 5.0, 12.0, 4.0, 2.0, 3.0], [9.0, 4.0, 1.0, 5.0, 15.0, 4.0, 1.0, 3.0, 9.0, 4.0, 0.75, 5.0, 20.0, 4.0, 1.0, 3.0]), :rejects),
    "dart_operator/round" => ((0, 0, 9007199254740991, -9007199254740991), :rejects),
    "dart_operator/smi_type" => (((false, false, false, false), Bool[1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0]), :rejects),
    "dart_operator/ternary" => ((-4, 5), :compiled),
    "dart_operator/truncdiv" => (([6, -1, 7, -1, 8, -1, 0, -1, 1, -1, 2, -1, 3, -1, 4, -1, 5, -1, 6, -1, 7, -1, 8, -1, 0, -1, 1, -1, 2, -1, 3, -1, 4, -1, 5, -1, 6, -1, 7, -1, 8, -1, 0, -1, 1, -1, 2, -1, 3, -1, 4, -1, 5, -1, 6, -1, 7, -1, 8, -1, 0, 1, 1, 2, 1, 3, 1, 4, 1, 5, 1, 6, 1, 7, 1, 8, 1, 0, 1, 1, 1, 2, 1, 3, 1, 4, 1, 5, 1, 6, 1, 7, 1, 8, 1, 0, 1, 1, 1, 2, 1, 3, 1, 4, 1, 5, 1, 6, 1, 7, 1, 8, 1, 0, 1, 1, 1, 2, 1], true), :rejects),
    "dart_operator/truncdiv_uint32" => (4294967295, :rejects),
    "dart_operator/truncdiv_zero" => ((true, true), :rejects),
    "dart_operator/unary" => ((true, 9), :compiled),
    "dart_operator/unary2" => (1, :compiled),
    "dart_operator/unsigned_right_shift" => ((true, true, true, true, true, 1, true, ("((~*)>>>(~*))", "((*+(*>>>*))+*)", "((*/(*>>>*))/*)", "(((*>>*)>>>*)>>*)", "((*&(*>>>*))&*)", "((*|(*>>>*))|*)", "((*^(*>>>*))^*)", "(*<(*>>>*))", "((*>>>*)<*)"), "((*>>>*)>>>*)"), :rejects),
    # tests/language/string/
    "dart_string/adjacent_const_string_literals" => (Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], :rejects),
    "dart_string/adjacent_string_literals" => ((Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1], Bool[1, 1, 1, 1, 1, 1, 1, 1], Bool[1, 1, 1, 1, 1, 1]), :rejects),
    "dart_string/bad_raw_string_runtime" => ((13, 13), :rejects),
    "dart_string/char_escape" => ((([1, 1, 1, 1, 1, 1, 1, 1], [0, 0, 0, 0, 0, 0, 0, 0], Bool[1, 1, 1, 1, 1, 1, 1, 1]), ([1, 1, 1, 1, 1, 1, 1, 1], [1, 1, 1, 1, 1, 1, 1, 1], Bool[1, 1, 1, 1, 1, 1, 1, 1]), ([1, 1, 1, 1, 1, 1, 1], [85, 85, 85, 85, 85, 85, 85], Bool[1, 1, 1, 1, 1, 1, 1]), ([1, 1, 1, 1, 1, 1, 1], [127, 127, 127, 127, 127, 127, 127], Bool[1, 1, 1, 1, 1, 1, 1]), ([1, 1, 1, 1, 1, 1, 1], [128, 194, 194, 194, 194, 194, 194], Bool[0, 1, 1, 1, 1, 1, 1]), ([1, 1, 1, 1, 1, 1, 1], [170, 194, 194, 194, 194, 194, 194], Bool[0, 1, 1, 1, 1, 1, 1]), ([1, 1, 1, 1, 1, 1, 1], [254, 195, 195, 195, 195, 195, 195], Bool[0, 1, 1, 1, 1, 1, 1]), ([1, 1, 1, 1, 1, 1, 1], [255, 195, 195, 195, 195, 195, 195], Bool[0, 1, 1, 1, 1, 1, 1]), ([1, 1, 1, 1], [225, 225, 225, 225], Bool[1, 1, 1, 1]), ([1, 1, 1, 1], [229, 229, 229, 229], Bool[1, 1, 1, 1]), ([1, 1, 1, 1], [231, 231, 231, 231], Bool[1, 1, 1, 1]), ([1, 1, 1, 1], [232, 232, 232, 232], Bool[1, 1, 1, 1]), ([1, 1, 1, 1], [234, 234, 234, 234], Bool[1, 1, 1, 1]), ([1, 1, 1, 1], [239, 239, 239, 239], Bool[1, 1, 1, 1]), ([1, 1, 1, 1], [239, 239, 239, 239], Bool[1, 1, 1, 1]), ([1, 1], [240, 240], Bool[1, 1]), ([1, 1], [240, 240], Bool[1, 1]), ([1], [244], Bool[1]), ([1], [244], Bool[1]), ([1, 1, 1, 1, 1, 1, 1, 1, 1], [8, 8, 8, 8, 8, 8, 8, 8, 8], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1]), ([1, 1, 1, 1, 1, 1, 1, 1, 1], [9, 9, 9, 9, 9, 9, 9, 9, 9], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1]), ([1, 1, 1, 1, 1, 1, 1, 1, 1], [10, 10, 10, 10, 10, 10, 10, 10, 10], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1]), ([1, 1, 1, 1, 1, 1, 1, 1, 1], [11, 11, 11, 11, 11, 11, 11, 11, 11], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1]), ([1, 1, 1, 1, 1, 1, 1, 1, 1], [12, 12, 12, 12, 12, 12, 12, 12, 12], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1]), ([1, 1, 1, 1, 1, 1, 1, 1, 1], [13, 13, 13, 13, 13, 13, 13, 13, 13], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1]), Bool[1, 1, 1, 1, 1, 1], Bool[0, 0]), :rejects),
    "dart_string/charcode" => ((Bool[1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0], Bool[0, 0, 1, 1], -1, -1), :rejects),
    "dart_string/const_interpolation_constant_string_interpolation" => ((Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], true), :rejects),
    "dart_string/const_interpolation2" => ((Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], Bool[1, 1, 1, 1]), :rejects),
    "dart_string/escapes" => (((15, 1, 1, 237, false), (15, 12, true, 11, true, 8, true), (15, 13, true, 10, true, 9, true), (7, 255, true), (7, 1, true), false), :rejects),
    "dart_string/interpolate_null" => ((true, -2), :rejects),
    "dart_string/interpolate" => ((true, true, true, true, true, Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]), :outside),
    "dart_string/interpolate2" => ((true, true, true, true, true, true, true, true), :rejects),
    "dart_string/interpolation_and_buffer" => ((true, 2, true, 1), :rejects),
    "dart_string/interpolation_newline" => ((true, true, true), :outside),
    "dart_string/interpolation_runtime" => ((Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], Bool[1, 1, 1, 1, 1, 1]), :outside),
    "dart_string/interpolation" => ((Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], Bool[1, 1, 1, 1, 1, 1]), :outside),
    "dart_string/interpolation7" => ((true, true), :rejects),
    "dart_string/interpolation8" => (true, :rejects),
    "dart_string/intrinsics" => ((11, 0, false, true), :rejects),
    "dart_string/join" => ((true, true), :outside),
    "dart_string/literals" => ((Bool[1, 1, 1, 1, 0], Bool[0, 0, 0, 1, 0], true), :outside),
    "dart_string/multiline_newline" => (([4, 4, 4, 6, 6, 6, 4, 4, 4, 6, 6, 6], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]), :rejects),
    "dart_string/multiline_newline_runtime" => (([4, 4, 4, 6, 6, 6, 4, 4, 4, 6, 6, 6], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]), :rejects),
    "dart_string/multiline_newline_runtime_1" => ((([4, 4, 4, 6, 6, 6, 4, 4, 4, 6, 6, 6], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]), 1), :rejects),
    "dart_string/multiline_newline_runtime_2" => ((([4, 4, 4, 6, 6, 6, 4, 4, 4, 6, 6, 6], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]), 2), :rejects),
    "dart_string/multiline_newline_runtime_3" => ((([4, 4, 4, 6, 6, 6, 4, 4, 4, 6, 6, 6], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]), 3), :rejects),
    "dart_string/multiline_newline_runtime_4" => ((([4, 4, 4, 6, 6, 6, 4, 4, 4, 6, 6, 6], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]), 1), :rejects),
    "dart_string/multiline_newline_runtime_5" => ((([4, 4, 4, 6, 6, 6, 4, 4, 4, 6, 6, 6], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]), 2), :rejects),
    "dart_string/multiline_newline_runtime_6" => ((([4, 4, 4, 6, 6, 6, 4, 4, 4, 6, 6, 6], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]), 3), :rejects),
    "dart_string/multiline_strings" => (Bool[0, 0, 1, 1, 1, 1, 1, 0, 0, 1, 1, 0], :rejects),
    "dart_string/optimizations" => ((true, true, true, -1), :rejects),
    "dart_string/raw_string" => (Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], :rejects),
    "dart_string/runtime" => ((Bool[1, 1, 1, 1, 1, 1], [115, 116, 114, 105, 110, 103], true, true, 129), :outside),
    "dart_string/split" => (3, :rejects),
    "dart_string/string" => ((Bool[1, 1, 1, 1, 1, 1], [115, 116, 114, 105, 110, 103], true, true, 129), :outside),
    "dart_string/supertype_checked" => ((-1, -1), :compiled),
    "dart_string/unicode_bom_middle" => ((3, 3), :rejects),
    "dart_string/unicode_hash" => ((true, true), :rejects),
    # tests/language/call/
    "dart_call/argument_inference" => ((true, false), :rejects),
    "dart_call/call" => ((true, true, true, true, true, true, true, true, -1, -1, -1), :rejects),
    "dart_call/closurization" => ((true, true, true, true, true, true, true, -1, -1, -1), :rejects),
    "dart_call/dynamic_call_through_getter" => (4, :compiled),
    "dart_call/evaluation_order" => ((true, true, true, true, true, true, true, true), :rejects),
    "dart_call/function_apply" => (497, :compiled),
    "dart_call/function" => ((true, true, true, -1), :rejects),
    "dart_call/function2" => ((true, true), :rejects),
    "dart_call/implicit_tearoff_assignment" => (((1, 1), (2, 2), (3, 3), (4, 4), (5, 5), (6, 6), (7, 7), (8, 8)), :compiled),
    "dart_call/implicit_tearoff_exceptions" => ((0, 0, 0, 0, 0, -1, false), :rejects),
    "dart_call/implicit_tearoff_local_assignment" => (((true, true, true, true), (true, true, true, true), -1, (true, true, true, true, true), (true, true, true, true)), :rejects),
    "dart_call/implicit_tearoff" => ([1, 2, 2, 3, 3, 3, 3, 4, 5, 6, 7, 8, 9, 10, 11, 1, 12, 13, 3, -1, 3, 3], :rejects),
    "dart_call/implicit_tearoff_type_variable" => ((1, 2, 3), :compiled),
    "dart_call/method_as_cast_legacy" => ((-3, -3, -3, -3, -3, 0), :rejects),
    "dart_call/method_as_cast" => ((-3, -3, -3, -3, -3, -3), :rejects),
    "dart_call/method_function_typed_value" => ((true, true, true, true, true, true), :compiled),
    "dart_call/method_implicit_invoke_instance_legacy" => (((true, true, true, true), (true, true, true, true), (true, true, true, true)), :compiled),
    "dart_call/method_implicit_invoke_instance" => (((true, true, true, true), (true, true, true, true), (true, true, true, true)), :compiled),
    "dart_call/method_implicit_invoke_local_legacy" => ((true, true, true, true, true, false), :compiled),
    "dart_call/method_implicit_invoke_local_runtime_legacy" => ((true, true, true, true), :compiled),
    "dart_call/method_implicit_invoke_local" => ((true, true), :compiled),
    "dart_call/method_implicit_invoke_static" => (((true, true, true, true), (true, true, true, true), (true, true, true, true)), :compiled),
    "dart_call/method_implicit_invoke_top_level" => ((true, true, true, true), :compiled),
    "dart_call/method_implicit_tear_off" => (((true, true, true), (true, true), -1, true, (true, true)), :rejects),
    "dart_call/method_is_check" => ((false, false, false, false, false, false), :compiled),
    "dart_call/method_must_not_be_field" => ((-1, 1, 1, 1, 1), :compiled),
    "dart_call/method_must_not_be_getter" => ((-1, -1, 1, 1, 1), :compiled),
    "dart_call/operator" => ((42, 35, 28, 42, 42, 7, 14, true, true, true, false, false), :rejects),
    "dart_call/property" => ((false, false, true), :compiled),
    "dart_call/regress60643" => (((-1, -4, true), (-1, -4, true), (-1, -4, true)), :rejects),
    "dart_call/through_getter" => (((true, true, true), (42, 42), (87, 87, 87, 87), (true, 87), (-1, -1, -1), true, (true, true, true, true, true)), :rejects),
    "dart_call/through_null_getter" => ((-1, -1, -1, -1, -1, -1, -1), :rejects),
    "dart_call/type_literal" => (1, :compiled),
    "dart_call/with_no_such_method" => ((true, true, true), :rejects),
    # tests/language/function/
    "dart_function/apply_generic" => (([1, 2, 3, -1, -1, -1, -1, -1, -1, -1], [1, 2, 3, 4, -1, -1, -1, -1, -1, -1], [1, 2, 3, 4, 5, 6, 7, -1, -1, -1], [1, 2, 3, -1, -1, -1, -1, -1, -1, -1], [1, 2, 3, 4, -1, -1, -1, -1, -1, -1], [1, 2, 3, 4, 5, 6, 7, -1, -1, -1], [1, 2, 3, -1, -1, -1, -1, -1, -1, -1], [1, 2, 3, 4, -1, -1, -1, -1, -1, -1], [1, 2, 3, 4, 5, 6, 7, -1, -1, -1]), :rejects),
    "dart_function/apply_generic2" => (([-1, 33, -1, 11, 22, -1], -1, [11, 22, 33, -1, -1], [-1, 33, -1, 11, 22], -1, [-1, 33, -1, 11, 22, -1], -1), :rejects),
    "dart_function/argument" => (42, :compiled),
    "dart_function/call_generic" => (((true, 1, 2, 3, -1, -1), (false, "Z1", 2, 4, -1, -1), (true, 7, 2, -1, -1, -1), (true, 8, 2, 3, -1, -1), (false, "A1", 2, 3, -1, -1), (true, 9, 2, 3, -1, -1), (true, 10, 2, 3, -1, -1), (false, "B1", 2, 3, -1, -1), (true, 15, -1, -1, -1, -1), (true, 16, 2, 3, 4, -1)), :rejects),
    "dart_function/direct_invocation" => ((1, 2, 3), :compiled),
    "dart_function/field" => (42, :compiled),
    "dart_function/function" => ((6, (2, 0, 1), (2, 0, 1), (1, 2), (1, 2), 45, 45, (-2, -2), (10, 10, true), (10, 1), (42, 42), true, (1, 1, 1), 1, (10, 10, 11, 2, 12, 12)), :rejects),
    "dart_function/getter" => ((42, 42), :compiled),
    "dart_function/literals" => ([42, 42, 84, 84, 84, 84, 42, 42, 84, 84, 84, 84, 42, 42, 42, 42], :rejects),
    "dart_function/literals2" => ((20, 20, 20, 7, 10, 20, (-1, -3), (-2, 2), true, false, (10, 100), (10, 101), true), :rejects),
    "dart_function/local_function" => ((18, 145, 90, 320, 145, 5, (true, 300), true, 99, (2, true, true, true, true, true, 2, 3)), :rejects),
    "dart_function/local2" => ((36, 9.0), :compiled),
    "dart_function/local3" => ((true, true, 2), :rejects),
    "dart_function/propagation" => ((true, false, true, false, 499), :compiled),
    "dart_function/regress_45601" => ((42, true, false, false, true), :rejects),
    "dart_function/syntax" => (([42, 87, 3, 42, 87, 3, 42, 87, 3, 42, 87, 3, 87, 3, 87, 3, 42, 87, 42, 87], [42, 87, 3, 42, 87, 3, 87, 3, 87, 3], Bool[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], [42, 43, 44, 45, 46, 47, 48, 49], [42, 87, 43, 44], 87, 42, true), :rejects),
    "dart_function/type_alias" => (((true, true, false, false, false, false), (true, true, false, false, false, true), (true, true, false, true, true, false), (true, true, false, false, true, false), (true, true, false, false, true, false), 3, -1, 99, true, false), :rejects),
    "dart_function/type_alias10" => ((true, true), :rejects),
    "dart_function/type_alias2" => (((false, false, true, false, false, false, false, false), (false, false, false, true, false, false, false, false), (false, false, true, false, false, false, false, false), (false, false, false, true, false, false, false, false), -1, -1), :rejects),
    "dart_function/type_alias3" => (((false, true, false), (false, false, false)), :rejects),
    "dart_function/type_alias4" => (((false, true, false), (false, false, true), (false, true, false), (false, false, true), false, -1), :rejects),
    "dart_function/type_alias6" => ((false, true), :compiled),
    "dart_function/type_alias8" => (true, :compiled),
    "dart_function/type_call_getter" => (Bool[0, 0, 0, 0, 0, 0], :rejects),
    "dart_function/type_call_getter2" => ([-1, -1, -1, -1, -1, -1], :rejects),
    "dart_function/type_in_constant" => ((true, true, true), :compiled),
    "dart_function/type_parameter_bound_object" => ((42, -1, -1), :rejects),
    "dart_function/type_parameter" => ((true, false, true, true, 42, 42), :rejects),
    "dart_function/type_parameter2" => ((true, false, true, true), :rejects),
    "dart_function/type" => ((-1, 0), :rejects),
    "dart_function/type_this_parameter" => (499, :compiled),
    "dart_function/type2" => ((-1, 0), :rejects),
    "dart_function/type3" => ((true, false), :rejects),
    # tests/language/parameter/
    "dart_parameter/default" => ([1, 2, 3, 4], :rejects),
    "dart_parameter/initializer" => ((1, 7, 111, 5, 2, 1, (true, true, true), 1, ((true, true, true), true)), :compiled),
    "dart_parameter/initializer2" => ((123, 123, 123, 123, 4, 4), :compiled),
    "dart_parameter/initializer5" => ((12, 12), :compiled),
    "dart_parameter/name_conflict" => ((true, true, true, true), :rejects),
    "dart_parameter/named_clash" => ((true, true, -1, -1), :rejects),
    "dart_parameter/named_count" => ((true, true, true, true, true, true, true, true, true), :rejects),
    "dart_parameter/named_default_eq_runtime" => ((((30, 70, 42, 28, 15, 21, 35, 14), (30, 70, 42, 28, 15, 21, 35, 14), (30, 70, 42, 28, 15, 21, 35, 14), (30, 70, 42, 28, 15, 21, 35, 14), (30, 70, 42, 28, 15, 21, 35, 14), (30, 70, 42, 28, 15, 21, 35, 14)), ((30, 70, 42, 28, 15, 21, 35, 14), (30, 70, 42, 28, 15, 21, 35, 14), (30, 70, 42, 28, 15, 21, 35, 14), (30, 70, 42, 28, 15, 21, 35, 14))), :compiled),
    "dart_parameter/named_default_eq" => ((((30, 70, 42, 28, 15, 21, 35, 14), (30, 70, 42, 28, 15, 21, 35, 14), (30, 70, 42, 28, 15, 21, 35, 14), (30, 70, 42, 28, 15, 21, 35, 14), (30, 70, 42, 28, 15, 21, 35, 14), (30, 70, 42, 28, 15, 21, 35, 14)), ((30, 70, 42, 28, 15, 21, 35, 14), (30, 70, 42, 28, 15, 21, 35, 14), (30, 70, 42, 28, 15, 21, 35, 14), (30, 70, 42, 28, 15, 21, 35, 14))), :compiled),
    "dart_parameter/named_parameters" => (((0, 0, 10, 10, 20, 20, 20, 20), (1020, 1020, 1025, 1025), (102030, 102030, 102530, 102530, 102535, 102535), (10200040, 10200040), (100, 1000, 100, 1000, true)), :compiled),
    "dart_parameter/named_passing_false" => (((true, true, true, true, true, true), (true, true, true, true, true, true), (true, true, true, true, true, true)), :compiled),
    "dart_parameter/named_passing_falsy" => (((true, true, true, true, true, true), (true, true, true, true, true, true), (true, true, true, true, true, true), (true, true, true, true, true, true), (true, true, true, true, true, true), (true, true, true, true, true, true), (true, true, true, true, true, true, true, true, true, true, true), (true, true, true, true, true, true, true, true, true, true, true), (true, true, true, true, true, true, true, true, true, true, true)), :rejects),
    "dart_parameter/named_passing_null" => (((true, true, true, true, true, true), (true, true, true, true, true, true), (true, true, true, true, true, true)), :compiled),
    "dart_parameter/named_passing_zero" => (((true, true, true, true, true, true), (true, true, true, true, true, true), (true, true, true, true, true, true)), :compiled),
    "dart_parameter/named_regression" => ((true, true), :compiled),
    "dart_parameter/named_runtime" => (((0, 0, 10, 10, 20, 20, 20, 20), (1020, 1020, 1025, 1025), (102030, 102030, 102530, 102530, 102535, 102535), (10200040, 10200040), (100, 1000, 100, 1000, true)), :compiled),
    "dart_parameter/named_with_conversions" => (((7, -1, -1, -1, -1, 7, true), (7, -1, -1, -1, -1, 7, true), (7, -1, -1, -1, -1, 7, true), (7, -1, -1, -1, -1, 7, true)), :rejects),
    "dart_parameter/named_with_dollars" => (((true, true, true, true, true, true), (true, true, true, true, true), (true, true, true, true, true), (true, true, true, true), (true, true, true, true)), :rejects),
    "dart_parameter/named_with_object_property_names" => (((true, true, true, true, true, true), (true, true, true, true, true, true), (true, true, true, true, true, true), (true, true, true, true, true, true), (true, true, true, true, true, true), (true, true, true, true, true, true), (true, true, true, true, true, true), (true, true, true, true, true, true), (true, true, true, true, true, true), (true, true, true, true, true, true)), :compiled),
    "dart_parameter/optional_named_runtime" => (((0, 0, 10, 10, 20, 20, 20, 20), (1020, 1020, 1025, 1025), (102030, 102030, 102530, 102530, 102035, 102035, 102535, 102535, 102535, 102535), (10200040, 10200040, 10203540, 10203540, 10250045, 10250045, 10253545, 10253545)), :compiled),
    "dart_parameter/optional_named" => (((0, 0, 10, 10, 20, 20, 20, 20), (1020, 1020, 1025, 1025), (102030, 102030, 102530, 102530, 102035, 102035, 102535, 102535, 102535, 102535), (10200040, 10200040, 10203540, 10203540, 10250045, 10250045, 10253545, 10253545)), :compiled),
    "dart_parameter/param" => (2, :compiled),
    "dart_parameter/parameter1" => (0, :compiled),
    "dart_parameter/parameter2" => (((4, 100), [1, 4, 9, 16, 25, 36], (true, false, false), (true, false, false)), :rejects),
    "dart_parameter/types_specialization" => (((true, true), (true, true)), :rejects),
    # tests/language/constructor/
    "dart_constructor/body" => ((4, 5, 6, 7), :compiled),
    "dart_constructor/call_as_function" => ((1, 2), :compiled),
    "dart_constructor/constructor11" => ([499, 42, 99], :rejects),
    "dart_constructor/constructor12_strong" => ((true, 2), :compiled),
    "dart_constructor/constructor12" => (((2, 3, 3, 1, 2, 3), (true, false, false, false, true), (2, 3, 3, 4), (0, 0), (1, 0, true, false, false, false)), :rejects),
    "dart_constructor/constructor2" => (([1, 5, 2, 3, 4, 6, 7], ((true, true, true), (true, true))), :rejects),
    "dart_constructor/constructor3" => (([4, 1, 2, 3, 5, 6], ((true, true), true)), :rejects),
    "dart_constructor/constructor4" => (([1, 2, 3, 4], (2, 1)), :rejects),
    "dart_constructor/constructor5" => (([10, 20, 100, 50, 101, 51, 11, 21], (100, 50, 10, 20)), :rejects),
    "dart_constructor/constructor6" => (([10, 20, 1001, 1011, 1111, 1121, 11, 21, 1131], 1001, 10, 20), :rejects),
    "dart_constructor/constructor7" => (([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], (1, 2, 3, 4, 5, 6, 7, 8, 9, 10)), :rejects),
    "dart_constructor/constructor8" => (((true, true), (true, true)), :rejects),
    "dart_constructor/constructor_contexts" => (((true, true, true, true), ((true, true), (true, true), true, true), (true, true, true, true), (true, true, (true, true), (true, true)), (true, true, true, true), ((true, true), (true, true), (true, true, true), (true, true, true))), :rejects),
    "dart_constructor/constructor" => ((10, 2, 10, 22, true, 3), :compiled),
    "dart_constructor/default_class_implicit_constructor" => ((true, true), :compiled),
    "dart_constructor/default_factory3" => ((true, true), :compiled),
    "dart_constructor/default_factory_library" => ((true, 1, 2), :rejects),
    "dart_constructor/default_factory" => ((true, true), :compiled),
    "dart_constructor/default" => ((499, true), :rejects),
    "dart_constructor/evaluation_redirecting_constructor" => (1, :rejects),
    "dart_constructor/example_constructor" => (([0, 1, 2, 3, 4, 5, 6], (true, true), (0, 4, 2, 1)), :rejects),
    "dart_constructor/external_constructor" => ((-1, -1), :rejects),
    "dart_constructor/forwarding_factory_constructor_default_values" => ((0, true), :rejects),
    "dart_constructor/implicit_super_constructor_call" => ((true, true), :rejects),
    "dart_constructor/implicit_super_constructor" => (42, :compiled),
    "dart_constructor/inference_super_constructor_call" => ((84, -1), :rejects),
    "dart_constructor/initializer" => (((true, true), (true, true, true), (3, 5, 10, 10), (3, 10), (true, true)), :compiled),
    "dart_constructor/multiple_field_assignment_constructor" => ((-1, -1), :rejects),
    "dart_constructor/name_clash" => (110, :rejects),
    "dart_constructor/named_arguments" => ((((true, true), (true, true), (true, true), (true, true), (true, true)), true, true), :rejects),
    "dart_constructor/named_constructor" => ([0, 0, 1, 1, 2, 2, 3, 3], :rejects),
    "dart_constructor/non_const_constructor_without_body" => ([-1, -1, 1, 2, 2, 1], :rejects),
    "dart_constructor/non_parameterized_factory" => ((true, true, true), :compiled),
    "dart_constructor/non_parameterized_factory2" => ((true, true), :compiled),
    "dart_constructor/patch_tear_off" => (1.0, :compiled),
    "dart_constructor/redirect" => ((499, 848, 499, 499, 499, 499, 499, 499), :compiled),
    "dart_constructor/return" => (11, :compiled),
    "dart_constructor/tear_off" => ((((true, 1, true, true), (true, 1, true, true), (true, 1, true, true), (true, 1, true, true), (true, 1, true, true), (true, 1, true, true), (true, 1, true, true), (true, 1, true, true)), ((true, true), (true, true), (true, true), (true, true), (true, true), (true, true), (true, true), (true, true)), ((true, 1, true, true), (true, 1, true, true), (true, 1, true, true), (true, 1, true, true), (true, 1, true, true), (true, 1, true, true), (true, 1, true, true), (true, 1, true, true)), (true, true, true, true, true, true, true, true), (0, 0, 1, 0, 0, 1), (true, true, true, true, true, true)), :rejects),
    "dart_constructor/unnamed_new" => (((1, 1, 1, 1, 1, 1, 1, 1, 1, 1), (0, 0, 1, 1, 0, 1), (1, 1, 1, 1, 1, 1, 1, 1, 1, 1), (0, 0, 1, 1, 0, 1), 1, 1, true, true), :compiled),
    "dart_constructor/with_mixin" => ((1, 1, 17, 13), :rejects),
)

# a case's answer is native's: of its type, and isequal (a NaN equal to itself, -0.0 apart from 0.0)
_dart_same(got, native) = typeof(got) == typeof(native) && isequal(got, native)

# what a compile gives: its RejectionError (an OutsideSubset by its errors' kinds), or :compiled. The landing's
# core stops at codegen, the compile this property judges: wasm-opt, an external tool, runs on every
# case in dev/corpus.sh's whole run and in test/src/compile.jl, never once per case in the landing
_dart_outcome(f, args) = try
    isdefined(Main, :wt_progress) && Main.wt_progress("dart_tests.jl: compiling $(nameof(typeof(f))) $(typeof(args))")
    WasmTarget.compile(f, Tuple(map(typeof, args)); optimize = !_DART_CORE_ONLY)
    :compiled
catch e
    e isa WasmTarget.RejectionError || rethrow()
    local r = e.rejection
    r isa WasmTarget.OutsideSubset || return e
    return _outside((t.kind for t in r.errors)...)
end

# an outcome as a failure names it: the rejection's own text (A51E9)
_dart_said(got)::String = got === :compiled ? "compiles" : got isa _Outside ? "rejects as OutsideSubset $(got[2])" :
    first(sprint(showerror, got), 400)

# a WasmTarget defect: reject.jl's two kinds that say WT itself is wrong, the builder's or wasm-opt's refusal
# (InvalidModule, D10's alarm) and a broken invariant (Internal)
_dart_defect(got)::Bool = got isa WasmTarget.RejectionError &&
    (got.rejection isa WasmTarget.InvalidModule || got.rejection isa WasmTarget.Internal)

# why a rejection is not located, or "" (A51E1): it names its compile (`at`), and the definition it reached
# stands in the pin table: an Unported's anchor parses by parse_anchor to a file of DART_FILES or LLVM_FILES,
# an Unquarantined's row opens with a file of this repository or of DART_FILES. Where the anchor points is
# never pinned: one lane's progress moves it (the snapshot that oscillated, 2026-10-28).
const _DART_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
function _dart_unlocated(e::WasmTarget.RejectionError)::String
    isempty(e.at) && return "its rejection names no compile (an empty `at`)"
    local r = e.rejection
    if r isa WasmTarget.Unported
        local a = WasmTarget.parse_anchor(r.anchor)
        a === nothing && return "its Unported anchor $(repr(r.anchor)) is no anchor"
        a.unit in (a.pin === :dart ? WasmTarget.DART_FILES : WasmTarget.LLVM_FILES) ||
            return "its Unported anchor names $(a.unit), in no pin table"
    elseif r isa WasmTarget.Unquarantined
        local m = match(r"^([\w./-]+?)(?::\d+)?(?::|\s|$)", r.row)
        local file = m === nothing ? "" : String(m[1])
        (isfile(joinpath(_DART_ROOT, file)) || file in WasmTarget.DART_FILES) ||
            return "its Unquarantined row $(repr(first(r.row, 120))) opens with no file of the repository or the pin"
    else
        return "a $(nameof(typeof(r))) is no rejection a :rejects case admits"
    end
    return ""
end

# each compile's budget (D17): intent, a case compiles in well under a second (the core's slowest today 1.7 s,
# an Unquarantined rejection); band, past DART_COMPILE_BUDGET seconds it fails, naming its case and seconds. The
# seconds are @timed's less its compile_time (A53E3): Julia compiling WasmTarget's own methods on a path's first
# use (a process's first compile ~30 s, a new path's ~20 s) is no case's cost, and which case pays it depends
# on the corpus's order. A compile that never returns is cut by dev/check.sh's hard limit (dev/corpus.sh's in
# the whole run), which names the case _dart_outcome wrote to WT_PROGRESS.
const DART_COMPILE_BUDGET = 10.0
_dart_secs(t::NamedTuple)::Float64 = t.time - t.compile_time

# why a case's outcome breaks its record's property, or "" when it holds
function _dart_breaks(today::Symbol, got)::String
    if today === :compiled
        # a compiling case never loses ground
        got === :compiled || return "recorded :compiled, now: $(_dart_said(got))"
    elseif today === :outside
        # Julia's verifier's verdict (D32): the program stands outside the strict subset, a fact of the
        # program and of Julia, never of a lane's progress
        got isa _Outside || return "recorded :outside, now: $(_dart_said(got))"
    elseif today === :wt_bug
        # still WT's defect (A51E4); a module never stands under :wt_bug (A53E2)
        _dart_defect(got) || return "recorded :wt_bug, fixed: now $(_dart_said(got)); re-record it"
    elseif today === :rejects
        # compiles, outside the subset, or a rejection at a definition not yet written, located (A51E1)
        (got === :compiled || got isa _Outside) && return ""
        _dart_defect(got) && return "a WasmTarget defect: $(_dart_said(got))"
        local why = _dart_unlocated(got)
        isempty(why) || return "$why: $(_dart_said(got))"
    else
        return "no record kind $(repr(today))"
    end
    return ""
end

# the landing's fixed core: the first case of each group; a case the change adds or edits has its native answer
# proven (DART_NATIVE_DUE) and its compile judged by dev/corpus.sh on the head
const _DART_CORE_ONLY = get(ENV, "WT_LANDING_CORE", "") == "1"
const DART_CORE = Set{String}("$(g)/$(c[1])" for (g, cs) in DART_GROUPS for c in cs[1:min(1, end)])

# a compiled case's modules, each fact of its answer read by test/runner.jl against native Julia's, computed
# afresh (a stale record is not the module's fault); a reader that does not compile fails the case, named. The
# reading has the compile's budget, per case. The whole run reads both modules, codegen's and wasm-opt's.
function _dart_read!(runs::Vector{Main.WTRunner.RunCase}, unread::Vector{Pair{String,String}}, key::String, f, args::Tuple)
    isdefined(Main, :wt_progress) && Main.wt_progress("dart_tests.jl: reading $key's answer")
    local secs = _dart_secs(@timed try
        append!(runs, Main.WTRunner.answer_cases(key, WasmTarget.compile, f, args, f(args...)))
    catch e
        e isa WasmTarget.RejectionError || rethrow()
        push!(unread, key => "the reader of its answer does not compile: $(sprint(showerror, e))")
    end)
    secs <= DART_COMPILE_BUDGET || push!(unread, key => "reading its answer took $(round(secs; digits = 1)) s, past its $(DART_COMPILE_BUDGET) s budget")
    return nothing
end

@testset "dart2wasm's tests, Julia the ground truth" begin
    local seen = Set{String}()
    local runs = Main.WTRunner.RunCase[]
    local unread = Pair{String,String}[]
    local nread = 0
    for (group, cases) in DART_GROUPS, case in cases
        local key = "$group/$(case[1])"
        push!(seen, key)
        @testset "$key" begin
            @test haskey(DART_CASES, key)
            if haskey(DART_CASES, key)
                local native, today = DART_CASES[key]
                local f, args = case[2], case[3:end]
                (key in DART_NATIVE_DUE || !_DART_CORE_ONLY) && @test _dart_same(f(args...), native)
                if !_DART_CORE_ONLY || key in DART_CORE
                    local timed = @timed _dart_outcome(f, args)
                    local got, secs = timed.value, _dart_secs(timed)
                    @test secs <= DART_COMPILE_BUDGET
                    # the record's property; a failure prints why, the rejection's own text in it (A51E9)
                    @test _dart_breaks(today, got) == ""
                    # the modules run in the whole run, every module whatever its record, a wrong answer never
                    # admitted (A53E2); the landing runs none, its cost fixed (the lead's ruling: a landing
                    # sample comes later, its cost measured)
                    if got === :compiled && !_DART_CORE_ONLY
                        _dart_read!(runs, unread, key, f, args)
                        nread += 1
                    end
                end
            end
        end
    end
    # every recorded case is a case of the corpus
    @test sort!(collect(setdiff(keys(DART_CASES), seen))) == String[]
    # every module read, in one node process: each fact native's, in both modules, or the case fails naming
    # the fact by its path and what the modules answered
    isdefined(Main, :wt_progress) && Main.wt_progress("dart_tests.jl: running $(length(runs)) modules in node")
    local results = Main.WTRunner.run_cases(runs)
    for (key, why) in unread
        @testset "$key runs as native Julia" begin
            @test why == ""
        end
    end
    # one @test per fact: its label and why it differs, "" when it equals native's in every module
    for r in results
        @test (r.label => r.why) == (r.label => "")
    end
    global DART_RUN_COUNTS = (nread, length(results), count(r -> r.ok, results))
end
println("dart tests: $(_DART_CORE_ONLY ? length(DART_CORE) : length(DART_CASES)) compiles checked$(_DART_CORE_ONLY ? " (the landing core)" : ""); native answers proven for ",
        _DART_CORE_ONLY ? "the $(length(DART_NATIVE_DUE)) the change adds or edits against $(_DART_BASE)" : "every case", "; $(DART_RUN_COUNTS[1]) compiled cases run in node, $(DART_RUN_COUNTS[3]) of their $(DART_RUN_COUNTS[2]) facts native's")
