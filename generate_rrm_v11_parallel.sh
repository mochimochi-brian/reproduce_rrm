#!/bin/bash
# Optional process-parallel edge writes for generate_rrm_v11_fast.g.
# Not a new Teramoto version of generate_rrm_v11.g.
# Default GAP_WORKERS=1 is the sequential generate_rrm path.
# GAP_WORKERS=k>1: master writes vertices (and Pechukas); workers write TS shards.
# Edge shards are deleted after concat unless RRM_KEEP_SHARDS=1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAP="${GAP:-gap}"
MEM="${MEM:-12g}"
GAP_WORKERS="${GAP_WORKERS:-1}"
GAPSRC="${ROOT}/generate_rrm_v11_fast.g"

rrm_count_from_log() {
    local log="$1" key="$2" value
    if ! value="$(grep "^${key}=" "$log")"; then
        echo "missing $key or unreadable log: $log" >&2
        return 1
    fi
    value="${value#*=}"
    if ! [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]]; then
        echo "invalid or duplicate $key in $log" >&2
        return 1
    fi
    printf '%s\n' "$value"
}

rrm_assert_nverts() {
    local expected="$1"
    local log got
    shift
    for log in "$@"; do
        got="$(rrm_count_from_log "$log" RRM_NVERT)" || return 1
        if [[ "$got" != "$expected" ]]; then
            echo "nvert mismatch: $log has '${got}', expected '${expected}'" >&2
            return 1
        fi
    done
}

rrm_ts_slice() {
    # 0-based worker w of k, nts items -> lo hi (1-based inclusive; lo>hi if empty)
    local w="$1" k="$2" nts="$3"
    local base=$((nts / k)) rem=$((nts % k)) start size
    start=$((1 + w * base + (w < rem ? w : rem)))
    size=$((base + (w < rem)))
    echo "$start $((start + size - 1))"
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
    {
        printf 'format=1\nnvert=%s\nnts=%s\nworkers=%s\n' "$nvert" "$nts" "$active"
        printf 'vertex_map_format=1\nvertex_map_sha256=%s\n' "$map_digest"
        (cd "$run_dir" && sha256sum vertices.dat edges.dat)
    } > "$run_dir/manifest.txt"
    ln -s -- "runs/${run_dir##*/}" "$publish_link"
    # The whole generation is unpublished until this same-filesystem rename.
    # Cleanup never removes its data, even if a signal arrives just after rename.
    mv -Tf -- "$publish_link" "$bundle/current"
    # Retain diagnostic maps/shards on every pre-publication failure.
    if ! rrm_keep_shards; then
        local w
        for ((w=0; w<active; w++)); do
            rm -f -- "$EFILE.part.$w" "$EFILE.part.$w.vertex-map"
        done
    fi
}

# Allow tests to call helpers without adding test-only CLI modes.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

if [[ "${1:-}" == --active-workers ]]; then
    if [[ $# -ne 3 ]]; then
        echo "Usage: $0 --active-workers K NTS" >&2
        exit 1
    fi
    rrm_active_workers "$2" "$3"
    exit 0
fi

if [[ "${1:-}" == --ts-slice ]]; then
    if [[ $# -ne 4 ]]; then
        echo "Usage: $0 --ts-slice W K NTS" >&2
        exit 1
    fi
    rrm_ts_slice "$2" "$3" "$4"
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
command -v python3 >/dev/null || { echo "parallel validation requires python3" >&2; exit 1; }
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

master_map="${VFILE}.vertex-map"
gap_v="$(rrm_gap_string "$VFILE")"

master_pid=""
pids=()
rrm_cleanup_workers() {
    rrm_kill_pids "${master_pid:-}" "${pids[@]:-}"
    rrm_kill_own_children
    rm -f -- "$publish_link"
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

nvert="$(rrm_count_from_log "$master_log" RRM_NVERT)"
nts="$(rrm_count_from_log "$master_log" RRM_NTS)"
map_digest="$(python3 "$ROOT/check_rrm_vertex_map.py" "$nvert" "$master_map")"

active="$(rrm_active_workers "$GAP_WORKERS" "$nts")"

worker_logs=()
w=0
while [[ $w -lt $active ]]; do
    read -r lo hi < <(rrm_ts_slice "$w" "$active" "$nts")
    shard="${EFILE}.part.${w}"
    wlog="${EFILE}.part.${w}.log"
    worker_logs+=("$wlog")
    gap_shard="$(rrm_gap_string "$shard")"
    echo "=== worker ${w} TS ${lo}..${hi} ==="
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
for ((w=0; w<active; w++)); do
    python3 "$ROOT/check_rrm_vertex_map.py" "$nvert" "$EFILE.part.$w.vertex-map" \
        --expected-sha256 "$map_digest" >/dev/null
done

: > "$EFILE"
w=0
while [[ $w -lt $active ]]; do
    part="${EFILE}.part.${w}"
    if [[ ! -f "$part" ]]; then
        echo "missing shard $part" >&2
        exit 1
    fi
    cat "$part" >> "$EFILE"
    w=$((w + 1))
done
if [[ ! -f "$VFILE" ]]; then
    echo "master did not write vertices" >&2
    exit 1
fi
rrm_publish_pair
