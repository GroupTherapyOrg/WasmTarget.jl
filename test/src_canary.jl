# The judge's canary (the round-13 architect's A13-5; included by test/src_tests.jl, a file no move's rule admits, G5):
# run LAST in every process of test/src_tests.jl that runs test files with records (a landing check's shard, the score's
# src part, a red file's run alone, a bisect's step), through the SAME path a test file's verdict takes (_wt_red and
# _wt_why over a testset, then _wt_record): one testset that must read failed and one that must read passed.
# A test file runs in the process that writes its record, so it can redefine those functions or Test.get_test_counts
# (the architect's p6: a file overriding get_test_counts made the next red file read passed); the canary then reads
# wrong, and the reader voids every row of that process, naming its files (dev/check.sh, dev/climb/measure.py src_run).
# Its two testsets are not the run's own: the failure it plants never fails the process.
# AS A FILE (spec v17 Z4, red's round-14 finding 4): after each test file F the harness runs it again as F, its two
# testsets described as F's own (`F`, the description test/src_tests.jl gives F's testset), each pushed on Test's testset
# stack as F's was, and its records carrying F's source file (the path a `@test` of F records): so a lasting change
# keyed on F's name, its source file or its testset (a `Test.record` method that drops F's failures) drops the canary's
# planted failure too, and F's canary reads wrong. With no file, the plain canary, last in every process.
function _wt_canary(f::Union{Nothing,String} = nothing)::Tuple{Bool,String}
    local name = f === nothing ? "~canary" : f
    local src = LineNumberNode(1, Symbol(f === nothing ? (@__FILE__) : joinpath(SRC_TEST_DIR, f)))
    local fail = Test.DefaultTestSet(f === nothing ? "~canary: must read failed" : name)
    local pass = Test.DefaultTestSet(f === nothing ? "~canary: must read passed" : name)
    Test.push_testset(fail)
    try
        redirect_stdout(devnull) do
            Test.record(fail, Test.Fail(:test, "1 == 2", nothing, false, nothing, src, false))
        end
    finally
        Test.pop_testset()
    end
    Test.push_testset(pass)
    try
        Test.record(pass, Test.Pass(:test, "1 == 1", nothing, true, src))
    finally
        Test.pop_testset()
    end
    local rf, rp = _wt_red(fail), _wt_red(pass)
    local wf, wp = _wt_why(fail), _wt_why(pass)
    local ok = rf && !rp && !isempty(wf) && isempty(wp)
    return ok, ok ? "" : "the canary as $name: the failing testset read $(rf ? "failed" : "passed") ($(repr(first(wf, 80)))), the passing one $(rp ? "failed" : "passed") ($(repr(first(wp, 80))))"
end
