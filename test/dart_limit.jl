# test/src/dart_tests.jl's hard limit on each case, its watchdog and the cut it makes, a file of its own so a plant can
# run it in a child julia (a cut that kills the process it judges) without loading the corpus; dart_tests.jl and each
# plant's child include it once per process
isdefined(Main, :_wt_cpu_seconds) || Base.include(Main, joinpath(@__DIR__, "instructions.jl"))
# each case's hard limit (no hang is allowed, Dale 2026-10-28; D17): intent, a case's compile, or the reading of its
# answer, returns in seconds; band, DART_CASE_LIMIT CPU seconds of the julia process, a watchdog process then
# interrupting it (SIGINT each second, taken at Julia's next safepoint) and the case failing by name, "past its
# 120-CPU-s hard limit: <group>/<case> compiling <method>", the process going on to the next case; before it a hang
# held a whole shard to dev/corpus.sh's limit and named only its method (355c70e5, 2026-10-29). The watchdog is one
# process per case, killed when the case returns.
# Julia cannot be relied on to take the interrupt: an allocating loop, or a compile (inference defers it to its end),
# may reach every safepoint inside a region that defers it, and a forced throw (^C^C) can crash the process; on
# 665146f1 every one of the corpus's four shards was killed so, and each kill lost its shard's verdicts (2026-11-01).
# So DART_CASE_GRACE seconds on, the watchdog names the case on stderr, appends it to WT_DART_KILLED and kills the
# process, which dev/corpus_shard.sh recovers as ReTestItems.jl recovers a test item past its timeout (that file names
# the precedent and how WT differs): the next attempt fails each killed case by name without compiling it again.
# Each limit is judged by CPU seconds, never the wall clock, which at background QoS measured the scheduler: a shard ran
# at 20 to 36% of an efficiency core beside the lanes (6732d4a6: CPU-s 243 to 434 in its 1200-s run), so a wall limit
# killed starvation as a hang. The figures: a case's and the warm-up's, the julia process's CPU time (the watchdog's
# `cpu`, read four times a second); a shard's in dev/corpus.sh, its finished attempts' children's time
# from bash's `times` in dev/corpus_shard.sh, plus its live processes' from ps. The numbers are as they were in wall
# seconds, now CPU seconds. A wall backstop stands only against a true hang, a process that accrues no CPU: each one
# is its CPU limit over 0.2, the lowest share measured (shard 2 on 6732d4a6, 243 CPU-s in 1200 s of wall), so at that
# share the CPU limit fires first: 120 / 0.2 = 600 s a case, 300 / 0.2 = 1500 s the warm-up, 1200 / 0.2 = 6000 s a run.
# Precedent: POSIX's RLIMIT_CPU (setrlimit), a process's CPU seconds bounded, with a wall watchdog beside it, as
# ReTestItems.jl's timeout is (src/ReTestItems.jl:409, v1.9.0 085999065a4c, a Timer on the wall clock).
# The watchdog starts before the case's code is inferred: _dart_limited does not specialize on it, so Julia infers and
# compiles the call inside the watchdog's time. Specialized, the warm-up's whole WasmTarget call graph was inferred
# before its watchdog started, and four warm-ups of 365 to 371 s passed a 300-s limit (6732d4a6)
const DART_CASE_LIMIT = 120
const DART_CASE_WALL = 600
const DART_CASE_GRACE = 5
Base.exit_on_sigint(false)
struct _DartPastLimit
    why::String
end
# The watchdog's one reading, `cpu`: process $_[0]'s user and system CPU seconds, undef once it is gone, from
# dev/cpu_seconds.pl, the one CPU reader (the kernel's rusage of the process on macOS: read there why `ps -o time=`
# reads 0 under the climb's door), which dev/corpus.sh's shards read too
const _CPU_PL = joinpath(dirname(@__DIR__), "dev", "cpu_seconds.pl")
const _DART_WATCHDOG = raw"""
my ($limit, $wall, $grace, $pid, $what, $killed) = @ARGV;
$main::WHO = "dart_tests.jl: the watchdog of $what";
do $ENV{WT_CPU_PL} or die "dart_tests.jl: the CPU reader $ENV{WT_CPU_PL}: " . ($@ || $!) . "\n";
my ($c0, $t0, $why) = (cpu($pid), time, '');
defined($c0) or exit 0;
while (1) {
  select(undef, undef, undef, 0.25);
  my $c = cpu($pid); defined($c) or exit 0;
  if ($c - $c0 >= $limit) { $why = "past its $limit-CPU-s hard limit"; last; }
  if (time - $t0 >= $wall) { $why = "past its $wall-s wall backstop, at " . int($c - $c0) . " CPU-s"; last; }
}
kill('INT', $pid);
for (1 .. $grace) { sleep(1); kill(0, $pid) or exit 0; kill('INT', $pid); }
print STDERR "dart_tests.jl: $what is $why and took no interrupt in $grace s: the process is killed\n";
if (defined($killed) && length($killed)) { open(my $fh, '>>', $killed) or die "$killed: $!"; print $fh "$what is $why\n"; close($fh); }
kill('KILL', $pid);
"""
# the shard's record of the cases its watchdogs killed (dev/corpus_shard.sh), which each kill appends to
const _DART_KILLED_FILE = get(ENV, "WT_DART_KILLED", "")
# a killed case's failure, located by the watchdog's own line, `<what> is past its <limit>`
_dart_killed(line::AbstractString)::_DartPastLimit = _DartPastLimit("took no interrupt, and its process was killed: $line")
function _dart_limited(@nospecialize(f::Function), what::String; limit::Real = DART_CASE_LIMIT, wall::Real = DART_CASE_WALL,
                       grace::Integer = DART_CASE_GRACE)
    # past `limit` CPU-s or `wall` s: SIGINT, then once a second for `grace` seconds; then the case named on stderr and
    # the process killed
    local c0, t0 = _wt_cpu_seconds(), time()
    local dog = run(pipeline(addenv(`perl -e $(_DART_WATCHDOG) $limit $wall $grace $(getpid()) $what $(_DART_KILLED_FILE)`, "WT_CPU_PL" => _CPU_PL); stdout = devnull, stderr = stderr); wait = false)
    try
        return f()   # a dynamic call: `f` is inferred and compiled here, in the watchdog's time
    catch e
        e isa InterruptException || rethrow()
        local cpu = _wt_cpu_seconds() - c0
        return (_DartPastLimit(cpu >= limit ? "past its $(limit)-CPU-s hard limit: $what" :
                               "past its $(wall)-s wall backstop, at $(round(Int, cpu)) CPU-s: $what"), UInt8[])
    finally
        process_running(dog) && kill(dog)
    end
end
