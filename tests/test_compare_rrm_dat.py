#!/usr/bin/env python3
"""Unit tests for tests/compare_rrm_dat.py (issue #17).

The full comparison must reject the mutations a degree check cannot see:
a degree-preserving rewiring, a changed TS or permutation label, a missing
edge, a changed multiplicity, and a self-loop that stopped being one.
"""
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMPARE = os.path.join(ROOT, 'tests', 'compare_rrm_dat.py')
DEGREE = os.path.join(ROOT, 'check_number_of_edges_dat.py')

# Six vertices in one EQ, distinct permutations, so a rewiring is visible.
PERMS = ['()', '(1,2)', '(1,3)', '(2,3)', '(1,2,3)', '(1,3,2)']
ONE_EQ_VERTICES = (
    'subgraph cluster_0 { label="0";\nfontsize="30pt"\n'
    + ''.join('{}[label="0 {}"]\n'.format(i + 1, p) for i, p in enumerate(PERMS))
    + '}\n'
)
# Both graphs are 3-regular on the same six vertices, so the EQ-degree check
# passes on either one.
K33 = [(1, 4), (1, 5), (1, 6), (2, 4), (2, 5), (2, 6), (3, 4), (3, 5), (3, 6)]
PRISM = [(1, 2), (2, 3), (3, 1), (4, 5), (5, 6), (6, 4), (1, 4), (2, 5), (3, 6)]


def labeled(pairs, ts='0'):
    """Attach a TS label to each pair so the label travels with the edge."""
    return [(u, v, ts, PERMS[(u * 6 + v) % len(PERMS)]) for u, v in pairs]


def edge_text(edges):
    return ''.join('{}--{}[label="{} {}"]\n'.format(u, v, ts, perm)
                   for u, v, ts, perm in edges)


def bare_edge_text(edges):
    return ''.join('{}--{}\n'.format(u, v) for u, v, _ts, _perm in edges)


class Pair(object):
    """A (vertices, edges) dat pair on disk."""

    def __init__(self, tmpdir, name, vertices, edges):
        self.v = os.path.join(tmpdir, name + '_v.dat')
        self.e = os.path.join(tmpdir, name + '_e.dat')
        with open(self.v, 'w') as handle:
            handle.write(vertices)
        with open(self.e, 'w') as handle:
            handle.write(edges)


class CompareTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmpdir = self._tmp.name
        self.addCleanup(self._tmp.cleanup)

    def compare(self, a, b, mode='exact', key=None):
        argv = [sys.executable, COMPARE, a.v, a.e, b.v, b.e, '--mode', mode]
        if key:
            argv += ['--key', key]
        return subprocess.run(argv, capture_output=True, text=True)

    def assertSame(self, a, b, mode='exact', key=None):
        got = self.compare(a, b, mode, key)
        self.assertEqual(got.returncode, 0,
                         'expected identical in mode {}:\n{}{}'.format(mode, got.stdout, got.stderr))

    def assertDiffers(self, a, b, mode='exact', key=None, needle=None):
        got = self.compare(a, b, mode, key)
        self.assertEqual(got.returncode, 1,
                         'expected a difference in mode {}:\n{}{}'.format(mode, got.stdout, got.stderr))
        if needle:
            self.assertIn(needle, got.stdout)

    def degree_check(self, pair):
        return subprocess.run([sys.executable, DEGREE, pair.v, pair.e],
                              capture_output=True, text=True)

    def pair(self, name, vertices=None, edges=None):
        return Pair(self.tmpdir, name,
                    ONE_EQ_VERTICES if vertices is None else vertices,
                    edge_text(labeled(K33)) if edges is None else edges)

    # --- agreement -------------------------------------------------------
    def test_identical_pair_matches_in_every_mode(self):
        a = self.pair('a')
        b = self.pair('b')
        for mode in ('exact', 'structure', 'normalized'):
            self.assertSame(a, b, mode)

    def test_reordered_edges_are_normalized_but_not_exact(self):
        a = self.pair('a')
        b = self.pair('b', edges=edge_text(list(reversed(labeled(K33)))))
        self.assertDiffers(a, b, 'exact')
        self.assertSame(a, b, 'normalized')

    def test_renumbered_vertices_are_normalized(self):
        # Same graph, vertex ids rotated: only the semantic key still matches.
        order = [3, 4, 5, 6, 1, 2]
        rotated = (
            'subgraph cluster_0 { label="0";\nfontsize="30pt"\n'
            + ''.join('{}[label="0 {}"]\n'.format(new + 1, PERMS[old - 1])
                      for new, old in enumerate(order))
            + '}\n'
        )
        new_id = {old: new + 1 for new, old in enumerate(order)}
        a = self.pair('a')
        b = self.pair('b', vertices=rotated,
                      edges=edge_text([(new_id[u], new_id[v], ts, perm)
                                       for u, v, ts, perm in labeled(K33)]))
        self.assertDiffers(a, b, 'exact')
        self.assertSame(a, b, 'normalized')

    def test_empty_edge_files_compare_equal(self):
        a = self.pair('a', edges='')
        b = self.pair('b', edges='')
        for mode in ('exact', 'structure', 'normalized'):
            self.assertSame(a, b, mode)

    # --- mutations the degree check cannot see ---------------------------
    def test_degree_preserving_rewiring_is_rejected(self):
        a = self.pair('a', edges=edge_text(labeled(K33)))
        b = self.pair('b', edges=edge_text(labeled(PRISM)))
        for pair in (a, b):
            got = self.degree_check(pair)
            self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
            self.assertIn('consistent degrees', got.stdout)
        self.assertDiffers(a, b, 'normalized')
        self.assertDiffers(a, b, 'structure')

    def test_changed_ts_label_is_rejected(self):
        a = self.pair('a')
        b = self.pair('b', edges=edge_text(labeled(K33, ts='1')))
        self.assertEqual(self.degree_check(b).returncode, 0)
        self.assertDiffers(a, b, 'normalized', needle='multiplicity')
        self.assertDiffers(a, b, 'exact')
        # structure deliberately ignores labels.
        self.assertSame(a, b, 'structure')

    def test_changed_edge_permutation_label_is_rejected(self):
        edges = labeled(K33)
        u, v, ts, perm = edges[0]
        other = '(1,2)(3,4)'
        self.assertNotEqual(perm, other)
        mutated = edge_text([(u, v, ts, other)] + edges[1:])
        a = self.pair('a')
        b = self.pair('b', edges=mutated)
        self.assertEqual(self.degree_check(b).returncode, 0)
        self.assertDiffers(a, b, 'normalized')

    def test_changed_vertex_permutation_label_is_rejected(self):
        mutated = ONE_EQ_VERTICES.replace('1[label="0 ()"]', '1[label="0 (1,2,3,4)"]', 1)
        a = self.pair('a')
        b = self.pair('b', vertices=mutated)
        self.assertEqual(self.degree_check(b).returncode, 0)
        self.assertDiffers(a, b, 'normalized', needle='vertex only in')
        # The id-keyed comparison does not see a relabelled vertex.
        self.assertSame(a, b, 'structure')

    def test_missing_edge_is_rejected(self):
        a = self.pair('a')
        b = self.pair('b', edges=edge_text(labeled(K33[:-1])))
        self.assertDiffers(a, b, 'normalized', needle='edge count differs')

    def test_changed_multiplicity_is_rejected(self):
        doubled = edge_text(labeled(K33)) + edge_text(labeled(K33[:1]))
        a = self.pair('a')
        b = self.pair('b', edges=doubled)
        self.assertDiffers(a, b, 'normalized', needle='multiplicity 1 vs 2')

    def test_self_loop_is_distinguished_from_an_ordinary_edge(self):
        loops = [(1, 1), (2, 2), (3, 3)]
        opened = [(1, 2), (2, 3), (3, 1)]
        a = self.pair('a', edges=edge_text(labeled(loops)))
        b = self.pair('b', edges=edge_text(labeled(opened)))
        self.assertDiffers(a, b, 'normalized')

    def test_duplicate_self_loop_multiplicity_is_kept(self):
        a = self.pair('a', edges=edge_text(labeled([(1, 1)])))
        b = self.pair('b', edges=edge_text(labeled([(1, 1), (1, 1)])))
        self.assertDiffers(a, b, 'normalized', needle='multiplicity')

    # --- label-free output ----------------------------------------------
    def test_unlabeled_output_is_the_labeled_output_without_labels(self):
        bare_vertices = (
            'subgraph cluster_0 { label="0";\nfontsize="30pt"\n'
            + ''.join('{}\n'.format(i + 1) for i in range(len(PERMS)))
            + '}\n'
        )
        bare_edges = bare_edge_text(labeled(K33))
        a = self.pair('a')
        b = self.pair('b', vertices=bare_vertices, edges=bare_edges)
        self.assertSame(a, b, 'structure')
        self.assertDiffers(a, b, 'exact')
        # Without labels there is no semantic key; the id contract is compared.
        self.assertSame(b, b, 'normalized', key='id')
        got = self.compare(a, b, 'normalized', key='label')
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertIn('needs vertex labels', got.stderr)

    def test_unlabeled_pairs_differ_by_id_structure(self):
        bare_vertices = (
            'subgraph cluster_0 { label="0";\nfontsize="30pt"\n'
            + ''.join('{}\n'.format(i + 1) for i in range(len(PERMS)))
            + '}\n'
        )
        a = self.pair('a', vertices=bare_vertices, edges=bare_edge_text(labeled(K33)))
        b = self.pair('b', vertices=bare_vertices, edges=bare_edge_text(labeled(PRISM)))
        self.assertDiffers(a, b, 'normalized', key='id')

    # --- malformed input --------------------------------------------------
    def test_unparsable_line_exits_two(self):
        a = self.pair('a')
        b = self.pair('b', edges='1==2\n')
        got = self.compare(a, b, 'normalized')
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertIn('cannot parse edge line', got.stderr)

    def test_edge_endpoint_without_a_vertex_exits_two(self):
        a = self.pair('a')
        b = self.pair('b', edges=edge_text(labeled([(1, 99)])))
        got = self.compare(a, b, 'normalized')
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertIn('no vertex', got.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
