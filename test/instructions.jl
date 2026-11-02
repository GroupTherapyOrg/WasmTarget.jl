# the process's instructions retired, read from its own counter: macOS's proc_pid_rusage, the rusage_info_v4 counter
# /usr/bin/time -l reports as "instructions retired" (sys/resource.h: ri_instructions, the 30th 64-bit field after
# the 16-byte ri_uuid). dev/check.sh and dev/corpus.sh run on macOS alone. One definition for test/src_tests.jl's
# per-file costs and test/src/dart_tests.jl's warm-up (D5); each includes it once per process.
function _wt_instructions()
    local info = zeros(UInt64, 40)   # rusage_info_v4 is 16 + 37 * 8 bytes; 40 words hold it
    ccall(:proc_pid_rusage, Cint, (Cint, Cint, Ptr{UInt64}), getpid(), 4, info) == 0 ||
        error("proc_pid_rusage(RUSAGE_INFO_V4) failed: no instruction count to measure by")
    info[2 + 29 + 1]
end

# the process's CPU seconds, user and system over its threads: C's clock(), CLOCKS_PER_SEC 10^6 on macOS and on Linux.
# A limit judged by them judges the program, not the scheduler: at background QoS beside the lanes a corpus shard ran
# at 20 to 36% of an efficiency core (6732d4a6, 2026-11-01)
_wt_cpu_seconds()::Float64 = ccall(:clock, Culong, ()) / 1e6
