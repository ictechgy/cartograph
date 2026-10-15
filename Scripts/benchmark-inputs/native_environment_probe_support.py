"""Small stdlib-only environment codec, bounded IO and safe observations."""
import hashlib
import json
import os
import stat
import sys

from pathlib import Path
import plistlib
import re

CONFIGURED_PYTHON = '/opt/homebrew/opt/python@3.14/bin/python3.14'
PYTHON = '/opt/homebrew/Cellar/python@3.14/3.14.7/bin/python3.14'
PHYSICAL_PYTHON = '/opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/bin/python3.14'
PYTHON_BYTES = 34640
PYTHON_SHA = '87d4df53fd91304be5bac391fb204643c36b7df2023c04a0953bcbc7d4fdf634'
IMAGE_OS, IMAGE_VERSION = 'macos26', '20260907.0351.1'
DEVELOPER_DIR = '/Applications/Xcode_26.6.app/Contents/Developer'
PLIST = '/System/Library/CoreServices/SystemVersion.plist'
ALIAS_COMPONENT_LIMIT, ALIAS_LINK_LIMIT, ALIAS_TARGET_LIMIT = 128, 32, 16384
ROOT = None
OUT = None
LOCK = None
ELIGIBILITY = ('accepted', 'native_actor_eligible', 'descendant_closure_eligible', 'runtime_closure_proved',
               'timing_eligible', 'final_protocol_ready', 'historical_run8_cause_established')

KEYS = ('PATH', 'LANG', 'LC_ALL', 'DEVELOPER_DIR', 'ImageOS', 'ImageVersion', 'HOME', 'TMPDIR')
PATH_PARTS = ('/usr/bin', '/bin', '/usr/sbin', '/sbin')
ENV_COUNT, NAME_BYTES, VALUE_BYTES, ENV_BYTES = 64, 128, 4096, 16384
CF_KEY, CF_VALUE_BYTES = '__CF_USER_TEXT_ENCODING', 256
REQUEST_BYTES, OBSERVATION_BYTES, OUTPUT_BYTES = 8192, 16384, 32768
INPUT_BYTES, INPUT_TOTAL = 64 * 1024 ** 2, 64 * 1024 ** 2


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def file_identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def read_bytes(path, cap):
    before = os.lstat(path)
    require(stat.S_ISREG(before.st_mode) and 0 <= before.st_size <= cap, 'bounded-regular-input-required')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        require(file_identity(os.fstat(fd)) == file_identity(before), 'input-open-drift')
        pieces, count = [], 0
        while count < before.st_size:
            piece = os.read(fd, min(65536, before.st_size - count))
            require(piece, 'input-truncated')
            count += len(piece)
            require(count <= before.st_size, 'input-read-drift')
            pieces.append(piece)
        require(count == before.st_size and file_identity(os.fstat(fd)) == file_identity(before)
                and file_identity(os.lstat(path)) == file_identity(before), 'input-terminal-drift')
        return b''.join(pieces)
    finally:
        os.close(fd)


def record(data):
    return dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())


def strict_json(data):
    def pairs(rows):
        value = {}
        for key, item in rows:
            require(key not in value, 'duplicate-json-key')
            value[key] = item
        return value
    def invalid(_value):
        raise ValueError('nonfinite-json')
    def finite(value):
        result = float(value)
        require(-float('inf') < result < float('inf'), 'nonfinite-json')
        return result
    return json.loads(data, object_pairs_hook=pairs, parse_constant=invalid, parse_float=finite)


def output_bound(value, cap):
    # Bound the complete encoded JSON size before serialization allocates it.
    nodes, size = 0, 1  # Trailing newline.
    def string_size(item):
        return 2 + sum(2 if c in '\\"' else 6 if ord(c) < 32 else 1 if ord(c) < 128
                       else 6 if ord(c) <= 65535 else 12 for c in item)
    def visit(item, depth):
        nonlocal nodes, size
        nodes += 1
        require(nodes <= 4096 and depth <= 16, 'output-tree-bound')
        if type(item) is dict:
            require(len(item) <= 64, 'output-object-bound')
            size += 2 + max(0, len(item) - 1)
            for key, child in item.items():
                require(type(key) is str and len(key) <= 128, 'output-key-bound')
                size += string_size(key) + 1
                visit(child, depth + 1)
        elif type(item) in (list, tuple):
            require(len(item) <= 128, 'output-array-bound')
            size += 2 + max(0, len(item) - 1)
            for child in item:
                visit(child, depth + 1)
        elif type(item) is str:
            require(len(item) <= 1024 and len(item.encode('utf-8', 'strict')) <= 4096, 'output-string-bound')
            size += string_size(item)
        elif type(item) is int:
            require(-(2 ** 64) <= item < 2 ** 64, 'output-integer-bound')
            size += 21
        else:
            require(item is None or type(item) in (bool, float), 'output-scalar-type')
            if type(item) is float:
                require(-float('inf') < item < float('inf'), 'output-nonfinite')
            size += 32 if type(item) is float else 5
        require(size <= cap, 'output-encoded-size-bound')
    visit(value, 0)


def encode(value, cap):
    output_bound(value, cap)
    body = (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False) + '\n').encode()
    require(len(body) <= cap, 'serialized-output-bound')
    return body


def save(path, value, cap=OUTPUT_BYTES):
    body = encode(value, cap)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        require(stat.S_ISREG(os.fstat(fd).st_mode), 'output-not-regular')
        offset = 0
        while offset < len(body):
            written = os.write(fd, body[offset:])
            require(written > 0, 'output-short-write')
            offset += written
        require(os.fstat(fd).st_size == len(body), 'output-size-mismatch')
    finally:
        os.close(fd)
    return record(body)


def bounded_environment(mapping):
    # No sorting/hashing/serialization until every entry passes all bounds.
    require(type(mapping) is dict and len(mapping) <= ENV_COUNT, 'environment-count-type')
    total = 0
    for name, value in mapping.items():
        require(type(name) is str and type(value) is str and 0 < len(name) <= NAME_BYTES
                and len(value) <= VALUE_BYTES, 'environment-string-bound')
        name_bytes, value_bytes = name.encode('utf-8', 'strict'), value.encode('utf-8', 'strict')
        require(len(name_bytes) <= NAME_BYTES and len(value_bytes) <= VALUE_BYTES
                and '=' not in name and '\0' not in name and '\0' not in value, 'environment-byte-bound')
        total += len(name_bytes) + len(value_bytes)
        require(total <= ENV_BYTES, 'environment-total-bound')
    require(CF_KEY not in mapping or len(mapping[CF_KEY].encode('utf-8', 'strict')) <= CF_VALUE_BYTES,
            'known-candidate-value-bound')
    return total


def requested_environment():
    require(type(ROOT) is str, 'root-not-configured')
    value = dict(PATH=':'.join(PATH_PARTS), LANG='C', LC_ALL='C',
                 DEVELOPER_DIR=DEVELOPER_DIR, ImageOS=IMAGE_OS, ImageVersion=IMAGE_VERSION,
                 HOME=ROOT + '/owned-home', TMPDIR=ROOT + '/owned-tmp')
    bounded_environment(value)
    require(set(value) == set(KEYS), 'requested-eight-key-mismatch')
    return value


def environment_rows(mapping):
    bounded_environment(mapping)
    require(mapping == requested_environment(), 'request-values-mismatch')
    return [dict(name=key, value=list(PATH_PARTS) if key == 'PATH' else mapping[key]) for key in sorted(KEYS)]


def decode_rows(rows):
    require(type(rows) is list and len(rows) == 8, 'environment-row-count')
    mapping = {}
    for row in rows:
        require(type(row) is dict and set(row) == {'name', 'value'}, 'environment-row-schema')
        name, value = row['name'], row['value']
        require(type(name) is str and name in KEYS and name not in mapping, 'environment-row-name')
        if name == 'PATH':
            require(type(value) is list and value == list(PATH_PARTS), 'environment-path-row')
            value = ':'.join(value)
        require(type(value) is str, 'environment-row-value')
        mapping[name] = value
    bounded_environment(mapping)
    require(mapping == requested_environment() and [row['name'] for row in rows] == sorted(KEYS), 'environment-row-contract')
    return mapping


def directory_identity(key):
    require(key in ('HOME', 'TMPDIR'), 'directory-key')
    path = requested_environment()[key]
    require(os.path.isabs(path) and os.path.realpath(path) == path, 'directory-alias')
    before = os.lstat(path)
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        opened, after = os.fstat(fd), os.lstat(path)
        rows = [(item.st_dev, item.st_ino, stat.S_IFMT(item.st_mode), item.st_uid) for item in (before, opened, after)]
        require(rows[0] == rows[1] == rows[2] and stat.S_ISDIR(before.st_mode)
                and before.st_uid == os.getuid(), 'directory-identity-owner-type')
        return dict(path=path, device=before.st_dev, inode=before.st_ino, type='directory', owner_uid=before.st_uid)
    finally:
        os.close(fd)


def directories():
    rows = {key: directory_identity(key) for key in ('HOME', 'TMPDIR')}
    require(rows['HOME']['path'] != rows['TMPDIR']['path'] and
            (rows['HOME']['device'], rows['HOME']['inode']) != (rows['TMPDIR']['device'], rows['TMPDIR']['inode']),
            'owned-directory-overlap')
    return rows


def safe_directory(row):
    require(type(row) is dict and set(row) == {'path', 'device', 'inode', 'type', 'owner_uid'}, 'directory-schema')
    require(type(row['path']) is str and row['path'] in (ROOT + '/owned-home', ROOT + '/owned-tmp'), 'directory-path')
    require(all(type(row[key]) is int and 0 <= row[key] < 2 ** 64 for key in ('device', 'inode', 'owner_uid'))
            and row['type'] == 'directory', 'directory-scalars')
    return dict(path_sha256=record(row['path'].encode())['sha256'],
                device=row['device'], inode=row['inode'], type=row['type'], owner_uid=row['owner_uid'])


def safe_directories(rows):
    require(type(rows) is dict and set(rows) == {'HOME', 'TMPDIR'}, 'directories-schema')
    return {key: safe_directory(rows[key]) for key in ('HOME', 'TMPDIR')}


def validate_request(value, sample):
    require(type(value) is dict and set(value) == {'schema_version', 'sample', 'environment_rows', 'directories'}
        and type(value['schema_version']) is int and value['schema_version'] == 1 and value['sample'] == sample,
        'request-schema')
    environment = decode_rows(value['environment_rows'])
    safe_directories(value['directories'])
    for key in ('HOME', 'TMPDIR'):
        require(value['directories'][key]['path'] == environment[key] and
            value['directories'][key]['owner_uid'] == os.getuid(), 'request-directory-owner-path')
    require((value['directories']['HOME']['device'], value['directories']['HOME']['inode']) !=
        (value['directories']['TMPDIR']['device'], value['directories']['TMPDIR']['inode']), 'request-directory-overlap')
    return environment, value['directories']


def observe(mapping, expected):
    total = bounded_environment(mapping)
    bounded_environment(expected)
    require(expected == requested_environment(), 'observation-request-contract')
    # Extra names occur only in the bounded digest input, never in output.
    extras = sorted(name for name in mapping if name not in KEYS)
    names_body = json.dumps(extras, ensure_ascii=True, separators=(',', ':')).encode()
    candidate = mapping.get(CF_KEY)
    return dict(entry_count=len(mapping), utf8_name_value_bytes=total,
                exact_equal=mapping == expected,
                requested_values_equal=all(mapping.get(key) == expected[key] for key in KEYS),
                missing_keys=[key for key in KEYS if key not in mapping],
                changed_keys=[key for key in KEYS if key in mapping and mapping[key] != expected[key]],
                extra_key_count=len(extras), extra_sorted_names_sha256=record(names_body)['sha256'],
                known_cf_candidate_present=CF_KEY in mapping,
                known_cf_candidate_value=None if candidate is None else record(candidate.encode('utf-8', 'strict')),
                requested_hashes=[dict(name=key, expected=record(expected[key].encode('utf-8', 'strict')),
                    observed=record(mapping[key].encode('utf-8', 'strict')) if key in mapping else None,
                    equal=key in mapping and mapping[key] == expected[key]) for key in KEYS],
                expected_sorted_keys_sha256=digest(sorted(expected)), observed_sorted_keys_sha256=digest(sorted(mapping)))


def pure_controls(expected, original_dirs):
    # All cases are bounded private copies. No case changes a real observation.
    missing = dict(expected); del missing['LANG']
    changed = dict(expected); changed['LANG'] = 'synthetic-changed'
    extra = dict(expected); extra[CF_KEY] = 'synthetic-only'
    changed_dirs = {key: dict(row) for key, row in original_dirs.items()}
    changed_dirs['HOME']['inode'] = (changed_dirs['HOME']['inode'] + 1) % (2 ** 64)
    results = dict(unchanged=observe(dict(expected), expected)['exact_equal'],
                   missing_key=observe(missing, expected)['exact_equal'],
                   changed_value=observe(changed, expected)['exact_equal'],
                   synthetic_extra_key=observe(extra, expected)['exact_equal'],
                   unchanged_directory=original_dirs == original_dirs,
                   synthetic_changed_directory=changed_dirs == original_dirs)
    require(results == dict(unchanged=True, missing_key=False, changed_value=False, synthetic_extra_key=False,
                            unchanged_directory=True, synthetic_changed_directory=False), 'pure-control-mismatch')
    return dict(scope='synthetic-pure-memory-predicate-controls-only', results=results,
                synthetic_extra_key_identifier=CF_KEY, observations_modified=False, child_launches=0)


def bracket(inputs):
    total, rows = 0, {}
    for path, expected in inputs.items():
        require(total <= INPUT_TOTAL, 'input-total-bound')
        data = read_bytes(path, min(INPUT_BYTES, INPUT_TOTAL - total))
        total += len(data)
        require(total <= INPUT_TOTAL, 'input-total-bound')
        rows[path] = record(data)
        require(rows[path] == expected, 'source-pin-mismatch')
    return rows


def digest(value):
    """원문을 공개하지 않고 제한된 구조의 동일성을 비교한다."""
    return record(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True,
                             allow_nan=False).encode())['sha256']


def configure_root(path):
    """호출자가 승인한 새 루트만 고정된 상대 출력 이름에 연결한다."""
    global ROOT, OUT, LOCK
    require(type(path) is str and os.path.isabs(path) and os.path.realpath(path) == path, 'root-alias')
    ROOT, OUT, LOCK = path, path + '/writers/pair', path + '/parent/lane.lock'


def eligibility():
    return {key: False for key in ELIGIBILITY}


def safe_error(error, stage):
    """예외 메시지와 파일 경로를 진단으로 내보내지 않는다."""
    names = {'ValueError', 'OSError', 'ChildProcessError', 'ProcessLookupError', 'PermissionError',
             'FileNotFoundError', 'FileExistsError', 'TimeoutError', 'Cancelled', 'RuntimeError'}
    code = OSError.errno.__get__(error, OSError) if isinstance(error, OSError) else None
    return dict(type=type(error).__name__ if type(error).__name__ in names else 'OtherError',
                errno=code if type(code) is int and 0 <= code <= 2147483647 else None, stage=stage)


def lane_identity():
    """FD9는 같은 열린 파일 설명의 사본이며 명시적으로 해제하지 않는다."""
    before, opened, after = os.lstat(LOCK), os.fstat(9), os.lstat(LOCK)
    require(all(stat.S_ISREG(x.st_mode) and x.st_uid == os.getuid() and x.st_size == 0
                and stat.S_IMODE(x.st_mode) == 0o600 for x in (before, opened, after)) and
            file_identity(before) == file_identity(opened) == file_identity(after), 'lane-identity')
    return dict(device=opened.st_dev, inode=opened.st_ino, mode=opened.st_mode, owner_uid=opened.st_uid)


def admission_text_hash(value):
    return hashlib.sha256(value.encode('utf-8', errors='surrogatepass')).hexdigest() if type(value) is str else None


def stat_identity(info):
    return [info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns]

def interpreter_alias(selected):
    """두 고정 별칭의 실제 링크 확장을 제한하며 원문 경로 조각은 해시로만 남긴다."""
    row=dict(status='unavailable',selected_path_sha256=admission_text_hash(selected))
    try:
        require(type(selected) is str,'interpreter-alias-path')
        path=Path(selected)
        require(path.is_absolute() and len(selected.split('/'))<=ALIAS_COMPONENT_LIMIT,'interpreter-alias-path')
        pending=selected.split('/')[1:];current=Path(path.anchor);components=[];links=0
        def append(component,kind,info,**extra):
            require(len(components)<ALIAS_COMPONENT_LIMIT,'interpreter-alias-component-limit')
            identity=stat_identity(info)
            if kind=='directory':identity=identity[:3]
            components.append(dict(component_sha256=admission_text_hash(component),entry_type=kind,
                                   identity=identity,**extra))
        def root():
            info=current.lstat();require(stat.S_ISDIR(info.st_mode),'interpreter-alias-root')
            append('', 'directory',info)
        root()
        while pending:
            component=pending.pop(0)
            # 빈 조각과 점도 디렉터리 탐색이며, '..' 전에 현재 파일을 지워서는 안 된다.
            current_info=current.lstat()
            require(stat.S_ISDIR(current_info.st_mode),'interpreter-alias-traversal')
            if component in ('','.'):
                append(component,'directory',current_info);continue
            if component=='..':
                current=current.parent;info=current.lstat()
                require(stat.S_ISDIR(info.st_mode),'interpreter-alias-parent')
                append(component,'directory',info);continue
            candidate=current/component;info=candidate.lstat()
            if stat.S_ISLNK(info.st_mode):
                links+=1;require(links<=ALIAS_LINK_LIMIT,'interpreter-alias-link-limit')
                target=os.readlink(candidate);encoded=os.fsencode(target)
                require(0<len(encoded)<=ALIAS_TARGET_LIMIT,'interpreter-alias-target-limit')
                require(stat_identity(candidate.lstat())==stat_identity(info),'interpreter-alias-link-changed')
                append(component,'symlink',info,link_target_bytes=len(encoded),
                       link_target_sha256=hashlib.sha256(encoded).hexdigest())
                target_path=Path(target)
                # Path.parts는 끝 '/.'와 '/'를 지우므로 원문 조각을 제한 안에서 그대로 센다.
                pending=(target.split('/')[1:] if target_path.is_absolute() else target.split('/'))+pending
                require(len(pending)<=ALIAS_COMPONENT_LIMIT,'interpreter-alias-component-limit')
                if target_path.is_absolute():current=Path(target_path.anchor);root()
            else:
                kind='directory' if stat.S_ISDIR(info.st_mode) else 'file'
                require(kind=='directory' if pending else stat.S_ISREG(info.st_mode),'interpreter-alias-entry')
                append(component,kind,info);current=candidate
        require(components[-1]['entry_type']=='file','interpreter-alias-not-file')
        row.update(status='available',resolved_path_sha256=admission_text_hash(str(current)),components=components)
    except (OSError,ValueError,RuntimeError) as error:
        row['failure_sha256']=admission_text_hash(str(error))
    return row



def publisher_runtime_admission():
    """Independent exact interpreter bootstrap; does not claim target image/kernel admission."""
    require(sys.platform == 'darwin' and list(sys.version_info[:3]) == [3, 14, 7], 'native-python-version')
    require(sys.executable == PYTHON and sys.flags.isolated == sys.flags.no_site ==
            sys.flags.dont_write_bytecode == 1, 'native-runtime-spelling-flags')
    aliases_before = {role: interpreter_alias(path) for role, path in
                      (('configured', CONFIGURED_PYTHON), ('runtime', PYTHON))}
    require(all(row['status'] == 'available' and row['resolved_path_sha256'] == admission_text_hash(PHYSICAL_PYTHON)
                for row in aliases_before.values()), 'native-alias-pin')
    before = os.lstat(PHYSICAL_PYTHON)
    body = read_bytes(PHYSICAL_PYTHON, PYTHON_BYTES)
    require(record(body) == dict(bytes=PYTHON_BYTES, sha256=PYTHON_SHA), 'native-physical-pin')
    identity = stat_identity(before)
    require(identity == stat_identity(os.lstat(PHYSICAL_PYTHON)), 'native-physical-drift')
    aliases_after = {role: interpreter_alias(path) for role, path in
                     (('configured', CONFIGURED_PYTHON), ('runtime', PYTHON))}
    require(aliases_before == aliases_after and all(row['components'][-1]['identity'] == identity
                for row in aliases_before.values()), 'native-alias-physical-drift')
    return dict(platform='darwin', python_version=[3, 14, 7],
        configured_path_sha256=admission_text_hash(CONFIGURED_PYTHON),
        runtime_path_sha256=admission_text_hash(PYTHON), physical_path_sha256=admission_text_hash(PHYSICAL_PYTHON),
        executable=dict(bytes=PYTHON_BYTES, sha256=PYTHON_SHA), physical_identity=identity,
        configured_alias_sha256=digest(aliases_before['configured']), runtime_alias_sha256=digest(aliases_before['runtime']),
        runtime_closure_proved=False)


def target_admission(runtime):
    """Compose the already observed exact runtime with every old image/kernel/plist pin."""
    uname = os.uname()
    require(uname.machine == 'arm64' and uname.release == '25.6.0', 'native-kernel-pin')
    require(os.environ.get('ImageOS') == IMAGE_OS and os.environ.get('ImageVersion') == IMAGE_VERSION,
            'native-image-pin')
    plist_body = read_bytes(PLIST, 65536)
    plist = plistlib.loads(plist_body)
    require(type(plist) is dict and plist.get('ProductVersion') == '26.6.2' and
            plist.get('ProductBuildVersion') == '25G83', 'native-product-pin')
    return dict(runtime, machine='arm64', os_release='25.6.0', image_os=IMAGE_OS, image_version=IMAGE_VERSION,
        product_version='26.6.2', product_build='25G83', plist=record(plist_body))


def native_admission():
    # One physical read per native bracket; target checks do not repeat the runtime bootstrap.
    return target_admission(publisher_runtime_admission())


def subprocess_provenance(module):
    """설치된 소스의 관찰은 업스트림 동일성 또는 실행 폐쇄 증명이 아니다."""
    origin = getattr(module, '__file__', None)
    require(type(origin) is str and os.path.isabs(origin) and origin.endswith('/subprocess.py'),
            'subprocess-source-origin')
    body = read_bytes(origin, 1048576)
    return dict(origin_sha256=admission_text_hash(origin), source=record(body),
                installed_upstream_equivalence_established=False, runtime_closure_proved=False,
                upstream_source_sha256='6628ffdd65c093a6c08cae01ffe82877d3ced515aac9e7be0cff16512c30a7d9',
                upstream_commit='823f0323ee6ec1402088b73bce1a38473cac36dc')
