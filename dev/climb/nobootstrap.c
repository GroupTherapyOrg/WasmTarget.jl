/* dev/climb/nobootstrap.c — nobootstrap argv...: exec argv with the task's bootstrap port null, so neither it nor
   any child can reach launchd or any Mach service (dev/climb/door.py's argv runs every build user's process through
   it). sudo keeps the caller's Mach bootstrap, and through Dale's a build user ran a job as Dale (probed 2026-11-09);
   a null port cannot be turned back into one without another task's port, which a build user cannot get.
   Precedent: launchd's own `launchctl asuser`, which moves a process into its user's bootstrap; it needs root, and
   the door has none, so the port is dropped instead. */
#include <mach/mach.h>
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 2) return 64;
    kern_return_t kr = task_set_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) { fprintf(stderr, "nobootstrap: task_set_special_port: %d\n", kr); return 70; }
    execv(argv[1], argv + 1);
    perror("nobootstrap: execv"); return 127;
}
