# dart2wasm's tests at the pin, ported with Julia as the ground truth (test/dart_tests.toml, dev/LEDGER.md
# D41): every case of test/smoke_corpus.jl's `dart_*` groups. Native Julia computes the answer recorded
# here (D3, never dart's value). Until WasmTarget compiles a case, its compile rejects with exactly the
# rejection recorded here, the first definition its path reaches unported; a port that moves the path
# on, or a compile that returns a module, fails the case until it is recorded again, so no case passes
# silently (the module is judged against native once the rebuild has its runner, dev/MARCH.md 1.B).
using Test, WasmTarget

# the corpus's `dart_*` groups, read in a module of their own as test/smoke.jl reads the whole corpus
const DART_GROUPS = let m = Module(:DartCorpus), groups = Pair{String,Vector{Any}}[]
    Core.eval(m, :(_g(name, cases) = push!($groups, name => cases)))
    Core.eval(m, :(_xf(name, cases) = push!($groups, name => cases)))
    Base.include(m, joinpath(@__DIR__, "smoke_corpus.jl"))
    filter(g -> startswith(first(g), "dart_"), groups)
end

# the definitions a dart case's compile reaches first today
const _COMPILE = WasmTarget.Unported(WasmTarget.anchor_of(WasmTarget.Dart2Wasm.compile))

# each case: native Julia's answer and the rejection its compile gives today
const DART_CASES = Dict{String,Tuple{Any,WasmTarget.Rejection}}(
    # tests/web/wasm
    "dart_web_wasm/assertion_failure_message" => (1, _COMPILE),
    "dart_web_wasm/boxed_value_tearoff" => (4, _COMPILE),
    "dart_web_wasm/closure_hash_code" => (31, _COMPILE),
    "dart_web_wasm/constructor_tearoff" => (255, _COMPILE),
    "dart_web_wasm/constructor" => (255, _COMPILE),
    "dart_web_wasm/flutter_regress_152029" => (1, _COMPILE),
    "dart_web_wasm/inlining" => (1005, _COMPILE),
    "dart_web_wasm/issue_54926" => (7, _COMPILE),
    "dart_web_wasm/issue_56234" => (-1, _COMPILE),
    "dart_web_wasm/lazy_const_record" => (20011, _COMPILE),
    "dart_web_wasm/lazy_static_number_initializer_regression" => (7, _COMPILE),
    "dart_web_wasm/no_omit_error_details" => (-1, _COMPILE),
    "dart_web_wasm/regress_54794" => (504, _COMPILE),
    "dart_web_wasm/regress_59782" => (3, _COMPILE),
    "dart_web_wasm/regress_59840" => (2.0, _COMPILE),
    "dart_web_wasm/regress_62273" => (3, _COMPILE),
    "dart_web_wasm/regress_63454" => (3, _COMPILE),
    "dart_web_wasm/regress_63747" => (16, _COMPILE),
    "dart_web_wasm/static_dispatch_pragma" => (12, _COMPILE),
    "dart_web_wasm/unreachable_selector_implementation" => (20, _COMPILE),
    "dart_web_wasm/function_apply" => (31, _COMPILE),
    # tests/language
    "dart_language/flutter_regession_151473" => (15, _COMPILE),
    "dart_language/local_null_initialization" => (192, _COMPILE),
    "dart_language/record_literal" => (391, _COMPILE),
    "dart_language/record_type" => (136, _COMPILE),
    "dart_language/regress_54994" => (1397, _COMPILE),
    "dart_language/regression_55741" => (155, _COMPILE),
    "dart_language/if_and" => (499, _COMPILE),
    "dart_language/if_dangling_else" => (15, _COMPILE),
    "dart_language/if_if" => (3001751, _COMPILE),
    "dart_language/if_nested_if" => (103, _COMPILE),
    "dart_language/return_in_loop" => (42, _COMPILE),
    "dart_language/return_skip_expression" => (15, _COMPILE),
    "dart_language/return_this_type" => (1, _COMPILE),
    "dart_language/bool_bool" => (191111111111102, _COMPILE),
    "dart_language/bool_check_strong" => (-11, _COMPILE),
    "dart_language/bool_condition_check_strong" => (-9, _COMPILE),
    "dart_language/identity_closure2" => (9, _COMPILE),
    "dart_language/identity_closure" => (2701, _COMPILE),
    "dart_language/identity_const" => (12, _COMPILE),
    "dart_language/identity_identical" => (4220, _COMPILE),
    "dart_language/identity_mint_identical" => (14, _COMPILE),
    "dart_language/identity_nan_identical" => (1731, _COMPILE),
    "dart_language/identity_strict_equal" => (48724, _COMPILE),
    "dart_language/double_literals_double_literal_coercion" => (59, _COMPILE),
    "dart_language/double_literals_implicit_double_context" => (31, _COMPILE),
    # the structural tests of pkg/dart2wasm/test/ir_tests and tests/web/wasm
    "dart_structural/hello" => (0, _COMPILE),
    "dart_structural/always_throws" => (-1, _COMPILE),
    "dart_structural/constant_string_ops" => (11003102, _COMPILE),
    "dart_structural/math_min_max" => (2.1162671e7, _COMPILE),
    "dart_structural/globals" => (120, _COMPILE),
    "dart_structural/try_blocks" => (876, _COMPILE),
    "dart_structural/type_brand" => (12341234, _COMPILE),
    "dart_structural/large_const_set" => (100011, _COMPILE),
    "dart_structural/long_string_import" => (100122, _COMPILE),
    "dart_structural/source_map_simple" => (-1, _COMPILE),
)

# what a compile gives: its rejection, or :compiled
_dart_outcome(f, args) = try
    WasmTarget.compile(f, Tuple(map(typeof, args)))
    :compiled
catch e
    e isa WasmTarget.RejectionError ? e.rejection : rethrow()
end

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
                @test f(args...) === native
                @test _dart_outcome(f, args) == today
            end
        end
    end
    # every recorded case is a case of the corpus
    @test sort!(collect(setdiff(keys(DART_CASES), seen))) == String[]
end
