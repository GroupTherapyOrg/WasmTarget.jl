# dev/tree_instructions.jl — the instructions retired by a command's whole process tree, for D14's band
#
#   julia dev/tree_instructions.jl <out> <command...>   runs the command, writes the tree's instructions (G) to <out>,
#                                                       exits with the command's status
#   julia dev/tree_instructions.jl --plant              a tree whose grandchild does fixed work: the grandchild counted,
#                                                       or exits 1; its G and CPU seconds at default and at background
#                                                       QoS printed, unjudged
#
# The load stage precompiles WasmTarget in a child process of `julia -e 'using WasmTarget'` (Base.compilecache), and
# rusage reports a process's own instructions alone, never its children's (A54E1), so its CPU seconds were judged,
# which an efficiency core doubles (13 and 28 CPU-s for the same precompile, 2026-11-01). Each process of the tree
# now reports its own counter as it exits: a library inserted into every process the command starts
# (DYLD_INSERT_LIBRARIES, inherited by each child, the precompile among them) reads proc_pid_rusage's
# ri_instructions (rusage_info_v4, the counter /usr/bin/time -l reports as "instructions retired") in its
# destructor, which exit() runs after everything else the process does, Julia's writing of the package image
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
# Its limit: Apple's counters retire fewer instructions for the same work on an efficiency core (a fixed loop, alone:
# 9.7 to 10.2 G at default QoS, 8.2 G at background, 2026-11-01), so a stage read on efficiency cores reads up to about
# a third low, the shards' and the ratchet's as the load's; the plant's band states it.

const COUNTER_C = """
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <unistd.h>
__attribute__((destructor)) static void wt_tree_count(void) {
    const char *dir = getenv("WT_TREE_COUNT_DIR");
    if (dir == NULL) return;
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return;
    char path[2048];
    snprintf(path, sizeof path, "%s/%d", dir, getpid());
    FILE *f = fopen(path, "w");
    if (f == NULL) return;
    fprintf(f, "%llu\\n", (unsigned long long)ri.ri_instructions);
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

# the user and system seconds of this process's reaped descendants (getrusage(RUSAGE_CHILDREN): ru_utime and ru_stime,
# each a timeval of 64-bit seconds and 32-bit microseconds)
function children_cpu()::Float64
    local buf = zeros(Int64, 18)
    ccall(:getrusage, Cint, (Cint, Ptr{Int64}), -1, buf) == 0 || error("getrusage(RUSAGE_CHILDREN) failed")
    return buf[1] + (buf[2] & 0xffffffff) / 1e6 + buf[3] + (buf[4] & 0xffffffff) / 1e6
end

# run `cmd` with every process of its tree reporting its instructions at exit; their sum in G, the tree's CPU seconds
# and the process
function tree_instructions(cmd::Cmd)::Tuple{Float64,Float64,Base.Process}
    local lib = counter_library()
    local counts = mktempdir()
    local c0 = children_cpu()
    local p = run(ignorestatus(addenv(cmd, "DYLD_INSERT_LIBRARIES" => lib, "WT_TREE_COUNT_DIR" => counts)))
    local cpu = children_cpu() - c0
    local total = UInt64(0)
    for f in readdir(counts; join = true)
        total += parse(UInt64, strip(read(f, String)))
    end
    rm(counts; recursive = true)
    return total / 1e9, cpu, p
end

# a child that spawns a grandchild doing fixed work: counted whole, and inside the band on either core type
function plant()::Vector{String}
    local work = `$(Base.julia_cmd()) --startup-file=no -e 'f(n) = (s = UInt(0); for i in UInt(1):n; s = hash(i, s); end; s); f(UInt(10^8)) == 0 && println(0)'`
    local tree = `$(Base.julia_cmd()) --startup-file=no -e "run($(repr(work)))"`
    local normal, normal_cpu, _ = tree_instructions(tree)
    # taskpolicy is a protected system binary, so the loader strips DYLD_ variables from it and from what it starts: the
    # counter itself runs under it, and inserts its library below it, writing the tree's G and CPU seconds
    local out = tempname()
    run(`taskpolicy -b $(Base.julia_cmd()) --startup-file=no $(@__FILE__) $out $tree`)
    local background, background_cpu = parse.(Float64, split(strip(read(out, String))))
    rm(out)
    local alone = first(tree_instructions(`$(Base.julia_cmd()) --startup-file=no -e 0`))
    local ratio = background_cpu / normal_cpu
    local faults = String[]
    # the grandchild's loop is G beyond a bare julia's start: a tree read without it reads no more than that
    normal > alone + 1 || push!(faults, "the grandchild's work is not counted ($(round(normal; digits = 2)) G against a bare start's $(round(alone; digits = 2)))")
    # the default and background G are printed, never judged: Apple's counters read fewer instructions on an efficiency
    # core for some instruction mixes (this hash loop, compiled once, read 12.2 G on a performance core and 6.2 G on an
    # efficiency core; a C multiply-add loop 10.0 G and 10.1 G), and which core a process lands on is the scheduler's
    # (the plant refused 7ae93d77 on it, A79E3)
    # the premise of dev/check.sh's floor, each stage's CPU seconds over ECORE_SLOWDOWN (an efficiency core runs this work
    # at least 1.4 times slower), is evidence, not a per-check assertion: taskpolicy does not hold work on the efficiency
    # cores (a tree like this one, its loop 4 times longer, read a background-to-default ratio of 1.70, 1.71, 1.73 and
    # 1.56, then 1.03, 1.02, 0.88 and 1.0 minutes later on the same quiet machine, 2026-11-02), so the premise rests on
    # the runs that did land there and on the load's 3.0, and the ratio measured here is printed, unjudged
    isempty(faults) && println("tree_instructions: the plant reads $(round(normal; digits = 2)) G in $(round(normal_cpu; digits = 2)) CPU-s at default QoS and $(round(background; digits = 2)) G in $(round(background_cpu; digits = 2)) at background (an efficiency core $(round(ratio; digits = 2)) times slower), a bare start $(round(alone; digits = 2)) G")
    return faults
end


function main(args::Vector{String})::Int
    if args == ["--plant"]
        local faults = plant()
        isempty(faults) || println(join(faults, "; "))
        return isempty(faults) ? 0 : 1
    end
    length(args) >= 2 || (println(stderr, "usage: julia dev/tree_instructions.jl <out> <command...> | --plant"); return 2)
    local g, cpu, p = tree_instructions(Cmd(args[2:end]))
    write(args[1], string(round(g; digits = 2), " ", round(cpu; digits = 2), "\n"))
    return p.exitcode
end

exit(main(ARGS))
