#!/usr/bin/env python3
"""One bounded Darwin Python-mapping observation; never changes the environment."""
import os
import sys

# Snapshot as early as practical: only os/sys imported by this script so far.
# These constants match probe_support.py and are independently reviewable here.
def early_snapshot():
    if len(os.environ) > 64:
        raise ValueError('early-environment-count')
    mapping, total = {}, 0
    for name, value in os.environ.items():
        if (type(name) is not str or type(value) is not str or not 0 < len(name) <= 128
                or len(value) > 4096):
            raise ValueError('early-environment-string')
        nb, vb = name.encode('utf-8', 'strict'), value.encode('utf-8', 'strict')
        total += len(nb) + len(vb)
        if (len(nb) > 128 or len(vb) > 4096 or total > 16384 or '=' in name or '\0' in name or '\0' in value
                or name == '__CF_USER_TEXT_ENCODING' and len(vb) > 256):
            raise ValueError('early-environment-bytes')
    mapping = dict(os.environ)
    if len(mapping) != len(os.environ):
        raise ValueError('early-environment-count-drift')
    return mapping

try:
    EARLY = early_snapshot() if __name__ == '__main__' else None
except BaseException:
    os.write(2, b'early-environment-refused\n')
    raise SystemExit(1)

# No process/engine/network/native-library calls are part of this observer.
def audit(event, _args):
    if (event in {'subprocess.Popen', 'os.system', 'os.fork', 'os.forkpty', 'os.posix_spawn',
                  'os.exec', 'os.spawn', 'os.kill', 'os.killpg', 'ctypes.dlopen', 'ctypes.dlsym'}
            or event.startswith('socket.')):
        raise RuntimeError('forbidden-observer-operation')
if __name__ == '__main__':
    sys.addaudithook(audit)

import hashlib
import json
import stat
import importlib.util
import resource

PACKET = os.path.dirname(os.path.abspath(__file__))

def bootstrap(expected):
    path = PACKET + '/native_environment_probe_support.py'
    def identity(info):
        return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    before = os.lstat(path)
    if not stat.S_ISREG(before.st_mode) or not 0 <= before.st_size <= 64 * 1024 ** 2:
        raise ValueError('support-not-bounded-regular')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if identity(os.fstat(fd)) != identity(before):
            raise ValueError('support-open-drift')
        parts, count = [], 0
        while part := os.read(fd, 65536):
            count += len(part)
            if count > before.st_size:
                raise ValueError('support-read-drift')
            parts.append(part)
        if count != before.st_size or identity(os.fstat(fd)) != identity(before) or identity(os.lstat(path)) != identity(before):
            raise ValueError('support-terminal-drift')
        body = b''.join(parts)
    finally:
        os.close(fd)
    if hashlib.sha256(body).hexdigest() != expected:
        raise ValueError('support-pin-mismatch')
    spec = importlib.util.spec_from_file_location('local_probe_support', path)
    module = importlib.util.module_from_spec(spec)
    exec(compile(body, path, 'exec', dont_inherit=True), module.__dict__)
    return module

def emit_observation(S, sample, request_sha, early, post_reporting):
    """Real request reader, observer producer and exclusive writer; native observations are control seams."""
    request_body = S.read_bytes(S.OUT + '/' + sample + '.request.json', S.REQUEST_BYTES)
    S.require(S.record(request_body)['sha256'] == request_sha, 'request-hash')
    request = S.strict_json(request_body)
    expected, owned = S.validate_request(request, sample)
    expected_dirs = S.safe_directories(owned)
    observed_dirs = S.directories()
    result = dict(schema_version=1, scope='native-python-mappings-only', sample=sample,
                  request_sha256=request_sha, early=S.observe(early, expected),
                  post_reporting=S.observe(post_reporting, expected),
                  python_mapping_unchanged_between_samples=early == post_reporting,
                  directories=S.safe_directories(observed_dirs),
                  directories_equal=observed_dirs == request['directories'],
                  interpreter_sha256=S.record(S.read_bytes(S.PHYSICAL_PYTHON, S.PYTHON_BYTES))['sha256'],
                  python_version=list(sys.version_info[:3]), platform='darwin', inherited_lock_fd=9,
                  environment_mutated=False, synthetic_control=False, child_launches=0)
    S.require(result['directories'] == expected_dirs or result['directories_equal'] is False, 'directory-comparison-consistency')
    S.require(result['interpreter_sha256'] == S.PYTHON_SHA and result['python_version'] == [3, 14, 7],
              'observer-physical-pin')
    S.save(S.OUT + '/' + sample + '.observation.json', result, S.OBSERVATION_BYTES)
    return result


def main():
    if (len(sys.argv) != 7 or sys.argv[1] != '--sample' or sys.argv[2] not in ('sample01', 'sample02')
            or sys.argv[3] != '--support-sha' or sys.argv[5] != '--request-sha'):
        raise ValueError('exact-child-arguments-required')
    sample = sys.argv[2]
    S = bootstrap(sys.argv[4])
    # Second bounded mapping after the fixed reporting imports/support load.
    POST_REPORTING = early_snapshot()
    cwd = os.getcwd()
    S.require(cwd.endswith('/writers/pair') and os.path.realpath(cwd) == cwd, 'observer-owned-cwd')
    S.configure_root(cwd[:-len('/writers/pair')])
    S.require(sys.platform == 'darwin' and sys.executable == S.PYTHON
              and list(sys.version_info[:3]) == [3, 14, 7]
              and sys.flags.isolated == sys.flags.no_site == sys.flags.dont_write_bytecode == 1, 'child-platform-flags')
    resource.setrlimit(resource.RLIMIT_FSIZE, (S.OUTPUT_BYTES, S.OUTPUT_BYTES))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    os.umask(0o077)
    S.lane_identity()
    emit_observation(S, sample, sys.argv[6], EARLY, POST_REPORTING)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception:
        os.write(2, b'observation-refused\n')
        raise SystemExit(1)
# Do not unlock the inherited shared open-file description. Exit closes this copy.
