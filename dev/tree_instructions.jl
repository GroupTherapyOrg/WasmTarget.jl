# dev/tree_instructions.jl — the instructions retired by a command's whole process tree, for D14's band
#
#   julia dev/tree_instructions.jl <out> <command...>   runs the command and writes to <out>, in G and seconds: the tree's
#                                                       instructions, those retired on performance cores, its CPU
#                                                       seconds, those on performance cores, and the command's own
#                                                       process's instructions; exits with the command's status
#   julia dev/tree_instructions.jl --plant              a tree whose grandchild does fixed work: the grandchild counted,
#                                                       each split inside its whole, and a run at background QoS read
#                                                       wholly on efficiency cores, or exits 1; the measured slowdown
#                                                       printed, unjudged
#
# The load stage precompiles WasmTarget in a child process of `julia -e 'using WasmTarget'` (Base.compilecache), and
# rusage reports a process's own instructions alone, never its children's (A54E1), so its CPU seconds were judged,
# which an efficiency core doubles (13 and 28 CPU-s for the same precompile, 2026-11-01). Each process of the tree
# now reports its own counter as it exits: a library inserted into every process the command starts
# (DYLD_INSERT_LIBRARIES, inherited by each child, the precompile among them) reads proc_pid_rusage's
# rusage_info_v6 in its destructor: ri_instructions (the counter /usr/bin/time -l reports as "instructions retired"),
# ri_pinstructions (those retired on performance cores), ri_user_time + ri_system_time and ri_user_ptime +
# ri_system_ptime (all CPU time and that on performance cores, in mach absolute time units, sys/resource.h:406-408), which exit() runs after everything else the process does, Julia's writing of the package image
# included (jl_atexit_hook writes it, then exit), and writes it to a file named by its pid. The tree's count is
# their sum, exact for every process that exits by exit(). The library is built by clang into the tree's .wtd at check
# time from COUNTER_C below, its file named by the source's hash, never a checked-in binary; one killed by a signal writes none, and the command fails.
# A protected system binary (taskpolicy, git) has the loader strip DYLD_ variables, so it and what it starts are not
# counted, a few milliseconds in the load. A process reports only when its binary admits inserted libraries: julia's hardened runtime carries
# com.apple.security.cs.allow-dyld-environment-variables, and the plant fails if a julia grandchild goes uncounted.
#
# precedent(linux: perf stat, whose counters are inherited by every process the command starts and summed over the
# tree; gnu: LD_PRELOAD interposition, the dynamic loader's own way to run code in every process of a tree, as
# libfaketime and the sanitizers' runtimes use it, macOS's DYLD_INSERT_LIBRARIES its counterpart). Julia's differs:
# none; this reads the kernel's counter at each process's exit, as perf stat's inherited counters sum.
#
# Its limit: Apple's counters retire fewer instructions for the same work on an efficiency core for some instruction
# mixes (a Julia hash loop, compiled once: 12.2 G on a performance core, 6.2 G on an efficiency core, about half; a C
# multiply-add loop 10.0 G and 10.1 G), so a process read on efficiency cores can read up to half low, the shards' and
# the ratchet's as the load's; dev/check.sh states the band this leaves the judged stages, both ways.

const COUNTER_C = """
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <unistd.h>
__attribute__((destructor)) static void wt_tree_count(void) {
    const char *dir = getenv("WT_TREE_COUNT_DIR");
    if (dir == NULL) return;
    struct rusage_info_v6 ri;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&ri) != 0) return;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    double ns = (double)tb.numer / tb.denom;
    char path[2048];
    snprintf(path, sizeof path, "%s/%d", dir, getpid());
    FILE *f = fopen(path, "w");
    if (f == NULL) return;
    fprintf(f, "%llu %llu %.0f %.0f\\n", (unsigned long long)ri.ri_instructions, (unsigned long long)ri.ri_pinstructions,
            (double)(ri.ri_user_time + ri.ri_system_time) * ns, (double)(ri.ri_user_ptime + ri.ri_system_ptime) * ns);
    fclose(f);
}
"""

# the inserted library, built once per source into the tree's .wtd
function counter_library()::String
    local dir = joinpath(dirname(@__DIR__), ".wtd")
    mkpath(dir)
    local lib = joinpath(dir, "tree_count_$(string(hash(COUNTER_C); base = 16)).dylib")
    isfile(lib) && return lib
    local src = lib * ".c"
    write(src, COUNTER_C)
    run(`clang -O2 -dynamiclib -o $lib $src`)
    return lib
end

# what a tree retired: its instructions and those on performance cores (G), its CPU seconds and those on performance
# cores, and the command's own process's instructions (G)
struct TreeCount
    g::Float64
    pg::Float64
    cpu::Float64
    pcpu::Float64
    root_g::Float64
end

# run `cmd` with every process of its tree reporting its counters at exit; their sums and the process
function tree_instructions(cmd::Cmd)::Tuple{TreeCount,Base.Process}
    local lib = counter_library()
    local counts = mktempdir()
    # run(...; wait = false) connects a command's standard streams to devnull unless they are given: the stage's output
    # (the ratchet's report, the shards' test summaries) goes where this process's goes
    local p = run(pipeline(ignorestatus(addenv(cmd, "DYLD_INSERT_LIBRARIES" => lib, "WT_TREE_COUNT_DIR" => counts));
                           stdin = stdin, stdout = stdout, stderr = stderr); wait = false)
    local root = getpid(p)
    wait(p)
    local sums = zeros(4); local root_g = 0.0
    for f in readdir(counts)
        local v = parse.(Float64, split(strip(read(joinpath(counts, f), String))))
        sums .+= v
        parse(Int, f) == root && (root_g = v[1])
    end
    rm(counts; recursive = true)
    return TreeCount(sums[1] / 1e9, sums[2] / 1e9, sums[3] / 1e9, sums[4] / 1e9, root_g / 1e9), p
end

# a child that spawns a grandchild doing fixed work: counted whole, and inside the band on either core type
function plant()::Vector{String}
    local work = `$(Base.julia_cmd()) --startup-file=no -e 'f(n) = (s = UInt(0); for i in UInt(1):n; s = hash(i, s); end; s); f(UInt(10^8)) == 0 && println(0)'`
    local tree = `$(Base.julia_cmd()) --startup-file=no -e "run($(repr(work)))"`
    local normal = first(tree_instructions(tree))
    # taskpolicy is a protected system binary, so the loader strips DYLD_ variables from it and from what it starts: the
    # counter itself runs under it, and inserts its library below it
    local out = tempname()
    run(`taskpolicy -b $(Base.julia_cmd()) --startup-file=no $(@__FILE__) $out $tree`)
    local background = TreeCount(parse.(Float64, split(strip(read(out, String))))...)
    rm(out)
    local alone = first(tree_instructions(`$(Base.julia_cmd()) --startup-file=no -e 0`))
    local faults = String[]
    # the grandchild's loop is G beyond a bare julia's start: a tree read without it reads no more than that
    normal.g > alone.g + 1 || push!(faults, "the grandchild's work is not counted ($(round(normal.g; digits = 2)) G against a bare start's $(round(alone.g; digits = 2)))")
    # each split lies inside its whole
    for (name, t) in (("default", normal), ("background", background))
        t.pg <= t.g && t.pcpu <= t.cpu * 1.001 || push!(faults, "the $name run's performance-core share exceeds its whole ($(t.pg) of $(t.g) G, $(t.pcpu) of $(t.cpu) s)")
    end
    # a known split: background QoS runs on the efficiency cores alone on Apple silicon, so that run's performance-core
    # share is nil (band: 2% of its CPU seconds, a process's first microseconds before its QoS applies)
    background.pcpu <= 0.02 * background.cpu || push!(faults, "the background run spent $(round(background.pcpu; digits = 3)) of $(round(background.cpu; digits = 2)) CPU-s on performance cores")
    # the two runs' per-core counts are printed, unjudged: which cores a default-QoS run lands on is the scheduler's
    isempty(faults) && println("tree_instructions: the plant reads $(round(normal.g; digits = 2)) G ($(round(normal.pg; digits = 2)) on performance cores) in $(round(normal.cpu; digits = 2)) CPU-s ($(round(normal.pcpu; digits = 2)) on performance cores) at default QoS, and $(round(background.g; digits = 2)) G in $(round(background.cpu; digits = 2)) CPU-s ($(round(background.pcpu; digits = 3)) on performance cores) at background; a bare start $(round(alone.g; digits = 2)) G")
    return faults
end

function main(args::Vector{String})::Int
    if args == ["--plant"]
        local faults = plant()
        isempty(faults) || println(join(faults, "; "))
        return isempty(faults) ? 0 : 1
    end
    length(args) >= 2 || (println(stderr, "usage: julia dev/tree_instructions.jl <out> <command...> | --plant"); return 2)
    local t, p = tree_instructions(Cmd(args[2:end]))
    write(args[1], join(round.((t.g, t.pg, t.cpu, t.pcpu, t.root_g); digits = 3), " "), "\n")
    # a command killed by a signal fails, as a shell reports it
    return p.exitcode != 0 ? p.exitcode : p.termsignal != 0 ? 128 + p.termsignal : 0
end

exit(main(ARGS))
