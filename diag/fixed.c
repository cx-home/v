// diag (cx-home/v#17): does a MAP_FIXED replace of a SUB-range of a touched anonymous region drop RSS on FreeBSD?
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/user.h>
static long rss_kb(void) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    struct kinfo_proc kp; size_t len = sizeof kp;
    if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0) return -1;
    return (long)kp.ki_rssize * (getpagesize() / 1024);
}
static char* region(size_t n) { char* p = mmap(NULL, n, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON, -1, 0); for (size_t i = 0; i < n; i += 4096) p[i] = 1; return p; }
static void fixed(char* p, size_t n) { if (mmap(p, n, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON|MAP_FIXED, -1, 0) == MAP_FAILED) perror("mmap fixed"); }
int main(void) {
    size_t M = 1024 * 1024;
    long r0 = rss_kb();
    char* a = region(256 * M); long r1 = rss_kb();
    fixed(a + 96 * M, 64 * M); long r2 = rss_kb();
    printf("A middle-64MB-of-256MB: base=%ld touched=%ld after=%ld (want ~%ld)\n", r0, r1, r2, r1 - 65536);
    munmap(a, 256 * M);
    char* b = region(256 * M); long s1 = rss_kb();
    for (size_t off = 0; off < 256 * M; off += 32 * 1024) fixed(b + off, 8 * 1024);  // 8 KB of every 32 KB = 64 MB
    long s2 = rss_kb();
    printf("B 8KB-pieces (64MB total) of 256MB: touched=%ld after=%ld (want ~%ld)\n", s1, s2, s1 - 65536);
    for (size_t off = 0; off < 256 * M; off += 32 * 1024) madvise(b + off + 8192, 8 * 1024, MADV_FREE);
    long s3 = rss_kb();
    printf("B' MADV_FREE another 64MB: after=%ld\n", s3);
    munmap(b, 256 * M);
    char* c = region(256 * M); long t1 = rss_kb();
    for (size_t off = 0; off < 256 * M; off += 2 * M) fixed(c + off + 4096, 2 * M - 8192); // inner of every 2 MB (superpage-sized) block
    long t2 = rss_kb();
    printf("C inner-of-each-2MB (~254MB): touched=%ld after=%ld\n", t1, t2);
    return 0;
}
