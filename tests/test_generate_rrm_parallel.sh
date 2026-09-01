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

fake_gap="$OUT/fake_gap.sh"
cat >"$fake_gap" <<'FAKE'
#!/bin/bash
set -euo pipefail
input=$(cat)
if [[ "$input" == *generate_rrm_vertices* ]]; then
    echo "RRM_NVERT=1"
    echo "RRM_NTS=${FAKE_NTS:-8}"
    if [[ -n "${FAKE_MASTER_SLEEP:-}" ]]; then
        echo $$ >>"${FAKE_MASTER_PIDS:?}"
        exec sleep "$FAKE_MASTER_SLEEP"
    fi
    exit 0
fi
if [[ "$input" == *generate_rrm_edge_shard* ]]; then
    echo started >>"${FAKE_STARTS:?}"
    if [[ -n "${FAKE_FAIL_PART0:-}" && "$input" == *'.part.0'* ]]; then
        exit 1
    fi
    if [[ -n "${FAKE_WRITE_SHARDS:-}" ]]; then
        shard=$(printf '%s\n' "$input" | sed -n 's/.*generate_rrm_edge_shard("\([^"]*\)".*/\1/p' | head -1)
        if [[ -z "$shard" ]]; then
            echo "fake_gap: no shard path" >&2
            exit 1
        fi
        echo "RRM_NVERT=1"
        if [[ -n "${FAKE_SKIP_PART1:-}" && "$input" == *'.part.1'* ]]; then
            exit 0
        fi
        printf 'edges from %s\n' "$shard" >"$shard"
        exit 0
    fi
    echo $$ >>"${FAKE_PIDS:?}"
    exec sleep 61
fi
exit 0
FAKE
chmod +x "$fake_gap"
dummy_g="$OUT/dummy.g"
: >"$dummy_g"

echo "== TERM during launch must not start more workers =="
term_dir="$OUT/term"
mkdir -p "$term_dir"
export FAKE_STARTS="$term_dir/starts"
export FAKE_PIDS="$term_dir/wpids"
: >"$FAKE_STARTS"
: >"$FAKE_PIDS"
unset FAKE_FAIL_PART0
set +e
RRM_TEST_LAUNCH_DELAY=1 GAP="$fake_gap" MEM=1g GAP_WORKERS=4 \
    "$DRIVER" "$term_dir/v.dat" "$term_dir/e.dat" "$dummy_g" \
    >"$term_dir/out.log" 2>&1 &
term_drv=$!
i=0
while [[ $i -lt 30 && ! -s "$FAKE_STARTS" ]]; do
    sleep 0.1
    i=$((i + 1))
done
sleep 0.2
kill -TERM "$term_drv" 2>/dev/null || true
wait "$term_drv" 2>/dev/null
term_rc=$?
set -e
starts=$(grep -c started "$FAKE_STARTS" || true)
if [[ "$starts" -gt 1 ]]; then
    echo "TERM returned into the launch loop (starts=$starts)" >&2
    cat "$term_dir/out.log" >&2
    exit 1
fi
if [[ "$term_rc" -eq 0 ]]; then
    echo "expected nonzero exit after TERM" >&2
    exit 1
fi
if [[ -s "$FAKE_PIDS" ]]; then
    while read -r wpid; do
        kill "$wpid" 2>/dev/null || true
        wait "$wpid" 2>/dev/null || true
    done <"$FAKE_PIDS"
fi
echo "TERM stops launch ok (starts=$starts exit $term_rc)"

echo "== TERM during master must kill the master GAP =="
mst_dir="$OUT/term-master"
mkdir -p "$mst_dir"
export FAKE_STARTS="$mst_dir/starts"
export FAKE_PIDS="$mst_dir/wpids"
export FAKE_MASTER_PIDS="$mst_dir/master.pid"
export FAKE_MASTER_SLEEP=60
export FAKE_NTS=8
: >"$FAKE_STARTS"
: >"$FAKE_PIDS"
: >"$FAKE_MASTER_PIDS"
unset RRM_TEST_LAUNCH_DELAY
unset FAKE_FAIL_PART0
set +e
GAP="$fake_gap" MEM=1g GAP_WORKERS=2 \
    "$DRIVER" "$mst_dir/v.dat" "$mst_dir/e.dat" "$dummy_g" \
    >"$mst_dir/out.log" 2>&1 &
mst_drv=$!
i=0
while [[ $i -lt 30 && ! -s "$FAKE_MASTER_PIDS" ]]; do
    sleep 0.1
    i=$((i + 1))
done
if [[ ! -s "$FAKE_MASTER_PIDS" ]]; then
    echo "master fake GAP did not start" >&2
    cat "$mst_dir/out.log" >&2
    kill -TERM "$mst_drv" 2>/dev/null || true
    wait "$mst_drv" 2>/dev/null || true
    exit 1
fi
sleep 0.2
kill -TERM "$mst_drv" 2>/dev/null || true
wait "$mst_drv" 2>/dev/null
mst_rc=$?
set -e
if [[ "$mst_rc" -eq 0 ]]; then
    echo "expected nonzero exit after TERM during master" >&2
    cat "$mst_dir/out.log" >&2
    exit 1
fi
mst_alive=0
while read -r mpid; do
    state=$(ps -o state= -p "$mpid" 2>/dev/null || true)
    if [[ -n "$state" && "$state" != *Z* ]]; then
        mst_alive=1
        kill "$mpid" 2>/dev/null || true
        wait "$mpid" 2>/dev/null || true
    fi
done <"$FAKE_MASTER_PIDS"
if [[ "$mst_alive" -ne 0 ]]; then
    echo "master GAP still running after TERM on the driver" >&2
    cat "$mst_dir/out.log" >&2
    exit 1
fi
starts=$(grep -c started "$FAKE_STARTS" || true)
if [[ "$starts" -ne 0 ]]; then
    echo "workers started after TERM during master (starts=$starts)" >&2
    cat "$mst_dir/out.log" >&2
    exit 1
fi
echo "TERM during master ok (exit $mst_rc)"
unset FAKE_MASTER_SLEEP FAKE_MASTER_PIDS FAKE_NTS

echo "== one worker failure must cancel siblings =="
fail_dir="$OUT/failfast"
mkdir -p "$fail_dir"
export FAKE_STARTS="$fail_dir/starts"
export FAKE_PIDS="$fail_dir/wpids"
export FAKE_NTS=6
export FAKE_FAIL_PART0=1
: >"$FAKE_STARTS"
: >"$FAKE_PIDS"
unset RRM_TEST_LAUNCH_DELAY
set +e
t0=$(date +%s)
GAP="$fake_gap" MEM=1g GAP_WORKERS=3 \
    "$DRIVER" "$fail_dir/v.dat" "$fail_dir/e.dat" "$dummy_g" \
    >"$fail_dir/out.log" 2>&1
fail_rc=$?
t1=$(date +%s)
set -e
elapsed=$((t1 - t0))
if [[ "$fail_rc" -eq 0 ]]; then
    echo "expected nonzero when a shard fails" >&2
    cat "$fail_dir/out.log" >&2
    exit 1
fi
if [[ "$elapsed" -ge 8 ]]; then
    echo "siblings were not cancelled (${elapsed}s)" >&2
    cat "$fail_dir/out.log" >&2
    exit 1
fi
alive=0
if [[ -s "$FAKE_PIDS" ]]; then
    while read -r wpid; do
        state=$(ps -o state= -p "$wpid" 2>/dev/null || true)
        if [[ -n "$state" && "$state" != *Z* ]]; then
            alive=1
        fi
        wait "$wpid" 2>/dev/null || true
    done <"$FAKE_PIDS"
fi
if [[ "$alive" -ne 0 ]]; then
    echo "sibling workers still running after a shard failure" >&2
    exit 1
fi
echo "sibling cancel ok (${elapsed}s exit $fail_rc)"
unset FAKE_STARTS FAKE_PIDS FAKE_NTS FAKE_FAIL_PART0

echo "== fake GAP: default deletes shards after concat =="
sh_dir="$OUT/shards-default"
mkdir -p "$sh_dir"
export FAKE_STARTS="$sh_dir/starts"
export FAKE_WRITE_SHARDS=1
export FAKE_NTS=2
: >"$FAKE_STARTS"
unset RRM_KEEP_SHARDS
unset FAKE_SKIP_PART1
GAP="$fake_gap" MEM=1g GAP_WORKERS=2 \
    "$DRIVER" "$sh_dir/v.dat" "$sh_dir/e.dat" "$dummy_g" \
    >"$sh_dir/out.log" 2>&1
if [[ ! -s "$sh_dir/e.dat" ]]; then
    echo "expected concatenated edges" >&2
    cat "$sh_dir/out.log" >&2
    exit 1
fi
if [[ -e "$sh_dir/e.dat.part.0" || -e "$sh_dir/e.dat.part.1" ]]; then
    echo "default fake run must delete shards after concat" >&2
    ls -l "$sh_dir" >&2
    exit 1
fi
echo "fake default shard cleanup ok"

echo "== fake GAP: RRM_KEEP_SHARDS=1 keeps shards =="
keep_dir="$OUT/shards-keep"
mkdir -p "$keep_dir"
export FAKE_STARTS="$keep_dir/starts"
: >"$FAKE_STARTS"
RRM_KEEP_SHARDS=1 GAP="$fake_gap" MEM=1g GAP_WORKERS=2 \
    "$DRIVER" "$keep_dir/v.dat" "$keep_dir/e.dat" "$dummy_g" \
    >"$keep_dir/out.log" 2>&1
if [[ ! -s "$keep_dir/e.dat.part.0" || ! -s "$keep_dir/e.dat.part.1" ]]; then
    echo "RRM_KEEP_SHARDS=1 must leave shards" >&2
    cat "$keep_dir/out.log" >&2
    ls -l "$keep_dir" >&2
    exit 1
fi
cat "$keep_dir/e.dat.part.0" "$keep_dir/e.dat.part.1" >"$keep_dir/cat.dat"
cmp -s "$keep_dir/cat.dat" "$keep_dir/e.dat"
echo "fake keep-shards ok"

echo "== fake GAP: concat failure must keep earlier shards =="
miss_dir="$OUT/shards-missing"
mkdir -p "$miss_dir"
export FAKE_STARTS="$miss_dir/starts"
export FAKE_SKIP_PART1=1
: >"$FAKE_STARTS"
unset RRM_KEEP_SHARDS
set +e
GAP="$fake_gap" MEM=1g GAP_WORKERS=2 \
    "$DRIVER" "$miss_dir/v.dat" "$miss_dir/e.dat" "$dummy_g" \
    >"$miss_dir/out.log" 2>&1
miss_rc=$?
set -e
if [[ "$miss_rc" -eq 0 ]]; then
    echo "expected nonzero when a shard is missing" >&2
    cat "$miss_dir/out.log" >&2
    exit 1
fi
if [[ ! -s "$miss_dir/e.dat.part.0" ]]; then
    echo "failed concat must not delete shards that were already written" >&2
    cat "$miss_dir/out.log" >&2
    ls -l "$miss_dir" >&2
    exit 1
fi
if [[ -e "$miss_dir/e.dat" ]]; then
    echo "failed concat must not publish a partial edge file" >&2
    cat "$miss_dir/out.log" >&2
    ls -l "$miss_dir" >&2
    exit 1
fi
echo "failed concat keeps shards ok (exit $miss_rc)"

echo "== unknown RRM_KEEP_SHARDS must abort =="
bad_dir="$OUT/shards-badflag"
mkdir -p "$bad_dir"
export FAKE_STARTS="$bad_dir/starts"
: >"$FAKE_STARTS"
unset FAKE_SKIP_PART1
set +e
RRM_KEEP_SHARDS=yes GAP="$fake_gap" MEM=1g GAP_WORKERS=2 \
    "$DRIVER" "$bad_dir/v.dat" "$bad_dir/e.dat" "$dummy_g" \
    >"$bad_dir/out.log" 2>&1
bad_rc=$?
set -e
if [[ "$bad_rc" -eq 0 ]]; then
    echo "expected nonzero for unrecognized RRM_KEEP_SHARDS" >&2
    cat "$bad_dir/out.log" >&2
    exit 1
fi
echo "unknown RRM_KEEP_SHARDS rejected (exit $bad_rc)"
unset FAKE_STARTS FAKE_WRITE_SHARDS FAKE_NTS FAKE_SKIP_PART1
unset RRM_KEEP_SHARDS

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
echo "== GAP_WORKERS=2 via driver (RRM_KEEP_SHARDS=1) =="
RRM_KEEP_SHARDS=1 GAP="$GAP" MEM="$MEM" GAP_WORKERS=2 \
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

echo "== GAP_WORKERS=2 default deletes shards =="
w2d_v="$OUT/w2d_v.dat"
w2d_e="$OUT/w2d_e.dat"
unset RRM_KEEP_SHARDS
GAP="$GAP" MEM="$MEM" GAP_WORKERS=2 \
    "$DRIVER" "$w2d_v" "$w2d_e" "$GFILE" >"$OUT/w2d.log" 2>&1
cmp -s "$w1_e" "$w2d_e"
if [[ -e "${w2d_e}.part.0" || -e "${w2d_e}.part.1" ]]; then
    echo "default run must delete edge shards after concat" >&2
    ls -l "$OUT"/w2d_e.dat.part.* 2>/dev/null >&2 || true
    exit 1
fi
echo "default shard cleanup ok"

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

echo "== GAP_WORKERS=2 Pechukas must abort on AuCu4 (master, before shards) =="
unset RRM_CONTINUE_ON_PECHUKAS
pech_dir="$OUT/pechukas"
mkdir -p "$pech_dir"
set +e
GAP="$GAP" MEM="$MEM" GAP_WORKERS=2 \
    "$DRIVER" "$pech_dir/v.dat" "$pech_dir/e.dat" "${ROOT}/data/AuCu4_AFIR.g" \
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
if [[ -e "$pech_dir/e.dat" ]]; then
    echo "edge file must not be written after a Pechukas abort" >&2
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
