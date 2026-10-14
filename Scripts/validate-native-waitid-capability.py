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
            resolved_path='/opt/homebrew/Cellar/python@3.14/3.14.7/Frameworks/Python.framework/Versions/3.14/bin/python3.14',
            bytes=34640,sha256='87d4df53fd91304be5bac391fb204643c36b7df2023c04a0953bcbc7d4fdf634')
IMAGE=dict(ImageOS='macos26',ImageVersion='20260907.0351.1')

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module);return module

CAP=load('owned_waitid_capability',HELPER)
OBS=load('waitid_interpreter_observation',ROOT/'Scripts/validate-native-measurement.py')
NORMALIZER=load('waitid_unchanged_normalizer',ROOT/'Scripts/normalize-indexstore-evidence.py')


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
                primary=dict(type=type(error).__name__,reason=str(error))
            finally:
                for sig in previous:signal.signal(sig,signal.SIG_IGN)
                if process is not None and code is None:
                    for signum,grace,label in ((signal.SIGTERM,7.0,'term'),(signal.SIGKILL,3.0,'kill')):
                        if not anchor:break
                        try:os.killpg(process.pid,signum)
                        except ProcessLookupError:pass
                        except BaseException as error:row['cleanup_errors'].append(dict(step=label,type=type(error).__name__))
                        try:wait_until(time.monotonic()+grace,False)
                        except subprocess.TimeoutExpired:pass
                        except BaseException as error:row['cleanup_errors'].append(dict(step=label+'-wait',type=type(error).__name__))
                        if code is not None:break
                    if uncertain and code is None:
                        # A later wait can establish an exit; uncertain ownership never permits a signal.
                        try:wait_until(time.monotonic()+3.0,False)
                        except BaseException as error:row['cleanup_errors'].append(dict(step='uncertain-wait',type=type(error).__name__))
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
        save(stem.with_suffix('.json'),row)
        return row
    finally:
        for sig,handler in previous.items():signal.signal(sig,handler)


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


def bind_interpreter():
    require(sys.platform=='darwin' and tuple(sys.version_info[:3])==(3,14,7),'native-python-version-mismatch')
    require(os.uname().machine=='arm64' and os.uname().release=='25.6.0','native-os-mismatch')
    require(all(os.environ.get(key)==value for key,value in IMAGE.items()),'native-image-mismatch')
    require(sys.executable==PYTHON['selected_path'],'selected-python-mismatch')
    observed=OBS.interpreter_observation(sys.executable)
    require(observed.get('status')=='available' and all(observed.get(k)==v for k,v in PYTHON.items()),'physical-python-mismatch')
    return observed


def same_interpreter(before,after):
    return all(before[k]==after[k] for k in ('selected_path','resolved_path','bytes','sha256','file_identity'))


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
                argv=actor.get('argv');require(type(argv) is list and len(argv)==9 and argv[:5]==[PYTHON['selected_path'],'-I','-S','-B',str(HELPER)]
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
    require(re.fullmatch(r'[0-9a-f]{40}',source_sha) and os.environ.get('GITHUB_SHA')==source_sha,'dispatch-source-mismatch')
    raw.mkdir(exist_ok=False);started=time.monotonic()
    home,temporary=raw/'setup/owned-home',raw/'setup/owned-tmp';home.mkdir(parents=True);temporary.mkdir()
    environment=environment_for(raw)
    result=dict(schema_version=1,profile='native-waitid-capability-outer-v1',source_sha=source_sha,status='incomplete',
                capability_only=True,descendant_closure_eligible=False,timing_eligible=False,final_protocol_ready=False,
                actual_engine_calls=0,interpreter_scope='Observed executable only; Python framework/stdlib and dynamic-loader closure unproved',
                command_schedule='two source-query metadata children and one capability child; at most13 actor children inside that child')
    material_safe=True
    try:
        before=bind_interpreter();result['interpreter_before']=before
        material_safe=False
        source=bind_sources(source_sha,raw,environment,'before');result['source_before']=source
        material_safe=True
        argv=[sys.executable,'-I','-S','-B',str(HELPER),'--output',str(raw/'runs/capability')]
        (raw/'runs').mkdir()
        material_safe=False
        outer=command(argv,ROOT,raw/'setup/capability-command',environment,150);result['command']=outer
        require_stable_child(outer)
        if outer['status']!='completed-zero':
            material_safe=False
            raise UnfinishedChild('capability-actor-cleanup-not-proved')
        material_safe=False
        result['source_after']=bind_sources(source_sha,raw,environment,'after')
        material_safe=True
        result['interpreter_after']=bind_interpreter()
        require(source['files']==result['source_after']['files'] and same_interpreter(before,result['interpreter_after']),'input-identity-changed')
        require(outer['status']=='completed-zero','capability-command-incomplete')
        data=source_bytes(raw/'runs/capability/results.json');value=NORMALIZER.strict_json(data.decode())
        result['capability_result']=dict(bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
        result['verification']=regrade(value,outer,source,sys.version)
        result['status']='capability-only-complete'
    except BaseException as error:
        result['failure']=dict(type=type(error).__name__,reason=str(error))
        if isinstance(error,UnfinishedChild):material_safe=False
    result['stable_originals']=material_safe
    if material_safe:
        try:result['original_files']=inventory(raw)
        except BaseException as error:
            result['status']='incomplete';result['stable_originals']=False
            result.setdefault('failure',dict(type=type(error).__name__,reason=str(error)))
    result['full_caller_wall_seconds_before_receipt']=time.monotonic()-started
    result['cost_scope']='Caller includes admission and actual child/cleanup; nested intervals overlap; final receipt/teardown and publication excluded'
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


def verify_originals(raw):
    value=read_json(raw/'results.json');status=read_json(raw/'setup/execute-status.json')
    require(type(value) is dict and value.get('profile')=='native-waitid-capability-outer-v1'
            and type(value.get('schema_version')) is int and value['schema_version']==1,'outer-schema')
    require(value.get('capability_only') is True and type(value.get('actual_engine_calls')) is int
            and value['actual_engine_calls']==0,'outer-scope')
    for key in ('descendant_closure_eligible','timing_eligible','final_protocol_ready'):
        require(value.get(key) is False,'promoted-eligibility')
    require(set(status)=={'exit_code'} and type(status['exit_code']) is int,'workflow-exit-schema')
    source_sha=value.get('source_sha')
    require(type(source_sha) is str and re.fullmatch(r'[0-9a-f]{40}',source_sha)
            and os.environ.get('GITHUB_SHA')==source_sha,'publication-source-mismatch')
    require(value.get('stable_originals') is True,'original-writer-not-proved-finished')
    if 'command' in value:
        require_stable_child(value['command'])
        require(value['command'].get('status')=='completed-zero','capability-actor-cleanup-not-proved')
    require(digest(value.get('original_files'))==digest(inventory(raw)),'original-membership-or-bytes-changed')
    verify_source_record(value['source_before'],source_sha,raw,'before')
    current=bind_interpreter();require(same_interpreter(current,value['interpreter_before']),'interpreter-changed')
    require(value.get('status') in ('capability-only-complete','incomplete'),'outer-status')
    if value['status']=='capability-only-complete':
        require(status['exit_code']==0 and 'failure' not in value,'actual-outer-incomplete')
        require(set(value['original_files'])==complete_membership(),'completed-member-set')
        verify_source_record(value['source_after'],source_sha,raw,'after')
        require(digest(value['source_before']['files'])==digest(value['source_after']['files'])
                and same_interpreter(current,value['interpreter_after']),'post-identity-mismatch')
        argv=[PYTHON['selected_path'],'-I','-S','-B',str(HELPER),'--output',str(raw/'runs/capability')]
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
    else:
        require(status['exit_code']!=0,'incomplete-with-successful-exit')
    return value


def publish(raw,public):
    started=time.monotonic();value=verify_originals(raw)
    bindings={name:hashlib.sha256(source_bytes(raw/name)).hexdigest() for name in ('results.json','setup/execute-status.json')}
    manifest=NORMALIZER.package(argparse.Namespace(input=raw,output=public,prefix=[
        'WORKSPACE='+str(ROOT),'OPT=/opt','USR=/usr','BIN=/bin','SBIN=/sbin','SYSTEM=/System','PRIVATE=/private']))
    require(set(row['path'] for row in manifest['files'])==set(value['original_files'])|set(bindings),'published-member-set')
    for row in manifest['files']:
        original=source_bytes(raw/row['path'])
        require(row['original_raw_sha256']==hashlib.sha256(original).hexdigest(),'manifest-original-mismatch')
    require(digest(verify_originals(raw))==digest(value),'publication-original-changed')
    require(all(hashlib.sha256(source_bytes(raw/name)).hexdigest()==sha for name,sha in bindings.items()),'publication-terminal-changed')
    return dict(status='scanned',capability_status=value['status'],files=len(manifest['files']),
                wall_seconds=time.monotonic()-started,capability_only=True,descendant_closure_eligible=False,
                timing_eligible=False,final_protocol_ready=False,actual_engine_calls=0)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--source-sha');parser.add_argument('--raw',type=Path,required=True)
    parser.add_argument('--public',type=Path);args=parser.parse_args()
    if args.public:
        result=publish(args.raw,args.public);print(json.dumps(result));return 0
    result=execute(args.raw,args.source_sha)
    return 0 if result['status']=='capability-only-complete' else 1


if __name__=='__main__':
    try:code=main()
    except BaseException as error:
        print(json.dumps(dict(status='incomplete',category='capability-wrapper-failed',
            error_type=type(error).__name__,message_sha256=hashlib.sha256(str(error).encode()).hexdigest())))
        code=125
    raise SystemExit(code)
