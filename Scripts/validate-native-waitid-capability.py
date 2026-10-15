#!/usr/bin/env python3
"""정확한 소스·인터프리터에 묶인 합성 waitid 기능 확인 한 번만 감독한다."""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[1]
HELPER=ROOT/'Scripts/benchmark-inputs/waitid_capability.py'
SOURCE_PATHS=('Scripts/validate-native-waitid-capability.py','Scripts/benchmark-inputs/waitid_capability.py',
              'Scripts/validate-native-measurement.py','Scripts/normalize-indexstore-evidence.py',
              '.github/workflows/waitid-capability.yml')
SOURCE_MODES={name:('100755' if name=='Scripts/normalize-indexstore-evidence.py' else '100644') for name in SOURCE_PATHS}
PYTHON=dict(selected_path='/opt/homebrew/opt/python@3.14/bin/python3.14',
            runtime_path='/opt/homebrew/Cellar/python@3.14/3.14.7/bin/python3.14',
            resolved_path='/opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/bin/python3.14',
            bytes=34640,sha256='87d4df53fd91304be5bac391fb204643c36b7df2023c04a0953bcbc7d4fdf634')
IMAGE=dict(ImageOS='macos26',ImageVersion='20260907.0351.1')
ALIAS_COMPONENT_LIMIT=128
ALIAS_LINK_LIMIT=32
ALIAS_TARGET_LIMIT=16384
INTERPRETER_SCOPE=('Observed executable only; alias endpoints cannot exclude intervening ABA mutation; '
                   'Python framework/stdlib and dynamic-loader closure unproved')
ADMISSION_REASONS=('native-python-version-mismatch','native-os-mismatch','native-image-mismatch',
                   'selected-python-mismatch','physical-python-mismatch')
ADMISSION_TEXT=dict(platform=r'darwin|linux|win32',machine=r'arm64|aarch64|x86_64|amd64',
                    os_release=r'[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}',image_os=r'macos[0-9]{1,3}',
                    image_version=r'[0-9]{8}\.[0-9]{4}\.[0-9]{1,2}')

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module);return module

CAP=load('owned_waitid_capability',HELPER)
OBS=load('waitid_interpreter_observation',ROOT/'Scripts/validate-native-measurement.py')
NORMALIZER=load('waitid_unchanged_normalizer',ROOT/'Scripts/normalize-indexstore-evidence.py')


CHECKPOINTS = ('interpreter-admission-before', 'source-before', 'capability-command', 'source-after',
               'interpreter-admission-after', 'complete', 'unavailable')
PHASES = (*CHECKPOINTS, 'outer-setup', 'final-inventory', 'result-finalization', 'original-admission',
          'terminal-bindings', 'normalization', 'member-check', 'original-recheck', 'terminal-recheck')
COMMAND_ROLES = {'source-before': 'source-before', 'capability-command': 'capability', 'source-after': 'source-after'}
_DIAGNOSTIC = None


def command_projection(row, *, returned=False, finalized=False):
    """명령 원본과 별도로 이미 관찰한 스칼라만 남기며 행 반환을 추측하지 않는다."""
    row = row if type(row) is dict else {}
    code = CAP.safe_int(row.get('observed_returncode'), -255, 255)
    uncertain = row.get('ownership_uncertain')
    unfinished = row.get('cleanup_root_unfinished')
    admitted = code is not None and uncertain is False and unfinished is False
    streams = {}
    if admitted and row.get('streams_status') == 'retained-after-root-reap':
        for name in ('stdout', 'stderr'):
            stream = row.get(name)
            if type(stream) is dict:
                size, sha = CAP.safe_int(stream.get('bytes'), 0, 8 * 1024**2), CAP.safe_hash(stream.get('sha256'))
                if size is not None and sha is not None: streams[name] = dict(bytes=size, sha256=sha)
    failure = row.get('failure')
    return dict(row_returned=returned is True, receipt_finalized=finalized is True,
        observed_returncode=code, wall_seconds=CAP.safe_wall(row.get('wall_seconds')),
        status=row.get('status') if (code is not None and CAP.safe_wall(row.get('wall_seconds')) is not None
            and row.get('status') in ('incomplete', 'completed-zero')) else 'unavailable',
        timed_out=(failure.get('type') == 'TimeoutExpired') if type(failure) is dict else False,
        cleanup_root_unfinished=unfinished if type(unfinished) is bool else None,
        root_reaped=(code is not None) if code is not None or unfinished is True else None,
        ownership_certain=not uncertain if type(uncertain) is bool else None,
        cleanup_succeeded=(row.get('cleanup_errors') == []) if type(row.get('cleanup_errors')) is list else None,
        failure=CAP.safe_error(failure) if type(failure) is dict else None, streams=streams)


class OuterDiagnostic(CAP.FailureLog):
    """원본 읽기 권한을 늘리지 않는 호출당 메모리 전용 진단이다."""
    def __init__(self):
        super().__init__()
        self.mode = 'execute'; self.checkpoint = 'unavailable'; self.phase = 'outer-setup'
        self.source_sha = None; self.helper_sha256 = None; self.status = 'incomplete'
        self.stable_originals = None; self.commands = {}; self.inner = None
        self.failure_checkpoint = 'unavailable'; self.failure_phase = 'unavailable'

    def record(self, value):
        if self.primary is None:
            self.failure_checkpoint = self.checkpoint if self.checkpoint in CHECKPOINTS else 'unavailable'
            self.failure_phase = self.phase if self.phase in PHASES else 'unavailable'
        super().record(value)

    def stage(self, *, checkpoint=None, phase=None):
        if checkpoint is not None:
            self.checkpoint = checkpoint if checkpoint in CHECKPOINTS else 'unavailable'
            self.phase = self.checkpoint
        if phase is not None: self.phase = phase if phase in PHASES else 'unavailable'

    def command(self, role, row, *, returned=False, finalized=False):
        if role in COMMAND_ROLES.values():
            self.commands[role] = command_projection(row, returned=returned, finalized=finalized)

    def value(self, intended):
        command = self.commands.get('capability', {})
        return dict(schema_version=1, role='waitid-capability-outer-diagnostic', diagnostic_only=True,
            mode=self.mode if self.mode in ('execute', 'publish') else 'execute',
            source_sha=self.source_sha if type(self.source_sha) is str and re.fullmatch(r'[0-9a-f]{40}', self.source_sha) else None,
            checkpoint=self.checkpoint if self.checkpoint in CHECKPOINTS else 'unavailable',
            phase=self.phase if self.phase in PHASES else 'unavailable',
            status=self.status if self.status in ('incomplete', 'capability-only-complete', 'scanned') else 'incomplete',
            failure_checkpoint=self.failure_checkpoint, failure_phase=self.failure_phase,
            intended_returncode=CAP.safe_int(intended, 0, 255), failure=self.primary, secondary=self.secondary,
            secondary_overflow=self.overflow,
            stable_originals=self.stable_originals if type(self.stable_originals) is bool else None,
            root_reaped=command.get('root_reaped'), ownership_certain=command.get('ownership_certain'),
            commands=self.commands, inner=self.inner, timing_eligible=False, descendant_closure_eligible=False,
            final_protocol_ready=False)


def diagnostic_stage(**values):
    if _DIAGNOSTIC is not None: _DIAGNOSTIC.stage(**values)


def diagnostic_failure(error=None, *, retained=None):
    if _DIAGNOSTIC is not None:
        _DIAGNOSTIC.record(retained if retained is not None else CAP.retained_error(error))


def require(value,reason):
    if not value:raise ValueError(reason)


def save(path,value):
    path.parent.mkdir(parents=True,exist_ok=True)
    with path.open('x') as stream:json.dump(value,stream,sort_keys=True,indent=2,allow_nan=False);stream.write('\n')


def digest(value):
    return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False).encode()).hexdigest()


def source_bytes(path):
    info=path.lstat()
    require(stat.S_ISREG(info.st_mode) and 0<=info.st_size<=8*1024**2,'source-not-bounded-regular-file')
    before=(info.st_dev,info.st_ino,info.st_mode,info.st_size,info.st_mtime_ns,info.st_ctime_ns)
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        data=b''
        while part:=os.read(fd,65536):
            data+=part;require(len(data)<=info.st_size,'source-size-changed')
        final=os.fstat(fd);current=path.lstat()
        require(before==(final.st_dev,final.st_ino,final.st_mode,final.st_size,final.st_mtime_ns,final.st_ctime_ns)
                ==(current.st_dev,current.st_ino,current.st_mode,current.st_size,current.st_mtime_ns,current.st_ctime_ns)
                and len(data)==info.st_size,'source-changed-during-read')
        return data
    finally:os.close(fd)


class Cancelled(BaseException):pass
class UnfinishedChild(ValueError):pass
class InterpreterAdmissionFailure(ValueError):
    def __init__(self,receipt,primary):
        super().__init__(receipt['reason']);self.receipt=receipt;self.primary=primary


def require_stable_child(row):
    if (row.get('cleanup_root_unfinished') is not False or row.get('ownership_uncertain') is not False
            or type(row.get('observed_returncode')) is not int or row.get('cleanup_errors')!=[]):
        raise UnfinishedChild('owned-child-not-proved-finished')


def command(argv,cwd,stem,environment,bound):
    """한 절대 기한과 미수거 앵커만 사용하며 수거/불확실성 뒤에는 번호 신호를 금지한다."""
    stem.parent.mkdir(parents=True,exist_ok=True)
    row=dict(argv=argv,cwd=str(cwd),environment_sha256=digest(environment),timeout_seconds=bound,
             observed_returncode=None,status='incomplete',cleanup_errors=[],cleanup_root_unfinished=False)
    process=None;code=None;critical=False;pending=None;primary=None;anchor=False;uncertain=False
    diagnostic = _DIAGNOSTIC; role = COMMAND_ROLES.get(stem.name)
    def observe(*, returned=False, finalized=False, partial=False):
        if diagnostic is not None and role is not None:
            snapshot = dict(row)
            if partial:
                snapshot.update(observed_returncode=code, failure=primary, wall_seconds=time.monotonic()-started,
                    ownership_uncertain=uncertain, cleanup_root_unfinished=process is not None and code is None)
            diagnostic.command(role, snapshot, returned=returned, finalized=finalized)
    def cancel(signum,_frame):
        nonlocal pending
        if critical:pending=signum
        else:raise Cancelled(f'signal-{signum}')
    def check_cancel():
        if pending is not None:raise Cancelled(f'signal-{pending}')
    def wait_until(expires,check_pending=True):
        nonlocal code,anchor,critical,uncertain
        while True:
            remaining=expires-time.monotonic()
            if remaining<=0:raise subprocess.TimeoutExpired(argv,bound)
            critical=True
            try:
                observed=process.wait(timeout=min(0.1,remaining))
                # Cancellation is deferred across BOTH the OS reap and local anchor assignment.
                code=observed;anchor=False
            except subprocess.TimeoutExpired:
                pass
            except BaseException:
                anchor=False;uncertain=True
                raise
            finally:critical=False
            if check_pending:check_cancel()
            if code is not None:return
    previous={sig:signal.signal(sig,cancel) for sig in (signal.SIGTERM,signal.SIGINT)}
    started=time.monotonic()
    try:
        with stem.with_suffix('.stdout').open('xb') as out,stem.with_suffix('.stderr').open('xb') as err:
            started=time.monotonic();expires=started+bound
            try:
                critical=True
                try:
                    process=subprocess.Popen(argv,cwd=cwd,env=environment,stdout=out,stderr=err,start_new_session=True)
                    anchor=True
                finally:critical=False
                row['pid']=process.pid
                check_cancel();wait_until(expires)
            except BaseException as error:
                primary=CAP.retained_error(error)
                diagnostic_failure(retained=primary)
            finally:
                try:
                    for sig in previous:signal.signal(sig,signal.SIG_IGN)
                    if process is not None and code is None:
                        for signum,grace,label in ((signal.SIGTERM,7.0,'term'),(signal.SIGKILL,3.0,'kill')):
                            if not anchor:break
                            try:os.killpg(process.pid,signum)
                            except ProcessLookupError:pass
                            except BaseException as error:
                                row['cleanup_errors'].append(dict(step=label,type=type(error).__name__))
                                diagnostic_failure(error)
                            try:wait_until(time.monotonic()+grace,False)
                            except subprocess.TimeoutExpired:pass
                            except BaseException as error:
                                row['cleanup_errors'].append(dict(step=label+'-wait',type=type(error).__name__))
                                diagnostic_failure(error)
                            if code is not None:break
                        if uncertain and code is None:
                            # A later wait can establish an exit; uncertain ownership never permits a signal.
                            try:wait_until(time.monotonic()+3.0,False)
                            except BaseException as error:
                                row['cleanup_errors'].append(dict(step='uncertain-wait',type=type(error).__name__))
                                diagnostic_failure(error)
                finally:
                    observe(partial=True)
        wall=time.monotonic()-started
        row.update(observed_returncode=code,failure=primary,wall_seconds=wall,ownership_uncertain=uncertain,
                   cleanup_root_unfinished=process is not None and code is None)
        if primary is None and type(code) is int and code==0 and wall<=bound and not row['cleanup_errors'] and not uncertain:
            row['status']='completed-zero'
        if row['cleanup_root_unfinished'] or uncertain:
            row['streams_status']='not-read-owned-child-unfinished-or-uncertain'
            row['unread_stream_paths']={suffix[1:]:str(stem.with_suffix(suffix)) for suffix in ('.stdout','.stderr')}
        else:
            row['streams_status']='retained-after-root-reap'
            for suffix in ('.stdout','.stderr'):
                data=source_bytes(stem.with_suffix(suffix))
                row[suffix[1:]]=dict(path=str(stem.with_suffix(suffix)),bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
                if diagnostic is not None and role == 'capability' and suffix == '.stdout' and code != 0:
                    diagnostic.inner = CAP.parse_inner_diagnostic(data, row['stdout'], diagnostic.helper_sha256)
                observe()
        observe()
        save(stem.with_suffix('.json'),row)
        observe(finalized=True)
        # 마지막 신호 복원 뒤에만 실제 반환된 행으로 표시한다.
    finally:
        for sig,handler in previous.items():signal.signal(sig,handler)
    observe(returned=True, finalized=True)
    return row


def bind_sources(source_sha,raw,environment,phase):
    row=command(['/usr/bin/git','ls-tree',source_sha,'--',*SOURCE_PATHS],ROOT,raw/'setup'/f'source-{phase}',environment,5)
    require_stable_child(row)
    require(row['status']=='completed-zero','source-query-incomplete')
    text=Path(row['stdout']['path']).read_text();expected={}
    for line in text.splitlines():
        match=re.fullmatch(r'(100644|100755) blob ([0-9a-f]{40})\t(.+)',line)
        require(match is not None and match[3] in SOURCE_PATHS and match[3] not in expected and match[1]==SOURCE_MODES[match[3]],'source-tree-schema')
        expected[match[3]]=match[2]
    require(set(expected)==set(SOURCE_PATHS),'source-tree-membership')
    observed={}
    for name in SOURCE_PATHS:
        data=source_bytes(ROOT/name)
        require(0<len(data)<=1024**2,'source-size')
        require(hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()==expected[name],'source-commit-mismatch')
        observed[name]=dict(bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),git_blob=expected[name],mode=SOURCE_MODES[name])
    return dict(files=observed,command=row)


def admission_text_hash(value):
    return hashlib.sha256(value.encode('utf-8',errors='surrogatepass')).hexdigest() if type(value) is str else None


def regular_identity(value,size):
    return (type(value) is list and len(value)==6 and
            all(type(part) is int and 0<=part<2**128 for part in value) and
            value[2]<=0o177777 and stat.S_ISREG(value[2]) and value[3]==size)


def stat_identity(info):
    return [info.st_dev,info.st_ino,info.st_mode,info.st_size,info.st_mtime_ns,info.st_ctime_ns]


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


def admission_expected():
    expected=dict(platform='darwin',python_version=[3,14,7],machine='arm64',os_release='25.6.0',
                  image_os=IMAGE['ImageOS'],image_version=IMAGE['ImageVersion'],
                  selected_path_sha256=admission_text_hash(PYTHON['runtime_path']))
    for prefix,path in (('',PYTHON['runtime_path']),('configured_',PYTHON['selected_path'])):
        expected.update({prefix+'physical_status':'available',prefix+'physical_selected_path_sha256':admission_text_hash(path),
                         prefix+'resolved_path_sha256':admission_text_hash(PYTHON['resolved_path']),
                         prefix+'bytes':PYTHON['bytes'],prefix+'sha256':PYTHON['sha256']})
    return expected


def admission_observed_keys():
    return set(admission_expected())|{
        prefix+key for prefix in ('','configured_') for key in ('file_identity_sha256','physical_failure_sha256')
    }|{role+'_alias_'+key for role in ('configured','runtime') for key in ('before_sha256','after_sha256','failure_sha256')}


def admission_checks(observed):
    expected=admission_expected()
    groups=(('platform','python_version'),('machine','os_release'),('image_os','image_version'),
            ('selected_path_sha256',),tuple(key for key in expected if key not in
                ('platform','python_version','machine','os_release','image_os','image_version','selected_path_sha256')))
    checks={reason:all(observed.get(key)==expected[key] for key in keys)
            for reason,keys in zip(ADMISSION_REASONS,groups)}
    checks['physical-python-mismatch'] &= (observed.get('file_identity_sha256') is not None and
        observed.get('file_identity_sha256')==observed.get('configured_file_identity_sha256') and
        all(observed.get(role+'_alias_before_sha256') is not None and
            observed.get(role+'_alias_before_sha256')==observed.get(role+'_alias_after_sha256') and
            observed.get(role+'_alias_failure_sha256') is None for role in ('configured','runtime')))
    return checks


def safe_physical(safe,prefix,observed):
    if type(observed) is not dict:
        safe[prefix+'physical_status']='invalid';return
    status=observed.get('status')
    safe[prefix+'physical_status']=status if status in ('available','unavailable','incomplete') else 'invalid'
    safe[prefix+'physical_selected_path_sha256']=admission_text_hash(observed.get('selected_path'))
    safe[prefix+'resolved_path_sha256']=admission_text_hash(observed.get('resolved_path'))
    size=observed.get('bytes');sha=observed.get('sha256');identity=observed.get('file_identity')
    safe[prefix+'bytes']=size if type(size) is int and 0<size<=256*1024**2 else None
    safe[prefix+'sha256']=sha if type(sha) is str and re.fullmatch(r'[0-9a-f]{64}',sha) else None
    safe[prefix+'file_identity_sha256']=digest(identity) if regular_identity(identity,safe[prefix+'bytes']) else None
    safe[prefix+'physical_failure_sha256']=admission_text_hash(observed.get('failure'))


def physical_receipt_valid(observed,path):
    return (type(observed) is dict and set(observed)=={
        'status','selected_path','resolved_path','bytes','sha256','file_identity','wall_seconds'} and
        observed['status']=='available' and observed['selected_path']==path and
        observed['resolved_path']==PYTHON['resolved_path'] and type(observed['bytes']) is int and
        observed['bytes']==PYTHON['bytes'] and observed['sha256']==PYTHON['sha256'] and
        regular_identity(observed['file_identity'],observed['bytes']) and measured_cost(observed['wall_seconds']))


def measured_cost(value):
    return type(value) in (int,float) and math.isfinite(value) and value>=0


def alias_receipt_valid(alias,path,identity):
    if (type(alias) is not dict or set(alias)!={'status','selected_path_sha256','resolved_path_sha256','components'} or
            alias['status']!='available' or alias['selected_path_sha256']!=admission_text_hash(path) or
            alias['resolved_path_sha256']!=admission_text_hash(PYTHON['resolved_path'])):return False
    components=alias['components']
    if type(components) is not list or not 1<=len(components)<=ALIAS_COMPONENT_LIMIT:return False
    links=0
    for row in components:
        if type(row) is not dict:return False
        kind=row.get('entry_type');link=kind=='symlink'
        if kind not in ('directory','file','symlink'):return False
        if set(row)!={'component_sha256','entry_type','identity'}|({'link_target_bytes','link_target_sha256'} if link else set()):return False
        part=row['identity']
        if (type(part) is not list or len(part)!=(3 if kind=='directory' else 6) or
                not all(type(item) is int and 0<=item<2**128 for item in part) or part[2]>0o177777 or
                not {'directory':stat.S_ISDIR,'file':stat.S_ISREG,'symlink':stat.S_ISLNK}[kind](part[2])):return False
        for key in ('component_sha256','link_target_sha256') if link else ('component_sha256',):
            if type(row[key]) is not str or re.fullmatch(r'[0-9a-f]{64}',row[key]) is None:return False
        if link:
            links+=1
            if type(row['link_target_bytes']) is not int or not 1<=row['link_target_bytes']<=ALIAS_TARGET_LIMIT:return False
    return (links<=ALIAS_LINK_LIMIT and components[0]['entry_type']=='directory' and
            components[-1]['entry_type']=='file' and digest(components[-1]['identity'])==digest(identity))


def interpreter_receipt_valid(value):
    if (type(value) is not dict or set(value)!={'status','configured','runtime','aliases_before','aliases_after','wall_seconds'} or
            value['status']!='available' or not measured_cost(value['wall_seconds'])):return False
    for role,path in (('configured',PYTHON['selected_path']),('runtime',PYTHON['runtime_path'])):
        if not physical_receipt_valid(value[role],path):return False
    if digest(value['configured']['file_identity'])!=digest(value['runtime']['file_identity']):return False
    for key in ('aliases_before','aliases_after'):
        aliases=value[key]
        if type(aliases) is not dict or set(aliases)!={'configured','runtime'}:return False
        for role,path in (('configured',PYTHON['selected_path']),('runtime',PYTHON['runtime_path'])):
            if not alias_receipt_valid(aliases[role],path,value[role]['file_identity']):return False
    return digest(value['aliases_before'])==digest(value['aliases_after'])


def bind_interpreter():
    # 실패 직전까지 관찰한 형식 제한 값만 보존하고 경로와 예외 원문은 해시로만 남긴다.
    started=time.perf_counter();safe={key:None for key in admission_observed_keys()}
    receipt=dict(status='incomplete',expected=admission_expected(),observed=safe,checks={})
    stage=ADMISSION_REASONS[0]
    def text_field(key,value):
        safe[key]=value if type(value) is str and re.fullmatch(ADMISSION_TEXT[key],value) else None
    def check(reason,exact=True):
        matched=admission_checks(safe)[reason] and exact;receipt['checks'][reason]=matched
        if not matched:
            receipt['reason']=reason
            raise InterpreterAdmissionFailure(receipt,dict(type='ValueError',reason=reason))
    try:
        text_field('platform',sys.platform)
        version=sys.version_info[:3]
        safe['python_version']=list(version) if (len(version)==3 and
            all(type(part) is int and 0<=part<=999 for part in version)) else None
        check(stage)
        stage=ADMISSION_REASONS[1];uname=os.uname()
        text_field('machine',uname.machine);text_field('os_release',uname.release);check(stage)
        stage=ADMISSION_REASONS[2]
        text_field('image_os',os.environ.get('ImageOS'));text_field('image_version',os.environ.get('ImageVersion'));check(stage)
        stage=ADMISSION_REASONS[3];selected=sys.executable
        safe['selected_path_sha256']=admission_text_hash(selected)
        check(stage,type(selected) is str and selected==PYTHON['runtime_path'])
        stage=ADMISSION_REASONS[4]
        paths=dict(configured=PYTHON['selected_path'],runtime=PYTHON['runtime_path']);aliases_before={};aliases_after={}
        observed={}
        for role,path in paths.items():
            alias=interpreter_alias(path);aliases_before[role]=alias
            if alias['status']=='available':safe[role+'_alias_before_sha256']=digest(alias)
            else:safe[role+'_alias_failure_sha256']=alias['failure_sha256']
        for role,path in paths.items():
            prefix='configured_' if role=='configured' else ''
            observed[role]=(OBS.interpreter_observation(path) if aliases_before[role]['status']=='available' else
                            dict(status='unavailable',selected_path=path))
            safe_physical(safe,prefix,observed[role])
        for role,path in paths.items():
            alias=interpreter_alias(path);aliases_after[role]=alias
            if alias['status']=='available':safe[role+'_alias_after_sha256']=digest(alias)
            else:safe[role+'_alias_failure_sha256']=alias['failure_sha256']
        binding=dict(status='available',**observed,aliases_before=aliases_before,aliases_after=aliases_after,
                     wall_seconds=time.perf_counter()-started)
        # 잘못된 도우미 스키마나 사슬 끝 정체성도 성공으로 승격하지 않는다.
        if admission_checks(safe)[stage] and not interpreter_receipt_valid(binding):
            safe['physical_status']='invalid'
        check(stage)
        return binding
    except InterpreterAdmissionFailure:raise
    except BaseException as error:
        receipt.update(reason='interpreter-admission-observation-failed',observation_stage=stage,
                       error_type_sha256=admission_text_hash(type(error).__name__),
                       message_sha256=admission_text_hash(str(error)))
        primary=dict(type='InterpreterObservationError',reason=receipt['reason'],
                     error_type_sha256=receipt['error_type_sha256'],message_sha256=receipt['message_sha256'])
        raise InterpreterAdmissionFailure(receipt,primary) from None


def same_interpreter(before,after):
    """측정 비용만 제외하고 두 물리 관찰과 모든 별칭 끝점 정체성을 엄격하게 비교한다."""
    if not interpreter_receipt_valid(before) or not interpreter_receipt_valid(after):return False
    def identities(value):
        result={key:item for key,item in value.items() if key!='wall_seconds'}
        for role in ('configured','runtime'):
            result[role]={key:item for key,item in value[role].items() if key!='wall_seconds'}
        return result
    return digest(identities(before))==digest(identities(after))


def regrade(value,outer,source,version):
    require(type(outer.get('pid')) is int and outer['pid']>0,'invalid-command-pid')
    require(type(value) is dict and value.get('profile')=='native-waitid-capability-v1'
            and value.get('capability_only') is True and value.get('status')=='capability-only-complete', 'capability-incomplete')
    for key in ('descendant_closure_eligible','timing_eligible','final_protocol_ready'):require(value.get(key) is False,'promoted-eligibility')
    require(type(value.get('actual_engine_calls')) is int and value['actual_engine_calls']==0,'unexpected-engine-call')
    require(value.get('source_sha256')==source['files']['Scripts/benchmark-inputs/waitid_capability.py']['sha256'],'capability-source-mismatch')
    require(value.get('schedule')==[dict(name=n,max_launches=c) for n,c in CAP.CASES]
            and digest(value.get('bounds'))==digest(dict(watchdog=5,case=10,suite=120,outer=150)),'capability-schedule-mismatch')
    require(digest(value.get('schedule'))==digest([dict(name=n,max_launches=c) for n,c in CAP.CASES]),'typed-schedule-mismatch')
    rows=value.get('cases');require(type(rows) is list and [r.get('name') for r in rows]==[n for n,_ in CAP.CASES],'capability-case-membership')
    total=0;cost=0
    for row,(name,count) in zip(rows,CAP.CASES):
        require(row.get('status')=='capability-case-passed' and row.get('cleanup',{}).get('errors')==[]
                and row['cleanup'].get('unfinished')==[],'capability-case-incomplete')
        wall=row.get('full_case_wall_seconds');require(type(wall) in (int,float) and math.isfinite(wall) and 0<=wall<=10,'invalid-case-wall');cost+=wall
        cleanup_wall=row['cleanup'].get('cleanup_wall_seconds');require(type(cleanup_wall) in (int,float) and math.isfinite(cleanup_wall) and 0<=cleanup_wall<=wall,'invalid-cleanup-wall')
        actors=row.get('actors');require(type(actors) is list and len(actors)==count,'actor-count-mismatch');total+=count
        if count:
            pids=[actor.get('pid') for actor in actors]
            require(all(type(pid) is int and pid>0 for pid in pids) and len(set(pids))==count,'actor-identity-mismatch')
            expected_state={'timeout-then-term':'incomplete-observation-timeout','term-ignore-then-kill':'incomplete-term-resistant',
                            'root-exit-member-live':'incomplete-live-member','owned-member-escape':'scope-violation'}.get(name,'enumerated-actors-complete')
            require(row.get('observed_tree_status')==expected_state,'observation-status-mismatch')
            if name=='timeout-then-term':require(row.get('expected_observation_timeout') is True,'timeout-not-observed')
            if name=='term-ignore-then-kill':require(row.get('expected_term_resistance') is True,'term-resistance-not-observed')
            for field in ('initial_enumerated_actors','post_exit_enumerated_actors'):
                census=row.get(field);require(type(census) is list and len(census)==count,'census-membership')
                for i,item in enumerate(census):
                    escaped=name=='owned-member-escape' and field=='post_exit_enumerated_actors' and i==1
                    require(digest(item)==digest(dict(pid=pids[i],process_group=pids[i] if escaped else pids[0],session=pids[i] if escaped else outer['pid'])),'census-identity-mismatch')
            for i,actor in enumerate(actors):
                CAP.verify_ledger(actor)
                observed=actor['terminal'];require(observed.get('pid')==pids[i] and observed.get('signo')==signal.SIGCHLD,'terminal-identity-mismatch')
                expected=-signal.SIGTERM if (i==0 and name in ('signal-exit','timeout-then-term')) or (i==1 and name in ('root-exit-member-live','owned-member-escape')) else -signal.SIGKILL if name=='term-ignore-then-kill' else 7 if name=='normal-seven' else 0
                require(actor['wait_returncode']==expected,'unexpected-final-exit')
                argv=actor.get('argv');require(type(argv) is list and len(argv)==9 and argv[:5]==[PYTHON['runtime_path'],'-I','-S','-B',str(HELPER)]
                    and argv[5]=='--actor' and all(type(arg) is str and re.fullmatch(r'[1-9][0-9]*',arg) for arg in argv[6:8])
                    and argv[6]!=argv[7] and argv[8]==('1' if name=='term-ignore-then-kill' else '0'),'actor-argv-mismatch')
                elapsed=actor.get('popen_start_to_exit_observed_seconds');require(type(elapsed) in (int,float) and math.isfinite(elapsed) and 0<=elapsed<=wall,'invalid-terminal-wall')
        elif name=='native-api-admission':
            require(row.get('admission',{}).get('platform')=='darwin' and row['admission'].get('python')==version
                    and row['admission'].get('supported') is True
                    and row['admission'].get('waitid')=='native-os.waitid'
                    and digest(row['admission'].get('constants'))==digest({name:getattr(os,name) for name in
                        ('P_PID','WEXITED','WNOWAIT','WNOHANG','CLD_EXITED','CLD_KILLED','CLD_DUMPED')}),'native-admission-mismatch')
        elif name=='injected-observation-refusals':require(row.get('subcases')==CAP.injected_refusals(),'refusal-subcases-mismatch')
        else:require(row.get('subcases')==list(CAP.LEDGER_NEGATIVES),'ledger-subcases-mismatch')
    elapsed=value.get('full_suite_wall_seconds_before_receipt')
    require(type(elapsed) in (int,float) and math.isfinite(elapsed) and cost<=elapsed<=120
            and type(value.get('actual_launches')) is int and value['actual_launches']==total==13,'suite-count-or-wall')
    return dict(status='capability-ledgers-verified',native_actor_launches=13,actual_engine_calls=0)


def execute(raw,source_sha):
    diagnostic_stage(phase='outer-setup')
    require(re.fullmatch(r'[0-9a-f]{40}',source_sha) and os.environ.get('GITHUB_SHA')==source_sha,'dispatch-source-mismatch')
    raw.mkdir(exist_ok=False);started=time.monotonic()
    home,temporary=raw/'setup/owned-home',raw/'setup/owned-tmp';home.mkdir(parents=True);temporary.mkdir()
    environment=environment_for(raw)
    result=dict(schema_version=1,profile='native-waitid-capability-outer-v1',source_sha=source_sha,status='incomplete',
                capability_only=True,descendant_closure_eligible=False,timing_eligible=False,final_protocol_ready=False,
                checkpoint='interpreter-admission-before',
                actual_engine_calls=0,interpreter_scope=INTERPRETER_SCOPE,
                command_schedule='two source-query metadata children and one capability child; at most13 actor children inside that child')
    material_safe=True
    diagnostic_stage(checkpoint=result['checkpoint'])
    try:
        before=bind_interpreter();result['interpreter_before']=before
        result['checkpoint']='source-before'
        diagnostic_stage(checkpoint=result['checkpoint'])
        material_safe=False
        source=bind_sources(source_sha,raw,environment,'before');result['source_before']=source
        if _DIAGNOSTIC is not None:
            _DIAGNOSTIC.source_sha = source_sha
            _DIAGNOSTIC.helper_sha256 = source['files']['Scripts/benchmark-inputs/waitid_capability.py']['sha256']
        material_safe=True
        result['checkpoint']='capability-command'
        diagnostic_stage(checkpoint=result['checkpoint'])
        argv=[sys.executable,'-I','-S','-B',str(HELPER),'--output',str(raw/'runs/capability')]
        (raw/'runs').mkdir()
        material_safe=False
        outer=command(argv,ROOT,raw/'setup/capability-command',environment,150);result['command']=outer
        require_stable_child(outer)
        if outer['status']!='completed-zero':
            material_safe=False
            raise UnfinishedChild('capability-actor-cleanup-not-proved')
        material_safe=False
        result['checkpoint']='source-after'
        diagnostic_stage(checkpoint=result['checkpoint'])
        result['source_after']=bind_sources(source_sha,raw,environment,'after')
        material_safe=True
        result['checkpoint']='interpreter-admission-after'
        diagnostic_stage(checkpoint=result['checkpoint'])
        result['interpreter_after']=bind_interpreter()
        require(source['files']==result['source_after']['files'] and same_interpreter(before,result['interpreter_after']),'input-identity-changed')
        require(outer['status']=='completed-zero','capability-command-incomplete')
        data=source_bytes(raw/'runs/capability/results.json');value=NORMALIZER.strict_json(data.decode())
        result['capability_result']=dict(bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
        result['verification']=regrade(value,outer,source,sys.version)
        result['status']='capability-only-complete'
        result['checkpoint']='complete'
        diagnostic_stage(checkpoint=result['checkpoint'])
    except BaseException as error:
        if isinstance(error,InterpreterAdmissionFailure):
            result['failure']=error.primary;result['interpreter_admission_failure']=error.receipt
        else:result['failure']=CAP.retained_error(error)
        diagnostic_failure(retained=result['failure'])
        if isinstance(error,UnfinishedChild):material_safe=False
    result['stable_originals']=material_safe
    if _DIAGNOSTIC is not None: _DIAGNOSTIC.stable_originals = material_safe
    if material_safe:
        diagnostic_stage(phase='final-inventory')
        try:result['original_files']=inventory(raw)
        except BaseException as error:
            result['status']='incomplete';result['stable_originals']=False
            result.setdefault('failure',CAP.retained_error(error))
            diagnostic_failure(error)
    if _DIAGNOSTIC is not None:
        _DIAGNOSTIC.status = result['status']; _DIAGNOSTIC.stable_originals = result['stable_originals']
    result['full_caller_wall_seconds_before_receipt']=time.monotonic()-started
    result['cost_scope']='Caller includes admission and actual child/cleanup; nested intervals overlap; final receipt/teardown and publication excluded'
    diagnostic_stage(phase='result-finalization')
    save(raw/'results.json',result)
    return result


def environment_for(raw):
    return dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin',LANG='C',LC_ALL='C',
                HOME=str(raw/'setup/owned-home'),TMPDIR=str(raw/'setup/owned-tmp'))


def inventory(raw):
    """호출 원본 전체를 보존하며 루트 결과/실제 셸 종료 영수증만 별도 결속한다."""
    require(raw.is_absolute() and raw.resolve(strict=True)==raw and stat.S_ISDIR(raw.lstat().st_mode),'evidence-root-alias')
    rows={};total=0
    for base,directories,files in os.walk(raw,followlinks=False):
        for name in directories:require(stat.S_ISDIR((Path(base)/name).lstat().st_mode),'nonregular-evidence-directory')
        for name in files:
            path=Path(base)/name;relative=path.relative_to(raw).as_posix()
            if relative in ('results.json','setup/execute-status.json'):continue
            require(relative.startswith(('setup/','runs/')),'unexpected-evidence-location')
            data=source_bytes(path);total+=len(data);require(total<=64*1024**2,'evidence-total-size')
            rows[relative]=dict(bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
    return rows


def read_json(path):
    return NORMALIZER.strict_json(source_bytes(path).decode())


def verify_command(row,raw,stem,argv,bound):
    target=raw/'setup'/stem
    require(digest(row)==digest(read_json(target.with_suffix('.json'))),'original-command-changed')
    require(row.get('argv')==argv and row.get('cwd')==str(ROOT) and type(row.get('timeout_seconds')) is int
            and row['timeout_seconds']==bound and row.get('environment_sha256')==digest(environment_for(raw)),
            'command-contract-mismatch')
    require(type(row.get('pid')) is int and row['pid']>0,'invalid-command-pid')
    wall=row.get('wall_seconds')
    require(row.get('status')=='completed-zero' and type(row.get('observed_returncode')) is int
            and row['observed_returncode']==0 and row.get('failure') is None and row.get('cleanup_errors')==[]
            and row.get('cleanup_root_unfinished') is False and row.get('ownership_uncertain') is False
            and row.get('streams_status')=='retained-after-root-reap'
            and type(wall) in (int,float) and math.isfinite(wall) and 0<wall<=bound,'command-incomplete')
    for suffix in ('.stdout','.stderr'):
        path=target.with_suffix(suffix);data=source_bytes(path)
        expected=dict(path=str(path),bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
        require(digest(row.get(suffix[1:]))==digest(expected),'command-stream-changed')


def verify_source_record(record,source_sha,raw,phase):
    require(type(record) is dict,'missing-source-record')
    files=record.get('files');require(type(files) is dict and set(files)==set(SOURCE_PATHS),'source-set-mismatch')
    row=record['command'];verify_command(row,raw,'source-'+phase,
        ['/usr/bin/git','ls-tree',source_sha,'--',*SOURCE_PATHS],5)
    observed={}
    for line in source_bytes(raw/'setup'/('source-'+phase+'.stdout')).decode().splitlines():
        match=re.fullmatch(r'(100644|100755) blob ([0-9a-f]{40})\t(.+)',line)
        require(match is not None and match[3] in SOURCE_PATHS and match[3] not in observed and match[1]==SOURCE_MODES[match[3]],'source-tree-schema')
        data=source_bytes(ROOT/match[3]);require(0<len(data)<=1024**2,'source-size')
        require(hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()==match[2],'source-commit-mismatch')
        observed[match[3]]=dict(bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),git_blob=match[2],mode=match[1])
    require(digest(observed)==digest(files),'source-files-changed')


def complete_membership():
    names={'setup/'+stem+suffix for stem in ('source-before','source-after','capability-command')
           for suffix in ('.json','.stdout','.stderr')}
    names.add('runs/capability/results.json')
    names.update('runs/capability/'+name+'-'+str(i)+suffix for name,count in CAP.CASES
                 for i in range(count) for suffix in ('.stdout','.stderr'))
    return names


def verify_admission_failure(value):
    # 누락된 소스 결속을 허용하는 유일한 경로이며 성공 영수증을 복원하거나 추측하지 않는다.
    receipt=value.get('interpreter_admission_failure')
    require(type(receipt) is dict,'missing-interpreter-admission-failure-receipt')
    reason=receipt.get('reason');unexpected=reason=='interpreter-admission-observation-failed'
    keys={'status','expected','observed','checks','reason'}
    if unexpected:keys.update(('observation_stage','error_type_sha256','message_sha256'))
    require(set(receipt)==keys and receipt.get('status')=='incomplete'
            and digest(receipt.get('expected'))==digest(admission_expected()),'admission-failure-schema')
    observed=receipt.get('observed');expected=admission_expected()
    require(type(observed) is dict and set(observed)==admission_observed_keys(),
            'admission-observation-schema')
    for key,pattern in ADMISSION_TEXT.items():
        item=observed[key]
        require(item is None or type(item) is str and re.fullmatch(pattern,item),'admission-observation-text')
    version=observed['python_version']
    require(version is None or type(version) is list and len(version)==3 and
            all(type(part) is int and 0<=part<=999 for part in version),'admission-observation-version')
    for prefix in ('','configured_'):
        size=observed[prefix+'bytes']
        require(size is None or type(size) is int and 0<size<=256*1024**2,'admission-observation-bytes')
        require(observed[prefix+'physical_status'] in (None,'available','unavailable','incomplete','invalid'),
                'admission-observation-status')
    for key in admission_observed_keys():
        if not key.endswith('sha256'):continue
        item=observed[key]
        require(item is None or type(item) is str and re.fullmatch(r'[0-9a-f]{64}',item),'admission-observation-hash')
    stage=receipt.get('observation_stage') if unexpected else reason
    require(stage in ADMISSION_REASONS,'admission-failure-reason')
    position=ADMISSION_REASONS.index(stage);checked=ADMISSION_REASONS[:position+(0 if unexpected else 1)]
    checks=receipt.get('checks');computed=admission_checks(observed)
    require(type(checks) is dict and set(checks)==set(checked) and all(type(v) is bool for v in checks.values())
            and all(checks[key] is computed[key] for key in checked)
            and all(checks[key] is True for key in ADMISSION_REASONS[:position]),'admission-failure-checks')
    if unexpected:
        for key in ('error_type_sha256','message_sha256'):
            require(type(receipt[key]) is str and re.fullmatch(r'[0-9a-f]{64}',receipt[key]),'admission-error-hash')
        failure=dict(type='InterpreterObservationError',reason=reason,
                     error_type_sha256=receipt['error_type_sha256'],message_sha256=receipt['message_sha256'])
    else:
        require(checks[reason] is False,'admission-failure-checks')
        failure=dict(type='ValueError',reason=reason)
    require(digest(value.get('failure'))==digest(failure),'admission-primary-failure-changed')


def verify_originals(raw):
    value=read_json(raw/'results.json')
    require(type(value) is dict and value.get('profile')=='native-waitid-capability-outer-v1'
            and type(value.get('schema_version')) is int and value['schema_version']==1,'outer-schema')
    require(value.get('capability_only') is True and type(value.get('actual_engine_calls')) is int
            and value['actual_engine_calls']==0,'outer-scope')
    for key in ('descendant_closure_eligible','timing_eligible','final_protocol_ready'):
        require(value.get(key) is False,'promoted-eligibility')
    source_sha=value.get('source_sha')
    require(type(source_sha) is str and re.fullmatch(r'[0-9a-f]{40}',source_sha)
            and os.environ.get('GITHUB_SHA')==source_sha,'publication-source-mismatch')
    if _DIAGNOSTIC is not None and value.get('stable_originals') is False:
        _DIAGNOSTIC.stable_originals = False
    require(value.get('stable_originals') is True,'original-writer-not-proved-finished')
    if 'command' in value:
        require_stable_child(value['command'])
        require(value['command'].get('status')=='completed-zero','capability-actor-cleanup-not-proved')
    status=read_json(raw/'setup/execute-status.json')
    require(type(status) is dict and set(status)=={'exit_code'} and type(status['exit_code']) is int,'workflow-exit-schema')
    require(value.get('status') in ('capability-only-complete','incomplete'),'outer-status')
    if value['status']=='incomplete':require(status['exit_code']!=0,'incomplete-with-successful-exit')
    else:require(status['exit_code']==0 and 'failure' not in value,'actual-outer-incomplete')
    if 'source_before' not in value:
        require(value['status']=='incomplete' and value.get('checkpoint')=='interpreter-admission-before',
                'missing-source-before-outside-early-admission')
        require(1<=status['exit_code']<=255,'early-admission-exit-code')
        wall=value.get('full_caller_wall_seconds_before_receipt')
        require(type(wall) in (int,float) and wall>=0 and (type(wall) is int or math.isfinite(wall)),
                'early-admission-caller-wall')
        require(value.get('interpreter_scope')==INTERPRETER_SCOPE
                and value.get('command_schedule')=='two source-query metadata children and one capability child; at most13 actor children inside that child'
                and value.get('cost_scope')=='Caller includes admission and actual child/cleanup; nested intervals overlap; final receipt/teardown and publication excluded',
                'early-admission-scope-text')
        verify_admission_failure(value)
        require(set(value)=={'schema_version','profile','source_sha','status','capability_only',
                'descendant_closure_eligible','timing_eligible','final_protocol_ready','checkpoint','actual_engine_calls',
                'interpreter_scope','command_schedule','failure','interpreter_admission_failure','stable_originals',
                'original_files','full_caller_wall_seconds_before_receipt','cost_scope'},
                'early-admission-unexpected-records')
        require(type(value.get('original_files')) is dict and value['original_files']=={},'early-admission-member-set')
        require(inventory(raw)=={},'early-admission-member-set')
        return value
    require(digest(value.get('original_files'))==digest(inventory(raw)),'original-membership-or-bytes-changed')
    verify_source_record(value['source_before'],source_sha,raw,'before')
    require(type(value.get('interpreter_before')) is dict,'missing-interpreter-before-receipt')
    current=bind_interpreter();require(same_interpreter(current,value['interpreter_before']),'interpreter-changed')
    if value['status']=='capability-only-complete':
        require(set(value['original_files'])==complete_membership(),'completed-member-set')
        verify_source_record(value['source_after'],source_sha,raw,'after')
        require(digest(value['source_before']['files'])==digest(value['source_after']['files'])
                and same_interpreter(current,value['interpreter_after']),'post-identity-mismatch')
        argv=[PYTHON['runtime_path'],'-I','-S','-B',str(HELPER),'--output',str(raw/'runs/capability')]
        verify_command(value['command'],raw,'capability-command',argv,150)
        data=source_bytes(raw/'runs/capability/results.json');inner=NORMALIZER.strict_json(data.decode())
        require(value.get('capability_result')==dict(bytes=len(data),sha256=hashlib.sha256(data).hexdigest()),'capability-original-changed')
        verified=regrade(inner,value['command'],value['source_before'],sys.version)
        require(digest(value.get('verification'))==digest(verified),'verification-changed')
        require(inner['full_suite_wall_seconds_before_receipt']<=value['command']['wall_seconds'],'inner-cost-not-enclosed')
        wall=value.get('full_caller_wall_seconds_before_receipt')
        child_cost=sum(value[key]['command']['wall_seconds'] for key in ('source_before','source_after'))+value['command']['wall_seconds']
        require(type(wall) in (int,float) and math.isfinite(wall) and wall>=child_cost,'caller-cost-not-enclosed')
        for name in complete_membership():
            if name.startswith('runs/') and name.endswith(('.stdout','.stderr')):
                require(value['original_files'][name]==dict(bytes=0,sha256=hashlib.sha256(b'').hexdigest()),'unexpected-actor-output')
    return value


def publish(raw,public):
    diagnostic_stage(phase='original-admission')
    started=time.monotonic();value=verify_originals(raw)
    if _DIAGNOSTIC is not None:
        _DIAGNOSTIC.source_sha = value['source_sha'] if 'source_before' in value else None
        _DIAGNOSTIC.stable_originals = value['stable_originals']
        _DIAGNOSTIC.checkpoint = value.get('checkpoint', 'unavailable')
    diagnostic_stage(phase='terminal-bindings')
    bindings={name:hashlib.sha256(source_bytes(raw/name)).hexdigest() for name in ('results.json','setup/execute-status.json')}
    execute_exit_code=read_json(raw/'setup/execute-status.json')['exit_code']
    diagnostic_stage(phase='normalization')
    manifest=NORMALIZER.package(argparse.Namespace(input=raw,output=public,prefix=[
        'WORKSPACE='+str(ROOT),'OPT=/opt','USR=/usr','BIN=/bin','SBIN=/sbin','SYSTEM=/System','PRIVATE=/private']))
    diagnostic_stage(phase='member-check')
    require(set(row['path'] for row in manifest['files'])==set(value['original_files'])|set(bindings),'published-member-set')
    for row in manifest['files']:
        original=source_bytes(raw/row['path'])
        require(row['original_raw_sha256']==hashlib.sha256(original).hexdigest(),'manifest-original-mismatch')
    diagnostic_stage(phase='original-recheck')
    require(digest(verify_originals(raw))==digest(value),'publication-original-changed')
    diagnostic_stage(phase='terminal-recheck')
    require(all(hashlib.sha256(source_bytes(raw/name)).hexdigest()==sha for name,sha in bindings.items()),'publication-terminal-changed')
    result=dict(status='scanned',capability_status=value['status'],files=len(manifest['files']),
                wall_seconds=time.monotonic()-started,capability_only=True,descendant_closure_eligible=False,
                timing_eligible=False,final_protocol_ready=False,actual_engine_calls=0,
                execute_exit_code=execute_exit_code)
    if value.get('checkpoint')=='interpreter-admission-before':
        result.update(checkpoint=value['checkpoint'],failure=value['failure'],
                      interpreter_admission_failure=value['interpreter_admission_failure'])
    return result


def main():
    global _DIAGNOSTIC
    previous = _DIAGNOSTIC; diagnostic = OuterDiagnostic(); _DIAGNOSTIC = diagnostic; code = 125
    try:
        parser=argparse.ArgumentParser();parser.add_argument('--source-sha');parser.add_argument('--raw',type=Path,required=True)
        parser.add_argument('--public',type=Path);args=parser.parse_args()
        if args.public:
            diagnostic.mode = 'publish'
            result=publish(args.raw,args.public);print(json.dumps(result));code=0
            diagnostic.status = 'scanned'
        else:
            result=execute(args.raw,args.source_sha)
            if result.get('checkpoint')=='interpreter-admission-before' and 'interpreter_admission_failure' in result:
                print(json.dumps(dict(status=result['status'],checkpoint=result['checkpoint'],failure=result['failure'],
                                      interpreter_admission_failure=result['interpreter_admission_failure'])))
            code = 0 if result['status']=='capability-only-complete' else 1
    except BaseException as error:
        diagnostic_failure(error)
        diagnostic.status = 'incomplete'
    finally:
        _DIAGNOSTIC = previous
    try:
        sys.stderr.write(CAP.diagnostic_line(diagnostic.value(code)));sys.stderr.flush()
    except BaseException:
        # 이미 실패한 호출은 첫 상태를 지키며 진단 출력 실패로 성공할 수 없다.
        code = code or 125
    return code


if __name__=='__main__':
    raise SystemExit(main())
