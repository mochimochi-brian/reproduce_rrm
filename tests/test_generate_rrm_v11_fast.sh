#!/bin/bash
# generate_rrm_v11_fast.g must match v11 dat files, pass the edge checker, and abort on fail.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GAP="${GAP:-gap}"
OUT="${OUT:-/tmp/rrm-v11-fast-test}"
MEM="${MEM:-12g}"
GFILE="${ROOT}/data/Au5Ag_AFIR.g"
FAST="generate_rrm_v11_fast.g"

cd "$ROOT"
mkdir -p "$OUT"

if [[ ! -f "$ROOT/$FAST" ]]; then
    echo "RED: $FAST is missing" >&2
    exit 1
fi

echo "== unit: RrmVertexIndex =="
"$GAP" -b -q -r <<EOF
Read("${ROOT}/tests/test_rrm_vertex_index.g");
QUIT;
EOF

echo "== Au5Ag: v11 gold vs v11_fast =="
run_one() {
    local src="$1" tag="$2"
    /usr/bin/time -p "$GAP" -b -q -r -m "$MEM" <<EOF
Read("${ROOT}/${src}");
Read("${GFILE}");
t:=Runtime();
generate_rrm("${OUT}/${tag}_v.dat","${OUT}/${tag}_e.dat",symc,ur,urt,ss,org_eq,org_ts,true,true);
Print("ms_${tag}=", Runtime()-t, "\n");
QUIT;
EOF
}

run_one generate_rrm_v11.g v11
run_one "$FAST" fast

cmp -s "${OUT}/v11_v.dat" "${OUT}/fast_v.dat"
cmp -s "${OUT}/v11_e.dat" "${OUT}/fast_e.dat"
echo "Au5Ag vertices/edges byte-identical to v11"

{
    echo "graph G {"
    cat "${OUT}/fast_v.dat"
    cat "${OUT}/fast_e.dat"
    echo "}"
} > "${OUT}/Au5Ag_fast.dot"
python3 "${ROOT}/check_number_of_edges_v3.py" "${OUT}/Au5Ag_fast.dot"

echo "== fail-closed: missing vertex must Error (gap -T, non-zero) =="
set +e
fail_out="$OUT/fail_closed.log"
"$GAP" -T -b -q -r >"$fail_out" 2>&1 <<EOF
Read("${ROOT}/${FAST}");
RrmVertexIndex([0], [[1,2,3]], 1, 99);
Print("UNREACHABLE\n");
QUIT;
EOF
fail_rc=$?
set -e
if [[ "$fail_rc" -eq 0 ]]; then
    echo "expected non-zero exit from missing lookup" >&2
    cat "$fail_out" >&2
    exit 1
fi
if grep -q UNREACHABLE "$fail_out"; then
    echo "lookup continued after fail" >&2
    cat "$fail_out" >&2
    exit 1
fi
if grep -q '^fail$' "$fail_out"; then
    echo "lookup printed the string fail" >&2
    cat "$fail_out" >&2
    exit 1
fi
echo "fail-closed ok (exit $fail_rc)"

echo "PASS"
