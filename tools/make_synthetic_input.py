#!/usr/bin/env python3
"""Generate a synthetic GAP input (`*.g`) for benchmarking the RRM producers.

The real GRRM catalogues that are large enough to show the cost of the GAP step
cannot always be shared, so this script writes a *fictitious* input with the
same shape as the files produced by ``rrm_reconstruction_v18.py``: it binds
``sym``, ``symc``, ``ur``, ``urt``, ``ss``, ``org_eq`` and ``org_ts``, which is
everything ``generate_rrm`` (and ``generate_rrm_vertices`` /
``generate_rrm_edge_shard``) reads.

What the generated input is, and what it is not
-----------------------------------------------

* ``sym = symc = SymmetricGroup([2..n+1])``: *n* identical atoms plus one
  distinct atom (point 1), i.e. the CNPI group of an A B_n cluster **without**
  the inversion extension. ``org_eq``/``org_ts`` are therefore the identity
  maps and no starred (inversion isomer) labels occur. Real monometallic
  catalogues have |CNPI| = 2 n! when inversion copies are distinct; a synthetic
  input with S_n only halves the vertex and edge counts for a given n.
* Stabilizers ``ur[i]`` are drawn from a fixed catalogue of subgroups
  (trivial, one transposition, or the symmetric group on the first
  ``--large-eq-points`` identical atoms), so the vertex count per EQ is
  |sym| / |ur[i]| exactly as in a real map.
* ``urt[i]`` is computed *in GAP* as the intersection of the four conjugates
  ``ur[a]^s1``, ``ur[a]^(s1^-1)``, ``ur[b]^s2``, ``ur[b]^(s2^-1)``. It is
  therefore a subgroup of whichever conjugate each branch of the Pechukas
  check inspects, so a generated input never violates Pechukas's theorem and
  all three producers run to completion on it.
* The geometry is fictitious. The file is a *load model* for the group-theory
  and I/O work of the GAP step (vertex enumeration, coset lookups, edge
  expansion, streamed writes). It says nothing about a physically meaningful
  reaction network, and it must not be used to validate chemistry.

Load skew
---------

Every ``--light-period``-th TS is a *light* TS: both endpoints are the EQ with
the large stabilizer and both permutations are the identity, so
``urt = ur[large]`` and the TS expands to |sym| / |ur[large]| edges. All other
TSs get random permutations and expand to |sym| / |urt| edges, which is the
full |sym| whenever the conjugate intersection is trivial -- the usual case when
the endpoint stabilizers are trivial, and not the case when ``--large-eqs`` puts
large stabilizers on every EQ, where a few intermediate expansions appear as
well. Either way the light TSs are far cheaper than the rest, which is a
controlled, documented imbalance between transition states -- the input class
the parallel driver is most sensitive to, because it splits work by TS count.
Run ``tools/rrm_input_stats.g`` on the result for the exact per-TS expansions.

Reproducibility
---------------

Output is byte-deterministic for a given (n, eqs, ts, seed, ...) tuple on any
Python 3.9+: the script uses its own xorshift64* generator rather than the
``random`` module, and writes the invocation and a summary into the header of
the generated file. Regenerate and compare with ``sha256sum`` to confirm you
have the same input.

Example::

    python3 tools/make_synthetic_input.py --identical 6 --eqs 8 --ts 30 \\
        --seed 1 -o data/synth_n6_e8_t30.g
"""

import argparse
import os
import sys


class Xorshift64:
    """Small deterministic PRNG, so generated inputs do not depend on the
    Python version (``random`` makes no such promise across releases)."""

    MASK = (1 << 64) - 1

    def __init__(self, seed: int) -> None:
        state = (seed ^ 0x9E3779B97F4A7C15) & self.MASK
        self.state = state or 0x9E3779B97F4A7C15

    def u64(self) -> int:
        x = self.state
        x ^= (x << 13) & self.MASK
        x ^= x >> 7
        x ^= (x << 17) & self.MASK
        self.state = x & self.MASK
        # xorshift64* output stage
        return (self.state * 0x2545F4914F6CDD1D) & self.MASK

    def below(self, n: int) -> int:
        if n <= 0:
            raise ValueError("below() needs a positive bound")
        # Rejection sampling keeps the distribution uniform and the stream
        # reproducible independently of the bound.
        limit = self.MASK - (self.MASK % n)
        while True:
            v = self.u64()
            if v <= limit:
                return v % n

    def shuffled(self, items):
        out = list(items)
        for i in range(len(out) - 1, 0, -1):
            j = self.below(i + 1)
            out[i], out[j] = out[j], out[i]
        return out


def perm_list(images):
    """GAP ``PermList`` term for the map 1->1, point k -> images[k-2]."""
    return "PermList([1,%s])" % ",".join(str(p) for p in images)


def eq_stabilizer_terms(n_identical: int, eqs: int, large_points: int,
                        transposition_period: int, large_eqs: int = 1):
    """GAP terms for ``ur``, one per EQ.

    The first ``large_eqs`` EQs carry the large stabilizer (the symmetric group
    on the first ``large_points`` identical atoms), which keeps their vertex
    count down; every ``transposition_period``-th further EQ carries a single
    transposition; the rest are trivial, which is also what dominates the real
    Au5Ag/AuCu4 inputs. Raising ``--large-eqs`` shrinks the vertex count without
    touching the edge count, which is how an edge-dominated input is built.
    """
    terms = []
    for i in range(1, eqs + 1):
        if i <= large_eqs and large_points >= 2:
            gens = []
            # SymmetricGroup on points 2..large_points+1 via a transposition
            # and a cycle, written as PermLists for readability.
            images = list(range(2, n_identical + 2))
            swap = images[:]
            swap[0], swap[1] = swap[1], swap[0]
            gens.append(perm_list(swap))
            cyc = images[:]
            head = cyc[:large_points]
            head = head[1:] + head[:1]
            cyc[:large_points] = head
            gens.append(perm_list(cyc))
            terms.append("Group([%s])" % ",".join(gens))
        elif transposition_period > 0 and i % transposition_period == 0:
            images = list(range(2, n_identical + 2))
            images[0], images[1] = images[1], images[0]
            terms.append("Group([%s])" % perm_list(images))
        else:
            terms.append("Group([()])")
    return terms


def build_ss(rng: Xorshift64, n_identical: int, eqs: int, ts: int,
             light_period: int, same_eq_period: int):
    """Return (list of GAP ``ss`` entries, list of 'light'/'heavy' marks)."""
    points = list(range(2, n_identical + 2))
    identity = perm_list(points)
    entries = []
    marks = []
    for i in range(1, ts + 1):
        if light_period > 0 and i % light_period == 0:
            # Both endpoints are EQ 1 with identity permutations: urt = ur[1],
            # so this TS expands to |sym| / |ur[1]| edges only.
            entries.append("[[1,%s],[1,%s]]" % (identity, identity))
            marks.append("light")
            continue
        a = 1 + rng.below(eqs)
        if same_eq_period > 0 and i % same_eq_period == 0:
            b = a
        else:
            b = 1 + rng.below(eqs)
            if b == a:
                b = 1 + (a % eqs)
        s1 = perm_list(rng.shuffled(points))
        s2 = perm_list(rng.shuffled(points))
        entries.append("[[%d,%s],[%d,%s]]" % (a, s1, b, s2))
        marks.append("heavy")
    return entries, marks


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Write a synthetic GAP input for RRM benchmarking.")
    ap.add_argument("--identical", type=int, default=6,
                    help="number of identical atoms n; sym = S_n on points "
                         "2..n+1 (default 6)")
    ap.add_argument("--eqs", type=int, default=8, help="number of EQs")
    ap.add_argument("--ts", type=int, default=30, help="number of TSs")
    ap.add_argument("--seed", type=int, default=1, help="PRNG seed")
    ap.add_argument("--large-eq-points", type=int, default=3,
                    help="EQ 1 stabilizer is S_k on the first k identical "
                         "atoms (default 3, order 6); use 0 for none")
    ap.add_argument("--large-eqs", type=int, default=1,
                    help="how many EQs carry the large stabilizer (default 1); "
                         "more means fewer vertices per unit of edge work")
    ap.add_argument("--transposition-period", type=int, default=4,
                    help="every p-th EQ gets a transposition stabilizer "
                         "(0 disables)")
    ap.add_argument("--light-period", type=int, default=3,
                    help="every p-th TS expands to |sym|/|ur[1]| edges "
                         "instead of |sym| (0 disables the skew)")
    ap.add_argument("--same-eq-period", type=int, default=5,
                    help="every p-th heavy TS connects permutation isomers of "
                         "one EQ, exercising the same-EQ Pechukas branch "
                         "(0 disables)")
    ap.add_argument("-o", "--output", required=True, help="path of the .g file")
    args = ap.parse_args(argv)

    if args.identical < 2:
        ap.error("--identical must be at least 2")
    if args.eqs < 1 or args.ts < 0:
        ap.error("--eqs must be >= 1 and --ts >= 0")
    if args.large_eq_points and not (2 <= args.large_eq_points <= args.identical):
        ap.error("--large-eq-points must be 0 or between 2 and --identical")
    if not 0 <= args.large_eqs <= args.eqs:
        ap.error("--large-eqs must be between 0 and --eqs")

    rng = Xorshift64(args.seed)
    ur_terms = eq_stabilizer_terms(args.identical, args.eqs,
                                   args.large_eq_points,
                                   args.transposition_period,
                                   args.large_eqs)
    ss_terms, marks = build_ss(rng, args.identical, args.eqs, args.ts,
                               args.light_period, args.same_eq_period)

    invocation = " ".join(
        ["python3 tools/make_synthetic_input.py",
         "--identical", str(args.identical),
         "--eqs", str(args.eqs),
         "--ts", str(args.ts),
         "--seed", str(args.seed),
         "--large-eq-points", str(args.large_eq_points),
         "--large-eqs", str(args.large_eqs),
         "--transposition-period", str(args.transposition_period),
         "--light-period", str(args.light_period),
         "--same-eq-period", str(args.same_eq_period),
         "-o", "<output path>"])
    # The output path is deliberately not part of the file, so that two
    # regenerations under different names still compare equal by sha256.

    header = [
        "# Synthetic RRM input -- NOT a GRRM output and not physically meaningful.",
        "# Generated by tools/make_synthetic_input.py; see that file for the",
        "# construction and its limits. Regenerate byte-identically with:",
        "#   %s" % invocation,
        "# sym = symc = S_%d on points 2..%d (no inversion extension), %d EQs, %d TSs"
        % (args.identical, args.identical + 1, args.eqs, args.ts),
        "# light TSs (|sym|/|ur[1]| edges): %d, heavy TSs (|sym| edges): %d"
        % (marks.count("light"), marks.count("heavy")),
    ]

    body = []
    body.append("sym:=SymmetricGroup([2..%d]);;" % (args.identical + 1))
    body.append("symc:=sym;;")
    body.append("ur:=[%s];;" % ",".join(ur_terms))
    body.append("ss:=[%s];;" % ",".join(ss_terms))
    # urt is derived in GAP so that the Pechukas conditions hold by
    # construction, under either conjugation convention used by the check.
    body.append("urt:=List([1..Length(ss)], i -> Intersection(")
    body.append("        ConjugateGroup(ur[ss[i][1][1]], ss[i][1][2]),")
    body.append("        ConjugateGroup(ur[ss[i][1][1]], ss[i][1][2]^-1),")
    body.append("        ConjugateGroup(ur[ss[i][2][1]], ss[i][2][2]),")
    body.append("        ConjugateGroup(ur[ss[i][2][1]], ss[i][2][2]^-1)));;")
    body.append("org_eq:=[1..Length(ur)];;")
    body.append("org_ts:=[1..Length(ss)];;")

    text = "\n".join(header + body) + "\n"
    out = args.output
    if out == "-":
        sys.stdout.write(text)
    else:
        parent = os.path.dirname(os.path.abspath(out))
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(out, "w", encoding="ascii", newline="\n") as fh:
            fh.write(text)
        sys.stderr.write("wrote %s (%d EQs, %d TSs, %d light TSs)\n"
                         % (out, args.eqs, args.ts, marks.count("light")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
