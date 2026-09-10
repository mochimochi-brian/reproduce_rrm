#!/bin/bash
# Issue #18: the measurement harness itself (tools/rrm_bench.py,
# tools/rrm_input_stats.g, tools/make_synthetic_input.py).
#
# Fast checks on tiny fixtures: the harness must report structural counts that
# agree with the produced files, detect that v11 / fast / par:k agree byte for
# byte, keep the three memory figures distinct, record a timeout instead of a
# speedup, and refuse to write raw output into the repository.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GAP="${GAP:-gap}"
MEM="${MEM:-512m}"
OUT="${OUT:-/tmp/rrm-bench-test}"
BENCH="${ROOT}/tools/rrm_bench.py"
SYNTH="${ROOT}/tools/make_synthetic_input.py"

cd "$ROOT"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "== input statistics agree with the produced files =="
python3 "$BENCH" --label small --gfile tests/fixtures/small_labels.g \
    --config fast --config v11 --config par:2 --reps 1 --mem "$MEM" \
    --gap "$GAP" --outdir "$OUT/small" --json "$OUT/small.json" \
    --markdown "$OUT/small.md" --deep-compare >/dev/null

python3 - "$OUT/small.json" <<'PY'
import json, sys
rep = json.load(open(sys.argv[1]))
st = rep["input"]["stats"]
# The fixture documents 15 vertices and 5 x |S_3| = 30 edges.
assert st["nvert"] == 15, st
assert st["nedge"] == 30, st
assert st["sym_order"] == 6, st
assert st["eq_verts"] == [3, 6, 6], st
assert st["ts_edges"] == [6] * 5, st

for name in ("fast", "v11", "par:2"):
    cfg = rep["configs"][name]
    s = cfg["summary"]
    assert s["ok_reps"] == 1, (name, s)
    assert not s["timed_out"], (name, s)
    assert s["wall_median_s"] > 0, (name, s)
    run = cfg["runs"][0]
    # Structural edge count must match the produced edge file.
    assert run["output"]["edges"]["lines"] == st["nedge"], (name, run["output"])
    assert run["output"]["vertices"]["bytes"] > 0, (name, run["output"])
    # The three memory figures are reported separately and consistently.
    # The sampled ones are lower bounds, so they are only ordered among
    # themselves; the exact ru_maxrss figure may exceed the sampled peak.
    assert s["max_single_peak_rss_kb"] > 0, (name, s)
    assert 0 < s["sampled_max_single_peak_rss_kb"] <= s["sum_peak_rss_kb"], \
        (name, s)
    assert s["concurrent_peak_rss_kb"] <= s["sum_peak_rss_kb"], (name, s)

# fast is the reference here; the other two must be byte-identical to it.
for name in ("v11", "par:2"):
    cmpres = rep["configs"][name]["comparison"]
    assert cmpres["byte_identical"] is True, (name, cmpres)
    assert cmpres["vertices"] == "identical", (name, cmpres)
    assert cmpres["edges"] == "identical", (name, cmpres)
assert rep["configs"]["v11"]["runs"][0]["comparison"][
    "compare_rrm_dat_exit"] == 0

# GAP's own clock is available for the sequential configurations only.
assert "gap_generate_ms" in rep["configs"]["v11"]["runs"][0]
assert "gap_generate_ms" not in rep["configs"]["par:2"]["runs"][0]

# The parallel run must be resolved into master and worker processes with a
# planned TS split that covers every TS exactly once.
par = rep["configs"]["par:2"]
assert par["active_workers"] == 2, par
covered = []
for w in par["planned_load"]:
    covered += list(range(w["ts_lo"], w["ts_hi"] + 1))
assert covered == list(range(1, st["nts"] + 1)), par["planned_load"]
assert sum(w["assigned_edges"] for w in par["planned_load"]) == st["nedge"]
run = par["runs"][0]
assert run["workers_observed"] == 2, run
assert run["master_wall_s"] > 0, run
assert run["driver_overhead_wall_s"] >= 0, run
roles = {p["role"] for p in run["processes"]}
assert {"master", "worker:0", "worker:1"} <= roles, roles

# A sequential run must resolve its one GAP process, not leave it unlabelled.
seq_roles = {p["role"] for p in rep["configs"]["fast"]["runs"][0]["processes"]}
assert "gap" in seq_roles, seq_roles

env = rep["environment"]
for key in ("gap_version", "uname", "cpu_model", "cpus", "mem_total_kb"):
    assert env.get(key), (key, env)
assert env["git"]["commit"], env
assert rep["mem"] and rep["input"]["sha256"], rep
print("statistics, comparison and process breakdown ok")
PY

echo "== per-configuration repetition counts =="
python3 "$BENCH" --label reps --gfile tests/fixtures/small_labels.g \
    --config fast --config v11 --reps 2 --reps-for v11=1 --mem "$MEM" \
    --gap "$GAP" --outdir "$OUT/reps" --json "$OUT/reps.json" \
    --markdown /dev/null >/dev/null
python3 - "$OUT/reps.json" <<'PY'
import json, sys
rep = json.load(open(sys.argv[1]))
assert rep["configs"]["fast"]["reps_requested"] == 2, rep["configs"]["fast"]
assert len(rep["configs"]["fast"]["runs"]) == 2, rep["configs"]["fast"]
assert rep["configs"]["v11"]["reps_requested"] == 1, rep["configs"]["v11"]
assert len(rep["configs"]["v11"]["runs"]) == 1, rep["configs"]["v11"]
print("per-configuration reps ok")
PY
set +e
python3 "$BENCH" --label reps --gfile tests/fixtures/small_labels.g \
    --config fast --reps 1 --reps-for nosuch=2 --mem "$MEM" --gap "$GAP" \
    --outdir "$OUT/reps" >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
    echo "expected --reps-for on an unused configuration to be rejected" >&2
    exit 1
fi

echo "== zero-TS input is measurable and reported as such =="
python3 "$BENCH" --label zero --gfile tests/fixtures/zero_ts.g \
    --config fast --config par:2 --reps 1 --mem "$MEM" --gap "$GAP" \
    --outdir "$OUT/zero" --json "$OUT/zero.json" --markdown /dev/null >/dev/null
python3 - "$OUT/zero.json" <<'PY'
import json, sys
rep = json.load(open(sys.argv[1]))
assert rep["input"]["stats"]["nts"] == 0, rep["input"]["stats"]
assert rep["input"]["stats"]["nedge"] == 0, rep["input"]["stats"]
par = rep["configs"]["par:2"]
# No TS means no workers; the master still publishes a validated pair.
assert "planned_load" not in par, par
assert par["comparison"]["byte_identical"] is True, par["comparison"]
assert par["runs"][0]["output"]["edges"]["bytes"] == 0, par["runs"][0]["output"]
print("zero-TS input ok")
PY

echo "== a timeout is recorded, not turned into a speedup =="
set +e
python3 "$BENCH" --label timeout --gfile tests/fixtures/small_labels.g \
    --config fast --config v11 --reps 1 --mem "$MEM" --gap "$GAP" \
    --outdir "$OUT/to" --timeout 0.05 --json "$OUT/to.json" \
    --markdown "$OUT/to.md" >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
    echo "expected a nonzero exit when every run is cut off" >&2
    exit 1
fi
python3 - "$OUT/to.json" <<'PY'
import json, sys
rep = json.load(open(sys.argv[1]))
for name, cfg in rep["configs"].items():
    s = cfg["summary"]
    assert s["timed_out"], (name, s)
    assert s["ok_reps"] == 0, (name, s)
    assert s["wall_median_s"] is None, (name, s)
PY
grep -q "n/a (timeout)" "$OUT/to.md" || {
    echo "the Markdown report must not print a time for a cut-off run" >&2
    exit 1
}
echo "timeout handling ok"

echo "== raw output may not be written inside the repository =="
set +e
python3 "$BENCH" --label refuse --gfile tests/fixtures/zero_ts.g --config fast \
    --reps 1 --mem "$MEM" --gap "$GAP" --outdir "$ROOT/bench-out" \
    >/dev/null 2>"$OUT/refuse.err"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] || [[ -e "$ROOT/bench-out" ]]; then
    echo "expected --outdir inside the repo to be rejected" >&2
    rm -rf "$ROOT/bench-out"
    exit 1
fi
grep -q "outside the repository" "$OUT/refuse.err" || {
    echo "expected an explanatory error for an in-repo --outdir" >&2
    exit 1
}
echo "in-repo outdir rejected"

echo "== synthetic input generation is deterministic and Pechukas-clean =="
python3 "$SYNTH" --identical 4 --eqs 3 --ts 6 --seed 7 -o "$OUT/syn_a.g" 2>/dev/null
python3 "$SYNTH" --identical 4 --eqs 3 --ts 6 --seed 7 -o "$OUT/syn_b.g" 2>/dev/null
cmp "$OUT/syn_a.g" "$OUT/syn_b.g"
python3 "$SYNTH" --identical 4 --eqs 3 --ts 6 --seed 8 -o "$OUT/syn_c.g" 2>/dev/null
if cmp -s "$OUT/syn_a.g" "$OUT/syn_c.g"; then
    echo "different seeds must give different inputs" >&2
    exit 1
fi
grep -q "make_synthetic_input.py" "$OUT/syn_a.g" || {
    echo "the generated input must record how to regenerate it" >&2
    exit 1
}
# The fast producer is fail-closed on Pechukas violations, so a clean exit here
# is what proves the generated input satisfies the conditions.
python3 "$BENCH" --label syn --gfile "$OUT/syn_a.g" --config fast --config v11 \
    --config par:2 --reps 1 --mem "$MEM" --gap "$GAP" --outdir "$OUT/syn" \
    --json "$OUT/syn.json" --markdown /dev/null >/dev/null
python3 - "$OUT/syn.json" <<'PY'
import json, sys
rep = json.load(open(sys.argv[1]))
st = rep["input"]["stats"]
assert st["sym_order"] == 24, st          # S_4
assert st["nts"] == 6 and st["neq"] == 3, st
# The light TSs expand to fewer edges than the heavy ones: that skew is the
# point of the synthetic input.
assert min(st["ts_edges"]) < max(st["ts_edges"]), st["ts_edges"]
for name in ("v11", "par:2"):
    assert rep["configs"][name]["comparison"]["byte_identical"] is True, name
    assert rep["configs"][name]["summary"]["exit_codes"] == [0], name
print("synthetic input ok")
PY

echo "GREEN: tools/rrm_bench.py, tools/rrm_input_stats.g and tools/make_synthetic_input.py behave as documented"
