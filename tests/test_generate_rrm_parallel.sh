#!/bin/bash
# Issues #6, #15, #16: parallel edges, atomic publication, vertex correspondence.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GAP="${GAP:-gap}"
OUT="${OUT:-/tmp/rrm-parallel-test}"
MEM="${MEM:-12g}"
GFILE="${ROOT}/data/Au5Ag_AFIR.g"
DRIVER="${ROOT}/generate_rrm_v11_parallel.sh"

cd "$ROOT"
rm -rf "$OUT"
mkdir -p "$OUT"

if [[ ! -x "$DRIVER" ]]; then
    echo "RED: $DRIVER is missing or not executable" >&2
    exit 1
fi

source "$DRIVER"

echo "== cap workers at TS count =="
if [[ "$("$DRIVER" --active-workers 8 5)" != 5 ]]; then
    echo "expected min(8,5)=5" >&2
    exit 1
fi
if [[ "$("$DRIVER" --active-workers 3 10)" != 3 ]]; then
    echo "expected min(3,10)=3" >&2
    exit 1
fi
if [[ "$("$DRIVER" --active-workers 4 0)" != 0 ]]; then
    echo "expected 0 workers when nts=0" >&2
    exit 1
fi
echo "active-worker cap ok"

echo "== TS slice partition =="
# The slice helper is what workers are given; tools/rrm_bench.py reads it to
# report the per-worker load, so it is exercised directly here.
if [[ "$("$DRIVER" --ts-slice 0 3 10)" != "1 4" ]]; then
    echo "expected worker 0 of 3 to take TS 1..4 of 10" >&2
    exit 1
fi
if [[ "$("$DRIVER" --ts-slice 2 3 10)" != "8 10" ]]; then
    echo "expected worker 2 of 3 to take TS 8..10 of 10" >&2
    exit 1
fi
if [[ "$("$DRIVER" --ts-slice 3 4 3)" != "4 3" ]]; then
    echo "expected an empty slice (lo>hi) for a worker past the TS count" >&2
    exit 1
fi
slice_cover="$(
    for w in 0 1 2 3; do "$DRIVER" --ts-slice "$w" 4 9; done |
    while read -r lo hi; do
        [[ "$lo" -le "$hi" ]] || continue
        seq "$lo" "$hi"
    done | tr '\n' ' '
)"
if [[ "$slice_cover" != "1 2 3 4 5 6 7 8 9 " ]]; then
    echo "slices must partition 1..nts in order, got '$slice_cover'" >&2
    exit 1
fi
echo "TS slice partition ok"

echo "== GAP string escape =="
if [[ "$(rrm_gap_string 'foo"bar')" != '"foo\"bar"' ]]; then
    echo "expected quoted path with escaped double-quote" >&2
    exit 1
fi
if [[ "$(rrm_gap_string 'a\b')" != '"a\\b"' ]]; then
    echo "expected backslash escaped for GAP" >&2
    exit 1
fi
set +e
rrm_gap_string $'a\nb' >"$OUT/gap_nl.out" 2>"$OUT/gap_nl.err"
nl_rc=$?
set -e
if [[ "$nl_rc" -eq 0 ]]; then
    echo "newline in path must be rejected" >&2
    exit 1
fi
echo "GAP string escape ok"

echo "== kill-pids terminates children =="
sleep 60 &
sleep_pid=$!
rrm_kill_pids "$sleep_pid"
reaped=0
i=0
while [[ $i -lt 20 ]]; do
    state=$(ps -o state= -p "$sleep_pid" 2>/dev/null || true)
    if [[ -z "$state" || "$state" == *Z* ]]; then
        reaped=1
        break
    fi
    sleep 0.1
    i=$((i + 1))
done
wait "$sleep_pid" 2>/dev/null || true
if [[ "$reaped" -ne 1 ]]; then
    echo "expected --kill-pids to stop pid $sleep_pid" >&2
    exit 1
fi
echo "kill-pids ok"

echo "== publication, failure, reader and signal regression tests =="
python3 "$ROOT/tests/test_parallel_publication.py"
echo "== vertex correspondence contract and real GAP permutation regression =="
GAP="$GAP" MEM="$MEM" python3 "$ROOT/tests/test_rrm_vertex_map.py"

seq_v="$OUT/seq_v.dat"
seq_e="$OUT/seq_e.dat"
w1_v="$OUT/w1_v.dat"
w1_e="$OUT/w1_e.dat"

echo "== sequential generate_rrm_v11_fast.g baseline =="
"$GAP" -b -q -r -m "$MEM" <<EOF
Read("${ROOT}/generate_rrm_v11_fast.g");
Read("${GFILE}");
generate_rrm("${seq_v}","${seq_e}",symc,ur,urt,ss,org_eq,org_ts,true,true);
QUIT;
EOF

echo "== GAP_WORKERS=1 via driver =="
GAP="$GAP" MEM="$MEM" GAP_WORKERS=1 \
    "$DRIVER" "$w1_v" "$w1_e" "$GFILE"

cmp -s "$seq_v" "$w1_v"
cmp -s "$seq_e" "$w1_e"
echo "GAP_WORKERS=1 vertices/edges byte-identical to sequential generate_rrm"

w2_log="$OUT/w2.log"
echo "== GAP_WORKERS=2 via driver (RRM_KEEP_SHARDS=1) =="
RRM_KEEP_SHARDS=1 GAP="$GAP" MEM="$MEM" GAP_WORKERS=2 \
    "$DRIVER" --bundle "$OUT/w2" "$GFILE" >"$w2_log" 2>&1

w2_run="$(readlink -f "$OUT/w2/current")"
w2_v="$w2_run/vertices.dat"
w2_e="$w2_run/edges.dat"
cmp -s "$w1_v" "$w2_v"
cmp -s "$w1_e" "$w2_e"
echo "GAP_WORKERS=2 concatenated output byte-identical to GAP_WORKERS=1"

if [[ ! -s "${w2_e}.part.0" || ! -s "${w2_e}.part.1" ]]; then
    echo "expected non-empty edge shards ${w2_e}.part.0 and ${w2_e}.part.1" >&2
    ls -l "$OUT" >&2
    exit 1
fi
if cmp -s "${w2_e}.part.0" "$w2_e" || cmp -s "${w2_e}.part.1" "$w2_e"; then
    echo "a single shard equals the full edge file; TS split did not happen" >&2
    exit 1
fi
cat "${w2_e}.part.0" "${w2_e}.part.1" >"$OUT/w2_cat.dat"
cmp -s "$OUT/w2_cat.dat" "$w2_e"
echo "shards concatenate in TS-index order"

echo "== GAP_WORKERS=2 default deletes shards =="
unset RRM_KEEP_SHARDS
GAP="$GAP" MEM="$MEM" GAP_WORKERS=2 \
    "$DRIVER" --bundle "$OUT/w2d" "$GFILE" >"$OUT/w2d.log" 2>&1
w2d_run="$(readlink -f "$OUT/w2d/current")"
w2d_v="$w2d_run/vertices.dat"
w2d_e="$w2d_run/edges.dat"
cmp -s "$w1_v" "$w2d_v"
cmp -s "$w1_e" "$w2d_e"
if [[ -e "${w2d_e}.part.0" || -e "${w2d_e}.part.1" ]]; then
    echo "default run must delete edge shards after concat" >&2
    ls -l "$OUT"/w2d_e.dat.part.* 2>/dev/null >&2 || true
    exit 1
fi
echo "default shard cleanup ok"

echo "== GAP_WORKERS=3 correspondence and byte equality =="
GAP="$GAP" MEM="$MEM" GAP_WORKERS=3 \
    "$DRIVER" --bundle "$OUT/w3" "$GFILE" >"$OUT/w3.log" 2>&1
w3_run="$(readlink -f "$OUT/w3/current")"
cmp -s "$w1_v" "$w3_run/vertices.dat"
cmp -s "$w1_e" "$w3_run/edges.dat"
cmp -s "$w2_run/vertices.dat.vertex-map" "$w3_run/vertices.dat.vertex-map"

nvert_lines=$(grep -c '^RRM_NVERT=' "$w2_log" || true)
if [[ "$nvert_lines" -lt 3 ]]; then
    echo "expected RRM_NVERT from master and each worker, got $nvert_lines" >&2
    cat "$w2_log" >&2
    exit 1
fi
echo "vertex-count lines present ($nvert_lines)"

echo "== nvert mismatch must abort =="
mismatch_dir="$OUT/mismatch"
mkdir -p "$mismatch_dir"
echo "RRM_NVERT=10" >"$mismatch_dir/a.log"
echo "RRM_NVERT=11" >"$mismatch_dir/b.log"
set +e
rrm_assert_nverts 10 "$mismatch_dir/a.log" "$mismatch_dir/b.log" >"$mismatch_dir/out.log" 2>&1
mismatch_rc=$?
set -e
if [[ "$mismatch_rc" -eq 0 ]]; then
    echo "expected non-zero exit on nvert mismatch" >&2
    cat "$mismatch_dir/out.log" >&2
    exit 1
fi
if ! grep -q mismatch "$mismatch_dir/out.log"; then
    echo "expected a mismatch message" >&2
    cat "$mismatch_dir/out.log" >&2
    exit 1
fi
echo "nvert mismatch abort ok (exit $mismatch_rc)"

echo "== GAP_WORKERS=2 Pechukas must abort on AuCu4 (master, before shards) =="
unset RRM_CONTINUE_ON_PECHUKAS
pech_dir="$OUT/pechukas"
mkdir -p "$pech_dir"
set +e
GAP="$GAP" MEM="$MEM" GAP_WORKERS=2 \
    "$DRIVER" --bundle "$pech_dir/result" "${ROOT}/data/AuCu4_AFIR.g" \
    >"$pech_dir/out.log" 2>&1
pech_rc=$?
set -e
if [[ "$pech_rc" -eq 0 ]]; then
    echo "expected non-zero exit for AuCu4 with GAP_WORKERS=2" >&2
    cat "$pech_dir/out.log" >&2
    exit 1
fi
if grep -q UNREACHABLE "$pech_dir/out.log"; then
    echo "driver continued after Pechukas" >&2
    cat "$pech_dir/out.log" >&2
    exit 1
fi
if [[ -L "$pech_dir/result/current" ]]; then
    echo "vertex/edge files must not be published after a Pechukas abort" >&2
    ls -l "$pech_dir" >&2
    exit 1
fi
if ! grep -q "Violation of Pechukus theorem" "$pech_dir/out.log"; then
    echo "expected Pechukas diagnostic from master" >&2
    cat "$pech_dir/out.log" >&2
    exit 1
fi
echo "parallel Pechukas abort ok (exit $pech_rc)"

echo "PASS"
