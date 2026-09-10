#!/bin/bash
# Issue #17: full labeled-graph comparison of generate_rrm_v11.g (reference),
# generate_rrm_v11_fast.g and generate_rrm_v11_parallel.sh.
#
# `cmp` is used wherever the enumeration order is the contract. The normalized
# comparison in tests/compare_rrm_dat.py is used where order is not, and to
# show what a full comparison detects that an EQ-degree check cannot.
#
# Fail-closed Pechukas behaviour is verified separately in
# tests/test_pechukas_policy.sh and tests/test_generate_rrm_parallel.sh; the
# AuCu4 section here covers the continue-mode equivalence and re-checks that the
# default policy publishes nothing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GAP="${GAP:-gap}"
OUT="${OUT:-/tmp/rrm-full-comparison-test}"
MEM="${MEM:-12g}"
COMPARE="${ROOT}/tests/compare_rrm_dat.py"
MUTATE="${ROOT}/tests/mutate_rrm_dat.py"
DEGREE="${ROOT}/check_number_of_edges_dat.py"
DRIVER="${ROOT}/generate_rrm_v11_parallel.sh"
FIXTURE="${ROOT}/tests/fixtures/small_labels.g"
ZERO_TS="${ROOT}/tests/fixtures/zero_ts.g"
AU5AG="${ROOT}/data/Au5Ag_AFIR.g"
AUCU4="${ROOT}/data/AuCu4_AFIR.g"

cd "$ROOT"
rm -rf "$OUT"
mkdir -p "$OUT"

for f in "$COMPARE" "$MUTATE" "$DEGREE" "$DRIVER" "$FIXTURE" "$ZERO_TS" "$AU5AG" "$AUCU4"; do
    if [[ ! -f "$f" ]]; then
        echo "RED: $f is missing" >&2
        exit 1
    fi
done

# Parent shells may export the continue flag; every section sets it explicitly.
unset RRM_CONTINUE_ON_PECHUKAS

run_generate() {
    # src gfile vout eout [gap label arguments, e.g. "true,false"]
    local src="$1" gfile="$2" vout="$3" eout="$4" labels="${5-}"
    local log="${eout}.log" extra="" rc=0
    if [[ -n "$labels" ]]; then
        extra=",${labels}"
    fi
    set +e
    "$GAP" -T -b -q -r -m "$MEM" >"$log" 2>&1 <<EOF
Read("${ROOT}/${src}");
Read("${gfile}");
generate_rrm("${vout}","${eout}",symc,ur,urt,ss,org_eq,org_ts${extra});
Print("RRM_DONE\n");
QUIT;
EOF
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]] || ! grep -q RRM_DONE "$log"; then
        echo "generate_rrm failed: src=$src gfile=$gfile labels='${labels}' (exit $rc)" >&2
        cat "$log" >&2
        exit 1
    fi
}

run_entrypoints() {
    # The driver only ever asks for labelled output. These are the same GAP
    # entry points it calls, with the label settings it does not expose.
    # gfile vout eout vlabel elabel
    local gfile="$1" vout="$2" eout="$3" vlabel="$4" elabel="$5"
    local log="${vout}.master.log" rc=0 nts lo hi part range mid i
    set +e
    "$GAP" -T -b -q -r -m "$MEM" >"$log" 2>&1 <<EOF
Read("${ROOT}/generate_rrm_v11_fast.g");
Read("${gfile}");
generate_rrm_vertices("${vout}",symc,ur,urt,ss,org_eq,org_ts,${vlabel});
QUIT;
EOF
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        echo "generate_rrm_vertices failed (exit $rc)" >&2
        cat "$log" >&2
        exit 1
    fi
    nts="$(sed -n 's/^RRM_NTS=//p' "$log")"
    if ! [[ "$nts" =~ ^(0|[1-9][0-9]*)$ ]]; then
        echo "could not read RRM_NTS from $log" >&2
        cat "$log" >&2
        exit 1
    fi
    # Two contiguous slices, concatenated in TS-index order.
    mid=$((nts / 2))
    local ranges=("1 ${mid}" "$((mid + 1)) ${nts}")
    : >"$eout"
    i=0
    for range in "${ranges[@]}"; do
        read -r lo hi <<<"$range"
        part="${eout}.part.${i}"
        : >"$part"
        if [[ "$lo" -le "$hi" ]]; then
            set +e
            "$GAP" -T -b -q -r -m "$MEM" >"${part}.log" 2>&1 <<EOF
Read("${ROOT}/generate_rrm_v11_fast.g");
Read("${gfile}");
generate_rrm_edge_shard("${part}",${lo},${hi},symc,ur,urt,ss,org_eq,org_ts,${elabel});
QUIT;
EOF
            rc=$?
            set -e
            if [[ "$rc" -ne 0 ]]; then
                echo "generate_rrm_edge_shard ${lo}..${hi} failed (exit $rc)" >&2
                cat "${part}.log" >&2
                exit 1
            fi
        fi
        cat "$part" >>"$eout"
        i=$((i + 1))
    done
}

run_parallel() {
    # gfile bundle_or_prefix workers -> prints "VFILE EFILE"
    local gfile="$1" dest="$2" workers="$3" rc=0
    if [[ "$workers" -eq 1 ]]; then
        set +e
        GAP="$GAP" MEM="$MEM" GAP_WORKERS=1 \
            "$DRIVER" "${dest}_v.dat" "${dest}_e.dat" "$gfile" >"${dest}.log" 2>&1
        rc=$?
        set -e
        if [[ "$rc" -ne 0 ]]; then
            echo "driver GAP_WORKERS=1 failed (exit $rc)" >&2
            cat "${dest}.log" >&2
            exit 1
        fi
        printf '%s %s\n' "${dest}_v.dat" "${dest}_e.dat"
        return 0
    fi
    rm -rf "$dest"
    set +e
    GAP="$GAP" MEM="$MEM" GAP_WORKERS="$workers" \
        "$DRIVER" --bundle "$dest" "$gfile" >"${dest}.log" 2>&1
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        echo "driver GAP_WORKERS=$workers failed (exit $rc)" >&2
        cat "${dest}.log" >&2
        exit 1
    fi
    local run
    run="$(readlink -f -- "$dest/current")"
    if [[ -z "$run" || ! -f "$run/manifest.txt" ]]; then
        echo "driver GAP_WORKERS=$workers published nothing" >&2
        exit 1
    fi
    printf '%s %s\n' "$run/vertices.dat" "$run/edges.dat"
}

parallel_pair() {
    # gfile dest workers -> sets PAR_V and PAR_E, or aborts
    PAR_V=""
    PAR_E=""
    read -r PAR_V PAR_E < <(run_parallel "$1" "$2" "$3")
    if [[ -z "$PAR_V" || -z "$PAR_E" || ! -f "$PAR_V" || ! -f "$PAR_E" ]]; then
        echo "driver produced no readable pair for $1 at GAP_WORKERS=$3" >&2
        exit 1
    fi
}

expect_identical() {
    # name a_v a_e b_v b_e [mode]
    local name="$1" av="$2" ae="$3" bv="$4" be="$5" mode="${6:-exact}"
    if [[ "$mode" == exact ]]; then
        if ! cmp -s "$av" "$bv" || ! cmp -s "$ae" "$be"; then
            echo "not byte-identical: $name" >&2
            python3 "$COMPARE" "$av" "$ae" "$bv" "$be" --mode exact >&2 || true
            exit 1
        fi
    fi
    if ! python3 "$COMPARE" "$av" "$ae" "$bv" "$be" --mode "$mode" >/dev/null; then
        echo "comparator reported a difference in mode $mode: $name" >&2
        python3 "$COMPARE" "$av" "$ae" "$bv" "$be" --mode "$mode" >&2 || true
        exit 1
    fi
    echo "  ok: $name (${mode})"
}

expect_different() {
    # name a_v a_e b_v b_e
    local name="$1" av="$2" ae="$3" bv="$4" be="$5" rc=0
    if cmp -s "$av" "$bv" && cmp -s "$ae" "$be"; then
        echo "expected a byte difference: $name" >&2
        exit 1
    fi
    set +e
    python3 "$COMPARE" "$av" "$ae" "$bv" "$be" --mode normalized >/dev/null
    rc=$?
    set -e
    if [[ "$rc" -ne 1 ]]; then
        echo "expected the normalized comparison to reject $name (exit $rc)" >&2
        exit 1
    fi
    echo "  ok: $name rejected"
}

degree_ok() {
    local name="$1" v="$2" e="$3" out rc=0
    set +e
    out="$(python3 "$DEGREE" "$v" "$e" 2>&1)"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        echo "degree check failed: $name" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
    echo "  ok: degree check passes for $name"
}

echo "== fixture: label settings, v11 vs generate_rrm_v11_fast.g =="
mkdir -p "$OUT/fixture"
# Every way of passing labels to generate_rrm: omitted, one argument, both.
for labels in "" "true" "false" "true,true" "true,false" "false,true" "false,false"; do
    tag="${labels//,/_}"
    tag="${tag:-default}"
    run_generate generate_rrm_v11.g "$FIXTURE" \
        "$OUT/fixture/v11_${tag}_v.dat" "$OUT/fixture/v11_${tag}_e.dat" "$labels"
    run_generate generate_rrm_v11_fast.g "$FIXTURE" \
        "$OUT/fixture/fast_${tag}_v.dat" "$OUT/fixture/fast_${tag}_e.dat" "$labels"
    expect_identical "fixture labels='${labels:-<default>}'" \
        "$OUT/fixture/v11_${tag}_v.dat" "$OUT/fixture/v11_${tag}_e.dat" \
        "$OUT/fixture/fast_${tag}_v.dat" "$OUT/fixture/fast_${tag}_e.dat"
done
# The omitted and single-argument forms must default to the two-argument form.
expect_identical "labels omitted defaults to true,true" \
    "$OUT/fixture/v11_true_true_v.dat" "$OUT/fixture/v11_true_true_e.dat" \
    "$OUT/fixture/v11_default_v.dat" "$OUT/fixture/v11_default_e.dat"
expect_identical "labels=true defaults elabel to true" \
    "$OUT/fixture/v11_true_true_v.dat" "$OUT/fixture/v11_true_true_e.dat" \
    "$OUT/fixture/v11_true_v.dat" "$OUT/fixture/v11_true_e.dat"
expect_identical "labels=false defaults elabel to true" \
    "$OUT/fixture/v11_false_true_v.dat" "$OUT/fixture/v11_false_true_e.dat" \
    "$OUT/fixture/v11_false_v.dat" "$OUT/fixture/v11_false_e.dat"
GOLD_V="$OUT/fixture/v11_true_true_v.dat"
GOLD_E="$OUT/fixture/v11_true_true_e.dat"
degree_ok "fixture" "$GOLD_V" "$GOLD_E"
if ! grep -q -- '--' "$GOLD_E" || ! grep -qE '^([0-9]+)--\1\[' "$GOLD_E"; then
    echo "fixture must contain self-loops" >&2
    exit 1
fi
if [[ "$(grep -c '^1--4\[' "$GOLD_E")" -lt 2 ]]; then
    echo "fixture must contain parallel edges between the same vertices" >&2
    exit 1
fi
if ! grep -q 'label="1\*' "$GOLD_V" || ! grep -q 'label="2\*' "$GOLD_E"; then
    echo "fixture must contain an inversion-isomer EQ and TS" >&2
    exit 1
fi
echo "fixture covers self-loops, parallel edges and inversion isomers"

echo "== fixture: parallel driver worker counts (1, 2, 3, 5, 8 with 5 TS) =="
for w in 1 2 3 5 8; do
    parallel_pair "$FIXTURE" "$OUT/fixture/par${w}" "$w"
    expect_identical "fixture GAP_WORKERS=$w vs v11" "$GOLD_V" "$GOLD_E" "$PAR_V" "$PAR_E"
    expect_identical "fixture GAP_WORKERS=$w vs v11" "$GOLD_V" "$GOLD_E" "$PAR_V" "$PAR_E" normalized
    degree_ok "fixture GAP_WORKERS=$w" "$PAR_V" "$PAR_E"
done
echo "worker counts at, below and above the TS count agree with v11"

echo "== fixture: TS=0 =="
mkdir -p "$OUT/zero"
run_generate generate_rrm_v11.g "$ZERO_TS" "$OUT/zero/v11_v.dat" "$OUT/zero/v11_e.dat" "true,true"
run_generate generate_rrm_v11_fast.g "$ZERO_TS" "$OUT/zero/fast_v.dat" "$OUT/zero/fast_e.dat" "true,true"
expect_identical "TS=0 fast vs v11" \
    "$OUT/zero/v11_v.dat" "$OUT/zero/v11_e.dat" "$OUT/zero/fast_v.dat" "$OUT/zero/fast_e.dat"
if [[ -s "$OUT/zero/v11_e.dat" ]]; then
    echo "TS=0 must produce an empty edge file" >&2
    exit 1
fi
for w in 1 2 3; do
    parallel_pair "$ZERO_TS" "$OUT/zero/par${w}" "$w"
    expect_identical "TS=0 GAP_WORKERS=$w vs v11" \
        "$OUT/zero/v11_v.dat" "$OUT/zero/v11_e.dat" "$PAR_V" "$PAR_E"
done
# An empty edge file is legitimate here. It is not evidence that any map is
# correct: the degree check passes on it either way.
degree_ok "TS=0 (empty edges are legitimate, not a correctness signal)" \
    "$OUT/zero/v11_v.dat" "$OUT/zero/v11_e.dat"

echo "== label settings the driver does not expose, via the GAP entry points =="
mkdir -p "$OUT/entry"
for combo in "true true" "true false" "false true" "false false"; do
    read -r vlabel elabel <<<"$combo"
    tag="v${vlabel}_e${elabel}"
    run_entrypoints "$FIXTURE" "$OUT/entry/${tag}_v.dat" "$OUT/entry/${tag}_e.dat" "$vlabel" "$elabel"
    expect_identical "entry points vlabel=$vlabel elabel=$elabel vs v11" \
        "$OUT/fixture/v11_${vlabel}_${elabel}_v.dat" \
        "$OUT/fixture/v11_${vlabel}_${elabel}_e.dat" \
        "$OUT/entry/${tag}_v.dat" "$OUT/entry/${tag}_e.dat"
done

echo "== labels off: the output is the labelled output with the labels removed =="
expect_identical "labels off keeps the id/cluster contract" \
    "$OUT/fixture/v11_true_true_v.dat" "$OUT/fixture/v11_true_true_e.dat" \
    "$OUT/fixture/v11_false_false_v.dat" "$OUT/fixture/v11_false_false_e.dat" structure
# The semantic correspondence for the unlabelled run is kept by the labelled
# run above; the unlabelled files themselves only carry the id contract.
if python3 "$COMPARE" \
        "$OUT/fixture/v11_false_false_v.dat" "$OUT/fixture/v11_false_false_e.dat" \
        "$OUT/fixture/v11_false_false_v.dat" "$OUT/fixture/v11_false_false_e.dat" \
        --mode normalized --key label >/dev/null 2>&1; then
    echo "normalized --key label must refuse unlabelled input" >&2
    exit 1
fi
expect_identical "labels off id contract" \
    "$OUT/fixture/v11_false_false_v.dat" "$OUT/fixture/v11_false_false_e.dat" \
    "$OUT/fixture/fast_false_false_v.dat" "$OUT/fixture/fast_false_false_e.dat" normalized

echo "== order: cmp is the contract, the normalized comparison is not order-bound =="
tac "$GOLD_E" >"$OUT/fixture/reordered_e.dat"
if cmp -s "$GOLD_E" "$OUT/fixture/reordered_e.dat"; then
    echo "reordering the edge file changed nothing" >&2
    exit 1
fi
expect_identical "reordered edges under the normalized comparison" \
    "$GOLD_V" "$GOLD_E" "$GOLD_V" "$OUT/fixture/reordered_e.dat" normalized

echo "== what a full comparison detects and a degree check does not =="
for mutation in swap-endpoints ts-label perm-label; do
    python3 "$MUTATE" "$mutation" "$GOLD_E" "$OUT/fixture/mut_${mutation}_e.dat"
    degree_ok "mutation ${mutation}" "$GOLD_V" "$OUT/fixture/mut_${mutation}_e.dat"
    expect_different "mutation ${mutation}" \
        "$GOLD_V" "$GOLD_E" "$GOLD_V" "$OUT/fixture/mut_${mutation}_e.dat"
done
for mutation in drop duplicate open-self-loop; do
    python3 "$MUTATE" "$mutation" "$GOLD_E" "$OUT/fixture/mut_${mutation}_e.dat"
    expect_different "mutation ${mutation}" \
        "$GOLD_V" "$GOLD_E" "$GOLD_V" "$OUT/fixture/mut_${mutation}_e.dat"
done
echo "a passing EQ-degree check is not evidence that the map is right"

echo "== Au5Ag: v11 vs fast vs parallel =="
mkdir -p "$OUT/au5ag"
run_generate generate_rrm_v11.g "$AU5AG" "$OUT/au5ag/v11_v.dat" "$OUT/au5ag/v11_e.dat" "true,true"
run_generate generate_rrm_v11_fast.g "$AU5AG" "$OUT/au5ag/fast_v.dat" "$OUT/au5ag/fast_e.dat" "true,true"
expect_identical "Au5Ag fast vs v11" \
    "$OUT/au5ag/v11_v.dat" "$OUT/au5ag/v11_e.dat" "$OUT/au5ag/fast_v.dat" "$OUT/au5ag/fast_e.dat"
for w in 1 2 3; do
    parallel_pair "$AU5AG" "$OUT/au5ag/par${w}" "$w"
    expect_identical "Au5Ag GAP_WORKERS=$w vs v11" \
        "$OUT/au5ag/v11_v.dat" "$OUT/au5ag/v11_e.dat" "$PAR_V" "$PAR_E"
done
degree_ok "Au5Ag" "$OUT/au5ag/v11_v.dat" "$OUT/au5ag/v11_e.dat"

echo "== AuCu4 continue mode: v11 vs fast vs parallel =="
mkdir -p "$OUT/aucu4"
run_generate generate_rrm_v11.g "$AUCU4" "$OUT/aucu4/v11_v.dat" "$OUT/aucu4/v11_e.dat" "true,true"
if ! grep -q "Violation of Pechukus theorem" "$OUT/aucu4/v11_e.dat.log"; then
    echo "AuCu4 must report the Pechukas violations under v11" >&2
    exit 1
fi
export RRM_CONTINUE_ON_PECHUKAS=1
run_generate generate_rrm_v11_fast.g "$AUCU4" "$OUT/aucu4/fast_v.dat" "$OUT/aucu4/fast_e.dat" "true,true"
expect_identical "AuCu4 continue mode fast vs v11" \
    "$OUT/aucu4/v11_v.dat" "$OUT/aucu4/v11_e.dat" "$OUT/aucu4/fast_v.dat" "$OUT/aucu4/fast_e.dat"
for w in 1 2 3; do
    parallel_pair "$AUCU4" "$OUT/aucu4/par${w}" "$w"
    expect_identical "AuCu4 continue mode GAP_WORKERS=$w vs v11" \
        "$OUT/aucu4/v11_v.dat" "$OUT/aucu4/v11_e.dat" "$PAR_V" "$PAR_E"
done
unset RRM_CONTINUE_ON_PECHUKAS

echo "== AuCu4 default policy: no equivalence claim, nothing published =="
set +e
"$GAP" -T -b -q -r -m "$MEM" >"$OUT/aucu4/default.log" 2>&1 <<EOF
Read("${ROOT}/generate_rrm_v11_fast.g");
Read("${AUCU4}");
generate_rrm("$OUT/aucu4/default_v.dat","$OUT/aucu4/default_e.dat",symc,ur,urt,ss,org_eq,org_ts,true,true);
Print("UNREACHABLE\n");
QUIT;
EOF
default_rc=$?
set -e
if [[ "$default_rc" -eq 0 ]] || grep -q UNREACHABLE "$OUT/aucu4/default.log"; then
    echo "AuCu4 must fail closed without RRM_CONTINUE_ON_PECHUKAS" >&2
    cat "$OUT/aucu4/default.log" >&2
    exit 1
fi
if [[ -e "$OUT/aucu4/default_v.dat" || -e "$OUT/aucu4/default_e.dat" ]]; then
    echo "AuCu4 default policy must not write dat files" >&2
    exit 1
fi
set +e
GAP="$GAP" MEM="$MEM" GAP_WORKERS=2 \
    "$DRIVER" --bundle "$OUT/aucu4/default_bundle" "$AUCU4" >"$OUT/aucu4/default_par.log" 2>&1
default_par_rc=$?
set -e
if [[ "$default_par_rc" -eq 0 || -L "$OUT/aucu4/default_bundle/current" ]]; then
    echo "parallel AuCu4 must fail closed and publish nothing" >&2
    cat "$OUT/aucu4/default_par.log" >&2
    exit 1
fi
echo "  ok: default policy exits non-zero and publishes nothing (exit $default_rc / $default_par_rc)"

echo "PASS"
