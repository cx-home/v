// vgc_zero_global.h — mincore(2) over the whole pages of a range: how many are
// in core (cx-home/cx-core-code#268; vgc_zero_global_resident_test.v).
#include <stdint.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

static int vgc_zg_resident(void *p, size_t n) {
	uintptr_t pg = (uintptr_t)sysconf(_SC_PAGESIZE);
	uintptr_t lo = ((uintptr_t)p + pg - 1) & ~(pg - 1);
	uintptr_t hi = ((uintptr_t)p + n) & ~(pg - 1);
	if (hi <= lo) {
		return 0;
	}
	size_t np = (size_t)((hi - lo) / pg);
#ifdef __APPLE__
	char *v = malloc(np);
#else
	unsigned char *v = malloc(np);
#endif
	if (v == NULL || mincore((void *)lo, (size_t)(hi - lo), v) != 0) {
		free(v);
		return -1;
	}
	int r = 0;
	for (size_t i = 0; i < np; i++) {
		if (v[i] & 1) {
			r++;
		}
	}
	free(v);
	return r;
}

static int vgc_zg_pages(void *p, size_t n) {
	uintptr_t pg = (uintptr_t)sysconf(_SC_PAGESIZE);
	uintptr_t lo = ((uintptr_t)p + pg - 1) & ~(pg - 1);
	uintptr_t hi = ((uintptr_t)p + n) & ~(pg - 1);
	return hi <= lo ? 0 : (int)((hi - lo) / pg);
}
