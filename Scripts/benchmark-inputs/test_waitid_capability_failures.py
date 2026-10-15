#!/usr/bin/env python3
"""실제 생산자·검증·스캐너와 가짜 OS 경계로 전체 실패 경로를 고정한다."""
import ast
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock

SOURCE_ROOT = Path(__file__).resolve().parents[2]
MODULE_FILES = {
    'waitid_failure_controls': SOURCE_ROOT / 'Scripts/validate-native-waitid-capability.py',
    'owned_waitid_capability': SOURCE_ROOT / 'Scripts/benchmark-inputs/waitid_capability.py',
    'waitid_interpreter_observation': SOURCE_ROOT / 'Scripts/validate-native-measurement.py',
    'waitid_unchanged_normalizer': SOURCE_ROOT / 'Scripts/normalize-indexstore-evidence.py',
}
MODULE_NAMES = (*MODULE_FILES, 'waitid_capability', 'waitid_outer_controls')
LOADED_SOURCE_SHA256 = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in MODULE_FILES.items()}
_saved_modules = {name: sys.modules.pop(name) for name in MODULE_NAMES if name in sys.modules}
try:
    SPEC = importlib.util.spec_from_file_location('waitid_failure_controls', MODULE_FILES['waitid_failure_controls'])
    M = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(M)
    CAP = M.CAP
    for name, module in zip(MODULE_FILES, (M, CAP, M.OBS, M.NORMALIZER)):
        assert Path(module.__file__).resolve() == MODULE_FILES[name], 'control-module-origin-mismatch'
        assert Path(module.__spec__.origin).resolve() == MODULE_FILES[name], 'control-spec-origin-mismatch'
        assert hashlib.sha256(MODULE_FILES[name].read_bytes()).hexdigest() == LOADED_SOURCE_SHA256[name], \
            'control-module-source-changed'
finally:
    for name in MODULE_NAMES: sys.modules.pop(name, None)
    sys.modules.update(_saved_modules)


ROUTES = (
    'complete', 'outer-setup', 'interpreter-before', 'source-before-nonzero', 'source-before-timeout',
    'source-before-uncertain', 'source-before-no-row', 'native-api', 'later-case', 'capability-timeout',
    'capability-uncertain', 'capability-no-row', 'source-after-nonzero', 'source-after-timeout',
    'source-after-uncertain', 'interpreter-after', 'final-inventory', 'outer-finalization', 'late-zero',
    'normalization', 'original-recheck', 'missing-lower', 'malformed-inner', 'disk-success-nonzero',
    'inner-cleanup', 'inner-finalization', 'stream-finalization', 'command-finalization', 'inner-setup',
)
UNSAFE_ORIGINAL_ROUTES = frozenset(ROUTES) - {
    'complete', 'interpreter-before', 'interpreter-after', 'normalization', 'original-recheck',
    'final-inventory', 'disk-success-nonzero',
}
BLOCKED_PUBLICATION_ROUTES = frozenset(ROUTES) - {
    'complete', 'interpreter-before', 'normalization', 'original-recheck',
}
CODECS = ('boolean-exit', 'nonfinite-wall', 'negative-wall', 'unknown-phase', 'unknown-role',
    'malformed-sha', 'oversized-text', 'raw-path', 'credential-value', 'unknown-case', 'extra-key',
    'duplicate-key', 'two-lines', 'stream-hash', 'helper-conflict', 'missing-helper')


class ClosingFailure:
    """정상 쓰기/flush/close를 먼저 수행한 뒤 실제 최종화 오류를 주입한다."""
    def __init__(self, stream, reason):
        self.stream, self.reason = stream, reason

    def __enter__(self):
        self.stream.__enter__()
        return self

    def __getattr__(self, name):
        return getattr(self.stream, name)

    def __exit__(self, kind, value, traceback):
        self.stream.__exit__(kind, value, traceback)
        raise OSError(self.reason)


class RootProcess:
    def __init__(self, fixture, role, code):
        self.fixture, self.role, self.code = fixture, role, code
        self.pid = 700 if role == 'capability' else 600 if role == 'source-before' else 601
        self.waits = 0
        self.signalled = False
        self.observed_returncode = None; self.ownership_uncertain = False

    def wait(self, timeout):
        self.waits += 1
        scenario = self.fixture.scenario
        if scenario == self.role + '-uncertain' and self.waits == 1:
            self.ownership_uncertain = True
            raise OSError('fixture-ownership-uncertain')
        if scenario == self.role + '-timeout' and not self.signalled:
            self.fixture.offset += 151 if self.role == 'capability' else 6
            raise subprocess.TimeoutExpired(['fixture-owned-command'], timeout)
        if scenario == 'late-zero' and self.role == 'capability':
            self.fixture.offset += 151
        self.observed_returncode = -signal.SIGTERM if self.signalled else self.code
        return self.observed_returncode


class ActorProcess:
    def __init__(self, fixture, argv, group, descriptors):
        self.fixture = fixture
        self.pid = 1000 + len(fixture.actors)
        self.group = group or self.pid
        self.session = 700
        self.code = None
        self.ignore = argv[-1] == '1'
        self.case = Path(fixture.actor_output).stem.rsplit('-', 1)[0]
        self.control, self.ready = descriptors
        fixture.actors[self.pid] = self
        fixture.controls[self.control + 1] = self
        fixture.ready[self.ready - 1] = b'R'

    def wait(self, timeout):
        if self.code is None:
            raise subprocess.TimeoutExpired(['fixture-owned-actor'], timeout)
        return self.code


class ProducerFixture:
    """매 경로마다 새 트리를 쓰며 결과/명령/상태 영수증은 실제 생산자가 작성한다."""
    wait = ActorProcess.wait

    def __init__(self, case, scenario):
        self.case, self.scenario = case, scenario
        self.temp = tempfile.TemporaryDirectory(prefix='waitid-full-route-', dir=M.ROOT)
        self.root = Path(self.temp.name).resolve()
        self.raw, self.public = self.root / 'raw', self.root / 'public'
        self.sha = 'a' * 40
        self.stack = contextlib.ExitStack()
        self.offset = 0
        self.clock = time.monotonic
        self.real_open, self.real_read_bytes = Path.open, Path.read_bytes
        self.real_os_read, self.real_os_close = os.read, os.close
        self.real_os_open = os.open
        self.real_inventory, self.real_package = M.inventory, M.NORMALIZER.package
        self.real_source_bytes = M.source_bytes
        self.real_walk = os.walk
        self.real_signal = signal.signal
        self.handlers, self.actors, self.controls, self.ready, self.roots = {}, {}, {}, {}, {}
        self.next_fd = 50000
        self.events, self.reads, self.launched, self.timer_calls = [], [], [], []
        self.forbidden_reads = []
        self.inner_codes, self.inner_stdout = [], []
        self.native_cleanup_refused = False
        self.final_inventory_refused = False
        self.mutated = False
        self.publishing = False
        self.actor_output = ''

    def patch(self, target, name, **kwargs):
        return self.stack.enter_context(mock.patch.object(target, name, **kwargs))

    def __enter__(self):
        physical = self.root / 'homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/bin/python3.14'
        physical.parent.mkdir(parents=True)
        physical.write_bytes(b'owned full-route interpreter identity fixture')
        runtime = self.root / 'homebrew/Cellar/python@3.14/3.14.7/bin/python3.14'
        runtime.parent.mkdir()
        runtime.symlink_to('../Frameworks/Python.framework/Versions/3.14/bin/python3.14')
        opt = self.root / 'homebrew/opt'
        opt.mkdir()
        (opt / 'python@3.14').symlink_to('../Cellar/python@3.14/3.14.7')
        selected = opt / 'python@3.14/bin/python3.14'
        pins = dict(selected_path=str(selected), runtime_path=str(runtime), resolved_path=str(physical),
                    bytes=physical.stat().st_size, sha256=hashlib.sha256(physical.read_bytes()).hexdigest())
        self.physical = physical
        self.patch(M, 'PYTHON', new=pins)
        self.patch(sys, 'platform', new='darwin')
        self.patch(sys, 'version_info', new=(3, 14, 8 if self.scenario == 'interpreter-before' else 7, 'final', 0))
        self.patch(sys, 'executable', new=str(runtime))
        self.patch(os, 'uname', return_value=SimpleNamespace(machine='arm64', release='25.6.0'))
        self.stack.enter_context(mock.patch.dict(os.environ, dict(M.IMAGE, GITHUB_SHA=self.sha)))
        for name, value in dict(P_PID=1, WEXITED=4, WNOWAIT=16777216, WNOHANG=1,
                                CLD_EXITED=1, CLD_KILLED=2, CLD_DUMPED=3).items():
            if not hasattr(os, name): self.patch(os, name, new=value, create=True)
        self.patch(subprocess, 'Popen', new=self)
        self.patch(os, 'waitid', new=self.waitid, create=True)
        self.patch(os, 'pipe', side_effect=self.pipe)
        self.patch(os, 'read', side_effect=self.read)
        self.patch(os, 'open', side_effect=self.os_open)
        self.patch(os, 'write', side_effect=self.write)
        self.patch(os, 'close', side_effect=self.close)
        self.patch(os, 'kill', side_effect=self.kill)
        self.patch(os, 'killpg', side_effect=self.killpg)
        self.patch(os, 'getpgid', side_effect=lambda pid: self.actors[pid].group)
        self.patch(os, 'getsid', side_effect=lambda pid: self.actors[pid].session)
        self.patch(CAP.select, 'select', side_effect=lambda reads, writes, errors, timeout: (reads, [], []))
        self.patch(signal, 'signal', side_effect=self.install)
        self.patch(signal, 'getitimer', return_value=(0.0, 0.0))
        self.patch(signal, 'setitimer', side_effect=lambda *args: self.timer_calls.append(args))
        self.patch(time, 'monotonic', side_effect=lambda: self.clock() + self.offset)
        fixture = self
        def opened(path, mode='r', *args, **kwargs):
            return fixture.open(path, mode, *args, **kwargs)
        def read_bytes(path):
            self.guard_read(path, 'Path.read_bytes')
            if self.scenario == 'inner-setup' and path == M.HELPER:
                raise OSError('fixture-helper-source-unavailable')
            return self.real_read_bytes(path)
        self.patch(Path, 'open', new=opened)
        self.patch(Path, 'read_bytes', new=read_bytes)
        self.patch(M, 'source_bytes', side_effect=self.source_bytes)
        self.patch(M, 'inventory', side_effect=self.inventory)
        self.patch(M.NORMALIZER, 'package', side_effect=self.package)
        self.patch(os, 'walk', side_effect=self.walk)
        return self

    def __exit__(self, *error):
        self.stack.close()
        self.temp.cleanup()

    def original_material_unsafe(self):
        return (self.scenario in UNSAFE_ORIGINAL_ROUTES or self.publishing
                and self.scenario in ('final-inventory', 'disk-success-nonzero'))

    def forbid(self, entry, path, reason):
        self.forbidden_reads.append(dict(entry=entry, path=str(path), reason=reason))
        raise AssertionError(reason)

    def guard_read(self, path, entry):
        path = Path(os.path.abspath(os.fsdecode(path)))
        self.reads.append(path)
        workflow_owned = (self.raw / 'results.json', self.raw / 'setup/execute-status.json')
        root_stream = False
        for role, pid in (('source-before', 600), ('capability', 700), ('source-after', 601)):
            stem = 'capability-command' if role == 'capability' else role
            if path not in (self.raw / 'setup' / (stem + '.stdout'), self.raw / 'setup' / (stem + '.stderr')):
                continue
            process = self.roots.get(pid)
            if (process is None or type(process.observed_returncode) is not int or process.ownership_uncertain):
                self.forbid(entry, path, 'unreaped or uncertain root stream read forbidden')
            root_stream = True
        if (self.original_material_unsafe() and path.is_relative_to(self.raw)
                and path not in workflow_owned and not root_stream):
            self.forbid(entry, path, 'unadmitted lower material read forbidden')

    def os_open(self, path, flags, mode=0o777, *, dir_fd=None):
        if flags & os.O_ACCMODE != os.O_WRONLY:
            self.guard_read(path, 'os.open')
        return self.real_os_open(path, flags, mode, dir_fd=dir_fd)

    def inventory(self, raw):
        if self.original_material_unsafe():
            self.forbid('inventory', raw, 'unsafe original inventory forbidden')
        return self.real_inventory(raw)

    def package(self, args):
        if self.scenario in BLOCKED_PUBLICATION_ROUTES:
            self.forbid('normalizer.package', args.input, 'unadmitted publication forbidden')
        return self.real_package(args)

    def assertion_bytes(self, path):
        # 생산 호출 뒤의 테스트 판정만 고정 원본 open을 쓴다. 생산 경로의 경계는 끄지 않는다.
        with self.real_open(path, 'rb') as stream:
            return stream.read()

    def pipe(self):
        pair = self.next_fd, self.next_fd + 1
        self.next_fd += 2
        return pair

    def read(self, fd, count):
        if fd >= 50000:
            return self.ready.pop(fd, b'')
        return self.real_os_read(fd, count)

    def close(self, fd):
        if fd < 50000: self.real_os_close(fd)

    def write(self, fd, data):
        actor = self.controls[fd]
        if data == b'E':
            actor.group = actor.session = actor.pid
            self.ready[actor.ready - 1] = b'E'
        else:
            actor.code = int(data)
        self.events.append(('actor-write', actor.pid, data))
        return len(data)

    def kill(self, pid, sig):
        actor = self.actors[pid]
        if not (actor.ignore and sig == signal.SIGTERM): actor.code = -sig
        self.events.append(('actor-signal', pid, sig))

    def killpg(self, pid, sig):
        if pid in self.roots:
            self.roots[pid].signalled = True
            self.events.append(('root-signal', pid, sig))
            return
        for actor in self.actors.values():
            if actor.group == pid and actor.code is None: self.kill(actor.pid, sig)

    def install(self, sig, handler):
        if (self.scenario == 'inner-cleanup' and handler == signal.SIG_IGN
                and any(a.case == 'normal-seven' for a in self.actors.values()) and not self.native_cleanup_refused):
            self.native_cleanup_refused = True
            raise OSError('fixture-inner-cleanup-refused')
        previous = self.handlers.get(sig, signal.SIG_DFL)
        self.handlers[sig] = handler
        return previous

    def waitid(self, kind, pid, options):
        actor = self.actors[pid]
        if actor.code is None:
            if options & os.WNOHANG: return None
            raise CAP.ObservationTimeout('fixture-observation-timeout')
        code = actor.code
        if self.scenario in ('later-case', 'inner-cleanup', 'inner-finalization') and actor.case == 'normal-seven':
            code = 0
        return SimpleNamespace(si_pid=pid, si_status=abs(code), si_code=os.CLD_EXITED if code >= 0 else os.CLD_KILLED,
                               si_signo=signal.SIGCHLD)

    def __call__(self, argv, *, process_group=None, **kwargs):
        self.launched.append(tuple(argv))
        if '--actor' in argv:
            self.case.assertIs(kwargs.get('close_fds'), True)
            self.case.assertEqual(len(kwargs['pass_fds']), 2)
            self.case.assertNotIn(1, kwargs['pass_fds'])
            self.case.assertNotIn(2, kwargs['pass_fds'])
            self.case.assertEqual(kwargs['stdin'], subprocess.DEVNULL)
            self.case.assertTrue(str(kwargs['stdout'].name).startswith(str(self.raw / 'runs/capability')))
            self.case.assertTrue(str(kwargs['stderr'].name).startswith(str(self.raw / 'runs/capability')))
            self.actor_output = kwargs['stdout'].name
            return ActorProcess(self, argv, process_group, kwargs['pass_fds'])
        role = 'capability' if '--output' in argv else 'source-before' if not self.roots else 'source-after'
        if role != 'capability':
            lines = []
            for name in M.SOURCE_PATHS:
                data = self.real_read_bytes(M.ROOT / name)
                blob = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
                lines.append(M.SOURCE_MODES[name] + ' blob ' + blob + '\t' + name)
            kwargs['stdout'].write(('\n'.join(lines) + '\n').encode())
            if self.scenario == 'normalization' and role == 'source-after':
                kwargs['stderr'].write(b'/unadmitted-location/example')
            code = 7 if self.scenario == role + '-nonzero' else 0
        else:
            captured = io.StringIO()
            with mock.patch.object(sys, 'argv', ['helper', '--output', argv[-1]]), contextlib.redirect_stdout(captured):
                if self.scenario in ('native-api', 'outer-finalization', 'malformed-inner'):
                    with mock.patch.object(os, 'waitid', None): code = CAP.main()
                else:
                    code = CAP.main()
            self.inner_codes.append(code)
            self.inner_stdout.append(captured.getvalue())
            data = captured.getvalue().encode()
            if self.scenario == 'malformed-inner': data = b'{"role":"unknown"}\n'
            if self.scenario == 'missing-lower':
                (self.raw / 'runs/capability/results.json').unlink()
                code = 1
            kwargs['stdout'].write(data)
            if self.scenario == 'interpreter-after':
                replacement = self.physical.with_name('replacement')
                replacement.write_bytes(self.real_read_bytes(self.physical))
                replacement.replace(self.physical)
        process = RootProcess(self, role, code)
        self.roots[process.pid] = process
        return process

    def open(self, path, mode, *args, **kwargs):
        path = Path(path)
        if 'r' in mode or '+' in mode:
            self.guard_read(path, 'Path.open')
        if mode == 'xb' and self.scenario in ('source-before-no-row', 'capability-no-row'):
            stem = 'source-before' if self.scenario.startswith('source-before') else 'capability-command'
            if path == self.raw / 'setup' / (stem + '.stdout'):
                raise OSError('fixture-command-open-refused')
        stream = self.real_open(path, mode, *args, **kwargs)
        failures = {
            'stream-finalization': (self.raw / 'setup/capability-command.stderr', 'xb', 'fixture-stream-close-refused'),
            'command-finalization': (self.raw / 'setup/capability-command.json', 'x', 'fixture-command-close-refused'),
            'outer-finalization': (self.raw / 'results.json', 'x', 'fixture-outer-close-refused'),
            'disk-success-nonzero': (self.raw / 'results.json', 'x', 'fixture-outer-close-refused'),
            'inner-finalization': (self.raw / 'runs/capability/results.json', 'x', 'fixture-inner-close-refused'),
        }
        selected = failures.get(self.scenario)
        if selected is not None and (path, mode) == selected[:2]: return ClosingFailure(stream, selected[2])
        return stream

    def source_bytes(self, path):
        path = Path(path)
        self.guard_read(path, 'source_bytes')
        # 패키저는 실제 실행하고 마지막 원본 읽기가 끝난 뒤 다음 끝점 관찰에만 변이를 드러낸다.
        if (self.scenario == 'original-recheck' and self.publishing and not self.mutated
                and (self.public / 'manifest.json').exists() and path == self.raw / 'setup/source-after.stderr'):
            data = self.real_source_bytes(path)
            path.write_bytes(b'changed-after-normalization')
            self.mutated = True
            return data
        return self.real_source_bytes(path)

    def walk(self, top, *args, **kwargs):
        if self.scenario == 'final-inventory' and Path(top) == self.raw and not self.publishing:
            self.final_inventory_refused = True
            raise OSError('fixture-inventory-refused')
        return self.real_walk(top, *args, **kwargs)

    def invoke(self, publish=False):
        self.publishing = publish
        args = ['outer', '--raw', str(self.raw)]
        args += ['--public', str(self.public)] if publish else ['--source-sha', 'b' * 40 if self.scenario == 'outer-setup' else self.sha]
        output, error = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, 'argv', args), contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            actual = M.main()
        if not error.getvalue() and self.scenario == 'native-api' and not publish:
            # 기준 소스의 의도한 실패까지 실제 생산된 뒤에만 첫-red 결손을 인정한다.
            self.case.assertEqual(actual, 1)
            outer = json.loads(self.assertion_bytes(self.raw / 'results.json'))
            inner = json.loads(self.assertion_bytes(self.raw / 'runs/capability/results.json'))
            self.case.assertEqual(outer['failure']['reason'], 'capability-actor-cleanup-not-proved')
            self.case.assertEqual(outer['command']['observed_returncode'], 1)
            self.case.assertEqual(inner['cases'][0]['failure']['reason'], 'native-waitid-unavailable')
            self.case.assertEqual([row['status'] for row in inner['cases']], ['incomplete'] + ['not-started'] * 11)
        self.case.assertTrue(error.getvalue(), 'missing outer diagnostic after actual producer route')
        diagnostic = json.loads(error.getvalue())
        self.case.assertLessEqual(len(error.getvalue().encode()), CAP.DIAGNOSTIC_LIMIT)
        self.case.assertEqual(error.getvalue(), CAP.diagnostic_line(diagnostic))
        self.case.assertEqual(diagnostic['intended_returncode'], actual)
        self.case.assertNotIn(str(self.root), error.getvalue())
        self.case.assertNotIn('actual_launches', error.getvalue())
        self.case.assertNotIn('native_actor_launches', error.getvalue())
        self.case.assertNotIn('metadata_child', error.getvalue())
        for field in ('timing_eligible', 'descendant_closure_eligible', 'final_protocol_ready'):
            self.case.assertIs(diagnostic[field], False)
        if not publish and (self.raw / 'setup').is_dir():
            M.save(self.raw / 'setup/execute-status.json', dict(exit_code=actual))
        return actual, diagnostic, output.getvalue()


class FullFailureRoutes(unittest.TestCase):
    def run_route(self, scenario, expected=1, reason=None, checkpoint=None, publish=125, category=None):
        self.assertIn(scenario, ROUTES)
        with ProducerFixture(self, scenario) as fixture:
            code, diagnostic, output = fixture.invoke()
            self.assertEqual(code, expected)
            if reason is not None:
                self.assertEqual(diagnostic['failure']['reason_sha256'], CAP.bounded_text_hash(reason))
            if category is not None: self.assertEqual(diagnostic['failure']['category'], category)
            if expected != 0:
                failure = diagnostic['failure']
                self.assertEqual(failure['type_sha256'], CAP.bounded_text_hash(failure['category']))
                failure_phase = ('outer-setup' if scenario == 'outer-setup' else 'final-inventory'
                    if scenario == 'final-inventory' else 'result-finalization'
                    if scenario == 'disk-success-nonzero' else checkpoint)
                self.assertEqual(diagnostic['failure_phase'], failure_phase)
                if category == 'TimeoutExpired':
                    self.assertEqual(failure['reason_status'], 'unavailable')
                    self.assertIsNone(failure['reason_sha256'])
            if checkpoint is not None: self.assertEqual(diagnostic['checkpoint'], checkpoint)
            if expected == 0:
                result = M.read_json(fixture.raw / 'results.json')
                self.assertEqual(result['status'], 'capability-only-complete')
                self.assertEqual(set(result['original_files']), M.complete_membership())
                self.assertEqual([c['name'] for c in M.read_json(fixture.raw / 'runs/capability/results.json')['cases']],
                                 [name for name, _ in CAP.CASES])
            publication, published, _ = fixture.invoke(publish=True)
            self.assertEqual(publication, publish)
            self.assertEqual(fixture.forbidden_reads, [])
            if publish == 125:
                self.assertEqual(published['status'], 'incomplete')
                self.assertIsNotNone(published['failure'])
            if scenario == 'complete':
                self.assertEqual(published['status'], 'scanned')
                self.assertEqual(len(M.read_json(fixture.public / 'manifest.json')['files']), 38)
                self.assertEqual(set(diagnostic['commands']), {'source-before', 'capability', 'source-after'})
                self.assertTrue(all(row['row_returned'] and row['receipt_finalized'] for row in diagnostic['commands'].values()))
            if scenario.endswith('-uncertain'):
                role = scenario.removesuffix('-uncertain')
                self.assertFalse(diagnostic['commands'][role]['ownership_certain'])
                self.assertEqual(diagnostic['commands'][role]['streams'], {})
                self.assertFalse(any(e[0] == 'root-signal' for e in fixture.events))
            if scenario.endswith('-timeout'):
                role = scenario.removesuffix('-timeout')
                self.assertEqual(diagnostic['commands'][role]['observed_returncode'], -signal.SIGTERM)
                self.assertTrue(diagnostic['commands'][role]['root_reaped'])
                self.assertTrue(diagnostic['commands'][role]['timed_out'])
            if scenario in ('source-before-no-row', 'capability-no-row'):
                self.assertNotIn(scenario.removesuffix('-no-row'), diagnostic['commands'])
            if scenario in ('native-api', 'later-case', 'outer-finalization', 'inner-cleanup', 'inner-finalization'):
                self.assertEqual(diagnostic['inner']['status'], 'source-bound')
                inner = diagnostic['inner']['value']
                produced = json.loads(fixture.assertion_bytes(fixture.raw / 'runs/capability/results.json'))
                self.assertEqual([row['name'] for row in produced['cases']], [name for name, _ in CAP.CASES])
                if scenario in ('native-api', 'outer-finalization'):
                    self.assertEqual(fixture.actors, {})
                    self.assertEqual([row['status'] for row in produced['cases']], ['incomplete'] + ['not-started'] * 11)
                inner_reason = 'native-waitid-unavailable' if scenario in ('native-api', 'outer-finalization') else 'unexpected-root-exit'
                self.assertEqual(inner['failure']['reason_sha256'], CAP.bounded_text_hash(inner_reason))
                self.assertEqual(inner['failure_phase'], 'case')
                self.assertEqual(inner['failure_case'], 'native-api-admission' if scenario in
                                 ('native-api', 'outer-finalization') else 'normal-seven')
                self.assertEqual(inner['source_sha256'], hashlib.sha256(fixture.real_read_bytes(M.HELPER)).hexdigest())
                if scenario in ('inner-cleanup', 'inner-finalization'):
                    secondary_reason = 'fixture-inner-cleanup-refused' if scenario == 'inner-cleanup' else 'fixture-inner-close-refused'
                    self.assertEqual(inner['secondary'][0]['reason_sha256'], CAP.bounded_text_hash(secondary_reason))
            if scenario == 'inner-setup': self.assertEqual(diagnostic['inner']['reason'], 'helper-source-unbound')
            if scenario == 'malformed-inner': self.assertEqual(diagnostic['inner']['reason'], 'invalid-helper-diagnostic')
            if scenario == 'missing-lower':
                self.assertFalse((fixture.raw / 'runs/capability/results.json').exists())
                self.assertEqual(diagnostic['inner']['status'], 'unavailable')
            if scenario in ('stream-finalization', 'command-finalization'):
                command = diagnostic['commands']['capability']
                self.assertEqual(command['observed_returncode'], 0)
                self.assertIsNotNone(command['wall_seconds'])
                self.assertTrue(command['root_reaped'])
                self.assertTrue(command['ownership_certain'])
                self.assertFalse(command['row_returned'])
                self.assertFalse(command['receipt_finalized'])
                self.assertEqual(bool(command['streams']), scenario == 'command-finalization')
                if scenario == 'stream-finalization':
                    for suffix in ('.stdout', '.stderr'):
                        self.assertNotIn(fixture.raw / 'setup' / ('capability-command' + suffix), fixture.reads)
            if scenario == 'late-zero':
                self.assertEqual(diagnostic['commands']['capability']['observed_returncode'], 0)
                self.assertGreater(diagnostic['commands']['capability']['wall_seconds'], 150)
                self.assertEqual(diagnostic['commands']['capability']['status'], 'incomplete')
            if scenario == 'disk-success-nonzero':
                self.assertEqual(M.read_json(fixture.raw / 'results.json')['status'], 'capability-only-complete')
                self.assertEqual(M.read_json(fixture.raw / 'setup/execute-status.json')['exit_code'], 125)
                self.assertEqual(published['failure']['reason_sha256'], CAP.bounded_text_hash('actual-outer-incomplete'))
            if scenario == 'normalization':
                self.assertEqual(published['phase'], 'normalization')
                self.assertEqual(published['failure']['category'], 'PublicationBlocked')
                reason = ('unmapped-absolute-path; artifact=setup/source-after.stderr; value_sha256_prefix='
                          + hashlib.sha256(b'/unadmitted-location/example').hexdigest()[:16])
                self.assertEqual(published['failure']['reason_sha256'], CAP.bounded_text_hash(reason))
                self.assertFalse((fixture.public / 'manifest.json').exists())
            if scenario == 'original-recheck':
                self.assertTrue(fixture.mutated)
                self.assertEqual(published['phase'], 'original-recheck')
                self.assertEqual(published['failure']['reason_sha256'], CAP.bounded_text_hash('original-membership-or-bytes-changed'))
            if scenario == 'outer-finalization':
                self.assertEqual(diagnostic['secondary'][-1]['reason_sha256'], CAP.bounded_text_hash('fixture-outer-close-refused'))
            return diagnostic

    def test_01_complete_producer(self):
        self.run_route('complete', expected=0, publish=0)

    def test_02_outer_setup(self):
        self.run_route('outer-setup', expected=125, reason='dispatch-source-mismatch', checkpoint='unavailable')

    def test_03_initial_interpreter_admission(self):
        self.run_route('interpreter-before', reason='native-python-version-mismatch',
                       checkpoint='interpreter-admission-before', publish=0)

    def test_04_source_before_nonzero(self):
        self.run_route('source-before-nonzero', reason='source-query-incomplete', checkpoint='source-before')

    def test_05_source_before_timeout(self):
        self.run_route('source-before-timeout', checkpoint='source-before', category='TimeoutExpired')

    def test_06_source_before_uncertain(self):
        self.run_route('source-before-uncertain', reason='fixture-ownership-uncertain', checkpoint='source-before')

    def test_07_source_before_no_returned_row(self):
        self.run_route('source-before-no-row', reason='fixture-command-open-refused', checkpoint='source-before')

    def test_08_native_api_admission(self):
        self.run_route('native-api', reason='capability-actor-cleanup-not-proved', checkpoint='capability-command')

    def test_09_later_fixed_case(self):
        self.run_route('later-case', reason='capability-actor-cleanup-not-proved', checkpoint='capability-command')

    def test_10_capability_timeout_reaped(self):
        self.run_route('capability-timeout', checkpoint='capability-command', category='TimeoutExpired')

    def test_11_capability_uncertain(self):
        self.run_route('capability-uncertain', reason='fixture-ownership-uncertain', checkpoint='capability-command')

    def test_12_capability_no_returned_row(self):
        self.run_route('capability-no-row', reason='fixture-command-open-refused', checkpoint='capability-command')

    def test_13_source_after_nonzero(self):
        self.run_route('source-after-nonzero', reason='source-query-incomplete', checkpoint='source-after')

    def test_14_source_after_timeout(self):
        self.run_route('source-after-timeout', checkpoint='source-after', category='TimeoutExpired')

    def test_15_source_after_uncertain(self):
        self.run_route('source-after-uncertain', reason='fixture-ownership-uncertain', checkpoint='source-after')

    def test_16_post_interpreter_conflict(self):
        self.run_route('interpreter-after', reason='input-identity-changed', checkpoint='interpreter-admission-after')

    def test_17_final_inventory_failure(self):
        self.run_route('final-inventory', reason='fixture-inventory-refused', checkpoint='complete')

    def test_18_outer_finalization_after_primary(self):
        self.run_route('outer-finalization', expected=125, reason='capability-actor-cleanup-not-proved',
                       checkpoint='capability-command')

    def test_19_actual_late_zero(self):
        self.run_route('late-zero', reason='capability-actor-cleanup-not-proved', checkpoint='capability-command')

    def test_20_real_normalizer_refusal(self):
        self.run_route('normalization', expected=0, checkpoint='complete')

    def test_21_original_endpoint_recheck(self):
        self.run_route('original-recheck', expected=0, checkpoint='complete')

    def test_22_missing_lower_result(self):
        self.run_route('missing-lower', reason='capability-actor-cleanup-not-proved', checkpoint='capability-command')

    def test_23_malformed_inner_diagnostic(self):
        self.run_route('malformed-inner', reason='capability-actor-cleanup-not-proved', checkpoint='capability-command')

    def test_24_disk_success_actual_nonzero(self):
        self.run_route('disk-success-nonzero', expected=125, reason='fixture-outer-close-refused', checkpoint='complete')

    def test_25_inner_cleanup_after_primary(self):
        self.run_route('inner-cleanup', reason='capability-actor-cleanup-not-proved', checkpoint='capability-command')

    def test_26_inner_receipt_close_after_primary(self):
        self.run_route('inner-finalization', reason='capability-actor-cleanup-not-proved', checkpoint='capability-command')

    def test_27_command_stream_close_after_observed_exit(self):
        self.run_route('stream-finalization', reason='fixture-stream-close-refused', checkpoint='capability-command')

    def test_28_command_receipt_close_after_observed_exit(self):
        self.run_route('command-finalization', reason='fixture-command-close-refused', checkpoint='capability-command')

    def test_29_inner_source_unavailable(self):
        self.run_route('inner-setup', reason='capability-actor-cleanup-not-proved', checkpoint='capability-command')


class DiagnosticCodecControls(unittest.TestCase):
    def test_sixteen_fixed_codec_refusals(self):
        helper = 'a' * 64
        diagnostic = CAP.InnerDiagnostic()
        diagnostic.source_sha256 = helper
        diagnostic.case, diagnostic.phase = 'normal-seven', 'case'
        diagnostic.record(dict(type='CapabilityFailure', reason='fixture-case-failure'))
        original = diagnostic.value(1)
        for name in CODECS:
            with self.subTest(name=name):
                value = copy.deepcopy(original)
                if name in ('boolean-exit', 'nonfinite-wall', 'negative-wall'):
                    row = dict(observed_returncode=True if name == 'boolean-exit' else 0,
                        wall_seconds=float('inf') if name == 'nonfinite-wall' else -1 if name == 'negative-wall' else .1,
                        status='completed-zero', ownership_uncertain=False, cleanup_root_unfinished=False)
                    safe = M.command_projection(row)
                    self.assertEqual(safe['status'], 'unavailable')
                    self.assertIsNone(safe['observed_returncode'] if name == 'boolean-exit' else safe['wall_seconds'])
                    continue
                if name == 'oversized-text':
                    for text in ('x' * 65537, '\u20ac' * 21846, '\ud800'):
                        self.assertIsNone(CAP.bounded_text_hash(text))
                    class Unprintable(Exception):
                        def __str__(self): raise AssertionError('exception-stringification-forbidden')
                    error = CAP.safe_error(CAP.retained_error(Unprintable('owned reason')))
                    self.assertEqual(error['category'], 'unknown-exception')
                    self.assertEqual(error['reason_sha256'], CAP.bounded_text_hash('owned reason'))
                    log = CAP.FailureLog()
                    for number in range(5): log.record(dict(type='ValueError', reason=str(number)))
                    self.assertEqual(log.primary['reason_sha256'], CAP.bounded_text_hash('0'))
                    self.assertEqual(len(log.secondary), 3)
                    self.assertTrue(log.overflow)
                    continue
                if name == 'unknown-phase': value['phase'] = 'unrecognized-phase'
                elif name == 'unknown-role': value['role'] = 'unrecognized-role'
                elif name == 'malformed-sha':
                    contradiction = copy.deepcopy(original)
                    contradiction['failure']['type_sha256'] = CAP.bounded_text_hash('ValueError')
                    contradictory_data = CAP.diagnostic_line(contradiction).encode()
                    contradictory_stream = dict(bytes=len(contradictory_data),
                        sha256=hashlib.sha256(contradictory_data).hexdigest())
                    self.assertEqual(CAP.parse_inner_diagnostic(contradictory_data, contradictory_stream, helper),
                                     dict(status='unavailable', reason='invalid-helper-diagnostic'))
                    value['failure']['reason_sha256'] = 'bad-sha'
                elif name in ('raw-path', 'credential-value'):
                    secret = '/unknown/private/path' if name == 'raw-path' else 'token=private-sensitive-value'
                    value['failure']['category'] = secret
                elif name == 'unknown-case': value['case'] = 'unrecognized-case'
                elif name == 'extra-key': value['extra'] = True
                elif name == 'helper-conflict': value['source_sha256'] = 'b' * 64
                elif name == 'missing-helper': value['source_sha256'] = None
                data = CAP.diagnostic_line(value).encode()
                if name == 'duplicate-key': data = data.replace(b'"schema_version":1', b'"schema_version":1,"schema_version":1')
                elif name == 'two-lines': data += data
                stream = dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
                if name == 'stream-hash': stream['sha256'] = 'f' * 64
                safe = CAP.parse_inner_diagnostic(data, stream, helper)
                self.assertEqual(safe['status'], 'unavailable')
                expected = 'helper-source-conflict' if name == 'helper-conflict' else 'helper-source-unbound' if name == 'missing-helper' else 'invalid-helper-diagnostic'
                self.assertEqual(safe['reason'], expected)
                encoded = json.dumps(safe)
                self.assertNotIn('/unknown/private/path', encoded)
                self.assertNotIn('private-sensitive-value', encoded)


if __name__ == '__main__':
    unittest.main()
