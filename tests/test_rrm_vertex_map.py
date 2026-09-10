#!/usr/bin/env python3
"""Contract validation and real GAP master/worker correspondence regressions."""

import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('vertex_map', ROOT / 'check_rrm_vertex_map.py')
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)
GAP = os.environ.get('GAP', 'gap')
SMALL = '''
symc:=Group((1,2));;
ur:=[Group(()),Group(())];;
org_eq:=[1,1];;
urt:=[Group(()),Group(())];;
ss:=[[[1,()],[2,()]],[[1,()],[2,()]]];;
org_ts:=[1,2];;
'''
# Only workers take this branch. Their enumeration AND hash lookup are changed.
SWAP = '''
OriginalBuild:=RrmBuildTransversals;;
SwapVertices:=false;;
RrmBuildTransversals:=function(sym,ur)
  local b, t, j;
  b:=OriginalBuild(sym,ur);
  if SwapVertices then
    t:=ShallowCopy(b.rt[1]);
    b.rt[1]:=Concatenation([t[2],t[1]],t{[3..Length(t)]});
    b.idx[1]:=RrmNewCosetIndex(sym);
    for j in [1..Length(b.rt[1])] do
      AddDictionary(b.idx[1],CanonicalRightCosetElement(ur[1],b.rt[1][j]),j);
    od;
    Print("TEST_SWAPPED_VERTEX_INDEX\\n");
  fi;
  return b;
end;;
OriginalShard:=generate_rrm_edge_shard;;
generate_rrm_edge_shard:=function(args...)
  SwapVertices:=true;
  return CallFuncList(OriginalShard,args);
end;;
'''


class MapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rrm-map-', dir='/tmp')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)

    def test_parser_rejects_malformed_contract(self):
        valid = b'RRM_VERTEX_MAP\t1\t2\t2\t2\n1\t1\t1\t0\t1\t2\n2\t2\t1\t1\t2\t1\nEND\t2\n'
        path = self.base / 'map'
        path.write_bytes(valid)
        digest = validator.validate_map(path, 2)
        self.assertEqual(len(digest), 64)
        invalid = [valid[:-1], valid + b'x', valid.replace(b'\n', b'\r\n'),
                   valid.replace(b'MAP\t1', b'MAP\t2'),
                   valid.replace(b'1\t1\t1\t0', b'01\t1\t1\t0'),
                   valid.replace(b'2\t2\t1\t1', b'3\t2\t1\t1'),
                   valid.replace(b'2\t2\t1\t1', b'2\t2\t1\t0'),
                   valid.replace(b'0\t1\t2', b'0\t1\t1'),
                   valid.replace(b'0\t1\t2', b'0\t1\t3'),
                   valid.replace(b'END\t2', b'END\t1'),
                   valid.replace(b'2\t2\t1\t1', b'2\t1\t1\t0')]
        for contents in invalid:
            with self.subTest(contents=contents):
                path.write_bytes(contents)
                with self.assertRaises(ValueError):
                    validator.validate_map(path, 2)
        path.write_bytes(valid)
        with self.assertRaises(ValueError):
            validator.validate_map(path, 3)
        path.write_bytes(b'RRM_VERTEX_MAP\t1\t0\t0\t0\nEND\t0\n')
        validator.validate_map(path, 0)

    def gap(self, source):
        result = subprocess.run([GAP, '-b', '-q', '-r', '-m', os.environ.get('MEM', '1g')],
                                input=f'Read("{ROOT}/generate_rrm_v11_fast.g");\n' + source + '\nQUIT;\n',
                                text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('Error,', result.stderr, result.stdout + result.stderr)
        return result

    def driver(self, fixture, bundle, ok=True, workers=3):
        result = subprocess.run([str(ROOT / 'generate_rrm_v11_parallel.sh'), '--bundle',
                                 str(bundle), str(fixture)], text=True, capture_output=True,
                                env={**os.environ, 'GAP': GAP, 'MEM': os.environ.get('MEM', '1g'),
                                     'GAP_WORKERS': str(workers)}, timeout=60)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_real_labels_inversion_and_identity(self):
        for identity in (False, True):
            fixture = SMALL if not identity else SMALL.replace('Group((1,2))', 'Group(())')
            for label in ('true', 'false'):
                v = self.base / f'v-{identity}-{label}'
                e = self.base / f'e-{identity}-{label}'
                self.gap(fixture + f'''
generate_rrm_vertices("{v}",symc,ur,urt,ss,org_eq,org_ts,{label});
generate_rrm_edge_shard("{e}",1,2,symc,ur,urt,ss,org_eq,org_ts,{label});
''')
                contents = Path(str(v) + '.vertex-map').read_bytes()
                self.assertEqual(contents, Path(str(e) + '.vertex-map').read_bytes())
                validator.validate_map(Path(str(v) + '.vertex-map'), 2 if identity else 4)
                if label == 'true':
                    expected = contents
                else:
                    self.assertEqual(contents, expected)
            if identity:
                self.assertEqual(contents, b'RRM_VERTEX_MAP\t1\t2\t2\t0\n1\t1\t1\t0\n2\t2\t1\t1\nEND\t2\n')

    def test_real_swapped_index_rejected_before_publication(self):
        fixture = self.base / 'small.g'
        fixture.write_text(SMALL)
        bundle = self.base / 'bundle'
        self.driver(fixture, bundle)
        old = (bundle / 'current').resolve()
        old_pair = [(old / name).read_bytes() for name in ('vertices.dat', 'edges.dat')]
        fixture.write_text(SMALL + SWAP)
        for target in (bundle, self.base / 'first'):
            result = self.driver(fixture, target, ok=False)
            self.assertIn('TEST_SWAPPED_VERTEX_INDEX', result.stdout)
            self.assertIn('SHA-256 mismatch', result.stderr)
        self.assertFalse((self.base / 'first' / 'current').exists())
        self.assertEqual((bundle / 'current').resolve(), old)
        self.assertEqual(old_pair, [(old / name).read_bytes() for name in ('vertices.dat', 'edges.dat')])

    def test_real_zero_ts_and_worker_cap(self):
        for nts in (0, 1, 2):
            fixture = self.base / f'ts{nts}.g'
            source = SMALL + f'ss:=ss{{[1..{nts}]}};; urt:=urt{{[1..{nts}]}};; org_ts:=org_ts{{[1..{nts}]}};;\n'
            fixture.write_text(source)
            bundle = self.base / f'bundle{nts}'
            self.driver(fixture, bundle, workers=4)
            run = (bundle / 'current').resolve()
            v, e = self.base / 'seq-v', self.base / 'seq-e'
            self.gap(source + f'generate_rrm("{v}","{e}",symc,ur,urt,ss,org_eq,org_ts);')
            self.assertEqual(v.read_bytes(), (run / 'vertices.dat').read_bytes())
            self.assertEqual(e.read_bytes(), (run / 'edges.dat').read_bytes())
            self.assertIn(f'workers={nts}\n', (run / 'manifest.txt').read_text())


if __name__ == '__main__':
    unittest.main()
