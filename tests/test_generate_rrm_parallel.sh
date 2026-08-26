#!/bin/bash
# Issue #6: optional process-parallel edge generation over TS slices.
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

echo "== GAP string escape =="
if [[ "$("$DRIVER" --gap-string 'foo"bar')" != '"foo\"bar"' ]]; then
    echo "expected quoted path with escaped double-quote" >&2
    exit 1
fi
if [[ "$("$DRIVER" --gap-string 'a\b')" != '"a\\b"' ]]; then
    echo "expected backslash escaped for GAP" >&2
    exit 1
fi
set +e
"$DRIVER" --gap-string $'a\nb' >"$OUT/gap_nl.out" 2>"$OUT/gap_nl.err"
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
"$DRIVER" --kill-pids "$sleep_pid"
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

w2_v="$OUT/w2_v.dat"
w2_e="$OUT/w2_e.dat"
w2_log="$OUT/w2.log"
echo "== GAP_WORKERS=2 via driver =="
GAP="$GAP" MEM="$MEM" GAP_WORKERS=2 \
    "$DRIVER" "$w2_v" "$w2_e" "$GFILE" >"$w2_log" 2>&1

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
"$DRIVER" --assert-nvert 10 "$mismatch_dir/a.log" "$mismatch_dir/b.log" >"$mismatch_dir/out.log" 2>&1
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

echo "PASS"
