#!/bin/bash
# Streaming dat degree checker: same EQ-number degrees, O(V) memory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="${ROOT}/check_number_of_edges_dat.py"
OUT="${OUT:-/tmp/rrm-dat-degree-test}"

mkdir -p "$OUT"

if [[ ! -f "$CHECK" ]]; then
    echo "RED: $CHECK is missing" >&2
    exit 1
fi

run_check() {
    python3 "$CHECK" "$1" "$2"
}

expect_ok() {
    local name="$1" vfile="$2" efile="$3"
    local out rc
    set +e
    out="$(run_check "$vfile" "$efile" 2>&1)"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        echo "expected pass: $name (exit $rc)" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
    if [[ "$out" != "All vertices with the same number have consistent degrees." ]]; then
        echo "unexpected pass message: $name" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
}

expect_fail() {
    local name="$1" vfile="$2" efile="$3"
    shift 3
    local out rc
    set +e
    out="$(run_check "$vfile" "$efile" 2>&1)"
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
        echo "expected fail: $name" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
    if [[ "$out" == *Traceback* ]]; then
        echo "expected a CLI diagnostic without a traceback: $name" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
    local needle
    for needle in "$@"; do
        if ! grep -Fq -- "$needle" <<<"$out"; then
            echo "missing '$needle' in $name output" >&2
            printf '%s\n' "$out" >&2
            exit 1
        fi
    done
}

# Same EQ, equal degrees (triangle).
cat >"$OUT/ok_v.dat" <<'EOF'
subgraph cluster_0 { label="0";
fontsize="30pt"
1[label="0 ()"]
2[label="0 (2,3)"]
3[label="0 (2,4)"]
}
EOF
cat >"$OUT/ok_e.dat" <<'EOF'
1--2[label="0 ()"]
2--3[label="0 (2,3)"]
3--1[label="0 (2,4)"]
EOF
expect_ok "consistent" "$OUT/ok_v.dat" "$OUT/ok_e.dat"

# Same EQ, unequal degrees.
cat >"$OUT/bad_v.dat" <<'EOF'
subgraph cluster_0 { label="0";
fontsize="30pt"
1[label="0 ()"]
2[label="0 (2,3)"]
}
EOF
cat >"$OUT/bad_e.dat" <<'EOF'
1--2[label="0 ()"]
1--1[label="1 ()"]
EOF
expect_fail "inconsistent" "$OUT/bad_v.dat" "$OUT/bad_e.dat" \
    "Error: Inconsistent degrees for vertices with the same number found:" \
    "Number 0:" \
    "vertex 1 (degree 2)" \
    "vertex 2 (degree 1)"

# 0 and 0* are separate groups: only 0* is inconsistent.
cat >"$OUT/inv_v.dat" <<'EOF'
subgraph cluster_0 { label="0";
fontsize="30pt"
1[label="0 ()"]
2[label="0 (2,3)"]
}
subgraph cluster_1 { label="0*";
fontsize="30pt"
3[label="0* ()"]
4[label="0* (2,3)"]
}
EOF
cat >"$OUT/inv_e.dat" <<'EOF'
1--2[label="0 ()"]
3--4[label="0 ()"]
3--3[label="1 ()"]
EOF
expect_fail "0 vs 0*" "$OUT/inv_v.dat" "$OUT/inv_e.dat" \
    "Number 0*:" \
    "vertex 3 (degree 2)" \
    "vertex 4 (degree 1)"
if grep -Fq "Number 0:" <<<"$(run_check "$OUT/inv_v.dat" "$OUT/inv_e.dat" || true)"; then
    echo "group 0 should stay consistent while 0* fails" >&2
    exit 1
fi

# Self-loop counts once: both vertices degree 2.
cat >"$OUT/loop_v.dat" <<'EOF'
subgraph cluster_0 { label="1";
fontsize="30pt"
1[label="1 ()"]
2[label="1 (2,3)"]
}
EOF
cat >"$OUT/loop_e.dat" <<'EOF'
1--2
1--1
2--2
EOF
expect_ok "self-loop" "$OUT/loop_v.dat" "$OUT/loop_e.dat"

# Unlabeled vertices inherit the cluster label.
cat >"$OUT/bare_v.dat" <<'EOF'
subgraph cluster_0 { label="2";
fontsize="30pt"
1
2
}
EOF
cat >"$OUT/bare_e.dat" <<'EOF'
1--2
2--1
EOF
expect_ok "unlabeled" "$OUT/bare_v.dat" "$OUT/bare_e.dat"

# Edge to a missing vertex is fail-closed.
cat >"$OUT/miss_v.dat" <<'EOF'
subgraph cluster_0 { label="0";
fontsize="30pt"
1[label="0 ()"]
}
EOF
cat >"$OUT/miss_e.dat" <<'EOF'
1--9[label="0 ()"]
EOF
expect_fail "out of range" "$OUT/miss_v.dat" "$OUT/miss_e.dat" \
    "Error: edge 1--9 refers to a missing vertex"

# A bare vertex after the cluster closes must not inherit the old EQ.
cat >"$OUT/after_v.dat" <<'EOF'
subgraph cluster_0 { label="0";
fontsize="30pt"
1
}
2
EOF
cat >"$OUT/after_e.dat" <<'EOF'
1--2
EOF
expect_fail "bare after cluster" "$OUT/after_v.dat" "$OUT/after_e.dat" \
    "unlabeled vertex 2 has no cluster"

# Sparse IDs must not grow arrays to max(id). GAP writes 1..N.
cat >"$OUT/sparse_v.dat" <<'EOF'
subgraph cluster_0 { label="0";
fontsize="30pt"
1[label="0 ()"]
3[label="0 (2,3)"]
}
EOF
cat >"$OUT/sparse_e.dat" <<'EOF'
1--3
EOF
expect_fail "sparse ids" "$OUT/sparse_v.dat" "$OUT/sparse_e.dat" \
    "vertex ids must be contiguous"

cat >"$OUT/huge_v.dat" <<'EOF'
subgraph cluster_0 { label="0";
fontsize="30pt"
1[label="0 ()"]
1000000000[label="0 (2,3)"]
}
EOF
: >"$OUT/huge_e.dat"
expect_fail "huge id" "$OUT/huge_v.dat" "$OUT/huge_e.dat" \
    "vertex ids must be contiguous"

# Local Au5Ag dat if present (generated artifacts are not in git).
if [[ -f "${ROOT}/vertices_Au5Ag_AFIR.dat" && -f "${ROOT}/edges_Au5Ag_AFIR.dat" ]]; then
    expect_ok "Au5Ag dat" "${ROOT}/vertices_Au5Ag_AFIR.dat" "${ROOT}/edges_Au5Ag_AFIR.dat"
fi

echo "PASS"
