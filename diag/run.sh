#!/bin/sh
# diag (cx-home/v#17) on FreeBSD: mt_sound T=16 default, port vs stub (the pre-port header), watched; full GC trace
set +e
S=bench/parallel-alloc/concurrent_mt_sound/mt_sound.v
./v -gc e -cc cc -o /tmp/mt_port $S
cp thirdparty/vgc/vgc_platform.h /tmp/port.h
git show 2af82f3673:thirdparty/vgc/vgc_platform.h > thirdparty/vgc/vgc_platform.h
./v -gc e -cc cc -o /tmp/mt_stub $S
cp /tmp/port.h thirdparty/vgc/vgc_platform.h
run() { # name env...
  name=$1; shift
  echo "=== $name $* $(date -u +%H:%M:%S)"
  env "$@" VGC_GCTRACE=1 STEPS=20000 /tmp/$name > /tmp/m.out 2>&1 &
  pid=$!; s=0; maxkb=0; killed=no
  while kill -0 $pid 2>/dev/null; do
    kb=$(ps -o rss= -p $pid 2>/dev/null | tr -d ' '); kb=${kb:-0}
    [ "$kb" -gt "$maxkb" ] && maxkb=$kb
    echo "  t=${s}s rss=${kb}KB gclines=$(grep -c '^\[gc' /tmp/m.out)"
    if [ "$kb" -gt 2600000 ] || [ $s -gt 120 ]; then kill -9 $pid; killed=yes; fi
    sleep 1; s=$((s+1))
  done
  wait $pid; rc=$?
  echo "  rc=$rc killed=$killed maxrss=${maxkb}KB secs=$s"
  grep 'mt_sound' /tmp/m.out
  grep '^\[gc' /tmp/m.out | head -40
}
echo "=== box $(uname -sm) ncpu=$(getconf _NPROCESSORS_ONLN) pagesize=$(getconf PAGESIZE)"
run mt_stub T=16
run mt_port T=16
run mt_stub T=8
run mt_port T=8
exit 0
