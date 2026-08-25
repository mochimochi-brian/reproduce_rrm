#!/bin/bash
# Optional process-parallel edge writes for generate_rrm_v11_fast.g.
# Not a new Teramoto version of generate_rrm_v11.g.
# Default GAP_WORKERS=1 is the sequential generate_rrm path.
# GAP_WORKERS=k>1: master writes vertices (and Pechukas); workers write TS shards.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
GAP="${GAP:-gap}"
MEM="${MEM:-12g}"
GAP_WORKERS="${GAP_WORKERS:-1}"
GAPSRC="${ROOT}/generate_rrm_v11_fast.g"

rrm_nvert_from_log() {
    grep '^RRM_NVERT=' "$1" | tail -1 | cut -d= -f2
}

rrm_assert_nverts() {
    local expected="$1"
    local log got
    shift
    for log in "$@"; do
        got="$(rrm_nvert_from_log "$log" || true)"
        if [[ "$got" != "$expected" ]]; then
            echo "nvert mismatch: $log has '${got}', expected '${expected}'" >&2
            return 1
        fi
    done
}

rrm_ts_slice() {
    # 0-based worker w of k, nts items -> lo hi (1-based inclusive; lo>hi if empty)
    local w="$1" k="$2" nts="$3"
    local base rem start size i
    base=$((nts / k))
    rem=$((nts % k))
    start=1
    i=0
    while [[ $i -lt $w ]]; do
        size=$base
        if [[ $i -lt $rem ]]; then
            size=$((base + 1))
        fi
        start=$((start + size))
        i=$((i + 1))
    done
    size=$base
    if [[ $w -lt $rem ]]; then
        size=$((base + 1))
    fi
    if [[ $size -eq 0 ]]; then
        echo "$((nts + 1)) ${nts}"
    else
        echo "${start} $((start + size - 1))"
    fi
}

if [[ "${1:-}" == --assert-nvert ]]; then
    shift
    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 --assert-nvert EXPECTED LOG..." >&2
        exit 1
    fi
    rrm_assert_nverts "$@"
    exit $?
fi

if [[ $# -lt 3 ]]; then
    echo "Usage: $0 VFILE EFILE GFILE" >&2
    exit 1
fi

VFILE="$1"
EFILE="$2"
GFILE="$3"

if ! [[ "$GAP_WORKERS" =~ ^[1-9][0-9]*$ ]]; then
    echo "GAP_WORKERS must be a positive integer (got '$GAP_WORKERS')" >&2
    exit 1
fi

if [[ ! -f "$GAPSRC" ]]; then
    echo "missing $GAPSRC" >&2
    exit 1
fi
if [[ ! -f "$GFILE" ]]; then
    echo "missing $GFILE" >&2
    exit 1
fi

if [[ "$GAP_WORKERS" -eq 1 ]]; then
    "$GAP" -b -q -r -m "$MEM" <<EOF
Read("${GAPSRC}");
Read("${GFILE}");
generate_rrm("${VFILE}","${EFILE}",symc,ur,urt,ss,org_eq,org_ts,true,true);
QUIT;
EOF
    exit 0
fi

mkdir -p "$(dirname -- "$VFILE")" "$(dirname -- "$EFILE")"

master_log="${VFILE}.master.log"
"$GAP" -b -q -r -m "$MEM" <<EOF | tee "$master_log"
Read("${GAPSRC}");
Read("${GFILE}");
generate_rrm_vertices("${VFILE}",symc,ur,urt,ss,org_eq,org_ts,true);
QUIT;
EOF

nvert="$(rrm_nvert_from_log "$master_log" || true)"
nts="$(grep '^RRM_NTS=' "$master_log" | tail -1 | cut -d= -f2 || true)"
if ! [[ "${nvert:-}" =~ ^[0-9]+$ && "${nts:-}" =~ ^[0-9]+$ ]]; then
    echo "master did not print RRM_NVERT/RRM_NTS" >&2
    exit 1
fi

pids=()
worker_logs=()
w=0
while [[ $w -lt $GAP_WORKERS ]]; do
    read -r lo hi < <(rrm_ts_slice "$w" "$GAP_WORKERS" "$nts")
    shard="${EFILE}.part.${w}"
    wlog="${EFILE}.part.${w}.log"
    worker_logs+=("$wlog")
    echo "=== worker ${w} TS ${lo}..${hi} ==="
    "$GAP" -b -q -r -m "$MEM" <<EOF >"$wlog" 2>&1 &
Read("${GAPSRC}");
Read("${GFILE}");
generate_rrm_edge_shard("${shard}",${lo},${hi},symc,ur,urt,ss,org_eq,org_ts,true);
QUIT;
EOF
    pids+=($!)
    w=$((w + 1))
done

fail=0
for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
        fail=1
    fi
done
for wlog in "${worker_logs[@]}"; do
    cat "$wlog"
done
if [[ "$fail" -ne 0 ]]; then
    echo "a GAP worker failed" >&2
    exit 1
fi

rrm_assert_nverts "$nvert" "${worker_logs[@]}"

: > "$EFILE"
w=0
while [[ $w -lt $GAP_WORKERS ]]; do
    part="${EFILE}.part.${w}"
    if [[ ! -f "$part" ]]; then
        echo "missing shard $part" >&2
        exit 1
    fi
    cat "$part" >> "$EFILE"
    w=$((w + 1))
done
