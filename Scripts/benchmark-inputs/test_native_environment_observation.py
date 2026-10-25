"""고정된 52개 계약을 실제 자식 없이 검사한다. 실행은 별도 승인 대상이다."""
import ast
from contextlib import ExitStack
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import stat
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).absolute().parents[2]
VALIDATOR = ROOT / 'Scripts/validate-native-environment-observation.py'
SUPPORT = ROOT / 'Scripts/benchmark-inputs/native_environment_probe_support.py'
OBSERVER = ROOT / 'Scripts/benchmark-inputs/native_environment_observer.py'
WORKFLOW = ROOT / '.github/workflows/native-environment-observation.yml'
SOURCE_SHA = 'a' * 40
FIXTURE_SOURCE_CAP = 524288
FIXTURE_FILE_CAP = 262144
METHOD_FILE_CAP = 1800
METHOD_TOTAL_CAP = 67108864
CONTRADICTION_CASES = ('observer-nonzero-contradiction', 'observer-signal-contradiction', 'observer-late-contradiction', 'observer-uncertain-contradiction', 'final-incomplete', 'inner-incomplete', 'inner-schedule-false', 'inner-source-false', 'inner-interpreter-false', 'inner-valid-false', 'final-deadline-false', 'final-deadline-int', 'missing-sample', 'reordered-samples', 'environment-false', 'directory-false', 'mapping-unchanged-false', 'expected-bytes-bool', 'observed-bytes-bool', 'outer-valid-false', 'outer-schedule-false', 'parent-incomplete', 'parent-budget-false', 'metadata-nonzero-contradiction')


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    exec(compile(path.read_bytes(), str(path), 'exec', dont_inherit=True), module.__dict__)
    return module


class Clock:
    def __init__(self, now=0):
        self.now = now

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class NativeEnvironmentObservationTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.denied = []
        def deny(*args, **kwargs):
            self.denied.append('real-operation')
            raise AssertionError('real operation forbidden in mock-only controls')
        self.deny = deny
        for name in ('Popen', 'run', 'call', 'check_call', 'check_output'):
            self.stack.enter_context(patch.object(subprocess, name, side_effect=deny))
        for name in ('waitpid', 'killpg', 'system', 'fork', 'forkpty', 'posix_spawn', 'posix_spawnp', 'execv', 'execve'):
            if hasattr(os, name):
                self.stack.enter_context(patch.object(os, name, side_effect=deny))
        self.stack.enter_context(patch.object(socket, 'socket', side_effect=deny))
        self.D = load(VALIDATOR, 'test_native_environment_driver')
        self.S = self.D.support()
        self.native_admission = self.S.native_admission
        self.runtime_admission = self.S.publisher_runtime_admission
        self.target_admission = self.S.target_admission
        self.observer = load(OBSERVER, 'test_native_observer')
        self.assertEqual(self.observer.__name__, 'test_native_observer')
        self.assertEqual(Path(self.observer.__file__).resolve(), OBSERVER.resolve())
        self.assertEqual(Path(self.observer.emit_observation.__code__.co_filename).resolve(), OBSERVER.resolve())
        self.stack.enter_context(patch.object(self.S, 'native_admission', side_effect=deny))
        self.stack.enter_context(patch.object(self.S, 'publisher_runtime_admission', side_effect=deny))
        self.stack.enter_context(patch.object(self.S, 'target_admission', side_effect=deny))
        self.stack.enter_context(patch.object(self.S, 'subprocess_provenance', side_effect=deny))
        self.stack.enter_context(patch.object(self.D.resource, 'setrlimit', side_effect=deny))
        self.temp = Path(self.stack.enter_context(tempfile.TemporaryDirectory())).resolve()
        self.raw = self.temp / 'native-environment-observation-123-1-raw'
        self.raw.mkdir(mode=0o700)
        for name in ('parent', 'parent/metadata', 'writers', 'writers/metadata', 'writers/pair', 'owned-home', 'owned-tmp'):
            (self.raw / name).mkdir(mode=0o700)
        (self.raw / 'parent/lane.lock').write_bytes(b'')
        (self.raw / 'parent/lane.lock').chmod(0o600)
        self.S.configure_root(str(self.raw))
        self.env, self.owned = self.S.requested_environment(), self.S.directories()
        self.identity = self.D.identity_from_raw(SOURCE_SHA, str(self.raw))
        self.clock = Clock()
        self.stack.enter_context(patch.object(self.D.time, 'monotonic', self.clock.monotonic))
        self.stack.enter_context(patch.object(self.D.time, 'sleep', self.clock.sleep))
        self.D.STARTED = 0
        self.D.PENDING, self.D.UNCERTAIN, self.D.HANDLES = None, False, []

    def tearDown(self):
        self.assertEqual(self.denied, [], 'A real process/native/network seam was reached')
        regular = [path for path in self.temp.rglob('*') if stat.S_ISREG(path.lstat().st_mode)]
        self.assertLessEqual(len(regular), METHOD_FILE_CAP)
        self.assertTrue(all(path.stat().st_size <= FIXTURE_FILE_CAP for path in regular))
        self.assertLessEqual(sum(path.stat().st_size for path in regular), METHOD_TOTAL_CAP)

    def fake_process(self, status=0, at=0, on_launch=None):
        handle = SimpleNamespace(pid=123, returncode=None)
        def launch(*args, **kwargs):
            if on_launch:
                on_launch(args, kwargs)
            return handle
        def wait(pid, flags):
            self.assertEqual((pid, flags), (123, os.WNOHANG))
            return (123, status) if self.clock.now >= at else (0, 0)
        popen = self.stack.enter_context(patch.object(self.D.subprocess, 'Popen', side_effect=launch))
        self.stack.enter_context(patch.object(self.D.os, 'waitpid', side_effect=wait))
        signals = self.stack.enter_context(patch.object(self.D.os, 'killpg'))
        return handle, popen, signals

    def command(self, role='sample01', deadline=20):
        return self.D.fixed_command(role, dict(raw=self.raw, environment=self.env, directories=self.owned,
            request_sha='b' * 64, source_sha=SOURCE_SHA, manifest_sha='c' * 64), deadline)

    def observation(self, sample='sample01', request_hash='b' * 64):
        return dict(schema_version=1, scope='native-python-mappings-only', sample=sample, request_sha256=request_hash,
            early=self.S.observe(self.env, self.env), post_reporting=self.S.observe(self.env, self.env),
            python_mapping_unchanged_between_samples=True, directories=self.S.safe_directories(self.owned),
            directories_equal=True, interpreter_sha256=self.S.PYTHON_SHA, python_version=[3, 14, 7],
            platform='darwin', inherited_lock_fd=9, environment_mutated=False, synthetic_control=False, child_launches=0)

    def terminal(self, role='caller', code=0):
        return dict(role=role, actual_exit=code, raw_terminal_wait=[123, code << 8], root_reaped=True,
            material_safe=True, ownership_uncertain=False, cleanup_errors=[], launch_attempted=True,
            handle_registered=True, status='completed', late_zero=False, late_exit=False, failure=None, secondary_failures=[],
            closed_outputs={}, command_ok=code == 0)

    def fixture(self):
        """실제 작성자 영수증과 공개 함수 경로를 쓰되 네이티브 호출은 하지 않는다."""
        directory = Path(tempfile.mkdtemp(dir=self.temp)).resolve()
        staging, public = directory / 'staging', directory / 'public'
        projections = {name: self.D.projection(name, self.identity, None, {}, False) for name in self.D.PUBLIC_CAPS}
        projections['results.json'] = self.D.projection('results.json', self.identity,
            dict(status='incomplete', observation_valid=False, observation_schedule_complete=False, sample_count=0), {}, True)
        body = self.S.read_bytes(ROOT / self.D.NORMALIZER_NAME, self.S.INPUT_BYTES)
        self.assertEqual(self.S.record(body), self.D.NORMALIZER_PIN)
        normalizer = self.D.load_pinned(self.D.NORMALIZER_NAME, body)
        return staging, public, projections, normalizer

    def package(self, fixture=None):
        staging, public, projections, normalizer = fixture or self.fixture()
        result = self.D.package_projections(staging, public, projections, self.identity, normalizer, 30)
        return result, staging, public, projections, normalizer

    def shell(self, **changes):
        value = dict(schema_version=1, run_id='123', run_attempt='1', job_id=self.D.JOB_ID, source_sha=SOURCE_SHA,
            invocation_tag=self.D.TAG, raw_root=str(self.raw), original_supervisor_exit=0, status_finalized=True)
        value.update(changes)
        return value

    def args(self):
        return SimpleNamespace(raw=str(self.raw), public=str(self.raw)[:-4] + '-public', source_sha=SOURCE_SHA,
            manifest_sha='c' * 64, shell_status_finalized='true', run_id='123', run_attempt='1', job_id=self.D.JOB_ID)

    def route(self, variant='matching', mutation=None):
        """Real supervisor -> caller -> observer producer -> publisher, zero real processes.

        Mock seams: Popen/raw wait/clock/signals, fixed Git bytes, installed native
        filesystem observations, inherited FD9, resource observations. All source,
        request, ownership schema, exclusive receipts, hashes, scanner/package and
        workflow-output writers are real. Each call owns a fresh fixture directory.
        """
        directory = Path(tempfile.mkdtemp(dir=self.temp)).resolve()
        raw = directory / 'native-environment-observation-123-1-raw'
        args = SimpleNamespace(raw=str(raw), public=str(raw)[:-4] + '-public', source_sha=SOURCE_SHA,
            manifest_sha=hashlib.sha256((ROOT / self.D.MANIFEST_NAME).read_bytes()).hexdigest(),
            shell_status_finalized='true', run_id='123', run_attempt='1', job_id=self.D.JOB_ID)
        checkout = directory / 'checkout'
        self.assertLessEqual(sum((ROOT / name).stat().st_size for name in self.D.MEMBERS), FIXTURE_SOURCE_CAP)
        self.assertTrue(all((ROOT / name).stat().st_size <= FIXTURE_FILE_CAP for name in self.D.MEMBERS))
        for name in self.D.MEMBERS:
            source, destination = ROOT / name, checkout / name
            destination.parent.mkdir(parents=True, exist_ok=True); destination.write_bytes(source.read_bytes())
            destination.chmod(stat.S_IMODE(source.stat().st_mode))
        output = directory / 'github-output'; output.write_bytes(b'')
        roles, waits, reads, inventories, signals = [], {}, [], [], []
        phase = ['supervisor']; runtime_changed = [False]; native_calls = []
        physical = SimpleNamespace(st_dev=1, st_ino=2, st_mode=stat.S_IFREG | 0o755, st_size=self.S.PYTHON_BYTES,
            st_mtime_ns=3, st_ctime_ns=4)
        real_read, real_record, real_lstat, real_fstat = self.S.read_bytes, self.S.record, os.lstat, os.fstat
        real_scandir, real_save, real_load = os.scandir, self.S.save, self.D.load_pinned
        plist = self.S.plistlib.dumps(dict(ProductVersion='26.6.2', ProductBuildVersion='25G83'))
        def native_stat(path, *a, **kw):
            if str(path) == self.S.PHYSICAL_PYTHON:
                row = copy.copy(physical)
                if runtime_changed[0] and variant == 'physical-drift': row.st_ino += 1
                return row
            return real_lstat(path, *a, **kw)
        def alias(path):
            value = dict(status='available', resolved_path_sha256=self.S.admission_text_hash(self.S.PHYSICAL_PYTHON),
                components=[dict(identity=self.S.stat_identity(native_stat(self.S.PHYSICAL_PYTHON)))])
            if runtime_changed[0] and variant in ('configured-alias-drift', 'runtime-alias-drift') and path == (
                self.S.CONFIGURED_PYTHON if variant == 'configured-alias-drift' else self.S.PYTHON):
                value['components'].insert(0, dict(identity=[1, 77, stat.S_IFDIR], entry_type='directory'))
            return value
        def read(path, cap):
            text = str(path); reads.append((phase[0], text, cap))
            if text == self.S.PHYSICAL_PYTHON: return b'physical-fixture'
            if text == self.S.PLIST:
                return self.S.plistlib.dumps(dict(ProductVersion='changed', ProductBuildVersion='25G83')) if variant == 'plist-refused' else plist
            if phase[0] == 'publisher' and variant in ('observer-uncertain', 'caller-uncertain', 'finalization-missing',
                    'finalization-partial', 'finalization-write-failure', 'result-partial'):
                self.assertFalse(Path(path).is_relative_to(raw / 'writers'), 'unsafe publication read lower material')
            return real_read(path, cap)
        def scanned(path):
            inventories.append((phase[0], str(path)))
            if phase[0] == 'publisher' and variant in ('observer-uncertain', 'caller-uncertain', 'finalization-missing',
                    'finalization-partial', 'finalization-write-failure', 'result-partial'):
                self.assertFalse(Path(path).is_relative_to(raw / 'writers'), 'unsafe publication inventoried lower material')
            return real_scandir(path)
        def native():
            return self.native_admission()
        def target(runtime):
            native_calls.append(phase[0])
            return self.target_admission(runtime)
        def save(path, value, cap=32768):
            if phase[0] == 'caller' and str(path).endswith('/results.json') and variant == 'result-write-failure':
                raise OSError(28, 'fixed result write fault')
            if phase[0] == 'caller' and str(path).endswith('/results.json') and variant == 'result-partial':
                Path(path).write_text('{'); raise OSError(28, 'fixed partial result fault')
            if phase[0] == 'caller' and str(path).endswith('/finalization.json') and variant == 'finalization-write-failure':
                raise OSError(28, 'fixed finalization fault')
            return real_save(path, value, cap)
        def launch(argv, **kw):
            if '--run-fixed-pair' in argv: role = 'caller'
            elif '--sample' in argv: role = argv[argv.index('--sample') + 1]
            else: role = self.D.METADATA_NAMES[self.D.fixed_git(SOURCE_SHA).index(argv)]
            roles.append(role); pid = 1000 + len(roles); code, at = 0, self.clock.now
            self.assertEqual(set(kw['env']), set(self.S.KEYS)); self.assertEqual(kw['pass_fds'], (9,))
            if role in self.D.METADATA_NAMES:
                rows = self.D.source_bracket(json.loads((checkout / self.D.MANIFEST_NAME).read_text()))
                body = (SOURCE_SHA + '\n').encode() if role == 'source-head' else b'' if role == 'source-status' else (
                    '\n'.join(row['mode'] + ' blob ' + row['blob'] + '\t' + name for name, row in rows.items()) + '\n').encode()
                os.write(kw['stdout'], body)
                if variant == 'metadata-nonzero' and role == 'source-head': code = 7
            elif role == 'caller':
                saved = self.D.STARTED, self.D.HANDLES, self.D.UNCERTAIN, self.D.PENDING
                self.D.STARTED, self.D.HANDLES, self.D.UNCERTAIN, self.D.PENDING = self.clock.now, [], False, None
                phase[0] = 'caller'
                try: code = self.D.caller(args)
                finally:
                    self.D.STARTED, self.D.HANDLES, self.D.UNCERTAIN, self.D.PENDING = saved
                    phase[0] = 'supervisor'
                if variant == 'caller-nonzero': code = 7
                if variant == 'caller-late': at = self.clock.now + 21
                if variant == 'finalization-missing': (raw / 'writers/pair/finalization.json').unlink()
                if variant == 'finalization-partial': (raw / 'writers/pair/finalization.json').write_text('{')
            else:
                expected = dict(kw['env']); early = dict(expected)
                if variant == 'environment-mismatch' and role == 'sample01': early['LANG'] = 'bounded-changed'
                if variant == 'directory-mismatch' and role == 'sample01':
                    home = Path(expected['HOME']); home.rename(raw / 'original-home'); home.mkdir(mode=0o700)
                self.observer.emit_observation(self.S, role, argv[argv.index('--request-sha') + 1], early, dict(early))
                if role == 'sample02' and variant == 'source-after-drift':
                    with (checkout / self.D.WORKFLOW_NAME).open('ab') as handle: handle.write(b'\n# bounded fixture drift\n')
                if role == 'sample01':
                    if variant == 'observer-nonzero': code = 7
                    if variant == 'observer-signal': code = -15
                    if variant == 'observer-late': at = self.clock.now + 6
            waits[pid] = (role, code, at)
            return SimpleNamespace(pid=pid, returncode=None)
        def wait(pid, flags):
            self.assertEqual(flags, os.WNOHANG)
            role, code, at = waits[pid]
            if (variant == 'observer-uncertain' and role == 'sample01') or (variant == 'caller-uncertain' and role == 'caller'):
                raise ChildProcessError('fixed wait uncertainty')
            return (pid, (-code if code < 0 else code << 8)) if self.clock.now >= at else (0, 0)
        def load_module(name, body):
            module = real_load(name, body)
            if name == self.D.NORMALIZER_NAME and variant == 'manifest-tamper':
                package = module.package
                def corrupt(arguments):
                    value = package(arguments); value['prefix_mappings'][0]['source'] = 'changed'
                    (arguments.output / 'manifest.json').write_bytes(self.S.encode(value, 16384)); return value
                module.package = corrupt
            return module
        old_root = self.S.ROOT
        self.clock.now = 0; self.D.STARTED = 0; self.D.HANDLES = []; self.D.PENDING = None; self.D.UNCERTAIN = False
        with ExitStack() as stack:
            stack.enter_context(patch.object(self.D, 'REPOSITORY', checkout))
            stack.enter_context(patch.dict(os.environ, RUNNER_TEMP=str(directory), GITHUB_RUN_ID='123', GITHUB_RUN_ATTEMPT='1',
                GITHUB_SHA=SOURCE_SHA, GITHUB_REPOSITORY='ictechgy/cartograph', GITHUB_OUTPUT=str(output),
                ImageOS=self.S.IMAGE_OS, ImageVersion='changed' if variant == 'image-refused' else self.S.IMAGE_VERSION))
            stack.enter_context(patch.object(self.S.sys, 'platform', 'darwin'))
            stack.enter_context(patch.object(self.S.sys, 'version_info', (3, 14, 8) if variant == 'runtime-refused' else (3, 14, 7)))
            stack.enter_context(patch.object(self.S.sys, 'executable', self.S.PYTHON))
            stack.enter_context(patch.object(self.S.sys, 'flags', SimpleNamespace(**dict({key: getattr(self.S.sys.flags, key) for key in dir(self.S.sys.flags)
                if not key.startswith('_')}, isolated=1, no_site=1, dont_write_bytecode=1))))
            stack.enter_context(patch.object(os, 'uname', return_value=SimpleNamespace(machine='arm64',
                release='changed' if variant == 'kernel-refused' else '25.6.0')))
            stack.enter_context(patch.object(self.S, 'publisher_runtime_admission', self.runtime_admission))
            stack.enter_context(patch.object(self.S, 'native_admission', side_effect=native))
            stack.enter_context(patch.object(self.S, 'target_admission', side_effect=target))
            stack.enter_context(patch.object(self.S, 'subprocess_provenance', return_value=dict(origin_sha256='b' * 64,
                source=self.S.record(b'fixed-subprocess-source'), installed_upstream_equivalence_established=False,
                runtime_closure_proved=False, upstream_commit='823f0323ee6ec1402088b73bce1a38473cac36dc',
                upstream_source_sha256='6628ffdd65c093a6c08cae01ffe82877d3ced515aac9e7be0cff16512c30a7d9')))
            stack.enter_context(patch.object(self.S, 'interpreter_alias', side_effect=alias))
            stack.enter_context(patch.object(os, 'lstat', side_effect=native_stat))
            stack.enter_context(patch.object(self.S, 'read_bytes', side_effect=read))
            stack.enter_context(patch.object(self.S, 'record', side_effect=lambda body: dict(bytes=self.S.PYTHON_BYTES,
                sha256=self.S.PYTHON_SHA) if body == b'physical-fixture' else real_record(body)))
            stack.enter_context(patch.object(os, 'scandir', side_effect=scanned))
            stack.enter_context(patch.object(os, 'fstat', side_effect=lambda fd: real_lstat(raw / 'parent/lane.lock') if fd == 9 else real_fstat(fd)))
            stack.enter_context(patch.object(os, 'dup2')); stack.enter_context(patch.object(os, 'set_inheritable'))
            stack.enter_context(patch.object(self.D.fcntl, 'flock'))
            stack.enter_context(patch.object(subprocess, 'Popen', side_effect=launch))
            stack.enter_context(patch.object(os, 'waitpid', side_effect=wait))
            stack.enter_context(patch.object(os, 'killpg', side_effect=lambda pid, number: signals.append((pid, number))))
            stack.enter_context(patch.object(self.S, 'save', side_effect=save))
            stack.enter_context(patch.object(self.D, 'load_pinned', side_effect=load_module))
            supervisor_code = self.D.supervise(args)
            shell = dict(schema_version=1, run_id='123', run_attempt='1', job_id=self.D.JOB_ID, source_sha=SOURCE_SHA,
                invocation_tag=self.D.TAG, raw_root=str(raw), original_supervisor_exit=7 if variant == 'shell-nonzero' else supervisor_code,
                status_finalized=True)
            self.S.save(Path(args.raw[:-4] + '-invocation-status.json'), shell, 8192)
            if mutation is not None: mutation(raw)
            runtime_changed[0] = True
            if variant in ('validator-endpoint-drift', 'workflow-endpoint-drift'):
                name = self.D.VALIDATOR_NAME if variant == 'validator-endpoint-drift' else self.D.WORKFLOW_NAME
                with (checkout / name).open('ab') as handle: handle.write(b'\n# between-phase drift\n')
            if variant == 'manifest-endpoint-drift':
                with (checkout / self.D.MANIFEST_NAME).open('ab') as handle: handle.write(b' ')
            if variant == 'source-input-drift':
                with (checkout / self.D.TEST_NAME).open('ab') as handle: handle.write(b'\n# between-phase source drift\n')
            phase[0] = 'publisher'; self.D.STARTED = self.clock.now; self.D.HANDLES = []; self.D.UNCERTAIN = False; self.D.PENDING = None
            publisher_error = None
            try: publisher_code = self.D.publish(args)
            except (ValueError, OSError) as error:
                publisher_code, publisher_error = 1, str(error)
            self.S.configure_root(old_root)
        regular = [path for path in directory.rglob('*') if stat.S_ISREG(path.lstat().st_mode)]
        self.assertLessEqual(len(regular), 62)
        self.assertLessEqual(sum(path.stat().st_size for path in regular), FIXTURE_SOURCE_CAP + 835584 + 180224 + 196608 + 1024)
        status_path = Path(args.raw[:-4] + '-publication-status.json')
        public_result = json.loads((Path(args.public) / 'results.json').read_text()) if status_path.exists() else None
        return SimpleNamespace(raw=raw, args=args, roles=roles, reads=reads, inventories=inventories, signals=signals,
            native_calls=native_calls, supervisor_code=supervisor_code, publisher_code=publisher_code, error=publisher_error,
            status_path=status_path, public_result=public_result, output=output.read_text())

    def rewrite_route(self, raw, mutate, result_copy_mutation=None):
        """Adversary repairs byte bindings only; all production validators still run."""
        read = lambda name: json.loads((raw / name).read_text())
        parent = read('parent/supervisor-finalization.json'); outer = read('parent/outer.json')
        final = read('writers/pair/finalization.json'); result = read('writers/pair/results.json')
        mutate(parent, outer, final, result)
        def replace(name, value, cap=32768):
            body = self.S.encode(value, cap); (raw / name).write_bytes(body); return self.S.record(body)
        for index, summary in enumerate(final['observers']):
            role = summary['role']; command_name = 'writers/pair/' + role + '.command.json'
            command = read(command_name); command.update(summary); result['commands'][index].update(summary)
            final['closed_files'][command_name] = replace(command_name, command)
        for sample, observation in result['observations'].items():
            if sample not in [row['role'] for row in final['observers']]: continue
            name = 'writers/pair/' + sample + '.observation.json'
            binding = replace(name, observation, 16384)
            for row in (final['observers'][self.D.SAMPLE_NAMES.index(sample)], result['commands'][self.D.SAMPLE_NAMES.index(sample)]):
                row['closed_outputs'][name] = binding
            command_name = 'writers/pair/' + sample + '.command.json'; command = read(command_name)
            command['closed_outputs'][name] = binding; final['closed_files'][command_name] = replace(command_name, command)
        # A result-copy-only adversary runs after summary synchronization, so it cannot be erased.
        if result_copy_mutation is not None:
            result_copy_mutation(result)
        final['result_file'] = replace('writers/pair/results.json', result)
        final['closed_files']['writers/pair/results.json'] = final['result_file']
        final_binding = replace('writers/pair/finalization.json', final, 8192)
        lower = dict(final['closed_files'], **{'writers/pair/finalization.json': final_binding})
        for row in final['observers']: lower.update(row['closed_outputs'])
        parent['lower_bindings'] = outer['lower_bindings'] = lower
        parent['closed_parent']['parent/outer.json'] = replace('parent/outer.json', outer)
        replace('parent/supervisor-finalization.json', parent, 8192)

    def test_p01(self):
        self.assertTrue(self.S.observe(self.env, self.env)['exact_equal'])
        self.assertEqual(self.D.HANDLES, [])

        route = self.route('matching')
        self.assertEqual(route.roles, [*self.D.METADATA_NAMES, 'caller', *self.D.SAMPLE_NAMES])
        self.assertEqual((route.supervisor_code, route.publisher_code), (0, 0), route.error)
        self.assertTrue(route.public_result['data']['observation_valid'])
        self.assertTrue(route.status_path.exists()); self.assertIn('ready=true\n', route.output)

    def test_p02(self):
        value = dict(self.env); del value['LANG']
        row = self.S.observe(value, self.env)
        self.assertEqual(row['missing_keys'], ['LANG'])
        self.assertFalse(row['exact_equal']); self.assertFalse(row['requested_values_equal'])

    def test_p03(self):
        value = dict(self.env, LANG='synthetic-changed')
        row = self.S.observe(value, self.env)
        self.assertEqual(row['changed_keys'], ['LANG'])
        item = next(item for item in row['requested_hashes'] if item['name'] == 'LANG')
        self.assertNotEqual(item['expected'], item['observed'])
        self.assertNotIn('synthetic-changed', json.dumps(row))

    def test_p04(self):
        value = dict(self.env); value[self.S.CF_KEY] = 'synthetic-only'
        row = self.S.observe(value, self.env)
        self.assertFalse(row['exact_equal']); self.assertTrue(row['requested_values_equal'])
        self.assertEqual(row['extra_key_count'], 1)
        self.assertEqual(row['known_cf_candidate_value'], self.S.record(b'synthetic-only'))
        self.assertEqual(self.S.pure_controls(self.env, self.owned)['scope'], 'synthetic-pure-memory-predicate-controls-only')

    def test_p05(self):
        self.assertTrue(self.S.pure_controls(self.env, self.owned)['results']['unchanged_directory'])

    def test_p06(self):
        before = copy.deepcopy(self.owned)
        self.assertFalse(self.S.pure_controls(self.env, self.owned)['results']['synthetic_changed_directory'])
        self.assertEqual(before, self.S.directories())

    def test_t01(self):
        rows = self.S.environment_rows(self.env)
        self.assertEqual(self.S.decode_rows(self.S.strict_json(self.S.encode(rows, 8192))), self.env)
        self.assertEqual([row['name'] for row in rows], sorted(self.S.KEYS))
        self.assertEqual(next(row['value'] for row in rows if row['name'] == 'PATH'), list(self.S.PATH_PARTS))
        for changed in (rows[:-1], rows + [rows[0]], rows[::-1], [rows[0]] * 8,
                        [dict(name='UNKNOWN', value='x')] + rows[1:], [dict(rows[0], value=1)] + rows[1:]):
            with self.subTest(rows=changed), self.assertRaises(ValueError): self.S.decode_rows(changed)

    def test_t02(self):
        with patch.dict(os.environ, {self.S.CF_KEY: 'ambient', 'GIT_CONFIG_COUNT': '9', 'OTHER': 'private'}):
            self.assertEqual(self.S.requested_environment(), self.env)
            self.assertEqual(set(self.env), set(self.S.KEYS))

    def test_t03(self):
        tree = ast.parse(OBSERVER.read_text())
        early = next(n.lineno for n in ast.walk(tree) if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store) and n.id == 'EARLY')
        late = next(n.lineno for n in ast.walk(tree) if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store) and n.id == 'POST_REPORTING')
        imports = [n for n in tree.body if isinstance(n, (ast.Import, ast.ImportFrom))]
        self.assertEqual([n.names[0].name for n in imports if n.lineno < early], ['os', 'sys'])
        self.assertTrue(all(n.lineno < late for n in imports))
        self.assertNotIn('os.environ[', OBSERVER.read_text())
        snapshot = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'early_snapshot')
        self.assertLess(next(n.lineno for n in ast.walk(snapshot) if isinstance(n, ast.For)),
            next(n.lineno for n in ast.walk(snapshot) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == 'dict'))

    def test_t04(self):
        cases = [{str(i): '' for i in range(65)}, {'': ''}, {'a' * 129: ''}, {'é' * 65: ''}, {'x': 'a' * 4097},
            {'x': 'é' * 2049}, {'x=y': ''}, {'x\0': ''}, {'x': '\0'}, {'x': '\ud800'}, {self.S.CF_KEY: 'a' * 257},
            {str(i): 'a' * 4096 for i in range(5)}, {1: ''}, {'x': 1}]
        for value in cases:
            with self.subTest(value_type=type(value).__name__), patch.object(self.S, 'record', side_effect=AssertionError('hashed early')):
                with self.assertRaises((ValueError, UnicodeError)): self.S.observe(value, self.env)
        self.S.bounded_environment({'a' * 128: 'a' * 4096})

    def test_t05(self):
        value = dict(self.env); del value['LANG']; value['UNPUBLISHED_NAME'] = 'unpublished-value'
        row = self.S.observe(value, self.env)
        self.D.validate_mapping(row, self.env)
        self.assertEqual([item['name'] for item in row['requested_hashes']], list(self.S.KEYS))
        self.assertIsNone(next(item['observed'] for item in row['requested_hashes'] if item['name'] == 'LANG'))
        self.assertNotIn('UNPUBLISHED_NAME', json.dumps(row)); self.assertNotIn('unpublished-value', json.dumps(row))

        for phase in ('early', 'post_reporting'):
            for side in ('expected', 'observed'):
                value = self.observation()
                row = next(row for row in value[phase]['requested_hashes'] if row['name'] == 'LANG')
                row[side]['bytes'] = True
                with self.subTest(phase=phase, side=side), self.assertRaises(ValueError):
                    self.D.validate_observation(value, 'sample01', 'b' * 64, self.owned)

    def test_t06(self):
        home = Path(self.env['HOME'])
        before = self.S.directories()
        (home / 'harmless').write_text('content')
        self.assertEqual(self.S.directories(), before)
        with patch.object(self.S.os.path, 'realpath', return_value='/alias'), self.assertRaises(ValueError): self.S.directory_identity('HOME')
        with patch.object(self.S.os, 'getuid', return_value=os.getuid() + 1), self.assertRaises(ValueError): self.S.directory_identity('HOME')
        real_fstat = os.fstat
        def replaced(fd):
            row = real_fstat(fd)
            return SimpleNamespace(st_dev=row.st_dev, st_ino=row.st_ino + 1, st_mode=row.st_mode, st_uid=row.st_uid)
        with patch.object(self.S.os, 'fstat', side_effect=replaced), self.assertRaises(ValueError): self.S.directory_identity('HOME')
        with patch.object(self.S, 'directory_identity', return_value=before['HOME']), self.assertRaises(ValueError): self.S.directories()
        real = self.temp / 'real-home'; home.rename(real); home.symlink_to(real)
        with self.assertRaises(ValueError): self.S.directory_identity('HOME')
        home.unlink(); home.write_text('not-directory')
        with self.assertRaises((ValueError, OSError)): self.S.directory_identity('HOME')

    def test_t07(self):
        # 읽기/별칭/OS는 모두 고정 가짜이며 실제 native_admission 본문을 통과시킨다.
        physical = SimpleNamespace(st_dev=1, st_ino=2, st_mode=stat.S_IFREG | 0o755, st_size=34640, st_mtime_ns=3, st_ctime_ns=4)
        aliases = dict(status='available', resolved_path_sha256=self.S.admission_text_hash(self.S.PHYSICAL_PYTHON),
            components=[dict(identity=self.S.stat_identity(physical))])
        plist = self.S.plistlib.dumps(dict(ProductVersion='26.6.2', ProductBuildVersion='25G83'))
        with ExitStack() as stack:
            stack.enter_context(patch.object(self.S.sys, 'platform', 'darwin'))
            stack.enter_context(patch.object(self.S.sys, 'version_info', (3, 14, 7)))
            stack.enter_context(patch.object(self.S.sys, 'executable', self.S.PYTHON))
            stack.enter_context(patch.object(self.S.sys, 'flags', SimpleNamespace(**dict({key: getattr(self.S.sys.flags, key) for key in dir(self.S.sys.flags)
                if not key.startswith('_')}, isolated=1, no_site=1, dont_write_bytecode=1))))
            stack.enter_context(patch.object(self.S.os, 'uname', return_value=SimpleNamespace(machine='arm64', release='25.6.0')))
            stack.enter_context(patch.dict(os.environ, ImageOS=self.S.IMAGE_OS, ImageVersion=self.S.IMAGE_VERSION))
            stack.enter_context(patch.object(self.S, 'interpreter_alias', return_value=aliases))
            stack.enter_context(patch.object(self.S.os, 'lstat', return_value=physical))
            stack.enter_context(patch.object(self.S, 'read_bytes', side_effect=lambda path, cap: plist if path == self.S.PLIST else b'physical'))
            original = self.S.record
            stack.enter_context(patch.object(self.S, 'record', side_effect=lambda data: dict(bytes=34640, sha256=self.S.PYTHON_SHA)
                if data == b'physical' else original(data)))
            stack.enter_context(patch.object(self.S, 'publisher_runtime_admission', self.runtime_admission))
            stack.enter_context(patch.object(self.S, 'target_admission', self.target_admission))
            self.assertEqual(self.native_admission()['platform'], 'darwin')
            for obj, field, value in ((self.S.sys, 'platform', 'linux'), (self.S.sys, 'version_info', (3, 14, 8)),
                                      (self.S.sys, 'executable', self.S.PHYSICAL_PYTHON)):
                with self.subTest(field=field), patch.object(obj, field, value), self.assertRaises(ValueError): self.native_admission()
            with patch.dict(os.environ, ImageVersion='changed'), self.assertRaises(ValueError): self.native_admission()
            with patch.object(self.S.os, 'uname', return_value=SimpleNamespace(machine='x86_64', release='25.6.0')), self.assertRaises(ValueError): self.native_admission()
            with patch.object(self.S.os, 'uname', return_value=SimpleNamespace(machine='arm64', release='changed')), self.assertRaises(ValueError): self.native_admission()
            wrong_plist = self.S.plistlib.dumps(dict(ProductVersion='26.6.2', ProductBuildVersion='changed'))
            with patch.object(self.S, 'read_bytes', return_value=wrong_plist), self.assertRaises(ValueError): self.native_admission()
            with patch.object(self.S, 'interpreter_alias', return_value=dict(status='unavailable')), self.assertRaises(ValueError): self.native_admission()
            with patch.object(self.S, 'read_bytes', return_value=b'bad'), self.assertRaises(Exception): self.native_admission()
            with patch.object(self.S, 'record', return_value=dict(bytes=34640, sha256='0' * 64)), self.assertRaises(ValueError): self.native_admission()

        for variant in ('image-refused', 'kernel-refused', 'plist-refused', 'runtime-refused'):
            route = self.route(variant)
            with self.subTest(variant=variant):
                self.assertEqual(route.supervisor_code, 1); self.assertEqual(route.roles, [])
                self.assertNotIn('publisher', route.native_calls, 'failed target admission must not be repeated')
                if variant == 'runtime-refused':
                    self.assertEqual(route.publisher_code, 1); self.assertFalse(route.status_path.exists())
                    self.assertNotIn('ready=true', route.output); self.assertNotIn('publication_bootstrap=true', route.output)
                    self.assertEqual(route.error, 'native-python-version')
                else:
                    self.assertEqual(route.publisher_code, 0, route.error)
                    self.assertFalse(route.public_result['data']['observation_valid'])
                    admitted = json.loads((Path(route.args.public) / 'setup/interpreter-admission.json').read_text())['data']
                    self.assertEqual(admitted['status'], 'refused'); self.assertIsNone(admitted['observed'])
                    self.assertIsNone(admitted['current_native_matches'])
                    original = json.loads((route.raw / 'parent/admission.json').read_text())
                    outer = json.loads((route.raw / 'parent/outer.json').read_text())
                    self.assertEqual(original['failure']['stage'], original['checkpoint'])
                    self.assertEqual(outer['failure']['stage'], 'supervisor')
                    self.assertTrue(self.D.typed_equal({key: original['failure'][key] for key in ('type', 'errno')},
                        {key: outer['failure'][key] for key in ('type', 'errno')}))

    def test_t08(self):
        base = self.temp / 'alias'; base.mkdir(); executable = base / 'python'; executable.write_text('x')
        link = base / 'link'; link.symlink_to('python')
        self.assertEqual(self.S.interpreter_alias(str(link))['status'], 'available')
        for suffix in ('/', '/.', '/..', '//', '/./x'):
            self.assertEqual(self.S.interpreter_alias(str(executable) + suffix)['status'], 'unavailable')
        for target in ('python/', 'python/.', 'python/..'):
            link.unlink(); link.symlink_to(target)
            self.assertEqual(self.S.interpreter_alias(str(link))['status'], 'unavailable')
        link.unlink(); link.symlink_to('link')
        self.assertEqual(self.S.interpreter_alias(str(link))['status'], 'unavailable')
        self.assertEqual(self.S.interpreter_alias('/' + '/'.join(['x'] * 129))['status'], 'unavailable')
        with patch.object(os, 'readlink', return_value='x' * 16385):
            self.assertEqual(self.S.interpreter_alias(str(link))['status'], 'unavailable')
        before = os.lstat(link)
        changed = SimpleNamespace(st_dev=before.st_dev, st_ino=before.st_ino + 1, st_mode=before.st_mode,
            st_size=before.st_size, st_mtime_ns=before.st_mtime_ns, st_ctime_ns=before.st_ctime_ns)
        real_lstat = Path.lstat
        visits = []
        def drift(path):
            if path == link:
                visits.append(1)
                return before if len(visits) == 1 else changed
            return real_lstat(path)
        with patch.object(Path, 'lstat', drift):
            self.assertEqual(self.S.interpreter_alias(str(link))['status'], 'unavailable')

    def test_t09(self):
        text = SUPPORT.read_text()
        self.assertIn('read_bytes(origin, 1048576)', text)
        self.assertIn('installed_upstream_equivalence_established=False', text)
        tree = ast.parse(VALIDATOR.read_text())
        self.assertFalse(any(isinstance(n, ast.Attribute) and n.attr in ('_wait', '_try_wait', '_internal_poll') for n in ast.walk(tree)))
        self.assertIn('6628ffdd65c093a6c08cae01ffe82877d3ced515aac9e7be0cff16512c30a7d9', text)

    def test_t10(self):
        manifest = json.loads((ROOT / self.D.MANIFEST_NAME).read_text())
        rows = self.D.source_bracket(manifest)
        self.assertEqual(set(rows), set(self.D.MEMBERS))
        for field, value in (('sha256', '0' * 64), ('bytes', 1), ('mode', '100755'), ('blob', '0' * 40)):
            altered = copy.deepcopy(manifest); altered['sources'][self.D.SUPPORT_NAME][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError): self.D.source_bracket(altered)
        self.assertNotIn(self.D.MANIFEST_NAME, manifest['sources'])
        self.assertEqual(manifest['endpoint_membership'], list(self.D.ENDPOINTS))
        args = self.args()
        with self.assertRaises(ValueError): self.D.metadata_expected('source-head', b'bad\n', args, rows)
        with self.assertRaises(ValueError): self.D.metadata_expected('source-tree', b'', args, rows)

        cases = (('validator-endpoint-drift', 'publisher-original-source-drift'),
            ('workflow-endpoint-drift', 'publisher-original-source-drift'), ('manifest-endpoint-drift', 'manifest-pin'),
            ('source-input-drift', 'source-pin-mismatch'), ('physical-drift', 'publisher-original-runtime-drift'),
            ('configured-alias-drift', 'publisher-original-runtime-drift'), ('runtime-alias-drift', 'publisher-original-runtime-drift'))
        for variant, gate in cases:
            route = self.route(variant)
            with self.subTest(variant=variant):
                self.assertEqual(route.supervisor_code, 0); self.assertEqual(route.publisher_code, 1)
                self.assertEqual(route.error, gate); self.assertFalse(route.status_path.exists())
                self.assertNotIn('ready=true', route.output)
        for member in (self.D.VALIDATOR_NAME, self.D.WORKFLOW_NAME, self.D.TEST_NAME):
            def change(raw, selected=member):
                parent_path = raw / 'parent/supervisor-finalization.json'; parent = json.loads(parent_path.read_text())
                category = 'endpoint' if selected in self.D.ENDPOINTS else 'source'
                for phase in ('before', 'after'):
                    name = 'parent/' + category + '-' + phase + '.json'; value = json.loads((raw / name).read_text())
                    value[selected]['sha256'] = 'f' * 64; value[selected]['blob'] = 'f' * 40
                    body = self.S.encode(value, 16384); (raw / name).write_bytes(body)
                    parent['closed_parent'][name] = self.S.record(body)
                parent_path.write_bytes(self.S.encode(parent, 8192))
            route = self.route(mutation=change)
            with self.subTest(coherently_rehashed=member):
                self.assertEqual(route.publisher_code, 1); self.assertFalse(route.status_path.exists())
                self.assertEqual(route.error, 'original-source-pin' if member == self.D.TEST_NAME else 'publisher-original-source-drift')

    def test_t11(self):
        self.D.UNCERTAIN = True
        with patch.object(self.S, 'read_bytes', side_effect=AssertionError('forbidden material read')), self.assertRaises(ValueError):
            self.D.source_bracket({})
        row = self.terminal(code=7)
        self.assertEqual(self.D.safe_status(row)['actual_exit'], 7)

        self.D.UNCERTAIN = False
        route = self.route('source-after-drift')
        self.assertEqual(route.supervisor_code, 1); self.assertEqual(route.publisher_code, 1)
        self.assertEqual(route.error, 'publisher-original-source-drift'); self.assertFalse(route.status_path.exists())
        caller = json.loads((route.raw / 'parent/caller.command.json').read_text())
        self.assertEqual(caller['actual_exit'], 1)

    def test_t12(self):
        for raw in ((124, 0), (123, 0x7f), (True, 0), (123, True), (0, 1), [123, 0]):
            state = self.D.ChildState('sample01'); state.handle = SimpleNamespace(pid=123, returncode=42); state.anchor = True
            with self.subTest(raw=raw), patch.object(os, 'waitpid', return_value=raw), self.assertRaises(ValueError): state.raw_once()
            self.assertTrue(state.uncertain); self.assertFalse(state.anchor)
        state = self.D.ChildState('sample01'); state.handle = SimpleNamespace(pid=123, returncode=None)
        with patch.object(os, 'waitpid', side_effect=ChildProcessError(10, 'synthetic')), self.assertRaises(ChildProcessError): state.raw_once()
        self.assertIsNone(state.code)
        row = self.terminal(); row['actual_exit'] = True
        self.assertFalse(self.D.validated_wait(row))

        for field, value in (('actual_exit', False), ('root_reaped', 1)):
            def change(raw, selected_field=field, selected_value=value):
                command_path = raw / 'writers/pair/sample01.command.json'
                command_body = command_path.read_bytes()
                final_before = json.loads((raw / 'writers/pair/finalization.json').read_text())['observers']
                def result_only(result):
                    result['commands'][0][selected_field] = selected_value
                self.rewrite_route(raw, lambda *unused: None, result_copy_mutation=result_only)
                altered = json.loads((raw / 'writers/pair/results.json').read_text())['commands'][0][selected_field]
                self.assertIs(type(altered), type(selected_value)); self.assertEqual(altered, selected_value)
                self.assertEqual(command_path.read_bytes(), command_body)
                self.assertTrue(self.D.typed_equal(final_before,
                    json.loads((raw / 'writers/pair/finalization.json').read_text())['observers']))
            route = self.route(mutation=change)
            with self.subTest(result_copy_only=field):
                self.assertEqual(route.supervisor_code, 0); self.assertEqual(route.publisher_code, 1)
                self.assertEqual(route.error, 'inner-result-identity')
                self.assertFalse(route.status_path.exists()); self.assertNotIn('ready=true', route.output)

    def test_t13(self):
        def pending(args, kwargs): self.D.cancel(signal.SIGTERM, None)
        handle, launched, signalled = self.fake_process(on_launch=pending)
        row = self.command()
        self.assertIs(self.D.HANDLES[0], handle)
        self.assertTrue(row['handle_registered']); self.assertEqual(row['actual_exit'], 0)
        self.assertFalse(row['command_ok'])
        state = self.D.ChildState('sample01'); state.handle = SimpleNamespace(pid=123, returncode=None); state.anchor = True
        def reap(*args): self.D.cancel(signal.SIGINT, None); return 123, 0
        with patch.object(os, 'waitpid', side_effect=reap): self.assertTrue(state.raw_once())
        self.assertFalse(state.anchor); self.assertEqual(state.handle.returncode, 0)

    def test_t14(self):
        state = self.D.ChildState('sample01'); state.handle = SimpleNamespace(pid=123, returncode=None); state.anchor = True
        with patch.object(os, 'waitpid', side_effect=ChildProcessError(10, 'synthetic')), self.assertRaises(ChildProcessError): state.raw_once()
        with patch.object(os, 'killpg') as send, self.assertRaises(ValueError): state.send(signal.SIGTERM)
        send.assert_not_called()
        with patch.object(os, 'waitpid', return_value=(123, 0)): state.raw_once()
        self.assertTrue(state.uncertain); self.assertTrue(self.D.UNCERTAIN); self.assertFalse(state.anchor)
        with patch.object(os, 'killpg') as send, self.assertRaises(ValueError): state.send(signal.SIGKILL)
        send.assert_not_called()

    def test_t15(self):
        handle, launched, signals = self.fake_process(at=8)
        row = self.command()
        self.assertEqual([call.args[1] for call in signals.call_args_list], [signal.SIGTERM, signal.SIGKILL])
        self.assertLessEqual(row['cleanup_deadline'] - row['cleanup_started'], 5)
        self.assertFalse(row['command_ok']); self.assertTrue(row['late_zero'])
        # 협력 기한이 cleanup 중간을 자르면 같은 절대 TERM/KILL 경계까지만 재개한다.
        self.D.HANDLES.clear(); self.clock.now = 0
        def slow_constructor(*args, **kwargs):
            self.clock.now = 19
            return SimpleNamespace(pid=124, returncode=None)
        points = []
        def wait(pid, flags):
            return (pid, 0) if self.clock.now >= 23 else (0, 0)
        with patch.object(subprocess, 'Popen', side_effect=slow_constructor), patch.object(os, 'waitpid', side_effect=wait), \
             patch.object(os, 'killpg', side_effect=lambda pid, number: points.append((number, self.clock.now))):
            resumed = self.command('sample02', deadline=20)
        self.assertEqual(resumed['cleanup_started'], 19)
        self.assertEqual(resumed['cleanup_deadline'], 24)
        self.assertGreaterEqual(points[1][1], 21)
        self.assertFalse(resumed['command_ok'])

        self.D.HANDLES = []; self.D.UNCERTAIN = False; self.D.PENDING = None; self.clock.now = 0
        fresh = self.temp / 'primary'; fresh.mkdir()
        for suffix in ('.stdout', '.stderr'):
            path = self.raw / ('writers/pair/sample01' + suffix)
            if path.exists(): path.unlink()
        self.fake_process(at=6)
        with patch.object(self.S, 'read_bytes', side_effect=OSError(5, 'secondary stream fault')):
            row = self.command()
        self.assertEqual(row['failure']['stage'], 'command')
        self.assertEqual(row['secondary_failures'], [dict(type='OSError', errno=5, stage='closed-stream-read')])
        self.assertEqual((row['actual_exit'], row['raw_terminal_wait']), (0, [123, 0]))
        self.assertTrue(row['late_zero']); self.assertFalse(row['command_ok'])

    def test_t16(self):
        self.fake_process()
        self.clock.now = 10
        row = self.command(deadline=20)
        self.assertTrue(row['launch_attempted']); self.assertEqual(row['available_seconds_at_launch'], 10)
        self.D.HANDLES.clear(); self.clock.now = 10.001
        row = self.command('sample02', deadline=20)
        self.assertFalse(row['launch_attempted']); self.assertEqual(row['status'], 'not-started')

    def test_t17(self):
        handle, launched, signals = self.fake_process(at=20.01)
        row = self.command('caller', deadline=30)
        self.assertFalse(row['command_ok']); self.assertTrue(row['late_zero'])
        self.assertEqual(row['actual_exit'], 0)
        self.assertIn('hard_wall_proved=False', VALIDATOR.read_text())

    def test_t18(self):
        tree = ast.parse(VALIDATOR.read_text())
        calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == 'Popen']
        self.assertEqual(len(calls), 1)
        self.assertEqual(len(self.D.fixed_git(SOURCE_SHA)), 3)
        self.assertEqual(self.D.SAMPLE_NAMES, ('sample01', 'sample02'))
        self.assertIn('direct_launch_maximum=9', VALIDATOR.read_text())
        for path in (OBSERVER, SUPPORT):
            self.assertFalse(any(isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr in
                ('Popen', 'run', 'fork', 'posix_spawn', 'system') for n in ast.walk(ast.parse(path.read_text()))))

    def test_t19(self):
        info = os.lstat(self.raw / 'parent/lane.lock')
        with patch.object(os, 'fstat', return_value=info):
            self.assertEqual(self.S.lane_identity()['inode'], info.st_ino)
        wrong = SimpleNamespace(st_mode=info.st_mode, st_uid=info.st_uid, st_size=1)
        with patch.object(os, 'fstat', return_value=wrong), self.assertRaises(ValueError): self.S.lane_identity()
        other = self.temp / 'busy'
        with patch.object(self.D.fcntl, 'flock', side_effect=BlockingIOError), self.assertRaises(BlockingIOError): self.D.make_raw(other)
        self.assertNotIn('LOCK_UN', VALIDATOR.read_text())
        self.assertIn('pass_fds=(9,)', VALIDATOR.read_text())

    def test_t20(self):
        path = self.temp / 'value.json'
        self.S.save(path, {'x': 1}, 32768)
        with self.assertRaises(FileExistsError): self.S.save(path, {'x': 2})
        with self.assertRaises(ValueError): self.S.read_bytes(path, 1)
        link = self.temp / 'link'; link.symlink_to(path)
        with self.assertRaises(ValueError): self.S.read_bytes(link, 32768)
        with patch.object(os, 'read', return_value=b'x' * 100), self.assertRaises(ValueError): self.S.read_bytes(path, 32768)
        captured = self.S.safe_error(ValueError('/private/path secret-text'), 'fixture')
        self.assertNotIn('private', json.dumps(captured)); self.assertNotIn('secret-text', json.dumps(captured))
        aggregate = self.temp / 'aggregate'; aggregate.mkdir(); self.S.save(aggregate / 'value.json', {'x': 1})
        with self.assertRaisesRegex(ValueError, 'bounded-regular-input-required'):
            self.D.tree_records(aggregate, {'value.json': 32768}, 1)
        before = os.lstat(path)
        drift = SimpleNamespace(st_dev=before.st_dev, st_ino=before.st_ino + 1, st_mode=before.st_mode,
            st_size=before.st_size, st_mtime_ns=before.st_mtime_ns, st_ctime_ns=before.st_ctime_ns)
        with patch.object(os, 'fstat', return_value=drift), self.assertRaisesRegex(ValueError, 'input-open-drift'):
            self.S.read_bytes(path, 32768)

        # Exact aggregate remainder must reach the real bounded reader before its open/read.
        for extra in (0, 1):
            directory = self.temp / ('remaining-' + str(extra)); directory.mkdir()
            first, second = directory / 'a', directory / 'b'
            first.write_bytes(b'abc'); second.write_bytes(b'de' + b'f' * extra)
            calls, opens = [], []
            original_read, original_open = self.S.read_bytes, os.open
            def read(path, cap):
                calls.append((Path(path).name, cap)); return original_read(path, cap)
            def opened(path, *a, **kw):
                opens.append(Path(path).name); return original_open(path, *a, **kw)
            with patch.object(self.S, 'INPUT_TOTAL', 5), patch.object(self.S, 'INPUT_BYTES', 5), \
                 patch.object(self.S, 'read_bytes', side_effect=read), patch.object(os, 'open', side_effect=opened):
                inputs = {str(first): self.S.record(b'abc'), str(second): self.S.record(b'de' + b'f' * extra)}
                if extra:
                    with self.assertRaisesRegex(ValueError, 'bounded-regular-input-required'): self.S.bracket(inputs)
                    self.assertEqual(opens, ['a'])
                else:
                    self.assertEqual(len(self.S.bracket(inputs)), 2); self.assertEqual(opens, ['a', 'b'])
            self.assertEqual(calls, [('a', 5), ('b', 2)])
        manifest = json.loads((ROOT / self.D.MANIFEST_NAME).read_text())
        sizes = [(ROOT / name).stat().st_size for name in self.D.MEMBERS]
        reserve = 1048576 + 65536 + self.S.PYTHON_BYTES
        for short in (0, 1):
            calls, opens = [], []
            original_read, original_open = self.S.read_bytes, os.open
            def read(path, cap): calls.append((str(path), cap)); return original_read(path, cap)
            def opened(path, *a, **kw): opens.append(str(path)); return original_open(path, *a, **kw)
            with patch.object(self.S, 'INPUT_TOTAL', reserve + sum(sizes) - short), \
                 patch.object(self.S, 'read_bytes', side_effect=read), patch.object(os, 'open', side_effect=opened):
                if short:
                    with self.assertRaisesRegex(ValueError, 'bounded-regular-input-required'): self.D.source_bracket(manifest)
                    self.assertNotIn(str(ROOT / self.D.MEMBERS[-1]), opens)
                else: self.assertEqual(len(self.D.source_bracket(manifest)), 8)
            self.assertEqual(calls[-1][1], sizes[-1] - short)

    def test_t21(self):
        deep = None
        for _ in range(18): deep = [deep]
        cases = [deep, list(range(129)), {str(i): i for i in range(65)}, {'x' * 129: 1}, 'x' * 1025,
            2 ** 64, float('nan'), float('inf'), {'x': object()}, '\x01' * 1024]
        for value in cases:
            with self.subTest(value_type=type(value).__name__), self.assertRaises((ValueError, UnicodeError)):
                self.S.encode(value, 1024)
        for body in (b'{"x":1,"x":2}', b'{"x":NaN}', b'{"x":1e999}'):
            with self.assertRaises(ValueError): self.S.strict_json(body)
        self.assertEqual(self.S.strict_json(self.S.encode({'x': 1}, 100)), {'x': 1})
        with self.assertRaisesRegex(ValueError, 'output-tree-bound'):
            self.S.encode([[None] * 128 for _ in range(32)], 1048576)

    def test_t22(self):
        value = self.observation()
        self.assertEqual(self.D.validate_observation(value, 'sample01', 'b' * 64, self.owned), value)
        for field, replacement in (('entry_count', 9), ('exact_equal', False), ('extra_key_count', 1), ('requested_hashes', [])):
            changed = copy.deepcopy(value); changed['early'][field] = replacement
            with self.subTest(field=field), self.assertRaises(ValueError): self.D.validate_observation(changed, 'sample01', 'b' * 64, self.owned)
        changed = copy.deepcopy(value); changed['directories_equal'] = False
        with self.assertRaises(ValueError): self.D.validate_observation(changed, 'sample01', 'b' * 64, self.owned)

        for variant, predicate in (('environment-mismatch', 'early'), ('directory-mismatch', 'directories_equal')):
            route = self.route(variant)
            with self.subTest(variant=variant):
                self.assertEqual(route.roles, [*self.D.METADATA_NAMES, 'caller', 'sample01'])
                self.assertEqual((route.supervisor_code, route.publisher_code), (1, 0), route.error)
                self.assertFalse(route.public_result['data']['observation_valid'])
                value = json.loads((Path(route.args.public) / 'setup/sample01.json').read_text())['data']
                self.assertFalse(value['observation']['early']['exact_equal'] if predicate == 'early' else value['observation'][predicate])
                self.assertEqual(json.loads((Path(route.args.public) / 'setup/actual-status.json').read_text())['data']['observers'][0]['actual_exit'], 0)
                if variant == 'directory-mismatch':
                    self.assertFalse(value['request_directories_current'])
                    self.assertNotEqual(value['request_baseline']['directories']['HOME']['inode'], value['observation']['directories']['HOME']['inode'])

    def test_t23(self):
        for code in (7, 127, -15):
            row = self.terminal(code=max(code, 0))
            if code < 0:
                row.update(actual_exit=code, raw_terminal_wait=[123, 15], command_ok=False)
            self.assertEqual(self.D.safe_status(row)['actual_exit'], code)
        for code in (True, 1.0, '0'):
            row = self.terminal(); row['actual_exit'] = code
            with self.assertRaises(ValueError): self.D.safe_status(row)
        row = self.terminal(); row.update(late_exit=True, late_zero=True, command_ok=False)
        self.assertTrue(self.D.safe_status(row)['late_zero'])

        for variant, role, expected in (('observer-nonzero', 'sample01', 7), ('observer-signal', 'sample01', -15),
            ('observer-late', 'sample01', 0), ('caller-nonzero', 'caller', 7), ('caller-late', 'caller', 0),
            ('shell-nonzero', 'shell', 7), ('metadata-nonzero', 'source-head', 7)):
            route = self.route(variant)
            with self.subTest(variant=variant):
                self.assertEqual(route.publisher_code, 0, route.error); self.assertFalse(route.public_result['data']['observation_valid'])
                if role == 'sample01': self.assertNotIn('sample02', route.roles)
                statuses = json.loads((Path(route.args.public) / 'setup/actual-status.json').read_text())['data']
                actual = statuses['original_supervisor_exit'] if role == 'shell' else statuses['caller']['actual_exit'] if role == 'caller' else next(
                    row['actual_exit'] for row in statuses['metadata'] + statuses['observers'] if row['role'] == role)
                self.assertEqual(actual, expected)

        for case in CONTRADICTION_CASES:
            def change(raw, selected=case):
                def mutate(parent, outer, final, result):
                    row = final['observers'][0]
                    if selected == 'observer-nonzero-contradiction': row.update(actual_exit=7, raw_terminal_wait=[row['raw_terminal_wait'][0], 7 << 8], command_ok=False)
                    elif selected == 'observer-signal-contradiction': row.update(actual_exit=-15, raw_terminal_wait=[row['raw_terminal_wait'][0], 15], command_ok=False)
                    elif selected == 'observer-late-contradiction': row.update(late_zero=True, late_exit=True, command_ok=False)
                    elif selected == 'observer-uncertain-contradiction':
                        row.update(actual_exit=None, raw_terminal_wait=None, root_reaped=False, material_safe=False,
                            ownership_uncertain=True, command_ok=False); final['material_safe'] = False
                    elif selected == 'final-incomplete': final['status'] = 'incomplete'
                    elif selected == 'inner-incomplete': result['status'] = 'incomplete'
                    elif selected == 'inner-schedule-false': result['observation_schedule_complete'] = False
                    elif selected == 'inner-source-false': result['source_brackets_equal'] = False
                    elif selected == 'inner-interpreter-false': result['interpreter_equal'] = False
                    elif selected == 'inner-valid-false': result['observation_valid'] = False
                    elif selected == 'final-deadline-false': final['successful_deadline'] = False
                    elif selected == 'final-deadline-int': final['successful_deadline'] = 1
                    elif selected == 'missing-sample': final['observers'].pop()
                    elif selected == 'reordered-samples': final['observers'].reverse()
                    elif selected == 'environment-false':
                        request = json.loads((raw / 'writers/pair/sample01.request.json').read_text())
                        expected = self.S.decode_rows(request['environment_rows']); altered = dict(expected, LANG='bounded-change')
                        result['observations']['sample01']['early'] = self.S.observe(altered, expected)
                        result['observations']['sample01']['post_reporting'] = self.S.observe(altered, expected)
                    elif selected == 'directory-false':
                        result['observations']['sample01']['directories']['HOME']['inode'] += 1
                        result['observations']['sample01']['directories_equal'] = False
                    elif selected == 'mapping-unchanged-false': result['observations']['sample01']['python_mapping_unchanged_between_samples'] = False
                    elif selected in ('expected-bytes-bool', 'observed-bytes-bool'):
                        item = next(item for item in result['observations']['sample01']['early']['requested_hashes'] if item['name'] == 'LANG')
                        item['expected' if selected.startswith('expected') else 'observed']['bytes'] = True
                    elif selected == 'outer-valid-false': outer['observation_valid'] = False
                    elif selected == 'outer-schedule-false': outer['observation_schedule_complete'] = False
                    elif selected == 'parent-incomplete': parent['status'] = outer['status'] = 'incomplete'
                    elif selected == 'parent-budget-false': parent['within_budget'] = False
                    elif selected == 'metadata-nonzero-contradiction':
                        metadata = outer['metadata'][0]
                        metadata.update(actual_exit=7, raw_terminal_wait=[metadata['raw_terminal_wait'][0], 7 << 8], command_ok=False)
                        name = 'parent/metadata/source-head.command.json'; command = json.loads((raw / name).read_text())
                        command.update(metadata); body = self.S.encode(command, 32768); (raw / name).write_bytes(body)
                        parent['closed_parent'][name] = self.S.record(body)
                    else: self.fail('undeclared contradiction')
                self.rewrite_route(raw, mutate)
            route = self.route(mutation=change)
            with self.subTest(contradiction=case):
                self.assertEqual(route.supervisor_code, 0)
                refused = {'observer-uncertain-contradiction': 'nested-writer-gate', 'final-deadline-int': 'inner-finalization-schema',
                    'missing-sample': 'unexpected-member', 'reordered-samples': 'observer-order',
                    'expected-bytes-bool': 'fixed-value-hash', 'observed-bytes-bool': 'hash-equality-consistency'}
                if case in refused:
                    self.assertEqual(route.publisher_code, 1); self.assertEqual(route.error, refused[case])
                    self.assertFalse(route.status_path.exists()); self.assertNotIn('ready=true', route.output)
                else:
                    self.assertEqual(route.publisher_code, 0, route.error)
                    self.assertFalse(route.public_result['data']['observation_valid'])
                    self.assertEqual(route.public_result['data']['status'], 'incomplete')
                    if case.startswith('observer-'):
                        actual = json.loads((Path(route.args.public) / 'setup/actual-status.json').read_text())['data']['observers'][0]
                        self.assertEqual(actual['actual_exit'], 7 if 'nonzero' in case else -15 if 'signal' in case else 0)

    def test_t24(self):
        result = dict(status='incomplete')
        actual = self.terminal('sample01', 7)
        original_save = self.S.save
        def fail_result(path, value, cap=32768):
            if str(path).endswith('/results.json'):
                Path(path).write_text('{')
                raise OSError(28, 'synthetic')
            return original_save(path, value, cap)
        with patch.object(self.S, 'save', side_effect=fail_result), patch.object(self.S, 'read_bytes', side_effect=AssertionError('partial reread')):
            receipt = self.D.result_receipt(self.raw, self.identity, result, [actual], True, 20)
        self.assertFalse(receipt['full_result_written']); self.assertIsNone(receipt['result_file'])
        self.assertEqual(receipt['observers'][0]['actual_exit'], 7)
        self.assertEqual((self.raw / 'writers/pair/results.json').read_text(), '{')
        self.assertFalse(receipt['successful_deadline'] is False and receipt['status'] == 'observed-two-matching-samples')

        for variant in ('result-write-failure', 'result-partial', 'finalization-write-failure', 'finalization-missing', 'finalization-partial'):
            route = self.route(variant)
            with self.subTest(variant=variant):
                self.assertEqual(route.supervisor_code, 1); self.assertEqual(route.publisher_code, 0, route.error)
                self.assertFalse(route.public_result['data']['observation_valid'])

    def test_t25(self):
        args = self.args()
        with patch.dict(os.environ, RUNNER_TEMP=str(self.temp), GITHUB_RUN_ID='123', GITHUB_RUN_ATTEMPT='1',
                        GITHUB_SHA=SOURCE_SHA, GITHUB_REPOSITORY='ictechgy/cartograph'), \
             patch.object(self.D, 'fresh_paths'), patch.object(self.D, 'make_raw'), patch.object(self.D, 'manifest_read', side_effect=ValueError('synthetic-source')), \
             patch.object(self.D, 'workflow_output') as output:
            self.assertEqual(self.D.supervise(args), 1)
        value = self.S.strict_json((self.raw / 'parent/admission.json').read_bytes())
        self.assertFalse(value['source_admitted']); self.assertIsNone(value['observed'])
        self.assertIsNone(self.S.strict_json((self.raw / 'parent/outer.json').read_bytes())['caller'])
        output.assert_not_called()

        def admission_only(raw):
            name = 'parent/admission.json'; path = raw / name
            value = json.loads(path.read_text())
            outer_body = (raw / 'parent/outer.json').read_bytes()
            value['failure'] = dict(type='ValueError', errno=None, stage='caller')
            body = self.S.encode(value, 32768); path.write_bytes(body)
            parent_path = raw / 'parent/supervisor-finalization.json'
            parent = json.loads(parent_path.read_text()); parent['closed_parent'][name] = self.S.record(body)
            parent_path.write_bytes(self.S.encode(parent, 8192))
            self.assertEqual((raw / 'parent/outer.json').read_bytes(), outer_body)
        route = self.route(mutation=admission_only)
        with self.subTest(admission_only_failure=True):
            self.assertEqual(route.supervisor_code, 0); self.assertEqual(route.publisher_code, 1)
            self.assertEqual(route.error, 'parent-failure-coherence')
            self.assertFalse(route.status_path.exists()); self.assertNotIn('ready=true', route.output)

    def test_t26(self):
        row = self.terminal(); row['ownership_uncertain'] = True; row['material_safe'] = False
        with patch.object(self.S, 'read_bytes', side_effect=AssertionError('unsafe lower read')), self.assertRaises(ValueError):
            self.D.read_inner(self.raw, row, self.identity)
        with self.assertRaises(FileNotFoundError): self.D.read_inner(self.raw, self.terminal(), self.identity)
        self.assertFalse((self.raw / 'writers/pair/results.json').exists())

    def test_t27(self):
        result, staging, public, projections, normalizer = self.package()
        extra = public / 'unexpected.json'; extra.write_text('{}')
        with self.assertRaises(ValueError): self.D.tree_records(public, dict(self.D.PUBLIC_CAPS, **{'manifest.json': 16384}), 524288)
        extra.unlink(); (public / 'setup/refusal.json').unlink()
        with self.assertRaises(ValueError): self.D.tree_records(public, dict(self.D.PUBLIC_CAPS, **{'manifest.json': 16384}), 524288)
        altered = copy.deepcopy(projections['results.json']); altered['identity']['run_id'] = '124'
        with self.assertRaises(ValueError): self.D.validate_projection(altered, 'results.json', self.identity)

    def test_t28(self):
        for name in self.D.FALSE_FLAGS:
            self.assertIs(self.D.flag_record()[name], False)
            value = self.D.projection('results.json', self.identity, None, {}, False); value[name] = True
            with self.subTest(flag=name), self.assertRaises(ValueError): self.D.validate_projection(value, 'results.json', self.identity)
        self.assertNotIn('accepted=True', VALIDATOR.read_text())

    def test_t29(self):
        text = WORKFLOW.read_text()
        for literal in ('workflow_dispatch:', 'runs-on: macos-26', 'timeout-minutes: 5', 'contents: read',
            '20260907.0351.1', 'native-observer-sdk-admission', 'cancel-in-progress: false',
            'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1',
            'actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9', 'include-hidden-files: false', 'retention-days: 14'):
            self.assertIn(literal, text)
        for forbidden in ('native-calibration.yml', 'pip install', 'brew install', 'xcodebuild', 'swift ', 'curl ', 'wget ', 'git '):
            self.assertNotIn(forbidden, text)
        self.assertNotIn('push:', text); self.assertNotIn('pull_request:', text)

    def test_t30(self):
        flags = self.S.eligibility()
        self.assertTrue(all(value is False for value in flags.values()))
        text = VALIDATOR.read_text()
        for literal in ('historical_run8_unresolved=True', 'pre_cpython_unobserved=True', 'no_retry=True', 'hard_wall_unproved=True'):
            self.assertIn(literal, text)
        self.assertNotIn('CoreFoundation', text)

    def test_t31(self):
        state = self.D.ChildState('sample01'); handle = SimpleNamespace(pid=123, returncode=99)
        state.handle = handle; state.anchor = True
        with patch.object(os, 'waitpid', side_effect=[(0, 0), (123, 7 << 8)]) as wait:
            self.assertFalse(state.raw_once()); self.assertIsNone(state.code)
            self.assertTrue(state.raw_once())
        self.assertEqual(state.code, 7); self.assertEqual(handle.returncode, 7)
        self.assertEqual(wait.call_count, 2); self.assertFalse(state.anchor)

    def test_t32(self):
        handle, _, _ = self.fake_process()
        self.command()
        self.assertIs(self.D.HANDLES[0], handle)
        self.D.UNCERTAIN = True
        with self.assertRaises(ValueError): self.command('sample02')
        tree = ast.parse(VALIDATOR.read_text())
        forbidden = {'wait', 'poll', 'communicate', 'send_signal', 'terminate', 'kill', '__del__'}
        self.assertFalse(any(isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr in forbidden for n in ast.walk(tree)))

    def test_t33(self):
        with patch.object(self.D.subprocess, 'Popen', side_effect=OSError(5, 'synthetic')), \
             patch.object(self.S, 'read_bytes', side_effect=AssertionError('constructor uncertain read')), \
             patch.object(os, 'killpg') as send:
            row = self.command()
        self.assertTrue(row['ownership_uncertain']); self.assertFalse(row['material_safe'])
        self.assertIsNone(row['actual_exit']); self.assertEqual(self.D.HANDLES, [])
        send.assert_not_called()

    def test_t34(self):
        with patch.object(self.D.resource, 'setrlimit'), patch.object(signal, 'signal') as handler, \
             patch.object(signal, 'getsignal', return_value=signal.SIG_IGN), self.assertRaises(ValueError):
            self.D.install_limits()
        handler.assert_not_called()
        state = self.D.ChildState('sample01'); state.handle = SimpleNamespace(pid=123, returncode=None); state.anchor = True
        with patch.object(os, 'waitpid', return_value=(123, 0)): state.raw_once()
        with patch.object(os, 'killpg') as send, self.assertRaises(ValueError): state.send(signal.SIGTERM)
        send.assert_not_called()

    def test_t35(self):
        self.fake_process(at=29)
        points = []
        with patch.object(os, 'killpg', side_effect=lambda pid, number: points.append((number, self.clock.now))):
            row = self.command('caller', deadline=30)
        self.assertEqual(points[0][0], signal.SIGTERM); self.assertGreaterEqual(points[0][1], 20)
        self.assertEqual(points[1][0], signal.SIGKILL); self.assertGreaterEqual(points[1][1], 27)
        self.assertLessEqual(row['cleanup_deadline'], 30)
        self.assertTrue(row['late_zero']); self.assertFalse(row['command_ok'])

    def test_t36(self):
        self.assertEqual(15 + 3 * 10 + 30 + 15, 90)
        for stage, count, required in (('metadata', 3, 75), ('metadata', 2, 65), ('metadata', 1, 55), ('caller', 0, 45), ('terminal', 0, 15)):
            self.clock.now = 90 - required
            self.assertEqual(self.D.budget_reserve(90, stage, count), required)
            self.clock.now += .001
            with self.subTest(stage=stage, count=count), self.assertRaises(ValueError): self.D.budget_reserve(90, stage, count)

    def test_t37(self):
        row = self.terminal('sample01'); row.update(material_safe=False, ownership_uncertain=True)
        final = dict(schema_version=1, identity=self.identity, full_result_written=False, result_file=None,
            material_safe=False, observers=[row], closed_files={}, status='incomplete', finalization_failure=None, successful_deadline=False)
        self.S.save(self.raw / 'writers/pair/finalization.json', final, 8192)
        original = self.S.read_bytes
        calls = []
        def read(path, cap):
            calls.append(str(path))
            if str(path).endswith('/finalization.json'): return original(path, cap)
            raise AssertionError('nested writer material was read')
        with patch.object(self.S, 'read_bytes', side_effect=read), patch.object(os, 'scandir', side_effect=AssertionError('unsafe inventory')), \
             self.assertRaises(ValueError): self.D.read_inner(self.raw, self.terminal(), self.identity)
        self.assertEqual(calls, [str(self.raw / 'writers/pair/finalization.json')])

        for variant in ('observer-uncertain', 'caller-uncertain'):
            route = self.route(variant)
            with self.subTest(variant=variant):
                self.assertEqual(route.supervisor_code, 1); self.assertEqual(route.publisher_code, 0, route.error)
                self.assertFalse(route.public_result['data']['observation_valid'])
                if variant == 'observer-uncertain': self.assertNotIn('sample02', route.roles)
                self.assertEqual(route.signals, [])

    def test_t38(self):
        args = self.args(); path = Path(str(self.raw)[:-4] + '-invocation-status.json')
        for field, value in (('run_id', '124'), ('run_attempt', '2'), ('job_id', 'wrong'), ('source_sha', 'b' * 40),
                ('invocation_tag', 'wrong'), ('raw_root', '/wrong'), ('original_supervisor_exit', True), ('status_finalized', False)):
            path.write_bytes(self.S.encode(self.shell(**{field: value}), 8192))
            with self.subTest(field=field), self.assertRaises(ValueError): self.D.shell_status(args, self.identity)
        path.write_bytes(self.S.encode(self.shell(original_supervisor_exit=7), 8192))
        self.assertEqual(self.D.shell_status(args, self.identity)[0]['original_supervisor_exit'], 7)
        args.shell_status_finalized = 'false'
        with self.assertRaises(ValueError): self.D.shell_status(args, self.identity)
        path.write_text('{'); args.shell_status_finalized = 'true'
        with self.assertRaises(ValueError): self.D.shell_status(args, self.identity)
        fresh = self.temp / 'native-environment-observation-124-1-raw'
        self.D.fresh_paths(fresh)
        old = Path(str(fresh)[:-4] + '-invocation-status.json')
        old.write_text('stale')
        with self.assertRaisesRegex(ValueError, 'preexisting-invocation-path'): self.D.fresh_paths(fresh)
        old.unlink(); old.symlink_to(self.temp / 'missing-target')
        with self.assertRaisesRegex(ValueError, 'preexisting-invocation-path'): self.D.fresh_paths(fresh)
        old.unlink()
        # lexists는 타입을 필터링하지 않으므로 FIFO/장치도 같은 거부 경로이다.
        with patch.object(os.path, 'lexists', side_effect=lambda p: str(p) == str(old)), \
             self.assertRaisesRegex(ValueError, 'preexisting-invocation-path'):
            self.D.fresh_paths(fresh)
        with patch.object(self.D, 'make_raw') as create, patch.object(subprocess, 'Popen') as launch, \
             patch.dict(os.environ, RUNNER_TEMP=str(self.temp), GITHUB_RUN_ID='123', GITHUB_RUN_ATTEMPT='1',
                        GITHUB_SHA=SOURCE_SHA, GITHUB_REPOSITORY='ictechgy/cartograph'), \
             self.assertRaisesRegex(ValueError, 'preexisting-invocation-path'):
            self.D.supervise(args)
        create.assert_not_called(); launch.assert_not_called()
        text = WORKFLOW.read_text()
        self.assertIn('if [[ ! -e "$receipt" && ! -L "$receipt" ]] && (set -o noclobber;', text)
        self.assertEqual(text.count('[[ ! -e "$prefix-$suffix" && ! -L "$prefix-$suffix" ]] || exit 125'), 2)
        observe = text.index('id: observe')
        self.assertLess(text.index('[[ ! -e "$prefix-$suffix"', observe), text.index('--supervise', observe))

    def test_t39(self):
        body = (ROOT / self.D.NORMALIZER_NAME).read_bytes()
        self.assertEqual(self.S.record(body), self.D.NORMALIZER_PIN)
        imports = {n.names[0].name.split('.')[0] if isinstance(n, ast.Import) else n.module.split('.')[0]
            for n in ast.parse(body).body if isinstance(n, (ast.Import, ast.ImportFrom))}
        self.assertEqual(imports, {'__future__', 'argparse', 'hashlib', 'json', 'math', 'os', 'pathlib', 're', 'sys', 'typing', 'urllib'})
        manifest = json.loads((ROOT / self.D.MANIFEST_NAME).read_text())
        self.assertEqual(manifest['sources'][self.D.NORMALIZER_NAME]['blob'], '806373a57e19ef5dbdd4f81a86dcca3d3fd294a7')
        self.assertEqual(manifest['sources'][self.D.NORMALIZER_NAME]['mode'], '100755')
        self.assertEqual(len(self.D.MEMBERS), 8)

    def test_t40(self):
        result, staging, public, projections, normalizer = self.package()
        self.assertEqual(len(projections), 9); self.assertEqual(len(result['public_records']), 10)
        self.assertEqual({str(p.relative_to(staging)) for p in normalizer.select_files(staging)}, set(self.D.PUBLIC_CAPS))
        self.assertTrue(all(value['data'] is None for name, value in projections.items() if name != 'results.json'))
        self.assertFalse(any('request' in name or name.endswith(('.stdout', '.stderr')) for name in result['public_records']))

    def test_t41(self):
        _, _, _, normalizer = self.fixture()
        sensitive = ('{"token":"synthetic"}', '{"x":"ghp_' + 'a' * 24 + '"}', '{"x":"a@example.test"}', 'x\x01')
        for text in sensitive:
            with self.subTest(text_hash=hashlib.sha256(text.encode()).hexdigest()), self.assertRaises(normalizer.PublicationBlocked):
                normalizer.check_sensitive(text, 'results.json')
        for text in ('{"x":NaN}', '{"x":1e999}', '{"x":1,"x":2}'):
            with self.assertRaises(ValueError): normalizer.strict_json(text)
        for value in ('/unmapped/private/path', 'Bearer ' + 'a' * 24):
            fixture = self.fixture(); fixture[2]['results.json']['data']['status'] = value
            with self.assertRaises(ValueError): self.package(fixture)
        # 고정 mapping 외의 모든 manifest 필드에 주입한 문자열은 원본 구조 검증에서 거부된다.
        result, staging, public, _, normalizer = self.package()
        original = normalizer.strict_json((public / 'manifest.json').read_text())
        expected = self.D.expected_manifest(staging, public, result['staged_records'], result['public_records'])
        for key in set(original) - {'prefix_mappings'}:
            changed = copy.deepcopy(original); changed[key] = 'ghp_' + 'z' * 24
            with self.subTest(field=key), self.assertRaises(ValueError): self.D.admit_generated_manifest(changed, expected)

    def test_t42(self):
        fixture = self.fixture(); normalizer = fixture[3]; package = normalizer.package
        def change(args):
            value = package(args)
            path = args.output / 'results.json'
            row = normalizer.strict_json(path.read_text()); row['data']['sample_count'] = 1
            path.write_bytes(self.S.encode(row, 32768))
            return value
        with patch.object(normalizer, 'package', side_effect=change), self.assertRaisesRegex(ValueError, 'canonical-evidence-identity-inverse'):
            self.package(fixture)
        self.assertFalse(self.D.typed_equal({'x': True}, {'x': 1}))
        self.assertFalse(self.D.typed_equal({'x': [1, 2]}, {'x': [2, 1]}))

    def test_t43(self):
        route = self.route('matching')
        self.assertEqual((route.supervisor_code, route.publisher_code), (0, 0), route.error)
        status = self.S.strict_json(route.status_path.read_bytes())
        self.assertTrue(status['ready']); self.assertEqual(status['original_supervisor_exit'], 0)
        self.assertEqual(status['evidence_files_scanned_in_full'], 9)
        self.assertTrue(status['manifest_scanner_view_passed']); self.assertTrue(status['exact_prefix_mappings_reconstructed'])
        actual = Path(route.args.public) / 'manifest.json'
        self.assertEqual(self.S.record(actual.read_bytes()), status['manifest'])
        self.assertEqual(len(self.S.strict_json(actual.read_bytes())['prefix_mappings']), 11)
        self.assertIn('ready=true\n', route.output)
        structural = ('mapping-container-not-list', 'missing-row', 'extra-row', 'explicit-order', 'fixed-order',
            'duplicate-row', 'extra-row-field', 'missing-row-field', 'explicit-argument', 'explicit-token',
            'explicit-source', 'provided-prefix-hash', 'alias-hashes-type', 'alias-hashes-membership',
            'fixed-prefix', 'fixed-token', 'fixed-source', 'scanner-view-key-collision')
        secret_fields = [(row, field) for row in range(11) for field in
            (('argument', 'token', 'source', 'provided_prefix_sha256', 'alias_prefix_sha256') if row < 2 else ('prefix', 'token', 'source'))]
        self.assertEqual((len(structural), len(secret_fields)), (18, 37))
        def mutate(value, case):
            rows = value['prefix_mappings']
            if isinstance(case, tuple):
                row, field = case
                rows[row][field] = ['ghp_' + 's' * 24] if field == 'alias_prefix_sha256' else 'ghp_' + 's' * 24
            elif case == 'mapping-container-not-list': value['prefix_mappings'] = {}
            elif case == 'missing-row': rows.pop()
            elif case == 'extra-row': rows.append(copy.deepcopy(rows[-1]))
            elif case == 'explicit-order': rows[0], rows[1] = rows[1], rows[0]
            elif case == 'fixed-order': rows[2], rows[3] = rows[3], rows[2]
            elif case == 'duplicate-row': rows[3] = copy.deepcopy(rows[2])
            elif case == 'extra-row-field': rows[0]['extra'] = 'fixed'
            elif case == 'missing-row-field': del rows[0]['source']
            elif case == 'explicit-argument': rows[0]['argument'] = '--changed'
            elif case == 'explicit-token': rows[0]['token'] = '$CHANGED'
            elif case == 'explicit-source': rows[0]['source'] = 'changed'
            elif case == 'provided-prefix-hash': rows[0]['provided_prefix_sha256'] = '0' * 64
            elif case == 'alias-hashes-type': rows[0]['alias_prefix_sha256'] = '0' * 64
            elif case == 'alias-hashes-membership': rows[0]['alias_prefix_sha256'] = ['0' * 64]
            elif case == 'fixed-prefix': rows[2]['prefix'] = '/changed'
            elif case == 'fixed-token': rows[2]['token'] = '$CHANGED'
            elif case == 'fixed-source': rows[2]['source'] = 'changed'
            elif case == 'scanner-view-key-collision': value['fixed_prefix_mappings_sha256'] = '0' * 64
            else: self.fail('unlisted mutation')
        completed = 0
        for case in (*structural, *secret_fields):
            fixture = self.fixture(); normalizer = fixture[3]; real_package = normalizer.package
            def changed_package(arguments, selected=case):
                value = real_package(arguments)
                mutate(value, selected)
                (arguments.output / 'manifest.json').write_bytes(self.S.encode(value, 16384))
                return value
            with self.subTest(case=case), patch.object(normalizer, 'package', side_effect=changed_package) as producer, \
                 patch.object(self.D, 'manifest_scanner_view', wraps=self.D.manifest_scanner_view) as view:
                with self.assertRaisesRegex(ValueError, '^generated-manifest-reconstruction$'):
                    self.package(fixture)
                producer.assert_called_once(); view.assert_not_called()
                completed += 1
        self.assertEqual(completed, 55)

        route = self.route('manifest-tamper')
        self.assertEqual(route.publisher_code, 1); self.assertEqual(route.error, 'generated-manifest-reconstruction')
        self.assertFalse(route.status_path.exists()); self.assertNotIn('ready=true', route.output)

    def test_t44(self):
        route = self.route('observer-uncertain')
        self.assertEqual(route.publisher_code, 0, route.error)
        public = Path(route.args.public)
        self.assertEqual(json.loads((public / 'setup/sample01.json').read_text())['availability'], 'withheld')
        source = json.loads((public / 'setup/source-binding.json').read_text())['data']
        self.assertFalse(source['git_membership_verified']); self.assertFalse(source['terminal_bracket_matches'])
        self.assertFalse(route.public_result['data']['observation_valid'])

    def test_t45(self):
        queries = self.D.fixed_git(SOURCE_SHA)
        self.assertEqual([row[:4] for row in queries], [['/usr/bin/git', '--no-optional-locks', '-c', 'core.fsmonitor=false']] * 3)
        self.assertEqual(queries[0][4:], ['rev-parse', 'HEAD'])
        self.assertEqual(queries[1][4:], ['status', '--porcelain'])
        self.assertEqual(queries[2][4:], ['ls-tree', '--full-tree', SOURCE_SHA, '--', *self.D.MEMBERS])
        self.assertNotIn('--version', json.dumps(queries))
        with patch.dict(os.environ, GIT_CONFIG_COUNT='100', GIT_TRACE='1'):
            self.fake_process()
            row = self.command('source-head', deadline=10)
            self.assertEqual(set(self.D.subprocess.Popen.call_args.kwargs['env']), set(self.S.KEYS))
        self.assertIn('pinned_git_boolean_fsmonitor_qualified=False', VALIDATOR.read_text())

    def test_t46(self):
        body = (ROOT / self.D.CI_NAME).read_bytes()
        self.assertEqual(self.S.record(body), self.D.CI_PIN)
        manifest = json.loads((ROOT / self.D.MANIFEST_NAME).read_text())
        self.assertEqual(manifest['sources'][self.D.CI_NAME]['blob'], '1385c991863eb0e4c243038883d4185c66f307d8')
        self.D.source_bracket(manifest)
        for field, value in (('sha256', '0' * 64), ('bytes', 1), ('mode', '100755'), ('blob', '0' * 40)):
            altered = copy.deepcopy(manifest); altered['sources'][self.D.CI_NAME][field] = value
            with self.subTest(ci_pin=field), self.assertRaisesRegex(ValueError, 'source-pin-mismatch'):
                self.D.source_bracket(altered)
        original_read = self.S.read_bytes
        def changed_ci(path, cap):
            observed = original_read(path, cap)
            return observed[:-1] + b'!' if Path(path) == ROOT / self.D.CI_NAME else observed
        with patch.object(self.S, 'read_bytes', side_effect=changed_ci), self.assertRaisesRegex(ValueError, 'source-pin-mismatch'):
            self.D.source_bracket(manifest)
        self.assertIn('python3 -m unittest discover -s Scripts/benchmark-inputs -v', body.decode())
        self.assertIn('/opt/homebrew/opt/python@3.14/bin/python3.14 -I -S -B -m unittest discover -s Scripts/benchmark-inputs -p test_native_environment_observation.py -v', WORKFLOW.read_text())
        tree = ast.parse(Path(__file__).read_text())
        cls = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == 'NativeEnvironmentObservationTests')
        names = [node.name for node in cls.body if isinstance(node, ast.FunctionDef) and node.name.startswith('test_')]
        expected = [f'test_p{i:02d}' for i in range(1, 7)] + [f'test_t{i:02d}' for i in range(1, 47)]
        self.assertEqual(names, expected)
        self.assertIn('id: controls\n        timeout-minutes: 1', WORKFLOW.read_text())
        self.assertEqual(manifest['schedule']['direct_launch_maximum'], 9)
