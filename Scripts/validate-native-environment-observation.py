#!/usr/bin/env python3
"""고정된 두 환경 관찰의 소유권, 실제 종료 상태와 공개 경계를 보존한다."""
import time
STARTED = time.monotonic()
import argparse
import fcntl
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import resource
import signal
import stat
import subprocess
import sys

REPOSITORY = Path(__file__).absolute().parent.parent
SUPPORT_NAME = 'Scripts/benchmark-inputs/native_environment_probe_support.py'
OBSERVER_NAME = 'Scripts/benchmark-inputs/native_environment_observer.py'
VALIDATOR_NAME = 'Scripts/validate-native-environment-observation.py'
TEST_NAME = 'Scripts/benchmark-inputs/test_native_environment_observation.py'
MANIFEST_NAME = 'Scripts/benchmark-inputs/native_environment_probe_manifest.json'
WORKFLOW_NAME = '.github/workflows/native-environment-observation.yml'
NORMALIZER_NAME = 'Scripts/normalize-indexstore-evidence.py'
CI_NAME = '.github/workflows/ci.yml'
MEMBERS = (VALIDATOR_NAME, OBSERVER_NAME, SUPPORT_NAME, MANIFEST_NAME, TEST_NAME, WORKFLOW_NAME, NORMALIZER_NAME, CI_NAME)
ENDPOINTS = (VALIDATOR_NAME, MANIFEST_NAME, WORKFLOW_NAME)
SOURCE_INPUTS = (OBSERVER_NAME, SUPPORT_NAME, TEST_NAME, NORMALIZER_NAME, CI_NAME)
SUPPORT_SHA = '2a21433cf7321df5d2a88d4976f32d160f996c1ac94fbc762a5d3e1d20705fa4'
NORMALIZER_PIN = dict(bytes=36808, sha256='17c705fac8670a77f9cbd7305c8f658807e2f6045a0ccb00172c79bccd1f7c17')
CI_PIN = dict(bytes=22818, sha256='92a20f908150cafe77b315d0a6187b0d8354495e71197c58a59ad2d3a442a78d')
JOB_ID = 'native-environment-observation'
TAG = 'fixed-native-environment-observation-v1'
SAMPLE_NAMES = ('sample01', 'sample02')
METADATA_NAMES = ('source-head', 'source-status', 'source-tree')
PUBLIC_CAPS = {'results.json': 32768, 'setup/source-binding.json': 32768,
    'setup/interpreter-admission.json': 32768, 'setup/actual-status.json': 16384,
    'setup/sample01.json': 16384, 'setup/sample02.json': 16384,
    'setup/synthetic-controls.json': 8192, 'setup/refusal.json': 16384, 'setup/limitations.json': 8192}
FALSE_FLAGS = ('accepted', 'native_actor_eligible', 'descendant_closure_eligible', 'runtime_closure_proved',
               'timing_eligible', 'final_protocol_ready', 'historical_run8_cause_established')
RAW_CAPS = {'parent/lane.lock': 0, 'parent/admission.json': 32768, 'parent/outer.json': 32768, 'parent/source-before.json': 16384, 'parent/source-after.json': 16384, 'parent/endpoint-before.json': 16384, 'parent/endpoint-after.json': 16384, 'writers/metadata/source-head.stdout': 32768, 'writers/metadata/source-head.stderr': 32768, 'parent/metadata/source-head.command.json': 32768, 'writers/metadata/source-status.stdout': 32768, 'writers/metadata/source-status.stderr': 32768, 'parent/metadata/source-status.command.json': 32768, 'writers/metadata/source-tree.stdout': 32768, 'writers/metadata/source-tree.stderr': 32768, 'parent/metadata/source-tree.command.json': 32768, 'writers/caller.stdout': 32768, 'writers/caller.stderr': 32768, 'parent/caller.command.json': 32768, 'writers/pair/sample01.request.json': 8192, 'writers/pair/sample01.stdout': 32768, 'writers/pair/sample01.stderr': 32768, 'writers/pair/sample01.observation.json': 16384, 'writers/pair/sample01.command.json': 32768, 'writers/pair/sample02.request.json': 8192, 'writers/pair/sample02.stdout': 32768, 'writers/pair/sample02.stderr': 32768, 'writers/pair/sample02.observation.json': 16384, 'writers/pair/sample02.command.json': 32768, 'writers/pair/results.json': 32768, 'writers/pair/finalization.json': 8192, 'parent/supervisor-finalization.json': 8192}
PENDING = None
HANDLES = []
UNCERTAIN = False
S = None


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def bootstrap_bytes(path, cap):
    """실패한 의존성을 불러오기 전에 독립적인 제한 판독을 수행한다."""
    def identity(info):
        return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    before = os.lstat(path)
    require(stat.S_ISREG(before.st_mode) and 0 <= before.st_size <= cap, 'bootstrap-bounded-regular')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        require(identity(os.fstat(fd)) == identity(before), 'bootstrap-open-drift')
        pieces, count = [], 0
        while piece := os.read(fd, min(65536, cap + 1 - count)):
            count += len(piece)
            require(count <= before.st_size, 'bootstrap-growth')
            pieces.append(piece)
        require(count == before.st_size and identity(os.fstat(fd)) == identity(before) ==
                identity(os.lstat(path)), 'bootstrap-terminal-drift')
        return b''.join(pieces)
    finally:
        os.close(fd)


def load_pinned(name, body):
    spec = importlib.util.spec_from_file_location('native_environment_' + Path(name).stem, REPOSITORY / name)
    module = importlib.util.module_from_spec(spec)
    exec(compile(body, str(REPOSITORY / name), 'exec', dont_inherit=True), module.__dict__)
    return module


def support():
    global S
    body = bootstrap_bytes(REPOSITORY / SUPPORT_NAME, 64 * 1024 ** 2)
    require(hashlib.sha256(body).hexdigest() == SUPPORT_SHA, 'support-pin')
    S = load_pinned(SUPPORT_NAME, body)
    return S


def scalar(value, low=-255, high=255):
    return type(value) is int and low <= value <= high


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'),
                                     ensure_ascii=True, allow_nan=False).encode()).hexdigest()


def flag_record():
    return {name: False for name in FALSE_FLAGS}


class Cancelled(BaseException):
    pass


def cancel(signum, _frame):
    global PENDING
    # 모든 신호는 등록, 수거, 반환값, 앵커 폐쇄가 끝난 다음에 처리한다.
    if PENDING is None:
        PENDING = signum


def checkpoint(deadline):
    if PENDING is not None:
        raise Cancelled()
    require(time.monotonic() <= deadline, 'phase-deadline')


def install_limits():
    os.umask(0o077)
    resource.setrlimit(resource.RLIMIT_FSIZE, (32768, 32768))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    require(signal.getsignal(signal.SIGCHLD) == signal.SIG_DFL, 'nondefault-sigchld')
    for number in (signal.SIGTERM, signal.SIGINT):
        signal.signal(number, cancel)


def current_identity(source_sha, raw, run_id=None, attempt=None):
    run_id = os.environ.get('GITHUB_RUN_ID') if run_id is None else run_id
    attempt = os.environ.get('GITHUB_RUN_ATTEMPT') if attempt is None else attempt
    require(type(source_sha) is str and re.fullmatch('[0-9a-f]{40}', source_sha), 'source-sha')
    require(all(type(x) is str and re.fullmatch('[1-9][0-9]{0,19}', x) for x in (run_id, attempt)), 'run-identity')
    temp = os.environ.get('RUNNER_TEMP')
    require(type(temp) is str and os.path.isabs(temp) and os.path.realpath(temp) == temp, 'canonical-runner-temp')
    prefix = temp + '/' + JOB_ID + '-' + run_id + '-' + attempt
    require(raw == prefix + '-raw' and not Path(raw).is_relative_to(REPOSITORY) and
            not REPOSITORY.is_relative_to(Path(raw)), 'fresh-root-location')
    return dict(run_id=run_id, run_attempt=attempt, job_id=JOB_ID, source_sha=source_sha,
                invocation_tag=TAG, raw_root_sha256=S.record(raw.encode())['sha256'])


def fixed_git(source_sha):
    return [
        ['/usr/bin/git', '--no-optional-locks', '-c', 'core.fsmonitor=false', 'rev-parse', 'HEAD'],
        ['/usr/bin/git', '--no-optional-locks', '-c', 'core.fsmonitor=false', 'status', '--porcelain'],
        ['/usr/bin/git', '--no-optional-locks', '-c', 'core.fsmonitor=false', 'ls-tree', '--full-tree',
         source_sha, '--', *MEMBERS],
    ]


def manifest_read(expected_sha):
    body = S.read_bytes(REPOSITORY / MANIFEST_NAME, 16384)
    require(type(expected_sha) is str and re.fullmatch('[0-9a-f]{64}', expected_sha) and
            S.record(body)['sha256'] == expected_sha, 'manifest-pin')
    value = S.strict_json(body)
    require(type(value) is dict and set(value) == {'schema_version', 'scope', 'sources', 'source_membership',
            'endpoint_membership', 'native_pins', 'schedule', 'qualification', 'false_flags'}, 'manifest-schema')
    require(type(value['schema_version']) is int and value['schema_version'] == 1 and
            value['scope'] == 'native-environment-observation-only' and value['source_membership'] == list(MEMBERS)
            and value['endpoint_membership'] == list(ENDPOINTS) and set(value['sources']) == set(SOURCE_INPUTS)
            and value['false_flags'] == list(FALSE_FLAGS), 'manifest-membership')
    require(value['native_pins'] == dict(configured_python=S.CONFIGURED_PYTHON, runtime_python=S.PYTHON,
        physical_python=S.PHYSICAL_PYTHON, physical_bytes=S.PYTHON_BYTES, physical_sha256=S.PYTHON_SHA,
        image_os=S.IMAGE_OS, image_version=S.IMAGE_VERSION, developer_dir=S.DEVELOPER_DIR,
        platform='darwin', python_version=[3, 14, 7], machine='arm64', os_release='25.6.0',
        product_version='26.6.2', product_build='25G83'), 'manifest-native-pins')
    require(value['schedule'] == dict(observer_count=2, observer_seconds=5, observer_term=2, observer_kill=3,
        caller_seconds=20, caller_term=7, caller_kill=3, supervisor_seconds=90, admission_seconds=15,
        metadata_count=3, metadata_slot_seconds=10, terminal_seconds=15, publisher_seconds=30,
        direct_launch_maximum=9, mock_step_seconds=60, supervisor_step_seconds=120,
        publisher_step_seconds=60, job_seconds=300), 'manifest-schedule')
    require(value['qualification'] == dict(installed_native_equivalence=False, hard_wall_proved=False,
        pinned_git_boolean_fsmonitor_qualified=False, separate_native_grant_required=True,
        upstream_commit='823f0323ee6ec1402088b73bce1a38473cac36dc',
        upstream_source_sha256='6628ffdd65c093a6c08cae01ffe82877d3ced515aac9e7be0cff16512c30a7d9'),
        'manifest-qualification')
    require(value['sources'][NORMALIZER_NAME] == dict(**NORMALIZER_PIN, mode='100755',
        blob='806373a57e19ef5dbdd4f81a86dcca3d3fd294a7') and
        value['sources'][CI_NAME] == dict(**CI_PIN, mode='100644', blob='622de642ab41685a788b0af2c10ef08e509c6ddb'),
        'unchanged-dependencies')
    return value, S.record(body)


def source_bracket(manifest, material_safe=True):
    require(material_safe and not UNCERTAIN, 'source-material-read-gate')
    total, rows = 0, {}
    for name in MEMBERS:
        remaining = S.INPUT_TOTAL - 1048576 - 65536 - S.PYTHON_BYTES - total
        require(remaining >= 0, 'source-total-limit')
        body = S.read_bytes(REPOSITORY / name, min(remaining, 16384 if name == MANIFEST_NAME else S.INPUT_BYTES))
        total += len(body)
        require(total + 1048576 + 65536 + S.PYTHON_BYTES <= S.INPUT_TOTAL, 'source-total-limit')
        info = os.lstat(REPOSITORY / name)
        row = dict(**S.record(body), mode='100755' if info.st_mode & 0o111 else '100644',
                   blob=hashlib.sha1(b'blob ' + str(len(body)).encode() + b'\0' + body).hexdigest(),
                   identity=list(S.file_identity(info)))
        if name in SOURCE_INPUTS:
            require({key: row[key] for key in ('bytes', 'sha256', 'mode', 'blob')} == manifest['sources'][name],
                    'source-pin-mismatch')
        rows[name] = row
    return rows


def split_bracket(rows):
    return ({name: rows[name] for name in SOURCE_INPUTS}, {name: rows[name] for name in ENDPOINTS})


def budget_reserve(deadline, stage, remaining_metadata=0):
    required = 10 * remaining_metadata + 30 + 15 if stage == 'metadata' else 45 if stage == 'caller' else 15
    require(deadline - time.monotonic() >= required, 'full-supervisor-stage-reserve')
    return required


class ChildState:
    """한 양수 PID의 원래 수거 기록만 신호 권한을 닫을 수 있다."""
    def __init__(self, role):
        self.role, self.handle, self.anchor = role, None, False
        self.uncertain, self.raw, self.code, self.terminal_at = False, None, None, None
        self.errors, self.signals = [], []

    def raw_once(self):
        global UNCERTAIN
        require(self.handle is not None and scalar(self.handle.pid, 1, 2 ** 31 - 1), 'retained-positive-pid')
        try:
            raw = os.waitpid(self.handle.pid, os.WNOHANG)
            require(type(raw) is tuple and len(raw) == 2 and all(type(x) is int for x in raw), 'raw-tuple')
            if raw == (0, 0):
                return False
            pid, status = raw
            require(pid == self.handle.pid and 0 <= status <= 65535 and
                    (os.WIFEXITED(status) or os.WIFSIGNALED(status)), 'raw-terminal')
            code = os.waitstatus_to_exitcode(status)
            require(scalar(code), 'raw-scalar')
            self.raw, self.code = [pid, status], code
            self.handle.returncode = code
            self.anchor = False
            self.terminal_at = time.monotonic()
            return True
        except BaseException as error:
            self.anchor, self.uncertain, UNCERTAIN = False, True, True
            self.errors.append(S.safe_error(error, 'raw-wait'))
            raise

    def wait_until(self, deadline, honor_cancel=True):
        while self.code is None:
            require(time.monotonic() < deadline, 'wait-budget-expired')
            self.raw_once()
            if honor_cancel and PENDING is not None:
                raise Cancelled()
            if self.code is None:
                time.sleep(min(.01, max(0, deadline - time.monotonic())))

    def send(self, number):
        global UNCERTAIN
        require(self.anchor and not self.uncertain and self.raw is None and self.code is None, 'closed-signal-anchor')
        try:
            os.killpg(self.handle.pid, number)
            self.signals.append('term' if number == signal.SIGTERM else 'kill')
        except ProcessLookupError:
            self.signals.append('term-not-found' if number == signal.SIGTERM else 'kill-not-found')
        except BaseException:
            self.anchor, self.uncertain, UNCERTAIN = False, True, True
            raise


def validated_wait(row):
    if type(row) is not dict or not scalar(row.get('actual_exit')):
        return False
    raw = row.get('raw_terminal_wait')
    if type(raw) is not list or len(raw) != 2 or not scalar(raw[0], 1, 2 ** 31 - 1) or not scalar(raw[1], 0, 65535):
        return False
    return ((os.WIFEXITED(raw[1]) or os.WIFSIGNALED(raw[1])) and
            os.waitstatus_to_exitcode(raw[1]) == row['actual_exit'] and row.get('root_reaped') is True and
            row.get('ownership_uncertain') is False and row.get('cleanup_errors') == [] and
            row.get('material_safe') is True)


def fixed_command(role, context, deadline):
    """호출할 수 있는 세 Git 명령, 한 caller, 두 observer만 닫힌 분기로 지정한다."""
    global UNCERTAIN
    require(not UNCERTAIN and len(HANDLES) < 4 and all(h.returncode is not None for h in HANDLES),
            'previous-child-not-closed')
    raw, environment = context['raw'], context['environment']
    S.bounded_environment(environment)
    require(type(environment) is dict and environment == S.requested_environment(), 'fresh-eight-key-environment')
    if role in METADATA_NAMES:
        argv = fixed_git(context['source_sha'])[METADATA_NAMES.index(role)]
        cwd, stem, runtime, term = REPOSITORY, raw / 'writers/metadata' / role, 5, 2
    elif role == 'caller':
        argv = [S.PYTHON, '-I', '-S', '-B', str(REPOSITORY / VALIDATOR_NAME), '--run-fixed-pair',
                '--source-sha', context['source_sha'], '--raw', str(raw), '--manifest-sha', context['manifest_sha']]
        cwd, stem, runtime, term = REPOSITORY, raw / 'writers/caller', 20, 7
    else:
        require(role in SAMPLE_NAMES, 'fixed-role')
        argv = [S.PYTHON, '-I', '-S', '-B', str(REPOSITORY / OBSERVER_NAME), '--sample', role,
                '--support-sha', SUPPORT_SHA, '--request-sha', context['request_sha']]
        cwd, stem, runtime, term = raw / 'writers/pair', raw / 'writers/pair' / role, 5, 2
    state, streams, cleanup = ChildState(role), [], []
    row = dict(role=role, actual_exit=None, raw_terminal_wait=None, root_reaped=False, material_safe=False,
        ownership_uncertain=False, cleanup_errors=cleanup, raw_wait_errors=state.errors,
        launch_attempted=False, handle_registered=False, status='not-started', signals=state.signals,
        late_zero=False, late_exit=False, failure=None, secondary_failures=[], closed_outputs={}, **flag_record())
    started = time.monotonic()
    expires, cleanup_started, cleanup_end = None, None, None
    try:
        checkpoint(deadline)
        for suffix in ('.stdout', '.stderr'):
            fd = os.open(str(stem) + suffix, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
            streams.append(fd)
        require(S.directories() == context['directories'], 'immediate-directory-drift')
        started = time.monotonic()
        row['available_seconds_at_launch'] = deadline - started
        require(deadline - started >= runtime + term + 3, 'full-runtime-cleanup-reserve')
        checkpoint(deadline)
        expires = started + runtime
        row['launch_attempted'] = True
        # handler는 Popen 반환과 강한 참조/앵커 등록 사이에서도 저장만 한다.
        state.handle = subprocess.Popen(argv, cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
            stdout=streams[0], stderr=streams[1], start_new_session=True, close_fds=True, pass_fds=(9,))
        HANDLES.append(state.handle)
        require(scalar(state.handle.pid, 1, 2 ** 31 - 1), 'launched-positive-pid')
        state.anchor = True
        row['handle_registered'] = True
        checkpoint(deadline)
        state.wait_until(expires)
    except BaseException as error:
        row['failure'] = S.safe_error(error, 'command')
        if row['launch_attempted'] and state.handle is None:
            state.uncertain, UNCERTAIN = True, True
    finally:
        if state.handle is not None and state.code is None:
            cleanup_started = time.monotonic()
            cleanup_end = min(cleanup_started + term + 3, deadline)
            # caller의 협력 기한에 닿으면 실패 전용으로 같은 cleanup의 남은 몫만 쓴다.
            if role in SAMPLE_NAMES and (PENDING is not None or time.monotonic() >= deadline):
                cleanup_end = cleanup_started + term + 3
            for number, boundary in ((signal.SIGTERM, cleanup_started + term), (signal.SIGKILL, cleanup_started + term + 3)):
                if state.code is not None or time.monotonic() >= cleanup_end:
                    break
                if state.anchor and not state.uncertain:
                    try:
                        state.send(number)
                    except BaseException as error:
                        cleanup.append(S.safe_error(error, 'cleanup-signal'))
                try:
                    state.wait_until(min(boundary, cleanup_end), False)
                except ValueError as error:
                    if time.monotonic() < min(boundary, cleanup_end):
                        cleanup.append(S.safe_error(error, 'cleanup-wait'))
                except BaseException as error:
                    cleanup.append(S.safe_error(error, 'cleanup-wait'))
                if role in SAMPLE_NAMES and (PENDING is not None or time.monotonic() >= deadline):
                    cleanup_end = cleanup_started + term + 3
                    # 협력 기한에서 잘린 TERM 대기를 같은 절대 경계까지만 재개한다.
                    if state.code is None and time.monotonic() < min(boundary, cleanup_end):
                        try:
                            state.wait_until(min(boundary, cleanup_end), False)
                        except ValueError as error:
                            if time.monotonic() < min(boundary, cleanup_end):
                                cleanup.append(S.safe_error(error, 'cleanup-resume-wait'))
                        except BaseException as error:
                            cleanup.append(S.safe_error(error, 'cleanup-resume-wait'))
        for fd in reversed(streams):
            try:
                os.close(fd)
            except BaseException as error:
                cleanup.append(S.safe_error(error, 'stream-close'))
    now = time.monotonic()
    stable = (state.raw is not None or not row['launch_attempted']) and not state.uncertain and not cleanup
    late = expires is not None and (now > expires or (state.terminal_at is not None and state.terminal_at > expires))
    row.update(actual_exit=state.code, raw_terminal_wait=state.raw, root_reaped=state.raw is not None,
        material_safe=stable, ownership_uncertain=state.uncertain, late_exit=late,
        late_zero=state.code == 0 and late, status='completed' if state.raw is not None else
        'incomplete' if row['launch_attempted'] else 'not-started', wall_seconds=now - started,
        cleanup_started=cleanup_started, cleanup_deadline=cleanup_end, cancellation_requested=PENDING)
    if stable:
        try:
            for suffix in ('.stdout', '.stderr'):
                path = str(stem) + suffix
                if len(streams) != 2:
                    break
                body = S.read_bytes(path, 32768)
                row['closed_outputs'][str(Path(path).relative_to(raw))] = S.record(body)
        except BaseException as error:
            secondary = S.safe_error(error, 'closed-stream-read')
            if row['failure'] is None:
                row['failure'] = secondary
            else:
                row['secondary_failures'].append(secondary)
    row['command_ok'] = (validated_wait(row) and state.code == 0 and not late and row['failure'] is None and
                         PENDING is None and now <= deadline)
    return row


def identity_from_raw(source_sha, raw):
    match = re.fullmatch(JOB_ID + r'-([1-9][0-9]{0,19})-([1-9][0-9]{0,19})-raw', Path(raw).name)
    require(match is not None and os.path.realpath(raw) == raw, 'caller-root-identity')
    return dict(run_id=match[1], run_attempt=match[2], job_id=JOB_ID, source_sha=source_sha,
                invocation_tag=TAG, raw_root_sha256=S.record(raw.encode())['sha256'])


def bound_record(value, maximum):
    return (type(value) is dict and set(value) == {'bytes', 'sha256'} and scalar(value['bytes'], 0, maximum)
            and type(value['sha256']) is str and re.fullmatch('[0-9a-f]{64}', value['sha256']) is not None)


def validate_mapping(row, expected):
    fields = {'entry_count', 'utf8_name_value_bytes', 'exact_equal', 'requested_values_equal', 'missing_keys',
              'changed_keys', 'extra_key_count', 'extra_sorted_names_sha256', 'known_cf_candidate_present',
              'known_cf_candidate_value', 'requested_hashes', 'expected_sorted_keys_sha256', 'observed_sorted_keys_sha256'}
    require(type(row) is dict and set(row) == fields, 'mapping-schema')
    for key, maximum in (('entry_count', 64), ('utf8_name_value_bytes', 16384), ('extra_key_count', 64)):
        require(scalar(row[key], 0, maximum), 'mapping-count')
    for key in ('missing_keys', 'changed_keys'):
        seq = row[key]
        require(type(seq) is list and len(seq) <= 8 and all(type(x) is str and x in S.KEYS for x in seq)
                and seq == [x for x in S.KEYS if x in seq], 'mapping-fixed-keys')
    require(not set(row['missing_keys']) & set(row['changed_keys']) and
            row['entry_count'] == 8 - len(row['missing_keys']) + row['extra_key_count'], 'mapping-count-consistency')
    require(all(type(row[key]) is bool for key in ('exact_equal', 'requested_values_equal', 'known_cf_candidate_present'))
            and row['requested_values_equal'] == (not row['missing_keys'] and not row['changed_keys'])
            and row['exact_equal'] == (row['requested_values_equal'] and row['extra_key_count'] == 0), 'mapping-predicates')
    for key in ('extra_sorted_names_sha256', 'expected_sorted_keys_sha256', 'observed_sorted_keys_sha256'):
        require(type(row[key]) is str and re.fullmatch('[0-9a-f]{64}', row[key]), 'mapping-hash')
    require(row['expected_sorted_keys_sha256'] == digest(sorted(S.KEYS)), 'expected-keyset')
    if row['extra_key_count'] == 0:
        require(row['extra_sorted_names_sha256'] == digest([]) and
                row['observed_sorted_keys_sha256'] == digest(sorted(set(S.KEYS) - set(row['missing_keys']))), 'known-keyset')
    candidate = row['known_cf_candidate_value']
    require((row['known_cf_candidate_present'] and row['extra_key_count'] >= 1 and bound_record(candidate, 256))
            or (not row['known_cf_candidate_present'] and candidate is None), 'candidate-schema')
    hashes = row['requested_hashes']
    require(type(hashes) is list and len(hashes) == 8, 'eight-hash-rows')
    for key, item in zip(S.KEYS, hashes):
        require(type(item) is dict and set(item) == {'name', 'expected', 'observed', 'equal'} and item['name'] == key
                and bound_record(item['expected'], 4096) and typed_equal(item['expected'], S.record(expected[key].encode()))
                and type(item['equal']) is bool, 'fixed-value-hash')
        missing = key in row['missing_keys']
        require((item['observed'] is None if missing else bound_record(item['observed'], 4096)) and
                item['equal'] == (not missing and key not in row['changed_keys']) and
                item['equal'] == typed_equal(item['expected'], item['observed']), 'hash-equality-consistency')
    return row


def validate_observation(value, sample, request_hash, owned, expected=None):
    fields = {'schema_version', 'scope', 'sample', 'request_sha256', 'early', 'post_reporting',
              'python_mapping_unchanged_between_samples', 'directories', 'directories_equal', 'interpreter_sha256',
              'python_version', 'platform', 'inherited_lock_fd', 'environment_mutated', 'synthetic_control', 'child_launches'}
    require(type(value) is dict and set(value) == fields and type(value['schema_version']) is int and
            value['schema_version'] == 1 and value['scope'] == 'native-python-mappings-only' and value['sample'] == sample
            and value['request_sha256'] == request_hash and value['interpreter_sha256'] == S.PYTHON_SHA
            and value['python_version'] == [3, 14, 7] and all(type(x) is int for x in value['python_version'])
            and value['platform'] == 'darwin' and type(value['inherited_lock_fd']) is int and value['inherited_lock_fd'] == 9
            and value['environment_mutated'] is False and value['synthetic_control'] is False
            and type(value['child_launches']) is int and value['child_launches'] == 0, 'observation-schema')
    require(type(value['directories_equal']) is bool and type(value['python_mapping_unchanged_between_samples']) is bool,
            'observation-booleans')
    projected = S.safe_directories(owned)
    require(type(value['directories']) is dict and set(value['directories']) == {'HOME', 'TMPDIR'}, 'directory-fields')
    for key in ('HOME', 'TMPDIR'):
        row = value['directories'][key]
        require(type(row) is dict and set(row) == set(projected[key]) and row['type'] == 'directory' and
            row['path_sha256'] == projected[key]['path_sha256'] and all(scalar(row[k], 0, 2 ** 64 - 1)
            for k in ('device', 'inode', 'owner_uid')), 'safe-directory-schema')
    require(value['directories_equal'] == (value['directories'] == projected), 'directory-predicate')
    expected = S.requested_environment() if expected is None else expected
    validate_mapping(value['early'], expected)
    validate_mapping(value['post_reporting'], expected)
    require(not value['python_mapping_unchanged_between_samples'] or value['early'] == value['post_reporting'],
            'snapshot-predicate')
    return value


def terminal_summary(row):
    keys = ('role', 'actual_exit', 'raw_terminal_wait', 'root_reaped', 'material_safe', 'ownership_uncertain',
            'cleanup_errors', 'launch_attempted', 'handle_registered', 'status', 'late_zero', 'late_exit',
            'failure', 'secondary_failures', 'closed_outputs', 'command_ok')
    return {key: row[key] for key in keys}


def result_receipt(raw, identity, result, commands, safe, deadline, closed_files=None):
    """부분 결과는 다시 읽지 않고 별도 최종 영수증에 알려진 종료만 남긴다."""
    receipt = dict(schema_version=1, identity=identity, full_result_written=False, result_file=None,
        material_safe=safe, observers=[terminal_summary(row) for row in commands], closed_files=dict(closed_files or {}),
        status=result['status'], finalization_failure=None, successful_deadline=False)
    try:
        receipt['result_file'] = S.save(raw / 'writers/pair/results.json', result, 32768)
        receipt['full_result_written'] = True
        receipt['closed_files']['writers/pair/results.json'] = receipt['result_file']
    except BaseException as error:
        receipt['finalization_failure'] = S.safe_error(error, 'result-write')
        result['status'] = 'incomplete'
    receipt['successful_deadline'] = time.monotonic() <= deadline and PENDING is None
    if not receipt['successful_deadline']:
        result['status'] = 'incomplete'
    receipt['status'] = result['status']
    S.save(raw / 'writers/pair/finalization.json', receipt, 8192)
    return receipt


def caller(args):
    """정상 경로의 모든 준비와 최종화를 독립적인 20초 안에 끝낸다."""
    raw, deadline = Path(args.raw), STARTED + 20
    S.configure_root(args.raw)
    identity = identity_from_raw(args.source_sha, args.raw)
    commands, observations, closed_files = [], {}, {}
    result = dict(schema_version=1, identity=identity, status='incomplete', observation_valid=False,
        observation_schedule_complete=False, commands=commands, observations=observations, synthetic_controls=None,
        source_brackets_equal=None, interpreter_equal=None, failure=None, **flag_record())
    stable, before, admission, failure_deadline = True, None, None, None
    try:
        checkpoint(deadline)
        S.lane_identity()
        manifest, _ = manifest_read(args.manifest_sha)
        before = source_bracket(manifest)
        admission = S.native_admission()
        owned, environment = S.directories(), S.requested_environment()
        result['synthetic_controls'] = S.pure_controls(environment, owned)
        for sample in SAMPLE_NAMES:
            checkpoint(deadline)
            require(stable and source_bracket(manifest) == before, 'between-observer-source-drift')
            require(S.directories() == owned and S.native_admission() == admission, 'between-observer-admission-drift')
            request = dict(schema_version=1, sample=sample, environment_rows=S.environment_rows(environment), directories=owned)
            request_file = S.save(raw / 'writers/pair' / (sample + '.request.json'), request, 8192)
            closed_files['writers/pair/' + sample + '.request.json'] = request_file
            decoded = S.strict_json(S.read_bytes(raw / 'writers/pair' / (sample + '.request.json'), 8192))
            require(decoded == request and S.decode_rows(decoded['environment_rows']) == environment and
                    S.directories() == owned, 'request-roundtrip')
            context = dict(raw=raw, environment=environment, directories=owned, request_sha=request_file['sha256'])
            row = fixed_command(sample, context, deadline)
            commands.append(row)
            stable = stable and row['material_safe']
            require(validated_wait(row), 'observer-writer-unstable')
            for name, record in row['closed_outputs'].items():
                require(record['bytes'] == 0, 'unexpected-observer-stream')
            path = 'writers/pair/' + sample + '.observation.json'
            body = S.read_bytes(raw / path, 16384)
            row['closed_outputs'][path] = S.record(body)
            observation = validate_observation(S.strict_json(body), sample, request_file['sha256'], owned)
            observations[sample] = observation
            require(row['command_ok'], 'observer-actual-failure')
            require(observation['early']['exact_equal'] and observation['post_reporting']['exact_equal'] and
                observation['directories_equal'] and observation['python_mapping_unchanged_between_samples'] and
                S.directories() == owned, 'observed-predicate-mismatch')
        checkpoint(deadline)
        require(stable, 'terminal-material-gate')
        result['source_brackets_equal'] = source_bracket(manifest) == before
        result['interpreter_equal'] = S.native_admission() == admission
        require(result['source_brackets_equal'] and result['interpreter_equal'], 'terminal-input-drift')
        result.update(status='observed-two-matching-samples', observation_valid=True, observation_schedule_complete=True)
    except BaseException as error:
        result['failure'] = S.safe_error(error, 'fixed-pair')
        failure_deadline = time.monotonic() + 2
    try:
        for row in commands:
            name = 'writers/pair/' + row['role'] + '.command.json'
            closed_files[name] = S.save(raw / name, row)
    except BaseException as error:
        if result['failure'] is None:
            result['failure'] = S.safe_error(error, 'command-receipt-write')
        result.update(status='incomplete', observation_valid=False, observation_schedule_complete=False)
    result['wall_before_finalization_seconds'] = time.monotonic() - STARTED
    final_deadline = deadline if failure_deadline is None else failure_deadline
    try:
        require(time.monotonic() <= final_deadline, 'failure-metadata-budget')
        receipt = result_receipt(raw, identity, result, commands, stable and not UNCERTAIN, deadline, closed_files)
        require(time.monotonic() <= final_deadline, 'finalization-budget')
    except BaseException:
        return 1
    return 0 if (receipt['status'] == 'observed-two-matching-samples' and receipt['full_result_written'] and
                 receipt['successful_deadline'] and time.monotonic() <= deadline and PENDING is None) else 1


def closed_read(raw, name, binding, cap):
    require(bound_record(binding, cap), 'closed-file-binding')
    body = S.read_bytes(raw / name, cap)
    require(S.record(body) == binding, 'closed-file-drift')
    return body


def validate_inner_finalization(value, identity):
    fields = {'schema_version', 'identity', 'full_result_written', 'result_file', 'material_safe', 'observers',
              'status', 'finalization_failure', 'successful_deadline', 'closed_files'}
    require(type(value) is dict and set(value) == fields and type(value['schema_version']) is int and
            value['schema_version'] == 1 and value['identity'] == identity and
            type(value['full_result_written']) is bool and type(value['material_safe']) is bool and
            type(value['successful_deadline']) is bool and value['status'] in ('incomplete', 'observed-two-matching-samples')
            and type(value['observers']) is list and len(value['observers']) <= 2, 'inner-finalization-schema')
    require([row.get('role') for row in value['observers']] == list(SAMPLE_NAMES[:len(value['observers'])]), 'observer-order')
    if value['full_result_written']:
        require(bound_record(value['result_file'], 32768), 'result-final-binding')
    else:
        require(value['result_file'] is None, 'missing-result-binding')
    allowed_closed = {'writers/pair/results.json'} | {'writers/pair/' + sample + suffix for sample in SAMPLE_NAMES
        for suffix in ('.request.json', '.command.json')}
    require(type(value['closed_files']) is dict and set(value['closed_files']) <= allowed_closed and
        all(bound_record(binding, 8192 if name.endswith('.request.json') else 32768)
            for name, binding in value['closed_files'].items()), 'caller-closed-membership')
    require(value['closed_files'].get('writers/pair/results.json') == value['result_file'], 'caller-result-binding')
    validate_error(value['finalization_failure'], ('result-write',))
    for row in value['observers']:
        require(type(row) is dict and set(row) == set(terminal_summary(row)), 'observer-terminal-fields')
        safe_status(row)
        require(type(row.get('closed_outputs')) is dict, 'observer-closed-bindings')
        permitted = {'writers/pair/' + row['role'] + suffix for suffix in ('.stdout', '.stderr', '.observation.json')}
        require(set(row['closed_outputs']) <= permitted and all(bound_record(item, 16384 if name.endswith('.json')
            else 32768) for name, item in row['closed_outputs'].items()), 'observer-output-membership')
        if row.get('material_safe') is True:
            require(validated_wait(row) or row.get('launch_attempted') is False, 'inner-writer-proof')
    require(value['material_safe'] == all(row.get('material_safe') is True for row in value['observers']), 'nested-material-proof')
    return value


def read_inner(raw, caller_row, identity):
    """caller 수거만으로 observer의 파일이나 결과를 읽지 않는다."""
    require(validated_wait(caller_row), 'caller-terminal-gate')
    body = S.read_bytes(raw / 'writers/pair/finalization.json', 8192)
    final = validate_inner_finalization(S.strict_json(body), identity)
    require(final['material_safe'] and all(validated_wait(row) or row.get('launch_attempted') is False
            for row in final['observers']), 'nested-writer-gate')
    observed = {'writers/pair/finalization.json': S.record(body)}
    for row in final['observers']:
        for name, binding in row['closed_outputs'].items():
            closed_read(raw, name, binding, 16384 if name.endswith('.json') else 32768)
            observed[name] = binding
    for name, binding in final['closed_files'].items():
        closed_read(raw, name, binding, 8192 if name.endswith('.request.json') else 32768)
        observed[name] = binding
    expected_pair = {name[len('writers/pair/'):] for name in observed if name.startswith('writers/pair/')}
    shallow_membership(raw / 'writers/pair', expected_pair)
    requests = {}
    for row in final['observers']:
        sample = row['role']
        request_name, command_name = ('writers/pair/' + sample + suffix for suffix in ('.request.json', '.command.json'))
        require(request_name in final['closed_files'] and command_name in final['closed_files'], 'observer-original-required')
        request = S.strict_json(closed_read(raw, request_name, final['closed_files'][request_name], 8192))
        requests[sample] = S.validate_request(request, sample)
        command = S.strict_json(closed_read(raw, command_name, final['closed_files'][command_name], 32768))
        require(typed_equal(terminal_summary(command), row), 'observer-command-original')
    result = None
    if final['full_result_written']:
        body = closed_read(raw, 'writers/pair/results.json', final['result_file'], 32768)
        result = S.strict_json(body)
        require(type(result) is dict and set(result) == {'schema_version', 'identity', 'status', 'observation_valid',
            'observation_schedule_complete', 'commands', 'observations', 'synthetic_controls', 'source_brackets_equal',
            'interpreter_equal', 'failure', 'wall_before_finalization_seconds', *FALSE_FLAGS} and
            type(result['schema_version']) is int and result['schema_version'] == 1 and result['identity'] == identity and
            all(result[key] is False for key in FALSE_FLAGS) and type(result['commands']) is list and
            typed_equal([terminal_summary(row) for row in result['commands']], final['observers']), 'inner-result-identity')
        require(result['status'] in ('incomplete', 'observed-two-matching-samples') and
            all(type(result[key]) is bool for key in ('observation_valid', 'observation_schedule_complete')) and
            all(result[key] is None or type(result[key]) is bool for key in ('source_brackets_equal', 'interpreter_equal')) and
            type(result['wall_before_finalization_seconds']) in (int, float) and
            0 <= result['wall_before_finalization_seconds'] <= 90 and type(result['observations']) is dict and
            list(result['observations']) == list(SAMPLE_NAMES[:len(result['observations'])]) and
            len(result['observations']) <= len(final['observers']), 'inner-result-fields')
        validate_error(result['failure'], ('fixed-pair', 'command-receipt-write'))
        for sample, observation in result['observations'].items():
            request_name = 'writers/pair/' + sample + '.request.json'
            require(sample in SAMPLE_NAMES and request_name in final['closed_files'] and
                observation.get('request_sha256') == final['closed_files'][request_name]['sha256'], 'observation-request-binding')
            expected, owned = requests[sample]
            validate_observation(observation, sample, final['closed_files'][request_name]['sha256'], owned, expected)
            observation_name = 'writers/pair/' + sample + '.observation.json'
            require(observation_name in observed and typed_equal(observation, S.strict_json(closed_read(
                raw, observation_name, observed[observation_name], 16384))), 'observation-original-equality')
        observed['writers/pair/results.json'] = final['result_file']
    return final, result, observed


def validate_error(value, stages):
    if value is None:
        return
    require(type(value) is dict and set(value) == {'type', 'errno', 'stage'} and value['type'] in
        ('ValueError', 'OSError', 'ChildProcessError', 'ProcessLookupError', 'PermissionError', 'FileNotFoundError',
         'FileExistsError', 'TimeoutError', 'Cancelled', 'RuntimeError', 'OtherError') and
        (value['errno'] is None or scalar(value['errno'], 0, 2147483647)) and value['stage'] in stages, 'safe-error-schema')


def command_success(row):
    safe_status(row)
    return row is not None and validated_wait(row) and row['command_ok'] is True and row['actual_exit'] == 0 and \
        row['status'] == 'completed' and row['launch_attempted'] is True and row['handle_registered'] is True and \
        row['late_exit'] is False and row['late_zero'] is False and row['failure'] is None and row['secondary_failures'] == []


def inner_success(final, inner):
    if final is None or inner is None:
        return False
    observations = inner['observations']
    return (final['status'] == inner['status'] == 'observed-two-matching-samples' and
        final['full_result_written'] is True and final['successful_deadline'] is True and
        final['finalization_failure'] is None and final['material_safe'] is True and
        inner['failure'] is None and inner['observation_valid'] is True and
        inner['observation_schedule_complete'] is True and inner['source_brackets_equal'] is True and
        inner['interpreter_equal'] is True and inner['wall_before_finalization_seconds'] <= 20 and
        [row['role'] for row in final['observers']] == list(SAMPLE_NAMES) and
        all(command_success(row) for row in final['observers']) and list(observations) == list(SAMPLE_NAMES) and
        all(value['early']['exact_equal'] is True and value['post_reporting']['exact_equal'] is True and
            value['directories_equal'] is True and value['python_mapping_unchanged_between_samples'] is True
            for value in observations.values()))


def validate_source_rows(value, names, manifest):
    require(type(value) is dict and set(value) == set(names), 'original-source-membership')
    for name, row in value.items():
        require(type(row) is dict and set(row) == {'bytes', 'sha256', 'mode', 'blob', 'identity'} and
            bound_record({key: row[key] for key in ('bytes', 'sha256')}, 16384 if name == MANIFEST_NAME else S.INPUT_BYTES)
            and row['mode'] in ('100644', '100755') and type(row['blob']) is str and
            re.fullmatch('[0-9a-f]{40}', row['blob']) is not None, 'original-source-row')
        identity = row['identity']
        require(type(identity) is list and len(identity) == 6 and all(scalar(n, 0, 2 ** 64 - 1) for n in identity)
            and stat.S_ISREG(identity[2]) and identity[3] == row['bytes'] and
            row['mode'] == ('100755' if identity[2] & 0o111 else '100644'), 'original-source-identity')
        if name in SOURCE_INPUTS:
            require(typed_equal({key: row[key] for key in ('bytes', 'sha256', 'mode', 'blob')},
                manifest['sources'][name]), 'original-source-pin')
    return value


def original_parent_records(raw, parent, identity):
    bindings = parent['closed_parent']
    admission = S.strict_json(closed_read(raw, 'parent/admission.json', bindings['parent/admission.json'], 32768))
    outer = S.strict_json(closed_read(raw, 'parent/outer.json', bindings['parent/outer.json'], 32768))
    require(type(admission) is dict and set(admission) == {'schema_version', 'identity', 'status', 'checkpoint',
        'failure', 'expected', 'observed', 'provenance', 'publisher_runtime', 'source_admitted', *FALSE_FLAGS} and
        type(admission['schema_version']) is int and admission['schema_version'] == 1 and
        typed_equal(admission['identity'], identity) and admission['source_admitted'] is True and
        admission['status'] in ('admitted', 'refused') and admission['checkpoint'] in
        ('source', 'native-admission', 'metadata', 'caller') and all(admission[key] is False for key in FALSE_FLAGS),
        'parent-admission-schema')
    require(typed_equal(admission['expected'], dict(platform='darwin', python_version=[3, 14, 7],
        physical_sha256=S.PYTHON_SHA, physical_bytes=S.PYTHON_BYTES, image_os=S.IMAGE_OS, image_version=S.IMAGE_VERSION)),
        'original-native-expected')
    validate_runtime_projection(admission['publisher_runtime'])
    validate_native_projection(admission['observed'])
    validate_error(admission['failure'], ('source', 'native-admission', 'metadata', 'caller'))
    require(type(outer) is dict and set(outer) == {'schema_version', 'identity', 'status', 'metadata', 'caller',
        'nested_available', 'lower_bindings', 'failure', 'observation_valid', 'observation_schedule_complete', *FALSE_FLAGS}
        and type(outer['schema_version']) is int and outer['schema_version'] == 1 and typed_equal(outer['identity'], identity)
        and outer['status'] == parent['status'] and typed_equal(outer['caller'], parent['caller']) and
        type(outer['nested_available']) is bool and outer['nested_available'] == parent['nested_available'] and
        typed_equal(outer['lower_bindings'], parent['lower_bindings']) and
        all(type(outer[key]) is bool for key in ('observation_valid', 'observation_schedule_complete')) and
        all(outer[key] is False for key in FALSE_FLAGS) and type(outer['metadata']) is list and
        [row.get('role') for row in outer['metadata']] == list(METADATA_NAMES[:len(outer['metadata'])]) and
        len(outer['metadata']) <= 3, 'parent-record-coherence')
    validate_error(outer['failure'], ('supervisor',))
    require((admission['failure'] is None and outer['failure'] is None) or
        (admission['failure'] is not None and outer['failure'] is not None and
         typed_equal({key: admission['failure'][key] for key in ('type', 'errno')},
                     {key: outer['failure'][key] for key in ('type', 'errno')}) and
         admission['failure']['stage'] == admission['checkpoint'] and outer['failure']['stage'] == 'supervisor'),
        'parent-failure-coherence')
    for row in [*outer['metadata'], *([outer['caller']] if outer['caller'] is not None else [])]:
        require(type(row) is dict and set(row) == set(terminal_summary(row)), 'parent-terminal-fields')
        safe_status(row)
        name = 'parent/caller.command.json' if row['role'] == 'caller' else 'parent/metadata/' + row['role'] + '.command.json'
        require(name in bindings, 'parent-command-required')
        original = S.strict_json(closed_read(raw, name, bindings[name], 32768))
        require(typed_equal(terminal_summary(original), row), 'parent-command-original')
    return admission, outer


def original_correspondence(raw, parent, identity, manifest, current, runtime):
    """Parent-only originals are always safe; unavailable Git/native checks never become equivalence."""
    admission, outer = original_parent_records(raw, parent, identity)
    require(typed_equal(admission['publisher_runtime'], runtime), 'publisher-original-runtime-drift')
    bindings, original = parent['closed_parent'], {}
    for phase in ('before', 'after'):
        names = ('parent/source-' + phase + '.json', 'parent/endpoint-' + phase + '.json')
        present = [name in bindings for name in names]
        require(present[0] == present[1] and (phase != 'before' or present[0]), 'original-source-bracket-required')
        if present[0]:
            rows = {}
            for name, members in zip(names, (SOURCE_INPUTS, ENDPOINTS)):
                rows.update(validate_source_rows(S.strict_json(closed_read(raw, name, bindings[name], 16384)), members, manifest))
            original[phase] = rows
    require(typed_equal(original['before'], current), 'publisher-original-source-drift')
    after_equal = 'after' in original and typed_equal(original['before'], original['after'])
    native_equal = None
    if admission['status'] == 'admitted':
        require(admission['observed'] is not None, 'original-native-required')
        native_equal = typed_equal(S.target_admission(runtime), admission['observed'])
        require(native_equal, 'publisher-original-native-drift')
    else:
        # Do not repeat the failed target gate. Exact runtime/source bootstrap is still mandatory.
        require(outer['caller'] is None and not outer['metadata'] and not parent['nested_available'], 'refused-target-has-writers')
    git_equal = False
    if parent['nested_available'] and validated_wait(parent['caller']) and len(outer['metadata']) == 3:
        git_equal = all(command_success(row) for row in outer['metadata'])
        if git_equal:
            for row in outer['metadata']:
                prefix = 'writers/metadata/' + row['role']
                require(set(row['closed_outputs']) == {prefix + '.stdout', prefix + '.stderr'}, 'metadata-original-membership')
                stdout = closed_read(raw, prefix + '.stdout', row['closed_outputs'][prefix + '.stdout'], 32768)
                require(row['closed_outputs'][prefix + '.stderr']['bytes'] == 0, 'metadata-original-stderr')
                closed_read(raw, prefix + '.stderr', row['closed_outputs'][prefix + '.stderr'], 32768)
                metadata_expected(row['role'], stdout, argparse.Namespace(source_sha=identity['source_sha']), original['before'])
    return dict(source_current=True, source_terminal=after_equal, git_bound=git_equal, native_current=native_equal)


def observation_baseline(request):
    expected, owned = S.validate_request(request, request['sample'])
    return dict(directories=S.safe_directories(owned),
        environment_hashes=[dict(name=key, **S.record(expected[key].encode())) for key in S.KEYS])


def baseline_owned(value):
    require(type(value) is dict and set(value) == {'directories', 'environment_hashes'}, 'baseline-schema')
    expected = S.requested_environment()
    require(typed_equal(value['environment_hashes'], [dict(name=key, **S.record(expected[key].encode()))
        for key in S.KEYS]), 'baseline-environment-hashes')
    rows = value['directories']
    require(type(rows) is dict and set(rows) == {'HOME', 'TMPDIR'}, 'baseline-directory-fields')
    owned = {}
    for key in ('HOME', 'TMPDIR'):
        row = rows[key]
        require(type(row) is dict and set(row) == {'path_sha256', 'device', 'inode', 'type', 'owner_uid'} and
            row['path_sha256'] == S.record(expected[key].encode())['sha256'], 'baseline-directory-path')
        owned[key] = dict(path=expected[key], **{field: row[field] for field in ('device', 'inode', 'type', 'owner_uid')})
    S.validate_request(dict(schema_version=1, sample='sample01', environment_rows=S.environment_rows(expected), directories=owned), 'sample01')
    return owned


def workflow_output(values):
    """이 호출의 GitHub 출력에만 최종화된 고정 필드를 쓴다."""
    path = os.environ.get('GITHUB_OUTPUT')
    require(type(path) is str and os.path.isabs(path), 'workflow-output-path')
    allowed = {'publication_bootstrap', 'ready', 'manifest_sha256', 'run_id', 'run_attempt', 'source_sha'}
    require(set(values) <= allowed and all(type(value) is str and re.fullmatch('[a-z0-9-]{1,64}', value)
            for value in values.values()), 'workflow-output-values')
    info = os.lstat(path)
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid(), 'workflow-output-owner')
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        require(S.file_identity(os.fstat(fd)) == S.file_identity(info), 'workflow-output-open-drift')
        data = ''.join(key + '=' + value + '\n' for key, value in values.items()).encode()
        require(os.write(fd, data) == len(data), 'workflow-output-short-write')
    finally:
        os.close(fd)



def fresh_paths(raw):
    """같은 호출 이름의 파일, FIFO, 장치, 끊어진 링크를 실행 전에 모두 거부한다."""
    prefix = str(raw)[:-4]
    for path in (str(raw), prefix + '-staging', prefix + '-public', prefix + '-invocation-status.json',
                 prefix + '-publication-status.json'):
        require(not os.path.lexists(path), 'preexisting-invocation-path')

def make_raw(raw):
    """既存 파일을 재사용하지 않고 부모와 하위 작성자 이름을 분리한다."""
    os.mkdir(raw, 0o700)
    for name in ('parent', 'parent/metadata', 'writers', 'writers/metadata', 'writers/pair', 'owned-home', 'owned-tmp'):
        os.mkdir(raw / name, 0o700)
    fd = os.open(raw / 'parent/lane.lock', os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if fd != 9:
            os.dup2(fd, 9, inheritable=True)
        else:
            os.set_inheritable(9, True)
    finally:
        if fd != 9:
            os.close(fd)
    S.lane_identity()


def metadata_expected(role, body, args, sources):
    if role == 'source-head':
        require(body == (args.source_sha + '\n').encode(), 'checkout-head-mismatch')
    elif role == 'source-status':
        require(body == b'', 'checkout-not-clean')
    else:
        expected = {name: row['mode'] + ' blob ' + row['blob'] + '\t' + name for name, row in sources.items()}
        lines = body.decode('ascii', 'strict').splitlines()
        require(len(lines) == len(MEMBERS) and set(lines) == set(expected.values()), 'checkout-tree-membership')


def supervise(args):
    """15+30+30+15 예산과 독립적인 부모 영수증을 유지한다."""
    raw, deadline = Path(args.raw), STARTED + 90
    S.configure_root(args.raw)
    identity = current_identity(args.source_sha, args.raw)
    require(identity == identity_from_raw(args.source_sha, args.raw) and
            os.environ.get('GITHUB_SHA') == args.source_sha and os.environ.get('GITHUB_REPOSITORY') == 'ictechgy/cartograph',
            'workflow-source-identity')
    fresh_paths(raw)
    make_raw(raw)
    closed, metadata, caller_row, inner = {}, [], None, None
    admission = dict(schema_version=1, identity=identity, status='refused', checkpoint='source', failure=None,
        expected=dict(platform='darwin', python_version=[3, 14, 7], physical_sha256=S.PYTHON_SHA,
            physical_bytes=S.PYTHON_BYTES, image_os=S.IMAGE_OS, image_version=S.IMAGE_VERSION),
        observed=None, provenance=None, publisher_runtime=None, source_admitted=False, **flag_record())
    outer = dict(schema_version=1, identity=identity, status='incomplete', metadata=metadata, caller=None,
        nested_available=False, lower_bindings={}, failure=None, observation_valid=False,
        observation_schedule_complete=False, **flag_record())
    bootstrap_safe, before = False, None
    def save_parent(name, value, cap=32768):
        closed[name] = S.save(raw / name, value, cap)
    try:
        checkpoint(STARTED + 15)
        manifest, _ = manifest_read(args.manifest_sha)
        before = source_bracket(manifest)
        admission['source_admitted'] = True
        admission['publisher_runtime'] = S.publisher_runtime_admission()
        bootstrap_safe = True
        source, endpoints = split_bracket(before)
        save_parent('parent/source-before.json', source, 16384)
        save_parent('parent/endpoint-before.json', endpoints, 16384)
        admission['checkpoint'] = 'native-admission'
        admission['observed'] = S.target_admission(admission['publisher_runtime'])
        admission['provenance'] = S.subprocess_provenance(subprocess)
        owned, environment = S.directories(), S.requested_environment()
        admission.update(status='admitted', checkpoint='metadata')
        checkpoint(STARTED + 15)
        for index, role in enumerate(METADATA_NAMES):
            budget_reserve(deadline, 'metadata', 3 - index)
            slot = STARTED + 15 + (index + 1) * 10
            row = fixed_command(role, dict(raw=raw, environment=environment, directories=owned,
                source_sha=args.source_sha), slot)
            metadata.append(terminal_summary(row))
            save_parent('parent/metadata/' + role + '.command.json', row)
            require(validated_wait(row) and row['command_ok'], 'metadata-failed')
            stdout_name = 'writers/metadata/' + role + '.stdout'
            stderr_name = 'writers/metadata/' + role + '.stderr'
            body = closed_read(raw, stdout_name, row['closed_outputs'][stdout_name], 32768)
            require(row['closed_outputs'][stderr_name]['bytes'] == 0, 'metadata-stderr')
            metadata_expected(role, body, args, before)
            checkpoint(slot)
        admission['checkpoint'] = 'caller'
        budget_reserve(deadline, 'caller')
        slot = STARTED + 75
        caller_row = fixed_command('caller', dict(raw=raw, environment=environment, directories=owned,
            source_sha=args.source_sha, manifest_sha=args.manifest_sha), slot)
        outer['caller'] = terminal_summary(caller_row)
        save_parent('parent/caller.command.json', caller_row)
        budget_reserve(deadline, 'terminal')
        terminal_deadline = min(time.monotonic() + 15, deadline)
        require(validated_wait(caller_row), 'caller-writer-unstable')
        final, inner, lower = read_inner(raw, caller_row, identity)
        outer.update(nested_available=True, lower_bindings=lower)
        require(not UNCERTAIN, 'terminal-source-gate')
        after = source_bracket(manifest)
        require(after == before and S.native_admission() == admission['observed'] and S.directories() == owned,
                'outer-terminal-input-drift')
        source, endpoints = split_bracket(after)
        save_parent('parent/source-after.json', source, 16384)
        save_parent('parent/endpoint-after.json', endpoints, 16384)
        checkpoint(terminal_deadline)
        require(command_success(caller_row) and inner_success(final, inner),
                'caller-actual-failure')
        outer.update(status='observed-two-matching-samples', observation_valid=True, observation_schedule_complete=True)
    except BaseException as error:
        outer['failure'] = S.safe_error(error, 'supervisor')
        admission['failure'] = S.safe_error(error, admission['checkpoint'])
    try:
        require(time.monotonic() <= deadline, 'supervisor-finalization-budget')
        save_parent('parent/admission.json', admission)
        save_parent('parent/outer.json', outer)
        receipt = dict(schema_version=1, identity=identity, closed_parent=closed, bootstrap_admitted=bootstrap_safe,
            caller=outer['caller'], nested_available=outer['nested_available'], lower_bindings=outer['lower_bindings'],
            status=outer['status'], within_budget=time.monotonic() <= deadline, **flag_record())
        S.save(raw / 'parent/supervisor-finalization.json', receipt, 8192)
        require(time.monotonic() <= deadline, 'supervisor-finalized-late')
        if bootstrap_safe:
            workflow_output({'publication_bootstrap': 'true'})
    except BaseException:
        return 1
    return 0 if outer['status'] == 'observed-two-matching-samples' and PENDING is None and time.monotonic() <= deadline else 1


def safe_status(row):
    """진단 성공은 원래 수거 상태나 불확실성을 바꾸지 못한다."""
    if row is None:
        return None
    require(type(row) is dict and row.get('role') in (*METADATA_NAMES, 'caller', *SAMPLE_NAMES), 'status-role')
    code = row.get('actual_exit')
    require(code is None or scalar(code), 'status-scalar')
    for name in ('root_reaped', 'material_safe', 'ownership_uncertain', 'launch_attempted',
                 'handle_registered', 'late_zero', 'late_exit', 'command_ok'):
        require(type(row.get(name)) is bool, 'status-boolean')
    require(type(row.get('cleanup_errors')) is list and len(row['cleanup_errors']) <= 8, 'cleanup-count')
    require(type(row.get('secondary_failures')) is list and len(row['secondary_failures']) <= 1, 'secondary-failure-count')
    validate_error(row.get('failure'), ('command', 'closed-stream-read'))
    for error in row['secondary_failures']:
        validate_error(error, ('closed-stream-read',))
    for error in row['cleanup_errors']:
        validate_error(error, ('cleanup-signal', 'cleanup-wait', 'cleanup-resume-wait', 'stream-close'))
    require(row.get('status') in ('completed', 'incomplete', 'not-started') and
        row['late_zero'] == (row['actual_exit'] == 0 and row['late_exit']), 'status-predicates')
    raw = row.get('raw_terminal_wait')
    if raw is not None:
        require(type(raw) is list and len(raw) == 2 and scalar(raw[0], 1, 2 ** 31 - 1) and
                scalar(raw[1], 0, 65535) and (os.WIFEXITED(raw[1]) or os.WIFSIGNALED(raw[1])) and
                os.waitstatus_to_exitcode(raw[1]) == code, 'status-raw-consistency')
    require(row['root_reaped'] == (raw is not None) and
            (not row['material_safe'] or validated_wait(row) or row['launch_attempted'] is False) and
            (not row['command_ok'] or validated_wait(row) and code == 0 and not row['late_exit'] and row['failure'] is None
             and row['secondary_failures'] == []), 'status-coherence')
    return dict(role=row['role'], actual_exit=code, raw_terminal_wait=raw, root_reaped=row['root_reaped'],
        ownership_uncertain=row['ownership_uncertain'], material_safe=row['material_safe'],
        late_zero=row['late_zero'], late_exit=row['late_exit'], cleanup_error_count=len(row['cleanup_errors']),
        command_ok=row['command_ok'])


def shell_status(args, identity):
    require(args.shell_status_finalized == 'true' and args.job_id == JOB_ID, 'fresh-shell-output-required')
    path = Path(args.raw[:-4] + '-invocation-status.json')
    body = S.read_bytes(path, 8192)
    value = S.strict_json(body)
    fields = {'schema_version', 'run_id', 'run_attempt', 'job_id', 'source_sha', 'invocation_tag',
              'raw_root', 'original_supervisor_exit', 'status_finalized'}
    require(type(value) is dict and set(value) == fields and type(value['schema_version']) is int and
            value['schema_version'] == 1 and value['status_finalized'] is True and
            all(value[key] == identity[key] for key in ('run_id', 'run_attempt', 'job_id', 'source_sha', 'invocation_tag'))
            and value['raw_root'] == args.raw and scalar(value['original_supervisor_exit'], 0, 255), 'shell-current-identity')
    return value, S.record(body), path


def parent_finalization(raw, identity):
    body = S.read_bytes(raw / 'parent/supervisor-finalization.json', 8192)
    value = S.strict_json(body)
    fields = {'schema_version', 'identity', 'closed_parent', 'bootstrap_admitted', 'caller', 'nested_available',
              'lower_bindings', 'status', 'within_budget', *FALSE_FLAGS}
    require(type(value) is dict and set(value) == fields and type(value['schema_version']) is int and
            value['schema_version'] == 1 and value['identity'] == identity and value['bootstrap_admitted'] is True
            and type(value['nested_available']) is bool and type(value['within_budget']) is bool
            and value['status'] in ('incomplete', 'observed-two-matching-samples') and
            all(value[key] is False for key in FALSE_FLAGS), 'parent-finalization-schema')
    allowed = {'parent/admission.json', 'parent/outer.json', 'parent/source-before.json', 'parent/source-after.json',
        'parent/endpoint-before.json', 'parent/endpoint-after.json', 'parent/caller.command.json',
        *('parent/metadata/' + name + '.command.json' for name in METADATA_NAMES)}
    require(type(value['closed_parent']) is dict and set(value['closed_parent']) <= allowed and
            {'parent/admission.json', 'parent/outer.json'} <= set(value['closed_parent']) and
            all(bound_record(row, 16384 if '/source-' in name and not name.endswith('command.json') or
                '/endpoint-' in name else 32768) for name, row in value['closed_parent'].items()), 'parent-bindings')
    safe_status(value['caller'])
    require(type(value['lower_bindings']) is dict and
            (value['nested_available'] or not value['lower_bindings']), 'parent-lower-availability')
    shallow_membership(raw / 'parent', {name[len('parent/'):] for name in value['closed_parent']} |
        {'supervisor-finalization.json', 'lane.lock'}, ('metadata',))
    return value, S.record(body)


def shallow_membership(root, expected, extra_directories=()):
    """허용된 얕은 증거 트리 이외에는 재귀 탐색을 하지 않는다."""
    expected = set(expected)
    directories = {str(Path(name).parent) for name in expected if str(Path(name).parent) != '.'} | set(extra_directories)
    directories |= {str(Path(name).parent) for name in list(directories) if str(Path(name).parent) != '.'}
    found = set()
    for relative in sorted({'.', *directories}):
        base = root if relative == '.' else root / relative
        info = os.lstat(base)
        require(stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode) and info.st_uid == os.getuid(), 'member-directory')
        entries = list(os.scandir(base))
        require(len(entries) <= 64, 'member-count')
        for entry in entries:
            name = entry.name if relative == '.' else relative + '/' + entry.name
            info = entry.stat(follow_symlinks=False)
            if name in directories:
                require(stat.S_ISDIR(info.st_mode), 'member-directory-type')
            else:
                require(name in expected and stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid(), 'unexpected-member')
                found.add(name)
    require(found == expected, 'exact-membership')
    return sorted(found)


def projection(name, identity, data, provenance, available):
    require(name in PUBLIC_CAPS and type(available) is bool, 'projection-role')
    return dict(schema_version=1, role=name, identity=identity, availability='available' if available else 'withheld',
                unavailable_reason=None if available else 'missing-or-unproved-writer', data=data if available else None,
                private_provenance=provenance, **flag_record())


def validate_projection(value, name, identity):
    fields = {'schema_version', 'role', 'identity', 'availability', 'unavailable_reason', 'data', 'private_provenance', *FALSE_FLAGS}
    require(type(value) is dict and set(value) == fields and type(value['schema_version']) is int and value['schema_version'] == 1
        and value['role'] == name and value['identity'] == identity and all(value[key] is False for key in FALSE_FLAGS),
        'projection-schema')
    require(value['availability'] in ('available', 'withheld') and
        ((value['availability'] == 'withheld' and value['data'] is None and value['unavailable_reason'] == 'missing-or-unproved-writer')
         or (value['availability'] == 'available' and value['unavailable_reason'] is None and type(value['data']) is dict)),
        'projection-availability')
    provenance_names = {'parent/admission.json', 'parent/outer.json', 'parent/source-before.json', 'parent/source-after.json',
        'parent/endpoint-before.json', 'parent/endpoint-after.json', 'writers/pair/results.json',
        'writers/pair/sample01.observation.json', 'writers/pair/sample02.observation.json',
        'writers/pair/sample01.request.json', 'writers/pair/sample02.request.json'}
    require(type(value['private_provenance']) is dict and set(value['private_provenance']) <= provenance_names and
        all(bound_record(binding, 32768) for binding in value['private_provenance'].values()), 'projection-provenance')
    if value['availability'] == 'withheld':
        return value
    data = value['data']
    fields_by_name = {
        'results.json': {'status', 'observation_valid', 'observation_schedule_complete', 'sample_count'},
        'setup/source-binding.json': {'manifest_sha256', 'source_before', 'source_after', 'endpoint_before', 'endpoint_after',
            'original_before_matches_current', 'terminal_bracket_matches', 'git_membership_verified'},
        'setup/interpreter-admission.json': {'status', 'checkpoint', 'observed', 'provenance', 'publisher_runtime', 'current_native_matches'},
        'setup/actual-status.json': {'original_supervisor_exit', 'caller', 'metadata', 'observers'},
        'setup/sample01.json': {'observation', 'request_baseline', 'request_directories_current'},
        'setup/sample02.json': {'observation', 'request_baseline', 'request_directories_current'},
        'setup/synthetic-controls.json': {'controls'}, 'setup/refusal.json': {'status', 'checkpoint', 'failure_type', 'failure_errno'},
        'setup/limitations.json': {'only_current_python_mappings', 'historical_run8_unresolved', 'pre_cpython_unobserved',
            'runtime_closure_unproved', 'hard_wall_unproved', 'installed_upstream_equivalence_unproved',
            'git_boolean_fsmonitor_pregrant_qualification_required', 'infrastructure_descendants_unmeasured', 'no_retry',
            'interpreter_bootstrap_failure_withholds_artifact', 'target_refusal_requires_independent_publisher_bootstrap'},
    }
    require(set(data) == fields_by_name[name], 'projection-data-fields')
    if name == 'results.json':
        require(data['status'] in ('incomplete', 'observed-two-matching-samples') and
            type(data['observation_valid']) is bool and type(data['observation_schedule_complete']) is bool and
            scalar(data['sample_count'], 0, 2), 'projection-result')
    elif name == 'setup/limitations.json':
        require(all(item is True for item in data.values()), 'projection-limitations')
    elif name == 'setup/refusal.json':
        require(data['status'] in ('incomplete', 'observed-two-matching-samples') and data['checkpoint'] in
            ('source', 'native-admission', 'metadata', 'caller') and data['failure_type'] in
            (None, 'ValueError', 'OSError', 'ChildProcessError', 'ProcessLookupError', 'PermissionError', 'FileNotFoundError',
             'FileExistsError', 'TimeoutError', 'Cancelled', 'RuntimeError', 'OtherError') and
            (data['failure_errno'] is None or scalar(data['failure_errno'], 0, 2147483647)), 'projection-refusal')
    validate_projection_data(data, name)
    S.output_bound(value, PUBLIC_CAPS[name])
    return value


def projection_inputs(raw, parent, identity, shell, manifest_sha, correspondence=None):
    """Validate observations against their original requests, never publication-time directory identities."""
    bindings = parent['closed_parent']
    admission, outer = original_parent_records(raw, parent, identity)
    common = {name: bindings[name] for name in ('parent/admission.json', 'parent/outer.json')}
    data, provenance, inner, final = {}, {}, None, None
    source_names = ('parent/source-before.json', 'parent/source-after.json', 'parent/endpoint-before.json', 'parent/endpoint-after.json')
    safe_lower = parent['nested_available'] and validated_wait(parent['caller'])
    if safe_lower:
        final, inner, observed = read_inner(raw, parent['caller'], identity)
        require(typed_equal(observed, parent['lower_bindings']), 'nested-parent-binding')
    if correspondence is not None:
        data['setup/source-binding.json'] = dict(manifest_sha256=manifest_sha,
            **{key: bindings.get(name) for key, name in zip(('source_before', 'source_after', 'endpoint_before', 'endpoint_after'), source_names)},
            original_before_matches_current=correspondence['source_current'], terminal_bracket_matches=correspondence['source_terminal'],
            git_membership_verified=correspondence['git_bound'])
        provenance['setup/source-binding.json'] = {name: bindings[name] for name in source_names if name in bindings}
    observations = inner['observations'] if inner is not None else {}
    for sample, value in observations.items():
        name = 'writers/pair/' + sample + '.observation.json'
        request_name = 'writers/pair/' + sample + '.request.json'
        request = S.strict_json(closed_read(raw, request_name, parent['lower_bindings'][request_name], 8192))
        expected, owned = S.validate_request(request, sample)
        validate_observation(value, sample, parent['lower_bindings'][request_name]['sha256'], owned, expected)
        data['setup/' + sample + '.json'] = dict(observation=value, request_baseline=observation_baseline(request),
            request_directories_current=typed_equal(S.directories(), owned))
        provenance['setup/' + sample + '.json'] = {name: parent['lower_bindings'][name], request_name: parent['lower_bindings'][request_name]}
    code = shell['original_supervisor_exit']
    valid = (safe_lower and code == 0 and parent['within_budget'] is True and parent['status'] == 'observed-two-matching-samples'
        and command_success(parent['caller']) and admission['failure'] is None and outer['failure'] is None and
        outer['observation_valid'] is True and
        outer['observation_schedule_complete'] is True and inner_success(final, inner) and correspondence is not None and
        all(correspondence[key] is True for key in ('source_current', 'source_terminal', 'git_bound', 'native_current')) and
        all(data['setup/' + sample + '.json']['request_directories_current'] is True for sample in SAMPLE_NAMES))
    data['results.json'] = dict(status='observed-two-matching-samples' if valid else 'incomplete',
        observation_valid=valid, observation_schedule_complete=valid, sample_count=len(observations))
    data['setup/actual-status.json'] = dict(original_supervisor_exit=code, caller=safe_status(parent['caller']),
        metadata=[safe_status(row) for row in outer['metadata']], observers=[safe_status(row) for row in final['observers']] if final else [])
    data['setup/interpreter-admission.json'] = dict(status=admission['status'], checkpoint=admission['checkpoint'],
        observed=admission['observed'], provenance=admission['provenance'], publisher_runtime=admission['publisher_runtime'],
        current_native_matches=None if correspondence is None else correspondence['native_current'])
    error = outer['failure']
    data['setup/refusal.json'] = dict(status=data['results.json']['status'], checkpoint=admission['checkpoint'],
        failure_type=error['type'] if error else None, failure_errno=error['errno'] if error else None)
    data['setup/limitations.json'] = dict(only_current_python_mappings=True, historical_run8_unresolved=True,
        pre_cpython_unobserved=True, runtime_closure_unproved=True, hard_wall_unproved=True,
        installed_upstream_equivalence_unproved=True, git_boolean_fsmonitor_pregrant_qualification_required=True,
        infrastructure_descendants_unmeasured=True, no_retry=True, interpreter_bootstrap_failure_withholds_artifact=True,
        target_refusal_requires_independent_publisher_bootstrap=True)
    if inner is not None and inner['synthetic_controls'] is not None:
        controls = inner['synthetic_controls']
        require(typed_equal(controls, S.pure_controls(S.requested_environment(),
            baseline_owned(data['setup/sample01.json']['request_baseline']) if observations else S.directories())), 'published-controls')
        data['setup/synthetic-controls.json'] = dict(controls=controls)
        provenance['setup/synthetic-controls.json'] = {'writers/pair/results.json': parent['lower_bindings']['writers/pair/results.json']}
    return {name: validate_projection(projection(name, identity, data.get(name), provenance.get(name, common), name in data),
        name, identity) for name in PUBLIC_CAPS}


SYSTEM_PREFIX_ROWS = [
    ('/usr/bin', '$SYSTEM_BIN'), ('/usr/lib', '$SYSTEM_LIB'), ('/usr/include', '$SYSTEM_INCLUDE'),
    ('/bin', '$SYSTEM_BASE_BIN'), ('/sbin', '$SYSTEM_SBIN'), ('/System/Library', '$SYSTEM_LIBRARY'),
    ('/Library/Developer/CommandLineTools', '$SYSTEM_CLT'), ('/dev/null', '$SYSTEM_NULL'), ('/dev/fd', '$SYSTEM_FD'),
]


def expected_manifest(staging, public, staged_records, public_records):
    """관찰한 manifest를 정답 틀로 쓰지 않고 고정 생산자 계약 전체를 재구성한다."""
    mappings = []
    for argument, path, token in (('--input', staging, '$EVIDENCE'), ('--output', public, '$PUBLIC_BUNDLE')):
        require(path.is_absolute() and str(path) == str(path.resolve()), 'manifest-owned-canonical-root')
        aliases = {str(path.absolute()).rstrip('/'), str(path.resolve()).rstrip('/')}
        require('' not in aliases, 'manifest-root-alias')
        mappings.append(dict(argument=argument, token=token, source='explicit',
            provided_prefix_sha256=S.record(str(path).encode())['sha256'],
            alias_prefix_sha256=sorted(S.record(alias.encode())['sha256'] for alias in aliases)))
    mappings.extend(dict(prefix=prefix, token=token, source='fixed-system-prefix') for prefix, token in SYSTEM_PREFIX_ROWS)
    return dict(schema_version=1, status='normalized_for_review', source_raw_unchanged=True,
        command=['normalize-indexstore-evidence.py', '--input', '$EVIDENCE', '--output', '$PUBLIC_BUNDLE'],
        prefix_mappings=mappings,
        files=[dict(path=name, original_raw_sha256=staged_records[name]['sha256'],
            normalized_sha256=public_records[name]['sha256'], original_bytes=staged_records[name]['bytes'],
            normalized_bytes=public_records[name]['bytes']) for name in sorted(PUBLIC_CAPS)],
        verified_sample_chunk_results=[], omitted_helper_identity_fields=[], identity_normalized_sample_chunks=[],
        embedded_memory_result_bindings=[], sample_hash_policy=(
            'Embedded sample chunk hashes describe unchanged raw inputs; use manifest normalized_sha256 for public derivatives.'),
        limits=dict(maximum_files=10000, maximum_file_bytes=8388608, maximum_total_bytes=67108864),
        excluded=['binary index records', 'build objects', 'executables', 'dependency checkouts', 'global caches'],
        privacy_note=('Declared path prefixes and fixed system paths were normalized; listed verified-helper identity metadata '
            'was omitted. Unknown absolute paths and configured sensitive-content patterns block generation. '
            'Automated screening is not a guarantee that arbitrary text is private; review before publication.'))


def typed_equal(left, right):
    """bool과 int, 목록 순서, 추가 필드를 구분해 전체 닫힌 구조를 검사한다."""
    if type(left) is not type(right):
        return False
    if type(right) is dict:
        return set(left) == set(right) and all(typed_equal(left[key], right[key]) for key in right)
    if type(right) is list:
        return len(left) == len(right) and all(typed_equal(a, b) for a, b in zip(left, right))
    return left == right


def admit_generated_manifest(value, expected):
    require(typed_equal(value, expected), 'generated-manifest-reconstruction')
    return value


def manifest_scanner_view(value, expected):
    admit_generated_manifest(value, expected)
    require('fixed_prefix_mappings_sha256' not in value, 'manifest-scanner-view-collision')
    view = {key: item for key, item in value.items() if key != 'prefix_mappings'}
    view['fixed_prefix_mappings_sha256'] = digest(value['prefix_mappings'])
    return view


def tree_records(root, caps, aggregate):
    shallow_membership(root, caps)
    rows, total = {}, 0
    for name, cap in caps.items():
        require(total <= aggregate, 'evidence-aggregate-cap')
        body = S.read_bytes(root / name, min(cap, aggregate - total))
        total += len(body)
        require(total <= aggregate, 'evidence-aggregate-cap')
        rows[name] = S.record(body)
    return rows


def package_projections(staging, public, projections, identity, normalizer, deadline):
    """실제 package/scanner를 호출하고 아홉 JSON의 정규화 역변환은 동일성만 허용한다."""
    require(set(projections) == set(PUBLIC_CAPS) and not public.is_relative_to(staging) and
            not staging.is_relative_to(public), 'publication-root-membership')
    os.mkdir(staging, 0o700)
    os.mkdir(staging / 'setup', 0o700)
    os.mkdir(public, 0o700)
    for name, value in projections.items():
        checkpoint(deadline)
        validate_projection(value, name, identity)
        S.save(staging / name, value, PUBLIC_CAPS[name])
    stage_before = tree_records(staging, PUBLIC_CAPS, 262144)
    selected = normalizer.select_files(staging)
    require([str(path.relative_to(staging)) for path in selected] == sorted(PUBLIC_CAPS), 'normalizer-selector-membership')
    checkpoint(deadline)
    returned = normalizer.package(argparse.Namespace(input=staging, output=public, prefix=[]))
    caps = dict(PUBLIC_CAPS, **{'manifest.json': 16384})
    public_records = tree_records(public, caps, 524288)
    require(tree_records(staging, PUBLIC_CAPS, 262144) == stage_before, 'staging-post-package-drift')
    for name in PUBLIC_CAPS:
        checkpoint(deadline)
        body = S.read_bytes(public / name, PUBLIC_CAPS[name])
        text = body.decode('utf-8', 'strict')
        normalizer.check_sensitive(name, name)
        normalizer.check_sensitive(text, name)
        parsed = normalizer.strict_json(text)
        validate_projection(parsed, name, identity)
        require(typed_equal(parsed, projections[name]), 'canonical-evidence-identity-inverse')
    manifest_body = S.read_bytes(public / 'manifest.json', 16384)
    value = normalizer.strict_json(manifest_body.decode('utf-8', 'strict'))
    require(typed_equal(value, returned), 'package-return-manifest-equality')
    expected = expected_manifest(staging, public, stage_before, public_records)
    # 실제 manifest는 바꾸지 않는다. 전체 검증 이후 정확히 증명된 블록만 별도 뷰에서 대체한다.
    admit_generated_manifest(value, expected)
    view = manifest_scanner_view(value, expected)
    normalizer.check_sensitive('manifest.json', 'manifest.json')
    normalizer.check_sensitive(S.encode(view, 16384).decode(), 'manifest.json')
    S.output_bound(value, 16384)
    require(S.read_bytes(public / 'manifest.json', 16384) == manifest_body and
            tree_records(staging, PUBLIC_CAPS, 262144) == stage_before and
            tree_records(public, caps, 524288) == public_records, 'publication-terminal-byte-drift')
    checkpoint(deadline)
    return dict(manifest=public_records['manifest.json'], selected_membership_sha256=digest(sorted(PUBLIC_CAPS)),
        public_membership_sha256=digest(sorted(caps)), evidence_files_scanned_in_full=9,
        manifest_scanner_view_passed=True, exact_prefix_mappings_reconstructed=True,
        fixed_prefix_mappings_sha256=digest(expected['prefix_mappings']), canonical_inverse_equal=True,
        staged_records=stage_before, public_records=public_records)


def publish(args):
    """현재 shell과 독립 부모 최종화가 허용한 바이트만 공개한다."""
    raw, deadline = Path(args.raw), STARTED + 30
    S.configure_root(args.raw)
    identity = current_identity(args.source_sha, args.raw, args.run_id, args.run_attempt)
    require(identity == identity_from_raw(args.source_sha, args.raw), 'publisher-root-identity')
    require(args.public == args.raw[:-4] + '-public', 'publisher-fixed-public-root')
    staging, public = Path(args.raw[:-4] + '-staging'), Path(args.public)
    manifest, _ = manifest_read(args.manifest_sha)
    bootstrap = source_bracket(manifest)
    runtime_before = S.publisher_runtime_admission()
    shell, shell_binding, shell_path = shell_status(args, identity)
    parent, parent_binding = parent_finalization(raw, identity)
    correspondence = original_correspondence(raw, parent, identity, manifest, bootstrap, runtime_before)
    projections = projection_inputs(raw, parent, identity, shell, args.manifest_sha, correspondence)
    private_output_budget(raw, parent)
    normalizer_body = S.read_bytes(REPOSITORY / NORMALIZER_NAME, S.INPUT_BYTES)
    require(S.record(normalizer_body) == NORMALIZER_PIN, 'normalizer-preimport-pin')
    normalizer = load_pinned(NORMALIZER_NAME, normalizer_body)
    result = package_projections(staging, public, projections, identity, normalizer, deadline)
    require(typed_equal(source_bracket(manifest), bootstrap) and
        typed_equal(S.publisher_runtime_admission(), runtime_before), 'publisher-source-after')
    require(typed_equal(original_correspondence(raw, parent, identity, manifest, bootstrap, runtime_before), correspondence),
        'publisher-original-correspondence-drift')
    require(S.record(S.read_bytes(shell_path, 8192)) == shell_binding and
        S.record(S.read_bytes(raw / 'parent/supervisor-finalization.json', 8192)) == parent_binding and
        typed_equal(projection_inputs(raw, parent, identity, shell, args.manifest_sha, correspondence), projections), 'publication-original-drift')
    checkpoint(deadline)
    status = dict(schema_version=1, identity=identity, normalizer=NORMALIZER_PIN, manifest=result['manifest'],
        original_shell_status=shell_binding, original_supervisor_exit=shell['original_supervisor_exit'],
        selected_membership_sha256=result['selected_membership_sha256'], public_membership_sha256=result['public_membership_sha256'],
        evidence_files_scanned_in_full=9, manifest_scanner_view_passed=True, exact_prefix_mappings_reconstructed=True,
        fixed_prefix_mappings_sha256=result['fixed_prefix_mappings_sha256'], canonical_inverse_equal=True,
        original_bindings_stable=True, ready=True, **flag_record())
    S.save(Path(args.raw[:-4] + '-publication-status.json'), status, 8192)
    checkpoint(deadline)
    workflow_output(dict(ready='true', manifest_sha256=result['manifest']['sha256'], run_id=identity['run_id'],
        run_attempt=identity['run_attempt'], source_sha=identity['source_sha']))
    checkpoint(deadline)
    return 0




def private_output_budget(raw, parent):
    """불확실한 하위 구역은 열지 않고 고정 작성 한도의 합만 적용한다."""
    require(sum(RAW_CAPS.values()) + 2 * 8192 == 835584 and 835584 <= 1048576, 'declared-private-output-cap')
    if not parent['nested_available'] or not validated_wait(parent['caller']):
        return None
    outer = S.strict_json(closed_read(raw, 'parent/outer.json', parent['closed_parent']['parent/outer.json'], 32768))
    bindings = dict(parent['closed_parent'])
    bindings.update(parent['lower_bindings'])
    for row in [*outer['metadata'], parent['caller']]:
        require(validated_wait(row), 'private-inventory-writer-gate')
        role = row['role']
        prefix = 'writers/caller' if role == 'caller' else 'writers/metadata/' + role
        require(set(row['closed_outputs']) == {prefix + '.stdout', prefix + '.stderr'}, 'private-stream-membership')
        bindings.update(row['closed_outputs'])
    total = 0
    for name, binding in bindings.items():
        require(name in RAW_CAPS, 'private-file-membership')
        body = closed_read(raw, name, binding, RAW_CAPS[name])
        total += len(body)
    total += len(S.read_bytes(raw / 'parent/supervisor-finalization.json', 8192))
    require(total + 2 * 8192 <= 1048576, 'observed-private-output-cap')
    shallow_membership(raw / 'writers', {name[len('writers/'):] for name in bindings if name.startswith('writers/')},
                       ('metadata', 'pair'))
    return total

def valid_hash(value):
    return type(value) is str and re.fullmatch('[0-9a-f]{64}', value) is not None


def validate_projected_status(value):
    if value is None:
        return
    fields = {'role', 'actual_exit', 'raw_terminal_wait', 'root_reaped', 'ownership_uncertain', 'material_safe',
              'late_zero', 'late_exit', 'cleanup_error_count', 'command_ok'}
    require(type(value) is dict and set(value) == fields and value['role'] in (*METADATA_NAMES, 'caller', *SAMPLE_NAMES)
        and (value['actual_exit'] is None or scalar(value['actual_exit'])) and
        scalar(value['cleanup_error_count'], 0, 8) and all(type(value[key]) is bool for key in
            ('root_reaped', 'ownership_uncertain', 'material_safe', 'late_zero', 'late_exit', 'command_ok')), 'projected-status-schema')
    raw = value['raw_terminal_wait']
    require((raw is None and value['actual_exit'] is None and not value['root_reaped']) or
        (type(raw) is list and len(raw) == 2 and scalar(raw[0], 1, 2 ** 31 - 1) and scalar(raw[1], 0, 65535) and
         (os.WIFEXITED(raw[1]) or os.WIFSIGNALED(raw[1])) and os.waitstatus_to_exitcode(raw[1]) == value['actual_exit'] and
         value['root_reaped']), 'projected-raw-status')
    require(not value['command_ok'] or (value['actual_exit'] == 0 and value['root_reaped'] and value['material_safe']
        and not value['ownership_uncertain'] and not value['late_exit'] and value['cleanup_error_count'] == 0),
        'projected-actual-precedence')


def validate_runtime_projection(value):
    fixed = dict(platform='darwin', python_version=[3, 14, 7],
        configured_path_sha256=S.admission_text_hash(S.CONFIGURED_PYTHON), runtime_path_sha256=S.admission_text_hash(S.PYTHON),
        physical_path_sha256=S.admission_text_hash(S.PHYSICAL_PYTHON), executable=dict(bytes=S.PYTHON_BYTES, sha256=S.PYTHON_SHA),
        runtime_closure_proved=False)
    dynamic = {'physical_identity', 'configured_alias_sha256', 'runtime_alias_sha256'}
    require(type(value) is dict and set(value) == set(fixed) | dynamic and
        all(typed_equal(value[key], expected) for key, expected in fixed.items()), 'publisher-runtime-fields')
    identity = value['physical_identity']
    require(type(identity) is list and len(identity) == 6 and all(scalar(n, 0, 2 ** 64 - 1) for n in identity) and
        stat.S_ISREG(identity[2]) and identity[3] == S.PYTHON_BYTES and valid_hash(value['configured_alias_sha256']) and
        valid_hash(value['runtime_alias_sha256']), 'publisher-runtime-identity')


def validate_native_projection(value):
    if value is None:
        return
    fixed = dict(platform='darwin', python_version=[3, 14, 7], machine='arm64', os_release='25.6.0',
        image_os=S.IMAGE_OS, image_version=S.IMAGE_VERSION, product_version='26.6.2', product_build='25G83',
        configured_path_sha256=S.admission_text_hash(S.CONFIGURED_PYTHON),
        runtime_path_sha256=S.admission_text_hash(S.PYTHON), physical_path_sha256=S.admission_text_hash(S.PHYSICAL_PYTHON),
        executable=dict(bytes=S.PYTHON_BYTES, sha256=S.PYTHON_SHA), runtime_closure_proved=False)
    dynamic = {'physical_identity', 'configured_alias_sha256', 'runtime_alias_sha256', 'plist'}
    require(type(value) is dict and set(value) == set(fixed) | dynamic and
        all(typed_equal(value[key], expected) for key, expected in fixed.items()), 'native-projection-fields')
    identity = value['physical_identity']
    require(type(identity) is list and len(identity) == 6 and all(scalar(n, 0, 2 ** 64 - 1) for n in identity)
        and stat.S_ISREG(identity[2]) and identity[3] == S.PYTHON_BYTES and bound_record(value['plist'], 65536)
        and valid_hash(value['configured_alias_sha256']) and valid_hash(value['runtime_alias_sha256']), 'native-projection-dynamic')


def validate_projection_data(data, name):
    if name == 'setup/source-binding.json':
        require(valid_hash(data['manifest_sha256']) and all(data[key] is None or bound_record(data[key], 16384)
            for key in ('source_before', 'source_after', 'endpoint_before', 'endpoint_after')) and
            all(type(data[key]) is bool for key in ('original_before_matches_current', 'terminal_bracket_matches',
                'git_membership_verified')), 'source-projection-bindings')
    elif name == 'setup/interpreter-admission.json':
        require(data['status'] in ('admitted', 'refused') and data['checkpoint'] in
            ('source', 'native-admission', 'metadata', 'caller'), 'admission-projection-fields')
        validate_native_projection(data['observed'])
        validate_runtime_projection(data['publisher_runtime'])
        require(data['current_native_matches'] is None or type(data['current_native_matches']) is bool, 'native-currentness-type')
        require(data['status'] != 'refused' or data['current_native_matches'] is None, 'refused-native-currentness')
        provenance = data['provenance']
        if provenance is not None:
            require(type(provenance) is dict and set(provenance) == {'origin_sha256', 'source',
                'installed_upstream_equivalence_established', 'runtime_closure_proved', 'upstream_source_sha256', 'upstream_commit'}
                and valid_hash(provenance['origin_sha256']) and bound_record(provenance['source'], 1048576)
                and provenance['installed_upstream_equivalence_established'] is False and provenance['runtime_closure_proved'] is False
                and provenance['upstream_commit'] == '823f0323ee6ec1402088b73bce1a38473cac36dc'
                and provenance['upstream_source_sha256'] == '6628ffdd65c093a6c08cae01ffe82877d3ced515aac9e7be0cff16512c30a7d9',
                'subprocess-provenance-schema')
    elif name == 'setup/actual-status.json':
        require(scalar(data['original_supervisor_exit'], 0, 255) and type(data['metadata']) is list and
            type(data['observers']) is list and len(data['metadata']) <= 3 and len(data['observers']) <= 2, 'actual-projection-counts')
        validate_projected_status(data['caller'])
        for row in data['metadata'] + data['observers']:
            validate_projected_status(row)
        require([row['role'] for row in data['metadata']] == list(METADATA_NAMES[:len(data['metadata'])]) and
            [row['role'] for row in data['observers']] == list(SAMPLE_NAMES[:len(data['observers'])]), 'actual-projection-order')
    elif name in ('setup/sample01.json', 'setup/sample02.json'):
        value = data['observation']
        require(type(value) is dict and valid_hash(value.get('request_sha256')), 'sample-request-digest')
        require(type(data['request_directories_current']) is bool, 'request-directory-currentness-type')
        validate_observation(value, Path(name).stem, value['request_sha256'], baseline_owned(data['request_baseline']))
    elif name == 'setup/synthetic-controls.json':
        require(typed_equal(data['controls'], S.pure_controls(S.requested_environment(), S.directories())), 'synthetic-projection')

def main(argv=None):
    parser = argparse.ArgumentParser()
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument('--supervise', action='store_true')
    modes.add_argument('--run-fixed-pair', action='store_true')
    modes.add_argument('--publish', action='store_true')
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--raw', required=True)
    parser.add_argument('--manifest-sha', required=True)
    parser.add_argument('--public')
    parser.add_argument('--shell-status-finalized')
    parser.add_argument('--run-id')
    parser.add_argument('--run-attempt')
    parser.add_argument('--job-id')
    args = parser.parse_args(argv)
    try:
        install_limits()
        support()
        require(os.path.realpath(REPOSITORY) == str(REPOSITORY), 'canonical-checkout')
        if args.publish:
            require(all(type(value) is str for value in (args.public, args.shell_status_finalized,
                    args.run_id, args.run_attempt, args.job_id)), 'publisher-fixed-arguments')
            return publish(args)
        require(all(value is None for value in (args.public, args.shell_status_finalized,
                    args.run_id, args.run_attempt, args.job_id)), 'unexpected-mode-arguments')
        return supervise(args) if args.supervise else caller(args)
    except BaseException:
        # 실제 stdout/stderr 원문이나 예외 경로를 공개하지 않는다.
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
