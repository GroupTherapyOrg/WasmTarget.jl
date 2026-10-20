# loaded by Pkg.test's process (julia_args -L): profile the whole test run, report at exit
include(joinpath(@__DIR__, "prof_classify.jl"))
Profile.init(n = 10^8, delay = 0.005)
const _PROF_T0 = time()
Profile.start_timer()
atexit() do
    Profile.stop_timer()
    println("suite ", round(time() - _PROF_T0; digits=1), " s")
    report_profile("suite WT_PHASE=" * get(ENV, "WT_PHASE", "") * " WT_FUZZ_PART=" * get(ENV, "WT_FUZZ_PART", ""))
end
