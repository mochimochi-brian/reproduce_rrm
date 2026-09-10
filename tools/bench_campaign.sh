#!/bin/bash
# Issue #18: the measurement campaign behind docs/results/issue18-performance.md.
#
# Runs tools/rrm_bench.py over four inputs and the configurations
# v11 / fast / par:1 / par:2 / par:4, then over three GAP -m settings, writing
# one JSON and one Markdown fragment per input into $RESULTS.
#
# Runs are strictly sequential: two benchmarks must never share the machine.
# Nothing else should be running either -- this script does not and cannot
# detect a busy machine.
#
#   OUT=/var/tmp/rrm-bench ./tools/bench_campaign.sh
#
# Environment:
#   OUT      raw GAP output, logs and bundles (default /var/tmp/rrm-bench).
#            Must be outside the repository; needs a few hundred MB.
#   RESULTS  JSON/Markdown reports (default $OUT/reports)
#   MEM      GAP -m per process for the main matrix (default 2g)
#   REPS     repetitions per configuration (default 3)
#   V11_TIMEOUT  seconds allowed for one v11 run on the large input
#            (default 3600). A cut-off run is reported as such and excluded
#            from the ratios; it is not repeated.
#   MEM_SWEEP  -m values for the startup-cost table (default "512m 2g 12g")
#   GAP      GAP binary (default gap)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-/var/tmp/rrm-bench}"
RESULTS="${RESULTS:-$OUT/reports}"
MEM="${MEM:-2g}"
REPS="${REPS:-3}"
V11_TIMEOUT="${V11_TIMEOUT:-3600}"
MEM_SWEEP="${MEM_SWEEP:-512m 2g 12g}"
GAP="${GAP:-gap}"
BENCH="$ROOT/tools/rrm_bench.py"

cd "$ROOT"
mkdir -p "$OUT" "$RESULTS"
echo "raw output:  $OUT"
echo "reports:     $RESULTS"
echo "MEM=$MEM REPS=$REPS GAP=$GAP"

bench() {
    local label="$1" gfile="$2"
    shift 2
    echo "=== $label ==="
    python3 "$BENCH" --label "$label" --gfile "$gfile" --gap "$GAP" \
        --outdir "$OUT" --json "$RESULTS/$label.json" \
        --markdown "$RESULTS/$label.md" "$@"
}

# 1. The bundled real input. Everything completes, so v11 is the reference and
#    every other configuration is compared against it byte for byte.
bench Au5Ag data/Au5Ag_AFIR.g --mem "$MEM" --reps "$REPS" \
    --config v11 --config fast --config par:1 --config par:2 --config par:4 \
    --deep-compare

# 2. Synthetic input about 3x Au5Ag in vertices, with the same shape. Still
#    small enough for v11 to be repeated.
bench synth-medium data/bench/synth_n6_eq8_ts30.g --mem "$MEM" --reps "$REPS" \
    --config v11 --config fast --config par:1 --config par:2 --config par:4 \
    --deep-compare

# 3. Larger synthetic input: 41k vertices, 147k edges. v11 is quadratic in the
#    vertex count, so it runs once under a time limit; the fast and parallel
#    configurations are repeated as usual. v11 stays the reference so that the
#    byte comparison is made at this size if it finishes within the limit.
bench synth-large data/bench/synth_n7_eq10_ts40.g --mem "$MEM" --reps "$REPS" \
    --config v11 --config fast --config par:1 --config par:2 --config par:4 \
    --reps-for v11=1 --timeout "$V11_TIMEOUT" --deep-compare

# 4. Edge-dominated input: few vertices, 341k edges. This is where splitting
#    the TS loop across processes can actually pay for the extra GAP startups.
bench synth-edge data/bench/synth_n7_eq4_ts200_edge.g --mem "$MEM" \
    --reps "$REPS" \
    --config v11 --config fast --config par:1 --config par:2 --config par:4 \
    --deep-compare

# 5. Sensitivity to GAP's -m. Every process pays the workspace cost, so k
#    workers pay it k times; this is measured, not argued.
for m in $MEM_SWEEP; do
    bench "Au5Ag-mem$m" data/Au5Ag_AFIR.g --mem "$m" --reps "$REPS" \
        --config fast --config par:2 --config par:4
done

echo
echo "campaign done; reports in $RESULTS"
ls -1 "$RESULTS"
