#!/bin/bash
# Optional process-parallel edge writes for generate_rrm_v11_fast.g.
# Not a new Teramoto version of generate_rrm_v11.g.
# Default GAP_WORKERS=1 is the sequential generate_rrm path.
# GAP_WORKERS=k>1: master writes vertices (and Pechukas); workers write TS shards.
# Edge shards are deleted after concat unless RRM_KEEP_SHARDS=1.
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

rrm_active_workers() {
    local k="$1" nts="$2"
    if [[ "$nts" -le 0 ]]; then
        echo 0
    elif [[ "$k" -gt "$nts" ]]; then
        echo "$nts"
    else
        echo "$k"
    fi
}

rrm_gap_string() {
    local s="$1"
    if [[ "$s" == *$'\n'* ]]; then
        echo "path must not contain a newline" >&2
        return 1
    fi
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"\n' "$s"
}

rrm_kill_pids() {
    local pid
    for pid in "$@"; do
        if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
}

rrm_keep_shards() {
    case "${RRM_KEEP_SHARDS:-}" in
        1|true|TRUE) return 0 ;;
        *) return 1 ;;
    esac
}

rrm_rm_numeric_shards() {
    # ${efile}.part.<digits> only. keep_n>0 leaves .part.0 .. .part.(keep_n-1).
    local efile="$1"
    local keep_n="${2:-0}"
    local f n
    for f in "$efile".part.[0-9]*; do
        [[ -f "$f" ]] || continue
        n="${f##*.part.}"
        if [[ "$n" =~ ^[0-9]+$ ]]; then
            if [[ "$keep_n" -le 0 || $((10#$n)) -ge "$keep_n" ]]; then
                rm -f "$f"
            fi
        fi
    done
}

rrm_kill_own_children() {
    local child
    # jobs -p is a builtin and sees the job before $! is assigned. Do not
    # background anything here; that would clobber $! for the caller.
    for child in $(jobs -p); do
        rrm_kill_pids "$child"
    done
}

rrm_after_bg() {
    # Must stay foreground. A background command here would replace $!.
    if [[ "${RRM_TEST_PID_REGISTER_DELAY:-0}" != 0 ]]; then
        sleep "$RRM_TEST_PID_REGISTER_DELAY"
    fi
}

rrm_publish_pair() {
    # These moves only affect this unpublished generation. A failure cannot
    # change the pair addressed by current.
    mv -T -- "$concat_tmp" "$EFILE"
    mv -T -- "$v_stage" "$VFILE"
    if ! rrm_keep_shards; then
        rrm_rm_numeric_shards "$EFILE" 0
    fi
    {
        printf 'format=1\nnvert=%s\nnts=%s\nworkers=%s\n' "$nvert" "$nts" "$active"
        (cd "$run_dir" && sha256sum vertices.dat edges.dat)
    } > "$run_dir/manifest.txt"
    ln -s -- "runs/${run_dir##*/}" "$publish_link"
    # Same-filesystem rename is the sole publication point. Cleanup only removes
    # staging paths and the temporary link, even if a signal arrives just after
    # rename but before the shell executes its next command.
    mv -Tf -- "$publish_link" "$bundle/current"
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

if [[ "${1:-}" == --active-workers ]]; then
    if [[ $# -ne 3 ]]; then
        echo "Usage: $0 --active-workers K NTS" >&2
        exit 1
    fi
    rrm_active_workers "$2" "$3"
    exit 0
fi

if [[ "${1:-}" == --gap-string ]]; then
    if [[ $# -ne 2 ]]; then
        echo "Usage: $0 --gap-string PATH" >&2
        exit 1
    fi
    rrm_gap_string "$2"
    exit $?
fi

if [[ "${1:-}" == --kill-pids ]]; then
    shift
    rrm_kill_pids "$@"
    exit 0
fi

if [[ "${1:-}" == --rm-numeric-shards ]]; then
    if [[ $# -lt 2 || $# -gt 3 ]]; then
        echo "Usage: $0 --rm-numeric-shards EFILE [KEEP_N]" >&2
        exit 1
    fi
    rrm_rm_numeric_shards "$2" "${3:-0}"
    exit 0
fi

bundle=""
if [[ "${1:-}" == --bundle ]]; then
    if [[ $# -ne 3 ]]; then
        echo "Usage: GAP_WORKERS=2 $0 --bundle OUTPUT_DIR GFILE" >&2
        exit 1
    fi
    bundle="$2"
    GFILE="$3"
    if [[ "$GAP_WORKERS" == 1 ]]; then
        echo "--bundle requires GAP_WORKERS>1" >&2
        exit 1
    fi
else
    if [[ $# -ne 3 ]]; then
        echo "Usage: $0 VFILE EFILE GFILE (GAP_WORKERS=1), or --bundle OUTPUT_DIR GFILE (GAP_WORKERS>1)" >&2
        exit 1
    fi
    VFILE="$1"
    EFILE="$2"
    GFILE="$3"
    if [[ "$GAP_WORKERS" != 1 ]]; then
        echo "Parallel output now requires --bundle OUTPUT_DIR GFILE; resolve OUTPUT_DIR/current once to read both files. See README." >&2
        exit 1
    fi
fi

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

gap_src="$(rrm_gap_string "$GAPSRC")"
gap_g="$(rrm_gap_string "$GFILE")"

if [[ "$GAP_WORKERS" -eq 1 ]]; then
    gap_e="$(rrm_gap_string "$EFILE")"
    gap_v="$(rrm_gap_string "$VFILE")"
    "$GAP" -b -q -r -m "$MEM" <<EOF
Read(${gap_src});
Read(${gap_g});
generate_rrm(${gap_v},${gap_e},symc,ur,urt,ss,org_eq,org_ts,true,true);
QUIT;
EOF
    exit 0
fi

if [[ -n "${RRM_KEEP_SHARDS:-}" ]]; then
    case "${RRM_KEEP_SHARDS}" in
        1|true|TRUE) ;;
        *)
            echo "RRM_KEEP_SHARDS must be 1 or true (got '${RRM_KEEP_SHARDS}')" >&2
            exit 1
            ;;
    esac
fi

# Serialize writers to a bundle. Readers do not acquire this lock.
mkdir -p -- "$bundle"
bundle="$(cd -- "$bundle" && pwd -P)"
exec {bundle_lock}>"$bundle/.writer.lock"
if ! flock -n "$bundle_lock"; then
    echo "another writer is using $bundle" >&2
    exit 1
fi
if [[ -e "$bundle/current" && ! -L "$bundle/current" ]]; then
    echo "bundle/current must be a symlink or absent" >&2
    exit 1
fi
if [[ -L "$bundle/runs" ]]; then
    echo "bundle/runs must be an ordinary directory on the bundle filesystem" >&2
    exit 1
fi
mkdir -p -- "$bundle/runs"
if [[ "$(stat -c %d "$bundle/runs")" != "$(stat -c %d "$bundle")" ]]; then
    echo "bundle/runs must be on the bundle filesystem" >&2
    exit 1
fi
run_dir="$(mktemp -d "$bundle/runs/run.XXXXXXXX")"
VFILE="$run_dir/vertices.dat"
EFILE="$run_dir/edges.dat"
publish_link="$run_dir/current.tmp"

v_stage="${VFILE}.staging"
concat_tmp="${EFILE}.concat"
gap_v="$(rrm_gap_string "$v_stage")"
rm -f "$v_stage" "$concat_tmp"
rrm_rm_numeric_shards "$EFILE" 0

master_pid=""
pids=()
rrm_cleanup_workers() {
    rrm_kill_pids "${master_pid:-}" "${pids[@]:-}"
    rrm_kill_own_children
    if [[ -n "${concat_tmp:-}" ]]; then
        rm -f "$concat_tmp"
    fi
    rm -f -- "$v_stage" "$publish_link"
}
rrm_reap_pids() {
    wait 2>/dev/null || true
}
rrm_on_cancel() {
    rrm_cleanup_workers
    rrm_reap_pids
    exit 143
}
# Traps must cover the master GAP as well as workers. A pipeline `| tee`
# would hide the GAP pid, so the master writes a log and we dump it after wait.
# rrm_kill_own_children also reaps children not yet stored in master_pid/pids.
trap rrm_cleanup_workers EXIT
trap rrm_on_cancel INT TERM

master_log="${VFILE}.master.log"
"$GAP" -b -q -r -m "$MEM" <<EOF >"$master_log" 2>&1 &
Read(${gap_src});
Read(${gap_g});
generate_rrm_vertices(${gap_v},symc,ur,urt,ss,org_eq,org_ts,true);
QUIT;
EOF
rrm_after_bg
master_pid=$!
set +e
wait "$master_pid"
master_rc=$?
set -e
master_pid=""
if [[ -f "$master_log" ]]; then
    cat "$master_log" || true
fi
if [[ "$master_rc" -ne 0 ]]; then
    echo "master GAP failed" >&2
    exit 1
fi

nvert="$(rrm_nvert_from_log "$master_log" || true)"
nts="$(grep '^RRM_NTS=' "$master_log" | tail -1 | cut -d= -f2 || true)"
if ! [[ "${nvert:-}" =~ ^[0-9]+$ && "${nts:-}" =~ ^[0-9]+$ ]]; then
    echo "master did not print RRM_NVERT/RRM_NTS" >&2
    exit 1
fi

active="$(rrm_active_workers "$GAP_WORKERS" "$nts")"
if [[ "$active" -eq 0 ]]; then
    if [[ ! -f "$v_stage" ]]; then
        echo "master did not write staged vertices" >&2
        exit 1
    fi
    : > "$concat_tmp"
    rrm_publish_pair
    exit 0
fi

worker_logs=()
w=0
while [[ $w -lt $active ]]; do
    read -r lo hi < <(rrm_ts_slice "$w" "$active" "$nts")
    shard="${EFILE}.part.${w}"
    wlog="${EFILE}.part.${w}.log"
    worker_logs+=("$wlog")
    gap_shard="$(rrm_gap_string "$shard")"
    echo "=== worker ${w} TS ${lo}..${hi} ==="
    rm -f "$shard"
    "$GAP" -b -q -r -m "$MEM" <<EOF >"$wlog" 2>&1 &
Read(${gap_src});
Read(${gap_g});
generate_rrm_edge_shard(${gap_shard},${lo},${hi},symc,ur,urt,ss,org_eq,org_ts,true);
QUIT;
EOF
    rrm_after_bg
    pids+=($!)
    w=$((w + 1))
    if [[ "${RRM_TEST_LAUNCH_DELAY:-0}" != 0 ]]; then
        sleep "$RRM_TEST_LAUNCH_DELAY"
    fi
done

fail=0
left=${#pids[@]}
while [[ $left -gt 0 ]]; do
    if ! wait -n; then
        fail=1
        rrm_cleanup_workers
        rrm_reap_pids
        break
    fi
    left=$((left - 1))
done
pids=()
master_pid=""
for wlog in "${worker_logs[@]}"; do
    cat "$wlog"
done
if [[ "$fail" -ne 0 ]]; then
    echo "a GAP worker failed" >&2
    exit 1
fi

rrm_assert_nverts "$nvert" "${worker_logs[@]}"

: > "$concat_tmp"
w=0
while [[ $w -lt $active ]]; do
    part="${EFILE}.part.${w}"
    if [[ ! -f "$part" ]]; then
        echo "missing shard $part" >&2
        exit 1
    fi
    cat "$part" >> "$concat_tmp"
    w=$((w + 1))
done
if [[ ! -f "$v_stage" ]]; then
    echo "master did not write staged vertices" >&2
    exit 1
fi
rrm_publish_pair
