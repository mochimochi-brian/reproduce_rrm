#!/bin/bash
# Issue #4: Pechukas violation must stop by default (non-zero, no dat files).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GAP="${GAP:-gap}"
OUT="${OUT:-/tmp/rrm-pechukas-test}"
MEM="${MEM:-12g}"
GFILE="${ROOT}/data/AuCu4_AFIR.g"

cd "$ROOT"
rm -rf "$OUT"
mkdir -p "$OUT"

if [[ ! -f "$GFILE" ]]; then
    echo "RED: $GFILE is missing" >&2
    exit 1
fi

echo "== AuCu4 default: Pechukas violation must abort before writing dat files =="
set +e
"$GAP" -T -b -q -r -m "$MEM" >"$OUT/default.log" 2>&1 <<EOF
Read("${ROOT}/generate_rrm_v11_fast.g");
Read("${GFILE}");
generate_rrm("${OUT}/v.dat","${OUT}/e.dat",symc,ur,urt,ss,org_eq,org_ts,true,true);
Print("UNREACHABLE\n");
QUIT;
EOF
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
    echo "expected non-zero exit on AuCu4 Pechukas violation" >&2
    cat "$OUT/default.log" >&2
    exit 1
fi
if grep -q UNREACHABLE "$OUT/default.log"; then
    echo "generate_rrm continued after Pechukas violation" >&2
    cat "$OUT/default.log" >&2
    exit 1
fi
if [[ -e "$OUT/v.dat" || -e "$OUT/e.dat" ]]; then
    echo "dat files were written after a Pechukas violation" >&2
    ls -l "$OUT"/*.dat >&2
    exit 1
fi
if ! grep -q "Violation of Pechukus theorem" "$OUT/default.log"; then
    echo "expected the existing Pechukas diagnostic" >&2
    cat "$OUT/default.log" >&2
    exit 1
fi
echo "default abort ok (exit $rc)"

echo "== AuCu4 continue flag: print-and-continue, dat files written =="
set +e
RRM_CONTINUE_ON_PECHUKAS=1 "$GAP" -T -b -q -r -m "$MEM" >"$OUT/continue.log" 2>&1 <<EOF
Read("${ROOT}/generate_rrm_v11_fast.g");
Read("${GFILE}");
generate_rrm("${OUT}/v_cont.dat","${OUT}/e_cont.dat",symc,ur,urt,ss,org_eq,org_ts,true,true);
Print("REACHED_END\n");
QUIT;
EOF
cont_rc=$?
set -e
if [[ "$cont_rc" -ne 0 ]]; then
    echo "continue flag should restore v11 print-and-continue (exit 0)" >&2
    cat "$OUT/continue.log" >&2
    exit 1
fi
if ! grep -q REACHED_END "$OUT/continue.log"; then
    echo "generate_rrm did not finish under continue flag" >&2
    cat "$OUT/continue.log" >&2
    exit 1
fi
if [[ ! -s "$OUT/v_cont.dat" || ! -s "$OUT/e_cont.dat" ]]; then
    echo "continue flag must still write dat files" >&2
    ls -l "$OUT" >&2
    exit 1
fi
if ! grep -q "TS8:" "$OUT/continue.log" || ! grep -q "TS16:" "$OUT/continue.log"; then
    echo "continue flag should report both AuCu4 Pechukas violations" >&2
    cat "$OUT/continue.log" >&2
    exit 1
fi
echo "continue flag ok"

echo "== Au5Ag: still succeeds with default (no continue flag) =="
AGFILE="${ROOT}/data/Au5Ag_AFIR.g"
if [[ ! -f "$AGFILE" ]]; then
    echo "RED: $AGFILE is missing" >&2
    exit 1
fi
set +e
"$GAP" -T -b -q -r -m "$MEM" >"$OUT/au5ag.log" 2>&1 <<EOF
Read("${ROOT}/generate_rrm_v11_fast.g");
Read("${AGFILE}");
generate_rrm("${OUT}/v_ag.dat","${OUT}/e_ag.dat",symc,ur,urt,ss,org_eq,org_ts,true,true);
Print("AU5AG_OK\n");
QUIT;
EOF
ag_rc=$?
set -e
if [[ "$ag_rc" -ne 0 ]]; then
    echo "Au5Ag must still succeed under the default Pechukas policy" >&2
    cat "$OUT/au5ag.log" >&2
    exit 1
fi
if ! grep -q AU5AG_OK "$OUT/au5ag.log"; then
    echo "Au5Ag generate_rrm did not finish" >&2
    cat "$OUT/au5ag.log" >&2
    exit 1
fi
if grep -q "Violation of Pechukus theorem" "$OUT/au5ag.log"; then
    echo "Au5Ag should not report a Pechukas violation" >&2
    cat "$OUT/au5ag.log" >&2
    exit 1
fi
if [[ ! -s "$OUT/v_ag.dat" || ! -s "$OUT/e_ag.dat" ]]; then
    echo "Au5Ag dat files missing" >&2
    exit 1
fi
echo "Au5Ag ok"

echo "PASS"
