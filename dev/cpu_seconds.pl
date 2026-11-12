#!/usr/bin/perl
# dev/cpu_seconds.pl — the one reader of a process's CPU seconds (test/dart_limit.jl's watchdog, dev/corpus.sh's shards).
# The watchdog's one reading, `cpu`: process $_[0]'s user and system CPU seconds, undef once it is gone. On macOS the
# kernel's own rusage of the process, read as libproc's proc_pid_rusage(pid, RUSAGE_INFO_V0) reads it (xnu
# libsyscall/wrappers/libproc/libproc.c: __proc_info(PROC_INFO_CALL_PIDRUSAGE = 9, pid, flavor, 0, buffer, 0), the
# syscall SYS_proc_info = 336 of <sys/syscall.h>; rusage_info_v0 of <sys/resource.h>: ri_user_time and ri_system_time
# after the 16-byte ri_uuid, in Mach absolute time units, hw.tbfrequency of them a second: 24 MHz on Apple silicon,
# where one is 125/3 ns, 10^9 on Intel). Any process may read it of a process of its own user, and a sandboxed one of a
# process in its own sandbox (`process-info*`, dev/climb/door.py's profiles); macOS's `ps -o time=` reads CPU time
# through task_for_pid and task_info instead, which only root may call, so the setuid /bin/ps reads it and a ps with no
# setuid bit reads 0:00.00 for every process: so it read under the climb's door, where a sandboxed process may exec
# no setuid program and each build user's PATH has such a ps first (dev/climb/HILL.md "No setuid program in a
# profile"), and no CPU limit ever fired there (probed, 2026-11-09). Precedent: psutil's Process.cpu_times on macOS
# (_psutil_osx, 5.9.8: proc_pidinfo's PROC_PIDTASKINFO, the same kernel times, scaled by mach_timebase_info), which
# reads a busy process of its user as /bin/ps does (probed: 1.51 CPU-s, ps 0:01.52). How it differs: perl has no
# foreign call, so it makes libproc's call by syscall, and reads the Mach unit from sysctl, not mach_timebase_info.
# Elsewhere (Linux, CI's runners) `ps -o time=`, procps reading /proc/<pid>/stat, which any user may read.
# A failed read other than "no such process" stops the watchdog, named on stderr, never read as 0 (D9)
#
#   perl dev/cpu_seconds.pl <pid>...   the CPU seconds the live ones have used, summed, an integer (a gone one adds 0)
#   do '<this file>'                    its sub cpu(pid), as test/dart_limit.jl's watchdog loads it ($main::WHO names the caller)
use strict; use warnings;
my $what = do { no warnings 'once'; $main::WHO } // 'dev/cpu_seconds.pl';
my $hz = $^O eq 'darwin' ? 0 + `/usr/sbin/sysctl -n hw.tbfrequency` : 0;
$^O ne 'darwin' || $hz > 0 or die "$what reads no hw.tbfrequency: no CPU time to judge by\n";
sub cpu {
  if ($^O eq 'darwin') {
    my $ri = "\0" x 512;
    if (syscall(336, 9, 0 + $_[0], 0, 0, $ri, 0) != 0) {
      return undef if $!{ESRCH};
      die "$what reads no CPU time of process $_[0]: $!\n";
    }
    my ($user, $system) = unpack('Q<Q<', substr($ri, 16, 16));
    return ($user + $system) / $hz;
  }
  my $t = `ps -o time= -p $_[0]`; $t =~ s/\s//g; return undef if $t eq ''; my $s = 0; $s = $s * 60 + $_ for split(/:/, $t); return $s;
}
unless (caller) { my $t = 0; for my $p (@ARGV) { my $c = cpu($p); $t += $c if defined $c; } printf "%d\n", $t; }
1;
