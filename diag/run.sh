#!/bin/sh
set +e
mkdir -p /tmp/pa && cp -R bench/parallel-alloc/. /tmp/pa/ 2>/dev/null
rm -f bench/parallel-alloc/vgc_concurrent_cached_span_test.v
echo "=== bench/parallel-alloc minus vgc_concurrent_cached_span (default)"
./v test bench/parallel-alloc 2>&1 | grep -E "^ *(OK|FAIL)|Summary|assert|Left|Right|bad=" | sed 's/ C: *[0-9.]* ms, R: */ /'
echo "=== same, markers forced"
VGC_MARK_PAR_MIN_US=0 ./v test bench/parallel-alloc 2>&1 | grep -E "^ *FAIL|Summary|assert|Left|Right"
echo "=== vlib/runtime"
./v test vlib/runtime 2>&1 | grep -E "FAIL|Summary"
exit 0
