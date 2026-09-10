#!/usr/bin/env python3
"""Mutate an edges dat file so the full comparison has something to catch.

Used by tests/test_rrm_full_comparison.sh.  Each mutation is the kind of
corruption an EQ-degree check cannot see on its own.

  swap-endpoints  exchange the second endpoints of two edges; every vertex
                  keeps its degree, so check_number_of_edges_dat.py still
                  passes, but the connection changed
  ts-label        change one edge's TS number
  perm-label      change one edge's permutation
  drop            remove one edge
  duplicate       repeat one edge, changing its multiplicity
  open-self-loop  rewrite a self-loop as an edge to another vertex
"""
import re
import sys

EDGE = re.compile(r'^(\d+)--(\d+)(\[label="([^"]*)"\])?$')


def parse(path):
    rows = []
    with open(path) as handle:
        for raw in handle:
            line = raw.strip()
            if not line:
                continue
            match = EDGE.match(line)
            if not match:
                raise SystemExit('cannot parse edge line: {}'.format(line))
            rows.append([int(match.group(1)), int(match.group(2)), match.group(4)])
    return rows


def render(rows):
    out = []
    for u, v, label in rows:
        if label is None:
            out.append('{}--{}\n'.format(u, v))
        else:
            out.append('{}--{}[label="{}"]\n'.format(u, v, label))
    return ''.join(out)


def swap_endpoints(rows):
    for i in range(len(rows)):
        for j in range(i + 1, len(rows)):
            a, b = rows[i], rows[j]
            if len({a[0], a[1], b[0], b[1]}) != 4:
                continue
            rows[i] = [a[0], b[1], a[2]]
            rows[j] = [b[0], a[1], b[2]]
            return rows
    raise SystemExit('no two edges with four distinct endpoints')


def relabel(rows, field):
    for i, (u, v, label) in enumerate(rows):
        if label is None:
            continue
        number, perm = label.split(' ', 1)
        if field == 'ts':
            new = '{} {}'.format(number + '9', perm)
        else:
            new = '{} {}'.format(number, '(1,2)(3,4)' if perm != '(1,2)(3,4)' else '(1,3)(2,4)')
        rows[i] = [u, v, new]
        return rows
    raise SystemExit('no labeled edge to mutate')


def open_self_loop(rows):
    ids = sorted({u for u, _v, _l in rows} | {v for _u, v, _l in rows})
    for i, (u, v, label) in enumerate(rows):
        if u != v:
            continue
        for other in ids:
            if other != u:
                rows[i] = [u, other, label]
                return rows
    raise SystemExit('no self-loop to open')


def main():
    if len(sys.argv) != 4:
        raise SystemExit('Usage: {} MUTATION IN_EDGES OUT_EDGES'.format(sys.argv[0]))
    mutation, src, dst = sys.argv[1:]
    rows = parse(src)
    if not rows:
        raise SystemExit('{} has no edges to mutate'.format(src))
    if mutation == 'swap-endpoints':
        rows = swap_endpoints(rows)
    elif mutation == 'ts-label':
        rows = relabel(rows, 'ts')
    elif mutation == 'perm-label':
        rows = relabel(rows, 'perm')
    elif mutation == 'drop':
        rows = rows[:-1]
    elif mutation == 'duplicate':
        rows = rows + rows[:1]
    elif mutation == 'open-self-loop':
        rows = open_self_loop(rows)
    else:
        raise SystemExit('unknown mutation: {}'.format(mutation))
    text = render(rows)
    with open(src) as handle:
        if text == handle.read():
            raise SystemExit('mutation {} changed nothing'.format(mutation))
    with open(dst, 'w') as handle:
        handle.write(text)


if __name__ == '__main__':
    main()
