#!/usr/bin/env python3
"""Compare two labeled RRM dat pairs (issue #17).

`cmp` is the contract wherever the two producers are required to enumerate in
the same order.  This tool is for the cases where that is not the contract, and
for reporting *what* differs when it is.

Modes
  exact       every field in file order: vertex id, cluster id, cluster label,
              vertex label, edge endpoints, edge label.  Byte equality implies
              this; this mode adds a diagnostic.
  structure   vertex ids/clusters and edge endpoints in file order, ignoring
              vertex and edge labels.  Used to check that a labels-off run is
              exactly the labels-on run with the labels removed, so the ids in
              the unlabeled output keep the meaning recorded by the labeled one.
  normalized  order-insensitive.  Vertices are identified by (EQ label,
              permutation) instead of by id, and edges by (TS label,
              permutation, endpoint pair).  Self-loops stay self-loops and
              multiplicities are compared as multiplicities.
              Automatic keys require labels on every vertex if any are present;
              ids are used only when both inputs have no vertex labels.

Exit status: 0 identical, 1 different, 2 usage or parse error.
"""
import argparse
import re
import sys
from collections import Counter

VERTEX_LABELED = re.compile(r'^(\d+)\[label="([^"]*)"\]$')
VERTEX_BARE = re.compile(r'^(\d+)$')
CLUSTER = re.compile(r'^subgraph\s+(\S+)\s*\{\s*label="([^"]*)"\s*;?\s*$')
EDGE = re.compile(r'^(\d+)--(\d+)(?:\[label="([^"]*)"\])?$')


class ParseError(Exception):
    pass


def _split_label(label):
    """`0 (1,2)` -> ('0', '(1,2)').  A label without a permutation is an error."""
    parts = label.split(' ', 1)
    if len(parts) != 2:
        raise ParseError('label {!r} is not "<number> <permutation>"'.format(label))
    return parts[0], parts[1]


def parse_vertices(path):
    """-> list of dicts with vid, cluster, cluster_label, eq, perm (eq/perm may be None)."""
    out = []
    cluster = None
    cluster_label = None
    with open(path) as handle:
        for lineno, raw in enumerate(handle, 1):
            line = raw.strip()
            if not line or line.startswith('fontsize'):
                continue
            if line == '}':
                cluster = None
                cluster_label = None
                continue
            match = CLUSTER.match(line)
            if match:
                cluster, cluster_label = match.group(1), match.group(2)
                continue
            match = VERTEX_LABELED.match(line)
            if match:
                eq, perm = _split_label(match.group(2))
                out.append({'vid': int(match.group(1)), 'cluster': cluster,
                            'cluster_label': cluster_label, 'eq': eq, 'perm': perm})
                continue
            match = VERTEX_BARE.match(line)
            if match:
                out.append({'vid': int(match.group(1)), 'cluster': cluster,
                            'cluster_label': cluster_label, 'eq': None, 'perm': None})
                continue
            raise ParseError('{}:{}: cannot parse vertex line: {}'.format(path, lineno, line))
    if not out:
        raise ParseError('{}: no vertices'.format(path))
    seen_ids = set()
    for vertex in out:
        if vertex['vid'] in seen_ids:
            raise ParseError('{}: duplicate vertex id {}'.format(path, vertex['vid']))
        seen_ids.add(vertex['vid'])
        if vertex['cluster'] is None:
            raise ParseError('{}: vertex {} is outside every cluster'.format(path, vertex['vid']))
    return out


def parse_edges(path):
    """-> list of dicts with u, v, ts, perm (ts/perm may be None). May be empty."""
    out = []
    with open(path) as handle:
        for lineno, raw in enumerate(handle, 1):
            line = raw.strip()
            if not line:
                continue
            match = EDGE.match(line)
            if not match:
                raise ParseError('{}:{}: cannot parse edge line: {}'.format(path, lineno, line))
            label = match.group(3)
            ts, perm = _split_label(label) if label is not None else (None, None)
            out.append({'u': int(match.group(1)), 'v': int(match.group(2)),
                        'ts': ts, 'perm': perm})
    return out


def _report(diffs, limit=10):
    for line in diffs[:limit]:
        print(line)
    if len(diffs) > limit:
        print('... and {} more differences'.format(len(diffs) - limit))


def _compare_in_order(a, b, fields, kind):
    diffs = []
    if len(a) != len(b):
        diffs.append('{} count differs: {} vs {}'.format(kind, len(a), len(b)))
    for i, (left, right) in enumerate(zip(a, b), 1):
        lkey = tuple(left[f] for f in fields)
        rkey = tuple(right[f] for f in fields)
        if lkey != rkey:
            diffs.append('{} {}: {} vs {}'.format(kind, i, lkey, rkey))
    return diffs


def compare_ordered(av, ae, bv, be, fields_v, fields_e):
    return (_compare_in_order(av, bv, fields_v, 'vertex')
            + _compare_in_order(ae, be, fields_e, 'edge'))


def _vertex_keys(vertices, key_mode, side):
    """-> (vid -> key, key -> vid). Duplicate semantic keys are parse errors."""
    by_vid = {}
    by_key = {}
    for vertex in vertices:
        if key_mode == 'label':
            if vertex['eq'] is None:
                raise ParseError(
                    '{}: normalized --key label needs vertex labels; vertex {} has none'
                    .format(side, vertex['vid']))
            key = ('label', vertex['eq'], vertex['perm'])
        else:
            key = ('id', vertex['vid'])
        if key in by_key:
            raise ParseError('{}: duplicate vertex key {}'.format(side, key))
        by_key[key] = vertex['vid']
        by_vid[vertex['vid']] = key
    return by_vid, by_key


def compare_normalized(av, ae, bv, be, key_mode):
    diffs = []
    a_by_vid, a_by_key = _vertex_keys(av, key_mode, 'A')
    b_by_vid, b_by_key = _vertex_keys(bv, key_mode, 'B')

    only_a = sorted(set(a_by_key) - set(b_by_key))
    only_b = sorted(set(b_by_key) - set(a_by_key))
    for key in only_a:
        diffs.append('vertex only in A: {}'.format(key))
    for key in only_b:
        diffs.append('vertex only in B: {}'.format(key))

    a_cluster = {a_by_vid[v['vid']]: v['cluster_label'] for v in av}
    b_cluster = {b_by_vid[v['vid']]: v['cluster_label'] for v in bv}
    for key in sorted(set(a_cluster) & set(b_cluster)):
        if a_cluster[key] != b_cluster[key]:
            diffs.append('vertex {} cluster label {} vs {}'
                         .format(key, a_cluster[key], b_cluster[key]))

    def edge_keys(edges, by_vid, side):
        counter = Counter()
        for edge in edges:
            for endpoint in (edge['u'], edge['v']):
                if endpoint not in by_vid:
                    raise ParseError('{}: edge endpoint {} has no vertex'.format(side, endpoint))
            ends = (by_vid[edge['u']], by_vid[edge['v']])
            loop = edge['u'] == edge['v']
            counter[(edge['ts'], edge['perm'], tuple(sorted(ends)), loop)] += 1
        return counter

    a_edges = edge_keys(ae, a_by_vid, 'A')
    b_edges = edge_keys(be, b_by_vid, 'B')
    for key in sorted(set(a_edges) | set(b_edges), key=repr):
        na, nb = a_edges[key], b_edges[key]
        if na != nb:
            diffs.append('edge {} multiplicity {} vs {}'.format(key, na, nb))
    if sum(a_edges.values()) != sum(b_edges.values()):
        diffs.append('edge count differs: {} vs {}'
                     .format(sum(a_edges.values()), sum(b_edges.values())))
    return diffs


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('a_vertices')
    parser.add_argument('a_edges')
    parser.add_argument('b_vertices')
    parser.add_argument('b_edges')
    parser.add_argument('--mode', choices=('exact', 'structure', 'normalized'),
                        default='exact')
    parser.add_argument('--key', choices=('auto', 'label', 'id'), default='auto',
                        help='normalized vertex identity: semantic label, or output id '
                             'for label-free runs (auto requires all vertex labels '
                             'if any are present; otherwise it uses ids)')
    args = parser.parse_args(argv)

    try:
        av = parse_vertices(args.a_vertices)
        ae = parse_edges(args.a_edges)
        bv = parse_vertices(args.b_vertices)
        be = parse_edges(args.b_edges)

        if args.mode == 'exact':
            diffs = compare_ordered(av, ae, bv, be,
                                    ('vid', 'cluster', 'cluster_label', 'eq', 'perm'),
                                    ('u', 'v', 'ts', 'perm'))
            key_mode = '-'
        elif args.mode == 'structure':
            diffs = compare_ordered(av, ae, bv, be,
                                    ('vid', 'cluster', 'cluster_label'), ('u', 'v'))
            key_mode = '-'
        else:
            key_mode = args.key
            if key_mode == 'auto':
                labeled = any(v['eq'] is not None for v in av + bv)
                key_mode = 'label' if labeled else 'id'
            diffs = compare_normalized(av, ae, bv, be, key_mode)
    except ParseError as err:
        print('Error: {}'.format(err), file=sys.stderr)
        return 2

    if diffs:
        print('Error: dat pairs differ (mode={}, key={})'.format(args.mode, key_mode))
        _report(diffs)
        return 1
    print('identical: {} vertices, {} edges (mode={}, key={})'
          .format(len(av), len(ae), args.mode, key_mode))
    return 0


if __name__ == '__main__':
    sys.exit(main())
