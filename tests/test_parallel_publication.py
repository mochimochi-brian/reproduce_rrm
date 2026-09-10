#!/usr/bin/env python3
"""Exercise the complete shell driver with deterministic GAP and I/O failures."""
import hashlib
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / 'generate_rrm_v11_parallel.sh'

FAKE_GAP = r'''
import json, os, re, sys, time
from pathlib import Path
s = sys.stdin.read()
master = 'generate_rrm_vertices(' in s
name = 'generate_rrm_vertices' if master else 'generate_rrm_edge_shard'
m = re.search(name + r'\(("(?:\\.|[^"\\])*")', s)
p = Path(json.loads(m[1]))
if os.environ.get('PID_LOG'):
    with open(os.environ['PID_LOG'], 'a') as f:
        f.write(str(os.getpid()) + '\n')
generation = os.environ.get('GENERATION', 'new')
role = 'master' if master else 'worker'
mode = os.environ.get('BAD_MAP') if os.environ.get('BAD_ROLE') == role else None
mapping = 'RRM_VERTEX_MAP\t1\t1\t1\t2\n1\t1\t1\t0\t1\t2\nEND\t1\n'
if mode == 'mismatch': mapping = mapping.replace('0\t1\t2', '0\t2\t1')
if mode == 'invalid': mapping = mapping.replace('0\t1\t2', '0\t1\t1')
if mode == 'truncated': mapping = mapping.rsplit('END', 1)[0]
if mode == 'count': mapping = mapping.replace('MAP\t1\t1', 'MAP\t1\t2')
if master and os.environ.get('FAIL_IO') == 'map':
    Path(str(p) + '.vertex-map').write_text(mapping[:10])
    sys.exit(73)
if mode != 'missing': Path(str(p) + '.vertex-map').write_text(mapping)
if mode == 'duplicate': print('RRM_NVERT=1')
if master and mode == 'duplicate_ts': print('RRM_NTS=2')
def count(key, value):
    if mode == 'missing_' + key: return
    print('RRM_' + key.upper() + '=' + ('bad' if mode == 'invalid_' + key else value), flush=True)
if master:
    if os.environ.get('FAIL_IO') == 'vertices':
        p.write_text('partial')
        sys.exit(73)
    p.write_text(generation + '\n')
    count('nvert', '1')
    count('nts', os.environ.get('NTS', '2'))
    if os.environ.get('MASTER_FAIL'): sys.exit(9)
    if os.environ.get('PAUSE') == 'master': time.sleep(120)
else:
    if os.environ.get('WORKER_FAIL') and p.name.endswith('.0'): sys.exit(9)
    if os.environ.get('PAUSE') == 'worker': time.sleep(120)
    if not (os.environ.get('MISSING_SHARD') and p.name.endswith('.1')):
        p.write_text(generation + '\n')
    count('nvert', '2' if os.environ.get('MISMATCH') else '1')
'''

IO_WRAPPER = r'''
import os, signal, sys, time
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
target = args[-1] if args else ''
mode = os.environ.get('FAIL_IO', '')
if (name == 'mv' and ((mode == 'vertices' and target.endswith('/vertices.dat')) or
                     (mode == 'current' and target.endswith('/current')))):
    sys.exit(73)
if name == 'sha256sum' and mode == 'manifest': sys.exit(74)
if name == 'cat' and mode == 'concat' and any(x.endswith('.part.1') for x in args):
    sys.exit(75)
if name == 'mv' and target.endswith('/current') and os.environ.get('SWITCH_SIGNAL'):
    # Inject a signal immediately before or after the actual publication syscall.
    if os.environ['SWITCH_SIGNAL'] == 'after':
        import subprocess
        subprocess.run(['/usr/bin/mv', *args], check=True)
    os.kill(os.getppid(), int(os.environ.get('SIGNAL', signal.SIGTERM)))
    sys.exit(76)
os.execv('/usr/bin/' + name, [name, *args])
'''


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rrm-publication-', dir='/tmp')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bundle = self.base / 'bundle with spaces'
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        for name, source in [('gap', FAKE_GAP), ('mv', IO_WRAPPER),
                             ('cat', IO_WRAPPER), ('sha256sum', IO_WRAPPER)]:
            p = self.bin / name
            p.write_text('#!' + sys.executable + '\n' + source)
            p.chmod(0o755)
        self.input = self.base / 'input.g'
        self.input.touch()
        self.env = {**os.environ, 'GAP': str(self.bin / 'gap'),
                    'GAP_WORKERS': '2', 'MEM': '1g',
                    'PATH': str(self.bin) + ':' + os.environ['PATH']}
        for key in ('RRM_KEEP_SHARDS', 'RRM_TEST_LAUNCH_DELAY',
                    'RRM_TEST_PID_REGISTER_DELAY'):
            self.env.pop(key, None)

    def command(self):
        return [str(DRIVER), '--bundle', str(self.bundle), str(self.input)]

    def run_driver(self, ok=True, **env):
        with subprocess.Popen(self.command(), env={**self.env, **env},
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, start_new_session=True) as proc:
            try:
                stdout, stderr = proc.communicate(timeout=60)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.communicate()
                raise
            result = subprocess.CompletedProcess(self.command(), proc.returncode, stdout, stderr)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def snapshot(self):
        # The supported reader resolves exactly once, then uses only this path.
        return (self.bundle / 'current').resolve(strict=True)

    def check_pair(self, run, generation='old', nts=2):
        self.assertEqual((run / 'vertices.dat').read_text(), generation + '\n')
        self.assertEqual((run / 'edges.dat').read_text(), (generation + '\n') * min(2, nts))
        manifest = (run / 'manifest.txt').read_text()
        for name in ('vertices.dat', 'edges.dat'):
            digest = hashlib.sha256((run / name).read_bytes()).hexdigest()
            self.assertIn(digest + '  ' + name, manifest)
        self.assertIn('nts=' + str(nts) + '\n', manifest)
        mapping = run / 'vertices.dat.vertex-map'
        self.assertIn('vertex_map_format=1\n', manifest)
        self.assertIn('vertex_map_sha256=' + hashlib.sha256(mapping.read_bytes()).hexdigest(), manifest)

    def test_success_and_pinned_reader_retention(self):
        self.run_driver(GENERATION='old', RRM_KEEP_SHARDS='1')
        old = self.snapshot()
        vertex = (old / 'vertices.dat').read_bytes()
        for i in range(3):
            self.run_driver(GENERATION='new')
            self.check_pair(self.snapshot(), 'new')
            self.check_pair(old)
            self.assertEqual(vertex, (old / 'vertices.dat').read_bytes())
        self.assertTrue((old / 'edges.dat.part.0').exists())
        self.assertFalse((self.snapshot() / 'edges.dat.part.0').exists())
        self.assertTrue((old / 'edges.dat.part.0.vertex-map').exists())
        self.assertFalse((self.snapshot() / 'edges.dat.part.0.vertex-map').exists())
        self.assertTrue((self.snapshot() / 'edges.dat.part.0.log').exists())

    def test_vertex_map_failures_preserve_published_pair(self):
        for role in ('master', 'worker'):
            modes = ['missing', 'invalid', 'truncated', 'count', 'duplicate',
                     'missing_nvert', 'invalid_nvert']
            modes += ['duplicate_ts', 'missing_nts', 'invalid_nts'] if role == 'master' else ['mismatch']
            for mode in modes:
                with self.subTest(role=role, mode=mode):
                    self.bundle = self.base / (role + '-' + mode)
                    env = dict(BAD_MAP=mode, BAD_ROLE=role)
                    self.run_driver(ok=False, **env)
                    self.assertFalse(os.path.lexists(self.bundle / 'current'))
                    self.run_driver(GENERATION='old')
                    old = self.snapshot()
                    self.run_driver(ok=False, **env)
                    self.assertEqual(self.snapshot(), old)
                    self.check_pair(old)

    def test_zero_ts_still_validates_master(self):
        self.run_driver(GENERATION='old')
        old = self.snapshot()
        self.run_driver(ok=False, NTS='0', BAD_ROLE='master', BAD_MAP='missing')
        self.assertEqual(self.snapshot(), old)
        self.check_pair(old)

    def test_zero_ts(self):
        self.run_driver(GENERATION='old')
        self.run_driver(NTS='0')
        self.check_pair(self.snapshot(), 'new', nts=0)

    def test_failures_preserve_old_pair_and_first_run_has_no_reference(self):
        cases = [dict(FAIL_IO=x) for x in ('vertices', 'map', 'current', 'manifest', 'concat')]
        cases += [{x: '1'} for x in ('MASTER_FAIL', 'WORKER_FAIL', 'MISSING_SHARD', 'MISMATCH')]
        for i, env in enumerate(cases):
            with self.subTest(env=env):
                self.bundle = self.base / ('case' + str(i))
                self.run_driver(ok=False, **env)
                self.assertFalse(os.path.lexists(self.bundle / 'current'))
                self.run_driver(GENERATION='old')
                old = self.snapshot()
                self.run_driver(ok=False, **env)
                self.assertEqual(self.snapshot(), old)
                self.check_pair(old)
                self.assertFalse(list(self.bundle.glob('runs/*/*.staging')))
                self.assertFalse(list(self.bundle.glob('runs/*/*.concat')))
                self.assertFalse(list(self.bundle.glob('runs/*/current.tmp')))

    def test_signal_at_publication_boundary(self):
        for sig in (signal.SIGINT, signal.SIGTERM):
            for phase in ('before', 'after'):
                with self.subTest(signal=sig, phase=phase):
                    self.run_driver(GENERATION='old')
                    old = self.snapshot()
                    self.run_driver(ok=False, SWITCH_SIGNAL=phase, SIGNAL=str(int(sig)))
                    self.check_pair(old)
                    self.check_pair(self.snapshot(), 'old' if phase == 'before' else 'new')

    def test_legacy_parallel_interface_rejected_without_modification(self):
        v, e = self.base / 'v.dat', self.base / 'e.dat'
        v.write_text('old vertices')
        e.write_text('old edges')
        result = subprocess.run([str(DRIVER), str(v), str(e), str(self.input)],
                                env=self.env, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'--bundle', result.stderr)
        self.assertEqual(v.read_text(), 'old vertices')
        self.assertEqual(e.read_text(), 'old edges')

    def test_historical_second_move_failure_reproduces_mixed_pair(self):
        # Frozen pre-fix publication order from Issue #15. The current driver
        # writes into a new generation; the full-driver cases inject write failures.
        v, e = self.base / 'vertices.dat', self.base / 'edges.dat'
        vs, es = self.base / 'v.staging', self.base / 'e.concat'
        for p, value in ((v, 'old'), (e, 'old'), (vs, 'new'), (es, 'new')):
            p.write_text(value)
        result = subprocess.run(['/bin/bash', '--noprofile', '--norc', '-ec', 'mv "$1" "$2"; mv "$3" "$4"',
                                 'legacy', str(es), str(e), str(vs), str(v)],
                                env={**self.env, 'FAIL_IO': 'vertices', 'BASH_ENV': '/dev/null'},
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual((v.read_text(), e.read_text()), ('old', 'new'))

    def test_signals_kill_children_and_preserve_pair(self):
        for sig in (signal.SIGINT, signal.SIGTERM):
            for phase in ('master', 'worker', 'registration'):
                with self.subTest(signal=sig, phase=phase):
                    self.run_driver(GENERATION='old')
                    old = self.snapshot()
                    pid_log = self.base / 'pids'
                    pid_log.write_text('')
                    env = {**self.env, 'PID_LOG': str(pid_log),
                           'PAUSE': 'master' if phase == 'registration' else phase}
                    if phase == 'registration':
                        env['RRM_TEST_PID_REGISTER_DELAY'] = '1'
                    if phase == 'worker':
                        env['RRM_TEST_LAUNCH_DELAY'] = '1'
                    with open(self.base / 'signal.log', 'w') as log:
                        proc = subprocess.Popen(self.command(), env=env, stdout=log, stderr=log)
                        try:
                            deadline = time.monotonic() + 30
                            expected = 2 if phase == 'worker' else 1
                            while len(pid_log.read_text().splitlines()) < expected:
                                if time.monotonic() > deadline:
                                    self.fail('fake GAP did not start')
                                time.sleep(0.02)
                            proc.send_signal(sig)
                            self.assertNotEqual(proc.wait(timeout=30), 0)
                        finally:
                            if proc.poll() is None:
                                proc.kill()
                                proc.wait()
                    self.assertEqual(self.snapshot(), old)
                    self.check_pair(old)
                    pids = pid_log.read_text().splitlines()
                    if phase == 'worker': self.assertEqual(len(pids), 2)
                    for pid in pids:
                        stat = Path('/proc') / pid / 'stat'
                        self.assertTrue(not stat.exists() or stat.read_text().split()[2] == 'Z', pid)

    def test_failed_concat_retains_shards(self):
        self.run_driver(ok=False, FAIL_IO='concat')
        self.assertTrue(list(self.bundle.glob('runs/*/edges.dat.part.0')))
        self.assertTrue(list(self.bundle.glob('runs/*/edges.dat.part.0.vertex-map')))
        run, = self.bundle.glob('runs/*')
        self.assertEqual((run / 'vertices.dat').read_text(), 'new\n')
        self.assertEqual((run / 'edges.dat').read_text(), 'new\n')
        self.assertTrue((run / 'vertices.dat.vertex-map').is_file())
        self.assertFalse(os.path.lexists(self.bundle / 'current'))

    def test_worker_failure_cancels_siblings(self):
        pid_log = self.base / 'pids'
        started = time.monotonic()
        self.run_driver(ok=False, WORKER_FAIL='1', PAUSE='worker', PID_LOG=str(pid_log))
        self.assertLess(time.monotonic() - started, 60)
        for pid in pid_log.read_text().splitlines():
            stat = Path('/proc') / pid / 'stat'
            self.assertTrue(not stat.exists() or stat.read_text().split()[2] == 'Z', pid)

    def test_invalid_keep_shards_and_bundle_layout(self):
        self.run_driver(ok=False, RRM_KEEP_SHARDS='yes')
        self.assertFalse(os.path.lexists(self.bundle / 'current'))
        self.bundle.mkdir(exist_ok=True)
        (self.bundle / 'current').write_text('user file')
        self.run_driver(ok=False)
        self.assertEqual((self.bundle / 'current').read_text(), 'user file')

    def test_writer_lock(self):
        self.bundle.mkdir()
        import fcntl
        with open(self.bundle / '.writer.lock', 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.run_driver(ok=False)
        self.assertFalse(os.path.lexists(self.bundle / 'current'))


if __name__ == '__main__':
    unittest.main()
