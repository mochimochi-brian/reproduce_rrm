#!/bin/bash
# Compare a preprocessed real GRRM input against the original v11, byte for byte.
# Usage: GAP=/path/to/gap OUT=/tmp/new-run bash tests/test_rrm_real_input.sh input.g
# Raw output stays outside the repository. OUT must be absent or empty.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GFILE="$(realpath -- "${1:?provide a preprocessed GAP input}")"
GAP="${GAP:-gap}"
MEM="${MEM:-1g}"
OUT="${OUT:-$(mktemp -d /tmp/rrm-real-input.XXXXXXXX)}"
export BASH_ENV=/dev/null
mkdir -p "$OUT"
OUT="$(realpath -- "$OUT")"
case "$OUT/" in
    "$ROOT/"*) echo "OUT must be outside the repository" >&2; exit 1 ;;
esac
if [[ -n "$(ls -A "$OUT")" ]]; then
    echo "OUT must be empty: $OUT" >&2
    exit 1
fi
test -f "$GFILE"
# GAP string literals use backslash escaping, independently of shell quoting.
gap_string() {
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}
input_literal="$(gap_string "$GFILE")"
out_literal="$(gap_string "$OUT")"

for producer in v11 fast; do
    src="$ROOT/generate_rrm_v11.g"
    [[ "$producer" != fast ]] || src="$ROOT/generate_rrm_v11_fast.g"
    cat >"$OUT/$producer.g" <<EOF
Read($(gap_string "$src"));
Read($input_literal);
out:=$out_literal;;
for vl in [true,false] do
    for el in [true,false] do
        tag:=Concatenation("$producer", "_", String(vl), "_", String(el));;
        generate_rrm(Concatenation(out,"/",tag,"_v.dat"),Concatenation(out,"/",tag,"_e.dat"),symc,ur,urt,ss,org_eq,org_ts,vl,el);
    od;
od;
Print("RRM_REAL_INPUT_DONE\n");
QUIT;
EOF
    if ! "$GAP" -T -b -q -r -m "$MEM" "$OUT/$producer.g" >"$OUT/$producer.log" 2>&1; then
        cat "$OUT/$producer.log" >&2
        exit 1
    fi
    grep -qx RRM_REAL_INPUT_DONE "$OUT/$producer.log"
done

compare_pair() {
    local name="$1" av="$2" ae="$3" bv="$4" be="$5"
    cmp "$av" "$bv"
    cmp "$ae" "$be"
    python3 "$ROOT/tests/compare_rrm_dat.py" "$av" "$ae" "$bv" "$be" \
        --mode exact >"$OUT/$name.compare.log"
    printf 'PASS: %s vertices and edges are byte-identical\n' "$name"
}

for vl in true false; do
    for el in true false; do
        compare_pair "labels_${vl}_${el}" \
            "$OUT/v11_${vl}_${el}_v.dat" "$OUT/v11_${vl}_${el}_e.dat" \
            "$OUT/fast_${vl}_${el}_v.dat" "$OUT/fast_${vl}_${el}_e.dat"
    done
done
for workers in 1 2 3; do
    GAP="$GAP" MEM="$MEM" GAP_WORKERS="$workers" \
        "$ROOT/generate_rrm_v11_parallel.sh" --bundle "$OUT/bundle$workers" "$GFILE" \
        >"$OUT/bundle$workers.log" 2>&1
    run="$(readlink -e -- "$OUT/bundle$workers/current")"
    (cd "$run" && sha256sum --check < <(tail -n 2 manifest.txt)) \
        >"$OUT/bundle$workers.checksums.log"
    compare_pair "bundle$workers" "$OUT/v11_true_true_v.dat" "$OUT/v11_true_true_e.dat" \
        "$run/vertices.dat" "$run/edges.dat"
done
sha256sum "$OUT"/*.dat >"$OUT/SHA256SUMS"
printf 'PASS: all 7 pairs match original v11; raw output: %s\n' "$OUT"
