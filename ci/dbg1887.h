// DEBUG cx-private#1887 (not for merge): report the faulting address and the
// process map when a tcc-built threaded vgc program faults on FreeBSD.
#include <signal.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
static void dbg1887_h(int sig, siginfo_t* si, void* uc) {
    (void)uc;
    char buf[160];
    int n = snprintf(buf, sizeof buf, "DBG1887 sig=%d addr=%p thread=%p\n", sig, si->si_addr, (void*)pthread_self());
    write(2, buf, n);
    char cmd[80];
    snprintf(cmd, sizeof cmd, "procstat -v %d 1>&2; procstat -t %d 1>&2", (int)getpid(), (int)getpid());
    system(cmd);
    _exit(77);
}
static void dbg1887_install(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = dbg1887_h;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &sa, 0);
    sigaction(SIGBUS, &sa, 0);
}
