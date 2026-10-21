#include <mach-o/dyld.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* The native code directory contains this launcher only. Managed PE assemblies
 * and their adjacent runtime live in Resources and remain replaceable files.
 * execv preserves stdin, cancellation PID ownership, and the host's exact argv. */
int main(int argc, char **argv) {
    (void)argc;
    char executable[PATH_MAX], resolved[PATH_MAX], target[PATH_MAX];
    uint32_t size = sizeof executable;
    if (_NSGetExecutablePath(executable, &size) != 0 || !realpath(executable, resolved)) return 70;
    for (int i = 0; i < 3; i++) {
        char *slash = strrchr(resolved, '/');
        if (!slash || slash == resolved) return 70;
        *slash = '\0';
    }
    int length = snprintf(target, sizeof target, "%s/Resources/SteamContentRuntime/GlimmerSteamContent", resolved);
    if (length < 0 || (size_t)length >= sizeof target) return 70;
    argv[0] = target;
    execv(target, argv);
    fputs("Steam content runtime could not start.\n", stderr);
    return 70;
}
