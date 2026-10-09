#!/bin/sh
# diag (cx-home/v#17) on FreeBSD: mt_sound default and -d vgc_concurrent, watched (RSS sampled every second, killed past 2.5 GB or 200 s)
set +e
cat > /tmp/off.c <<'C'
#include <stdio.h>
#include <stddef.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/user.h>
int main(void) { printf("kinfo_proc size=%zu ki_rssize_off=%zu ki_size_off=%zu ki_groups_off=%zu KI_NGROUPS=%d\n", sizeof(struct kinfo_proc), offsetof(struct kinfo_proc, ki_rssize), offsetof(struct kinfo_proc, ki_size), offsetof(struct kinfo_proc, ki_groups), KI_NGROUPS); return 0; }
C
cc -o /tmp/off /tmp/off.c && /tmp/off
./v -gc e -cc cc -d vgc_concurrent -o /tmp/mtc bench/parallel-alloc/concurrent_mt_sound/mt_sound.v
./v -gc e -cc cc -o /tmp/mtd bench/parallel-alloc/concurrent_mt_sound/mt_sound.v
for b in mtd mtc; do for t in 8 16; do
  echo "=== $b T=$t $(date -u +%H:%M:%S)"
  VGC_GCTRACE=1 T=$t STEPS=20000 /tmp/$b > /tmp/m.out 2>&1 &
  pid=$!
  s=0; maxkb=0; killed=no
  while kill -0 $pid 2>/dev/null; do
    kb=$(ps -o rss= -p $pid 2>/dev/null | tr -d ' '); kb=${kb:-0}
    [ "$kb" -gt "$maxkb" ] && maxkb=$kb
    if [ $((s % 5)) -eq 0 ]; then echo "  t=${s}s rss=${kb}KB cpu=$(ps -o time= -p $pid 2>/dev/null) gclines=$(grep -c '^\[gc' /tmp/m.out) acd=$(grep -c 'acd' /tmp/m.out)"; fi
    if [ "$kb" -gt 2500000 ] || [ $s -gt 200 ]; then kill -9 $pid; killed=yes; fi
    sleep 1; s=$((s+1))
  done
  wait $pid; rc=$?
  echo "  rc=$rc killed=$killed maxrss=${maxkb}KB secs=$s"
  grep 'mt_sound' /tmp/m.out
  grep '^\[gc' /tmp/m.out | head -2; grep '^\[gc' /tmp/m.out | tail -4
  grep -v '^\[gc' /tmp/m.out | grep -v mt_sound | sort | uniq -c | sort -rn | head -6
done; done
exit 0
