#!/bin/sh
set +e
cc -O1 -o /tmp/fixed diag/fixed.c && /tmp/fixed
sysctl vm.pmap.pg_ps_enabled
exit 0
