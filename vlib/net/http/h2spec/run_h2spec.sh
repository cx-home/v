#!/usr/bin/env bash
# run_h2spec.sh — run the h2spec HTTP/2 conformance suite against the net.http
# HTTP/2 server and gate on a known-failures baseline.
#
# h2spec (https://github.com/summerwind/h2spec) is the reference RFC 9113 / 7541
# conformance tester. It connects as a client and runs ~146 cases. This harness:
#   1. builds the V h2spec target server (h2spec_server.v),
#   2. starts it on a free port (TLS + ALPN h2),
#   3. runs a PINNED h2spec binary against it,
#   4. compares the set of FAILED case IDs against h2spec_expected_failures.txt,
#   5. fails on a regression (a case that newly fails, or a recorded failure that
#      now passes). The baseline is currently EMPTY (the server passes all 146
#      h2spec cases as of vlang/v#27627), so today ANY h2spec failure fails the
#      gate; the regression-vs-baseline mechanism stays in place so a future gap
#      can be re-baselined without breaking CI for unrelated work.
#
# h2spec is NOT installed here. Provide it via $H2SPEC_BIN or on PATH; CI fetches
# a pinned release (see .github/workflows/h2spec.yml). This script never runs
# `go install` — the version must be pinned and reproducible.
#
# Env:
#   VEXE           path to the V compiler (default: ./v then ./vnew)
#   H2SPEC_BIN     path to the h2spec binary (default: h2spec on PATH)
#   H2SPEC_PORT    port for the target server (default: 18443)
#   H2SPEC_TIMEOUT h2spec per-case timeout, seconds (default: 5). Several h2spec
#                  cases wait for the server's GOAWAY/close and FLAKE at h2spec's
#                  2s default under load; 5s is comfortably stable here. Raise it
#                  if a timing case still flakes on a slow runner.
#   VFLAGS_CC      extra V flags, e.g. '-cc gcc' (mbedtls needs a real C compiler)

set -uo pipefail
orig_pwd="$(pwd)" # the caller's cwd, captured BEFORE we cd into the script dir
cd "$(dirname "$0")"
here="$(pwd)"
repo_root="$(cd ../../../.. && pwd)"

# resolve a caller-supplied path argument: an absolute path or a bare command name
# (PATH lookup, e.g. "h2spec") is used as-is; a relative path is resolved against
# the caller's original cwd, since we cd'd into the script dir above. Without this,
# a documented value like `VEXE=./vnew` (relative to the repo root) would wrongly
# resolve to vlib/net/http/h2spec/vnew and the build would fail. (Codex P1/P3.)
resolve_path() {
    case "$1" in
        /*) printf '%s' "$1" ;;            # absolute path
        */*) printf '%s' "$orig_pwd/$1" ;; # relative path containing a slash
        *) printf '%s' "$1" ;;             # bare name -> PATH lookup
    esac
}

VEXE="${VEXE:-}"
if [ -z "$VEXE" ]; then
    if [ -x "$repo_root/v" ]; then VEXE="$repo_root/v"; elif [ -x "$repo_root/vnew" ]; then VEXE="$repo_root/vnew"; else VEXE="v"; fi
else
    VEXE="$(resolve_path "$VEXE")"
fi
H2SPEC_BIN="$(resolve_path "${H2SPEC_BIN:-h2spec}")"
PORT="${H2SPEC_PORT:-18443}"
TIMEOUT="${H2SPEC_TIMEOUT:-5}"
SERVER_BIN="$here/h2spec_server.bin"
EXPECTED="$here/h2spec_expected_failures.txt"

if ! command -v "$H2SPEC_BIN" >/dev/null 2>&1 && [ ! -x "$H2SPEC_BIN" ]; then
    echo "ERROR: h2spec not found (set H2SPEC_BIN or put it on PATH; CI fetches a pinned release)." >&2
    exit 2
fi

echo "==> building h2spec target server with $VEXE ${VFLAGS_CC:-}"
# shellcheck disable=SC2086
"$VEXE" ${VFLAGS_CC:-} -o "$SERVER_BIN" "$here/h2spec_server.v" || { echo "build failed" >&2; exit 1; }

cleanup() { [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null; rm -f "$SERVER_BIN"; }
trap cleanup EXIT

echo "==> starting target on 127.0.0.1:$PORT"
H2SPEC_PORT="$PORT" "$SERVER_BIN" &
SRV_PID=$!

# Wait for the port to accept connections (up to ~10s).
for _ in $(seq 1 100); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then exec 3>&- 3<&-; break; fi
    kill -0 "$SRV_PID" 2>/dev/null || { echo "server exited early" >&2; exit 1; }
    sleep 0.1
done

echo "==> running h2spec (TLS, insecure cert OK)"
# -t TLS, -k skip cert verification (self-signed). Parse the JUnit XML report —
# its <testcase classname="..." name="..."> identifiers are h2spec's stable
# contract, unlike the pretty console output. A failing case has a <failure>
# (or <error>) child; we use "classname :: name" as the stable case ID.
report_xml="$here/h2spec_report.xml"
"$H2SPEC_BIN" -t -k -h 127.0.0.1 -p "$PORT" --timeout "$TIMEOUT" --junit-report "$report_xml" 2>&1 | tail -40 || true
if [ ! -s "$report_xml" ]; then
    echo "ERROR: h2spec produced no JUnit report ($report_xml); check the flags/version." >&2
    exit 2
fi
# One <testcase ...> ... </testcase> per line is not guaranteed, so track state.
awk '
    /<testcase /{ pkg=""; cls=""; fail=0
        if (match($0, /package="[^"]*"/))   { pkg=substr($0,RSTART+9, RLENGTH-10) }
        if (match($0, /classname="[^"]*"/)) { cls=substr($0,RSTART+11,RLENGTH-12) }
        if ($0 ~ /<failure|<error/) fail=1 }
    /<failure|<error/{ fail=1 }
    /<\/testcase>/{ if (pkg!="" && fail) print pkg " :: " cls; pkg=""; cls=""; fail=0 }
' "$report_xml" | sed 's/&#34;/"/g; s/&quot;/"/g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g' \
    | sort -u > "$here/h2spec_failed_now.txt"

grep -vE '^\s*#|^\s*$' "$EXPECTED" 2>/dev/null | sort -u > "$here/h2spec_expected.norm.txt" || true

new_failures="$(comm -23 "$here/h2spec_failed_now.txt" "$here/h2spec_expected.norm.txt" | grep -vE '^\s*$' || true)"
now_passing="$(comm -13 "$here/h2spec_failed_now.txt" "$here/h2spec_expected.norm.txt" | grep -vE '^\s*$' || true)"

rc=0
if [ -n "$new_failures" ]; then
    echo "::error:: h2spec REGRESSION — these cases newly fail:" >&2
    echo "$new_failures" >&2
    rc=1
fi
if [ -n "$now_passing" ]; then
    # Fail too (not just warn): a recorded failure that now passes must be removed
    # from the baseline, otherwise the gate keeps allowing that case and a later
    # PR can reintroduce the failure unnoticed. (Codex P2.) All 146 cases are
    # deterministic at H2SPEC_TIMEOUT=5 (baseline is empty as of #27627), so this
    # does not flap.
    echo "::error:: these recorded failures now PASS — remove them from h2spec_expected_failures.txt to keep the gate honest:" >&2
    echo "$now_passing" >&2
    rc=1
fi
[ "$rc" -eq 0 ] && echo "==> h2spec: no regressions vs baseline"

# cx-home/v#35 DIAGNOSTIC (fix/plat-v35-diag only, never merged): does http2/6.9.2/2's
# 'tls: DialWithDialer timed out' need the earlier cases (accumulation: workers held,
# a long collection) or does it fail alone? Fresh server per pass; established
# connections to the server sampled every 0.25 s; h2spec lines timestamped.
if [ "${H2SPEC_DIAG:-0}" = "1" ]; then
    kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=''
    "$VEXE" ${VFLAGS_CC:-} -o "$SERVER_BIN" "$here/h2spec_server.v" || exit 1
    dport=$((PORT + 10))
    diag_pass() { # <label> <vjobs> <h2spec args...>
        local label=$1 vj=$2; shift 2
        dport=$((dport + 1))
        echo "==== DIAG $label (VJOBS=$vj, port $dport) $(date -u +%T)"
        VJOBS=$vj H2SPEC_PORT="$dport" "$SERVER_BIN" > "$here/diag_$label.srv" 2>&1 &
        local sp=$!
        for _ in $(seq 1 100); do (exec 3<>"/dev/tcp/127.0.0.1/$dport") 2>/dev/null && { exec 3>&- 3<&-; break; }; sleep 0.1; done
        ( while kill -0 $sp 2>/dev/null; do echo "$(date -u +%T.%N | cut -c1-12) est=$(ss -Htn state established "( sport = :$dport )" | wc -l) synrecv=$(ss -Htn state syn-recv "( sport = :$dport )" | wc -l) cpu=$(ps -o %cpu= -p $sp) thr=$(ls /proc/$sp/task | wc -l)"; sleep 0.25; done ) > "$here/diag_$label.ss" &
        local smp=$!
        "$H2SPEC_BIN" -t -k -h 127.0.0.1 -p "$dport" --timeout "$TIMEOUT" "$@" 2>&1 | while IFS= read -r l; do echo "$(date -u +%T.%N | cut -c1-12) $l"; done > "$here/diag_$label.out"
        grep -nE '×|Error|Tests|failed' "$here/diag_$label.out" | head -20
        local t; t=$(grep -m1 -n 'DialWithDialer' "$here/diag_$label.out" | cut -c1-40)
        if [ -n "$t" ]; then
            echo "-- context (h2spec):"; grep -B14 -A3 -m1 'DialWithDialer' "$here/diag_$label.out"
            ts=$(grep -m1 'DialWithDialer' "$here/diag_$label.out" | cut -c1-8)
            echo "-- sampler around $ts:"; grep -B40 -A8 -m1 "^$ts" "$here/diag_$label.ss" | head -60
        fi
        echo "-- server stderr tail:"; tail -5 "$here/diag_$label.srv"
        kill $sp 2>/dev/null; wait $sp 2>/dev/null; kill $smp 2>/dev/null
    }
    diag_pass full4 4
    diag_pass full64 64
    diag_pass only692 4 http2/6.9.2
    diag_pass sect69 4 http2/6.9
    diag_pass sect6 4 http2/6
fi
exit "$rc"
