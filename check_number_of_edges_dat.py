#!/usr/bin/env python3
"""Stream vertices_*.dat / edges_*.dat and check EQ-number degree consistency.

This is a necessary condition, not a correctness check. Every vertex carrying
the same EQ number must have the same degree; graphs that satisfy that and are
still wrong pass here. K3,3 and the triangular prism (six vertices, nine edges,
degree three) both pass when all vertices share an EQ, and so does a file with
no edges at all. Use tests/compare_rrm_dat.py against a reference run to compare
labeled graphs, and see the README section "Equivalence with the reference
implementation".
"""
import re
import sys
from collections import defaultdict

VERTEX_LABELED = re.compile(r'^(\d+)\[label="([^"]+)"\]$')
VERTEX_BARE = re.compile(r'^(\d+)$')
CLUSTER = re.compile(r'subgraph\s+cluster_\S+\s*\{\s*label="([^"]+)"')
EDGE = re.compile(r'^(\d+)--(\d+)(?:\[label="[^"]*"\])?$')


def _append(eq_of, deg, vid, eq):
    expected = len(deg)
    if vid != expected:
        raise ValueError(
            "Error: vertex ids must be contiguous starting at 1, got {} (expected {})".format(
                vid, expected
            )
        )
    eq_of.append(eq)
    deg.append(0)


def parse_vertices(filename):
    eq_of = [None]
    deg = [0]
    current_eq = None
    with open(filename, 'r') as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith('fontsize'):
                continue
            if line == '}':
                current_eq = None
                continue
            m = CLUSTER.search(line)
            if m:
                current_eq = m.group(1)
                continue
            m = VERTEX_LABELED.match(line)
            if m:
                vid = int(m.group(1))
                number = m.group(2).split()[0]
                if current_eq is not None and number != current_eq:
                    raise ValueError(
                        "Error: vertex {} label {} does not match cluster {}".format(
                            vid, number, current_eq
                        )
                    )
                _append(eq_of, deg, vid, number)
                continue
            m = VERTEX_BARE.match(line)
            if m:
                vid = int(m.group(1))
                if current_eq is None:
                    raise ValueError("Error: unlabeled vertex {} has no cluster".format(vid))
                _append(eq_of, deg, vid, current_eq)
                continue
            raise ValueError("Error: cannot parse vertex line: {}".format(line))
    return eq_of, deg


def apply_edges(filename, eq_of, deg):
    n = len(deg) - 1
    with open(filename, 'r') as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            m = EDGE.match(line)
            if not m:
                raise ValueError("Error: cannot parse edge line: {}".format(line))
            v1, v2 = int(m.group(1)), int(m.group(2))
            if (
                v1 < 1
                or v1 > n
                or v2 < 1
                or v2 > n
                or eq_of[v1] is None
                or eq_of[v2] is None
            ):
                raise ValueError("Error: edge {}--{} refers to a missing vertex".format(v1, v2))
            deg[v1] += 1
            if v1 != v2:
                deg[v2] += 1


def check_consistency(eq_of, deg):
    groups = defaultdict(list)
    for vid in range(1, len(deg)):
        eq = eq_of[vid]
        if eq is None:
            continue
        groups[eq].append((vid, deg[vid]))

    errors = {}
    for num, verts in groups.items():
        degs = set(d for _, d in verts)
        if len(degs) > 1:
            errors[num] = verts
    return errors


def main():
    if len(sys.argv) != 3:
        print("Usage: {} <vertices.dat> <edges.dat>".format(sys.argv[0]), file=sys.stderr)
        sys.exit(1)

    try:
        eq_of, deg = parse_vertices(sys.argv[1])
        apply_edges(sys.argv[2], eq_of, deg)
    except ValueError as error:
        print(error, file=sys.stderr)
        sys.exit(1)
    errors = check_consistency(eq_of, deg)
    if errors:
        print("Error: Inconsistent degrees for vertices with the same number found:")
        for num, verts in errors.items():
            vert_info = ", ".join(
                "vertex {} (degree {})".format(vid, d) for vid, d in verts
            )
            print("Number {}: {}".format(num, vert_info))
        sys.exit(1)
    print("All vertices with the same number have consistent degrees.")


if __name__ == '__main__':
    main()
