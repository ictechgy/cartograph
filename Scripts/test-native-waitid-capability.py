#!/usr/bin/env python3
"""Owned mocks and temporary evidence only; never launch capability actors."""
import ast
import contextlib
import copy
import errno
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
from types import SimpleNamespace
import unittest
from unittest import mock

SPEC=importlib.util.spec_from_file_location('waitid_outer_controls',Path(__file__).with_name('validate-native-waitid-capability.py'))
M=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(M)


def mock_native_primitives(module):
    """Pure mocks only: fill absent names, preserve available native objects, restore absence."""
    stack=contextlib.ExitStack()
    values=dict(P_PID=1,WEXITED=4,WNOWAIT=16777216,WNOHANG=1,CLD_EXITED=1,CLD_KILLED=2,CLD_DUMPED=3)
    def unavailable(*_args):raise OSError(38,'mock native primitive unavailable')
    values['waitid']=unavailable
    for name,value in values.items():
        if not hasattr(module,name):stack.enter_context(mock.patch.object(module,name,value,create=True))
    return stack


class OuterControls(unittest.TestCase):
    def setUp(self):
        self.native_mocks=mock_native_primitives(M.os);self.addCleanup(self.native_mocks.close)
        self.temporary=tempfile.TemporaryDirectory();self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name).resolve();self.raw=self.root/'raw';self.public=self.root/'public'
        self.sha='a'*40
        self.env=mock.patch.dict(os.environ,{'GITHUB_SHA':self.sha});self.env.start();self.addCleanup(self.env.stop)
        identity=[1,2,0o100755,M.PYTHON['bytes'],5,6]
        aliases={};observations={}
        for role,path in (('configured',M.PYTHON['selected_path']),('runtime',M.PYTHON['runtime_path'])):
            observations[role]=dict(status='available',selected_path=path,resolved_path=M.PYTHON['resolved_path'],
                                    bytes=M.PYTHON['bytes'],sha256=M.PYTHON['sha256'],file_identity=list(identity),wall_seconds=.001)
            aliases[role]=dict(status='available',selected_path_sha256=M.admission_text_hash(path),
                               resolved_path_sha256=M.admission_text_hash(M.PYTHON['resolved_path']),components=[
                dict(component_sha256=M.admission_text_hash(''),entry_type='directory',identity=[1,1,0o40755]),
                dict(component_sha256=M.admission_text_hash('python3.14'),entry_type='file',identity=list(identity))])
        self.interpreter=dict(status='available',**observations,aliases_before=copy.deepcopy(aliases),
                              aliases_after=copy.deepcopy(aliases),wall_seconds=.003)

    def write(self,path,value):
        path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(value,sort_keys=True,indent=2)+'\n')

    def mock_command(self,wait,*,clock=None,launch=None):
        process=mock.Mock(pid=701);process.wait.side_effect=wait
        handlers={};signals=[]
        def install(sig,handler):
            old=handlers.get(sig,signal.SIG_DFL);handlers[sig]=handler;return old
        def popen(*args,**kwargs):
            if launch:launch(handlers,process)
            return process
        with mock.patch.object(M.signal,'signal',side_effect=install), \
             mock.patch.object(M.subprocess,'Popen',side_effect=popen), \
             mock.patch.object(M.os,'killpg',side_effect=lambda p,s:signals.append((p,s))), \
             mock.patch.object(M.time,'monotonic',side_effect=clock or self.clock()):
            # Tests can inject cancellation at the exact wait return boundary through this retained handler map.
            process.handlers=handlers
            row=M.command(['owned-mock'],self.root,self.root/'command',{},1)
        return row,process,signals

    def clock(self):
        value=0
        def now():
            nonlocal value
            value+=.01;return value
        return now

    def test_completed_zero_wait_closes_signalling_and_keeps_original_receipt(self):
        row,process,signals=self.mock_command(lambda **_:0)
        self.assertEqual(row['status'],'completed-zero');self.assertEqual(signals,[])
        process.poll.assert_not_called();self.assertEqual(M.read_json(self.root/'command.json'),row)
        self.assertLessEqual(process.wait.call_args.kwargs['timeout'],.1)

    def test_cancellation_at_reap_return_and_assignment_boundaries_never_signals(self):
        for boundary in ('return','assignment'):
            with self.subTest(boundary=boundary):
                work=self.root/boundary;work.mkdir()
                original_root=self.root;self.root=work;armed={};fired=[]
                def install(handlers,process):
                    armed['handlers']=handlers
                    def wait(**_):
                        if boundary=='return':handlers[signal.SIGTERM](signal.SIGTERM,None);fired.append('return')
                        return 0
                    process.wait.side_effect=wait
                assignment_line=next(i for i,line in enumerate(Path(M.__file__).read_text().splitlines(),1)
                                     if 'code=observed;anchor=False' in line)
                def trace(frame,event,arg):
                    if boundary=='assignment' and event=='line' and frame.f_code.co_name=='wait_until' \
                       and frame.f_code.co_filename==M.__file__ and frame.f_lineno==assignment_line and not fired:
                        # The real wait has returned, but neither local assignment has executed yet.
                        armed['handlers'][signal.SIGINT](signal.SIGINT,None);fired.append('assignment')
                    return trace
                previous=sys.gettrace()
                try:
                    sys.settrace(trace)
                    row,process,signals=self.mock_command(None,launch=install)
                finally:sys.settrace(previous);self.root=original_root
                self.assertEqual(fired,[boundary]);self.assertEqual(row['observed_returncode'],0)
                self.assertEqual(row['failure']['type'],'Cancelled');self.assertEqual(row['status'],'incomplete')
                self.assertFalse(row['cleanup_root_unfinished']);self.assertEqual(signals,[])

    def test_cancel_during_launch_registers_handle_before_term_cleanup(self):
        def launch(handlers,process):handlers[signal.SIGTERM](signal.SIGTERM,None)
        row,process,signals=self.mock_command(lambda **_:-signal.SIGTERM,launch=launch)
        self.assertEqual(signals,[(701,signal.SIGTERM)]);self.assertEqual(row['observed_returncode'],-signal.SIGTERM)
        self.assertEqual(row['failure']['type'],'Cancelled');self.assertFalse(row['cleanup_root_unfinished'])

    def test_timeout_uses_one_deadline_then_term_and_kill_with_bounded_waits(self):
        ticks=iter([0,.01,1.1,1.2,8.3,8.4,8.5,8.6])
        row,process,signals=self.mock_command(lambda **_:-signal.SIGKILL,clock=lambda:next(ticks))
        self.assertEqual(signals,[(701,signal.SIGTERM),(701,signal.SIGKILL)])
        self.assertEqual(row['failure']['type'],'TimeoutExpired');self.assertEqual(row['observed_returncode'],-signal.SIGKILL)

    def test_non_timeout_wait_error_forbids_all_numeric_signals_and_preserves_first_error(self):
        calls=[OSError(errno.ECHILD,'uncertain'),0]
        def wait(**_):
            item=calls.pop(0)
            if isinstance(item,BaseException):raise item
            return item
        row,process,signals=self.mock_command(wait)
        self.assertTrue(row['ownership_uncertain']);self.assertEqual(signals,[])
        self.assertEqual(row['observed_returncode'],0);self.assertEqual(row['failure']['type'],'ChildProcessError')
        self.assertEqual(row['status'],'incomplete')

    def test_unfinished_cleanup_retains_primary_and_secondary_errors(self):
        row,process,signals=self.mock_command(lambda **_: (_ for _ in ()).throw(RuntimeError('wait refused')))
        self.assertTrue(row['cleanup_root_unfinished']);self.assertEqual(signals,[])
        self.assertEqual(row['failure']['type'],'RuntimeError');self.assertEqual(row['cleanup_errors'][0]['step'],'uncertain-wait')

    def test_uncertain_or_unfinished_command_never_reads_live_streams(self):
        for exits in ((OSError(errno.ECHILD,'uncertain'),0),(RuntimeError('uncertain'),RuntimeError('still uncertain'))):
            with self.subTest(exits=exits):
                previous=self.root;self.root=previous/str(len(list(previous.iterdir())));self.root.mkdir()
                outcomes=list(exits)
                def wait(**_):
                    item=outcomes.pop(0)
                    if isinstance(item,BaseException):raise item
                    return item
                with mock.patch.object(M,'source_bytes') as read:
                    row,process,signals=self.mock_command(wait)
                self.root=previous;read.assert_not_called();self.assertEqual(signals,[])
                self.assertEqual(row['streams_status'],'not-read-owned-child-unfinished-or-uncertain')
                self.assertNotIn('stdout',row);self.assertNotIn('stderr',row)

    def test_late_reaped_zero_is_incomplete_without_signalling(self):
        ticks=iter([0,.01,.02,1.5])
        row,process,signals=self.mock_command(lambda **_:0,clock=lambda:next(ticks))
        self.assertEqual(row['observed_returncode'],0);self.assertGreater(row['wall_seconds'],1)
        self.assertEqual(row['status'],'incomplete');self.assertEqual(signals,[])

    def test_existing_command_stream_is_not_overwritten_or_launched(self):
        (self.root/'command.stdout').write_bytes(b'prior')
        with mock.patch.object(M.subprocess,'Popen') as launched,self.assertRaises(FileExistsError):
            M.command(['owned-mock'],self.root,self.root/'command',{},1)
        launched.assert_not_called();self.assertEqual((self.root/'command.stdout').read_bytes(),b'prior')

    def test_source_reader_refuses_symlink_directory_and_oversize(self):
        ordinary=self.root/'source';ordinary.write_bytes(b'body')
        link=self.root/'link';link.symlink_to(ordinary)
        for path in (link,self.root):
            with self.subTest(path=path),self.assertRaises(ValueError):M.source_bytes(path)
        with mock.patch.object(M.os,'open') as opened,mock.patch.object(Path,'lstat',return_value=SimpleNamespace(st_mode=0o100644,st_size=8*1024**2+1)):
            with self.assertRaises(ValueError):M.source_bytes(ordinary)
        opened.assert_not_called()

    def source_record(self,phase):
        files={};lines=[]
        for name in M.SOURCE_PATHS:
            data=(M.ROOT/name).read_bytes();blob=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
            files[name]=dict(bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),git_blob=blob,mode=M.SOURCE_MODES[name])
            lines.append(M.SOURCE_MODES[name]+' blob '+blob+'\t'+name)
        row=self.command_record('source-'+phase,['/usr/bin/git','ls-tree',self.sha,'--',*M.SOURCE_PATHS],5,stdout=('\n'.join(lines)+'\n').encode())
        return dict(files=files,command=row)

    def command_record(self,name,argv,bound,stdout=b''):
        stem=self.raw/'setup'/name;stem.parent.mkdir(parents=True,exist_ok=True)
        row=dict(argv=argv,cwd=str(M.ROOT),environment_sha256=M.digest(M.environment_for(self.raw)),timeout_seconds=bound,
                 observed_returncode=0,status='completed-zero',cleanup_errors=[],cleanup_root_unfinished=False,
                 ownership_uncertain=False,streams_status='retained-after-root-reap',pid=700,wall_seconds=1 if bound==5 else 2,failure=None)
        for suffix,data in (('.stdout',stdout),('.stderr',b'')):
            path=stem.with_suffix(suffix);path.write_bytes(data)
            row[suffix[1:]]=dict(path=str(path),bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
        self.write(stem.with_suffix('.json'),row);return row

    def inner(self):
        value=dict(schema_version=1,profile='native-waitid-capability-v1',capability_only=True,descendant_closure_eligible=False,
                   timing_eligible=False,final_protocol_ready=False,actual_engine_calls=0,status='capability-only-complete',
                   source_sha256=hashlib.sha256(M.HELPER.read_bytes()).hexdigest(),schedule=[dict(name=n,max_launches=c) for n,c in M.CAP.CASES],
                   bounds=dict(watchdog=5,case=10,suite=120,outer=150),cases=[],actual_launches=13,full_suite_wall_seconds_before_receipt=1.5)
        for number,(name,count) in enumerate(M.CAP.CASES):
            row=dict(name=name,status='capability-case-passed',cleanup=dict(errors=[],unfinished=[],cleanup_wall_seconds=.001),
                     actors=[],full_case_wall_seconds=.1)
            if count:
                pids=[1000+number*10+i for i in range(count)]
                row['observed_tree_status']={'timeout-then-term':'incomplete-observation-timeout','term-ignore-then-kill':'incomplete-term-resistant',
                    'root-exit-member-live':'incomplete-live-member','owned-member-escape':'scope-violation'}.get(name,'enumerated-actors-complete')
                if name=='timeout-then-term':row['expected_observation_timeout']=True
                if name=='term-ignore-then-kill':row['expected_term_resistance']=True
                row['initial_enumerated_actors']=[dict(pid=p,process_group=pids[0],session=700) for p in pids]
                row['post_exit_enumerated_actors']=copy.deepcopy(row['initial_enumerated_actors'])
                if name=='owned-member-escape':row['post_exit_enumerated_actors'][1].update(process_group=pids[1],session=pids[1])
                for i,pid in enumerate(pids):
                    exit_code=-signal.SIGTERM if (i==0 and name in ('signal-exit','timeout-then-term')) or (i==1 and name in ('root-exit-member-live','owned-member-escape')) else -signal.SIGKILL if name=='term-ignore-then-kill' else 7 if name=='normal-seven' else 0
                    actor=dict(pid=pid,terminal=dict(pid=pid,code=os.CLD_EXITED if exit_code>=0 else os.CLD_KILLED,status=abs(exit_code),signo=signal.SIGCHLD,expected_wait_returncode=exit_code),
                               wait_returncode=exit_code,audit_finished_before_reap=True,signal_after_reap=False,reap_count=1,popen_start_to_exit_observed_seconds=.05,
                               argv=[M.PYTHON['runtime_path'],'-I','-S','-B',str(M.HELPER),'--actor','11','14','1' if name=='term-ignore-then-kill' else '0'])
                    row['actors'].append(actor)
            elif name=='native-api-admission':
                row['admission']=dict(platform='darwin',python=sys.version,waitid='native-os.waitid',supported=True,constants={n:getattr(os,n) for n in ('P_PID','WEXITED','WNOWAIT','WNOHANG','CLD_EXITED','CLD_KILLED','CLD_DUMPED')})
            elif name=='injected-observation-refusals':row['subcases']=M.CAP.injected_refusals()
            else:row['subcases']=list(M.CAP.LEDGER_NEGATIVES)
            value['cases'].append(row)
        return value

    def complete_fixture(self):
        self.raw.mkdir();(self.raw/'runs/capability').mkdir(parents=True)
        for name,count in M.CAP.CASES:
            for i in range(count):
                for suffix in ('.stdout','.stderr'):(self.raw/'runs/capability'/f'{name}-{i}{suffix}').write_bytes(b'')
        before=self.source_record('before');after=self.source_record('after')
        command=self.command_record('capability-command',[M.PYTHON['runtime_path'],'-I','-S','-B',str(M.HELPER),'--output',str(self.raw/'runs/capability')],150)
        inner=self.inner();self.write(self.raw/'runs/capability/results.json',inner)
        data=(self.raw/'runs/capability/results.json').read_bytes()
        value=dict(schema_version=1,profile='native-waitid-capability-outer-v1',source_sha=self.sha,status='capability-only-complete',
                   capability_only=True,descendant_closure_eligible=False,timing_eligible=False,final_protocol_ready=False,actual_engine_calls=0,stable_originals=True,
                   source_before=before,source_after=after,interpreter_before=self.interpreter,interpreter_after=self.interpreter,
                   command=command,capability_result=dict(bytes=len(data),sha256=hashlib.sha256(data).hexdigest()),
                   verification=M.regrade(inner,command,before,sys.version),full_caller_wall_seconds_before_receipt=5)
        value['original_files']=M.inventory(self.raw);self.write(self.raw/'results.json',value);self.write(self.raw/'setup/execute-status.json',dict(exit_code=0))
        return value,inner

    def test_nine_item_actor_argv_and_ignore_term_case_binding(self):
        value,inner=self.complete_fixture()
        self.assertEqual(M.regrade(inner,value['command'],value['source_before'],sys.version)['native_actor_launches'],13)
        actor=inner['cases'][1]['actors'][0]
        for argv in (actor['argv'][:-1],actor['argv']+['extra'],actor['argv'][:-1]+['1'],actor['argv'][:6]+['0','14','0'],actor['argv'][:6]+['14','14','0']):
            changed=copy.deepcopy(inner);changed['cases'][1]['actors'][0]['argv']=argv
            with self.subTest(argv=argv),self.assertRaisesRegex(ValueError,'actor-argv'):M.regrade(changed,value['command'],value['source_before'],sys.version)

    def test_rehashed_null_boolean_or_float_pid_and_census_refuse(self):
        value,inner=self.complete_fixture()
        for pid in (None,True,700.0,0,-1):
            changed=copy.deepcopy(inner);outer=copy.deepcopy(value['command']);outer['pid']=pid
            for case in changed['cases']:
                for key in ('initial_enumerated_actors','post_exit_enumerated_actors'):
                    for row in case.get(key,[]):row['session']=pid
            with self.subTest(pid=pid),self.assertRaisesRegex(ValueError,'command-pid'):
                M.regrade(changed,outer,value['source_before'],sys.version)
        changed=copy.deepcopy(inner);changed['cases'][1]['initial_enumerated_actors'][0]['pid']=1010.0
        with self.assertRaisesRegex(ValueError,'census-identity'):
            M.regrade(changed,value['command'],value['source_before'],sys.version)
        for pid in (None,True,700.0,0,-1):
            row=copy.deepcopy(value['command']);row['pid']=pid
            self.write(self.raw/'setup/capability-command.json',row)
            with self.subTest(pid=pid),self.assertRaisesRegex(ValueError,'command-pid'):
                M.verify_command(row,self.raw,'capability-command',row['argv'],150)

    def test_complete_producer_originals_publish_through_unchanged_scanner(self):
        value,inner=self.complete_fixture()
        with mock.patch.object(M,'bind_interpreter',return_value=self.interpreter):
            result=M.publish(self.raw,self.public)
        self.assertEqual(result['status'],'scanned');self.assertEqual(result['files'],38)
        self.assertFalse(result['timing_eligible']);self.assertFalse(result['descendant_closure_eligible'])
        self.assertEqual(M.read_json(self.raw/'results.json'),value)
        self.assertEqual(len(M.read_json(self.public/'manifest.json')['files']),38)

    def test_outer_nonzero_receipt_refuses_complete_inner_even_if_close_failed_after_flush(self):
        self.complete_fixture();self.write(self.raw/'setup/execute-status.json',dict(exit_code=125))
        with mock.patch.object(M,'bind_interpreter',return_value=self.interpreter),mock.patch.object(M.NORMALIZER,'package') as package:
            with self.assertRaisesRegex(ValueError,'actual-outer-incomplete'):M.publish(self.raw,self.public)
        package.assert_not_called()

    def test_workflow_exit_boolean_and_missing_receipt_refuse(self):
        self.complete_fixture();path=self.raw/'setup/execute-status.json';self.write(path,dict(exit_code=False))
        with self.assertRaisesRegex(ValueError,'workflow-exit-schema'):M.verify_originals(self.raw)
        path.unlink()
        with self.assertRaises(FileNotFoundError):M.verify_originals(self.raw)

    def test_original_member_missing_extra_or_rehashed_actor_output_refuses(self):
        value,inner=self.complete_fixture();path=self.raw/'runs/capability/normal-zero-0.stdout'
        path.unlink()
        with self.assertRaisesRegex(ValueError,'membership'):M.verify_originals(self.raw)
        path.write_bytes(b'changed');value['original_files']=M.inventory(self.raw);self.write(self.raw/'results.json',value)
        with mock.patch.object(M,'bind_interpreter',return_value=self.interpreter),self.assertRaisesRegex(ValueError,'actor-output'):M.verify_originals(self.raw)
        path.write_bytes(b'');(self.raw/'setup/extra.json').write_text('{}');value['original_files']=M.inventory(self.raw);self.write(self.raw/'results.json',value)
        with mock.patch.object(M,'bind_interpreter',return_value=self.interpreter),self.assertRaisesRegex(ValueError,'member-set'):M.verify_originals(self.raw)

    def test_rehashed_command_exit_or_argv_or_wall_cannot_certify_completion(self):
        value,inner=self.complete_fixture();original=copy.deepcopy(value)
        for changes in (dict(observed_returncode=False),dict(argv=['other']),dict(wall_seconds=151),dict(ownership_uncertain=True)):
            value=copy.deepcopy(original);value['command'].update(changes)
            self.write(self.raw/'setup/capability-command.json',value['command']);value['original_files']=M.inventory(self.raw);self.write(self.raw/'results.json',value)
            with self.subTest(changes=changes),mock.patch.object(M,'bind_interpreter',return_value=self.interpreter),self.assertRaises(ValueError):M.verify_originals(self.raw)

    def test_rehashed_source_query_missing_duplicate_mode_or_blob_refuses(self):
        value,inner=self.complete_fixture();record=value['source_before'];path=self.raw/'setup/source-before.stdout';text=path.read_text()
        for changed in ('\n'.join(text.splitlines()[:-1])+'\n',text+text.splitlines()[0]+'\n',text.replace('100644','100755',1),text.replace(record['files'][M.SOURCE_PATHS[0]]['git_blob'],'b'*40)):
            path.write_text(changed);record=copy.deepcopy(value['source_before']);data=path.read_bytes()
            record['command']['stdout'].update(bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
            self.write(self.raw/'setup/source-before.json',record['command'])
            with self.subTest(changed=changed[:20]),self.assertRaises(ValueError):M.verify_source_record(record,self.sha,self.raw,'before')

    def test_current_source_mutation_refuses_despite_unchanged_originals(self):
        value,inner=self.complete_fixture();real=M.source_bytes
        def changed(path):return b'changed' if path==M.ROOT/M.SOURCE_PATHS[0] else real(path)
        with mock.patch.object(M,'source_bytes',side_effect=changed),self.assertRaisesRegex(ValueError,'source-commit'):M.verify_originals(self.raw)

    def test_current_interpreter_identity_drift_refuses(self):
        self.complete_fixture();changed=copy.deepcopy(self.interpreter);changed['runtime']['file_identity'][1]+=1
        with mock.patch.object(M,'bind_interpreter',return_value=changed),self.assertRaisesRegex(ValueError,'interpreter-changed'):M.verify_originals(self.raw)

    def test_raw_result_or_member_mutation_during_publication_refuses(self):
        for mode in ('result','member','source'):
            with self.subTest(mode=mode):
                self.raw=self.root/mode;self.public=self.root/(mode+'-public');value,inner=self.complete_fixture()
                real=M.NORMALIZER.package
                def publish(args):
                    manifest=real(args)
                    if mode=='result':
                        value['full_caller_wall_seconds_before_receipt']+=1;self.write(self.raw/'results.json',value)
                    elif mode=='member':(self.raw/'setup/source-after.stderr').write_bytes(b'changed')
                    else: self.interpreter['runtime']['file_identity'][1]+=1
                    return manifest
                with mock.patch.object(M,'bind_interpreter',side_effect=lambda:copy.deepcopy(self.interpreter)),mock.patch.object(M.NORMALIZER,'package',side_effect=publish):
                    with self.assertRaises(ValueError):M.publish(self.raw,self.public)
                if mode=='source':self.interpreter['runtime']['file_identity'][1]-=1

    def test_partial_originals_remain_incomplete_without_completed_membership(self):
        value,inner=self.complete_fixture();value.update(status='incomplete',failure=dict(type='ValueError',reason='owned refusal'))
        (self.raw/'runs/capability/normal-zero-0.stdout').unlink();value['original_files']=M.inventory(self.raw)
        self.write(self.raw/'results.json',value);self.write(self.raw/'setup/execute-status.json',dict(exit_code=1))
        with mock.patch.object(M,'bind_interpreter',return_value=self.interpreter):result=M.publish(self.raw,self.public)
        self.assertEqual(result['capability_status'],'incomplete');self.assertFalse(result['final_protocol_ready'])

    def test_sensitive_actor_stream_still_refuses_without_scanner_relaxation(self):
        value,inner=self.complete_fixture();value.update(status='incomplete',failure=dict(type='ValueError',reason='partial'))
        (self.raw/'runs/capability/normal-zero-0.stdout').write_text('token=private-sensitive-value')
        value['original_files']=M.inventory(self.raw);self.write(self.raw/'results.json',value);self.write(self.raw/'setup/execute-status.json',dict(exit_code=1))
        with mock.patch.object(M,'bind_interpreter',return_value=self.interpreter),self.assertRaises(M.NORMALIZER.PublicationBlocked):M.publish(self.raw,self.public)

    def test_unsupported_interpreter_refuses_before_any_command(self):
        with mock.patch.object(M,'bind_interpreter',side_effect=ValueError('unavailable')),mock.patch.object(M,'command') as command:
            result=M.execute(self.raw,self.sha)
        command.assert_not_called();self.assertEqual(result['status'],'incomplete');self.assertEqual(result['actual_engine_calls'],0)

    @contextlib.contextmanager
    def native_file_identity(self):
        # 실행 가능한 자식 대신 실제 임시 정규 파일과 심볼릭 링크의 정체성을 관찰한다.
        fixture=tempfile.TemporaryDirectory(prefix='waitid-alias-fixture-',dir=M.ROOT);self.addCleanup(fixture.cleanup)
        homebrew=Path(fixture.name)/'homebrew';cellar=homebrew/'Cellar/python@3.14/3.14.7'
        physical=cellar/'Frameworks/Python.framework/Versions/3.14/bin/python3.14'
        physical.parent.mkdir(parents=True);body=b'owned interpreter identity fixture';physical.write_bytes(body)
        runtime=cellar/'bin/python3.14';runtime.parent.mkdir()
        runtime.symlink_to('../Frameworks/Python.framework/Versions/3.14/bin/python3.14')
        opt=homebrew/'opt';opt.mkdir();(opt/'python@3.14').symlink_to('../Cellar/python@3.14/3.14.7')
        selected=opt/'python@3.14/bin/python3.14'
        pins=dict(selected_path=str(selected),runtime_path=str(runtime),resolved_path=str(physical),
                  bytes=len(body),sha256=hashlib.sha256(body).hexdigest())
        with mock.patch.object(M,'PYTHON',pins),mock.patch.object(M.sys,'platform','darwin'), \
             mock.patch.object(M.sys,'version_info',(3,14,7,'final',0)), \
             mock.patch.object(M.sys,'executable',str(runtime)), \
             mock.patch.object(M.os,'uname',return_value=SimpleNamespace(machine='arm64',release='25.6.0')), \
             mock.patch.dict(os.environ,M.IMAGE):
            yield selected,physical,pins

    def replace_alias(self,path,target=None):
        replacement=path.with_name(path.name+'-replacement')
        replacement.symlink_to(os.readlink(path) if target is None else target)
        replacement.replace(path)

    def mock_capability_command(self,argv,cwd,stem,environment,bound):
        self.assertEqual(argv[0],M.PYTHON['runtime_path'])
        self.assertNotEqual(argv[0],M.PYTHON['selected_path'])
        (self.raw/'runs/capability').mkdir()
        for name,count in M.CAP.CASES:
            for i in range(count):
                for suffix in ('.stdout','.stderr'):
                    (self.raw/'runs/capability'/f'{name}-{i}{suffix}').write_bytes(b'')
        self.write(self.raw/'runs/capability/results.json',self.inner())
        return self.command_record('capability-command',argv,bound)

    def test_real_launch_shaped_aliases_pass_execute_main_and_both_publication_endpoints(self):
        with self.native_file_identity() as (selected,physical,pins), \
             mock.patch.object(M,'bind_sources',side_effect=lambda sha,raw,env,phase:self.source_record(phase)), \
             mock.patch.object(M,'command',side_effect=self.mock_capability_command) as command, \
             mock.patch.object(M.subprocess,'Popen') as launched, \
             mock.patch.object(M.sys,'argv',['outer','--source-sha',self.sha,'--raw',str(self.raw)]):
            with mock.patch.object(M.time,'monotonic',side_effect=(0,10)):
                self.assertEqual(M.main(),0)
            value=M.read_json(self.raw/'results.json');binding=value['interpreter_before']
            self.assertTrue(M.same_interpreter(binding,value['interpreter_after']))
            self.assertEqual(binding['configured']['selected_path'],str(selected))
            self.assertEqual(binding['runtime']['selected_path'],pins['runtime_path'])
            self.assertEqual(binding['configured']['file_identity'],binding['runtime']['file_identity'])
            self.assertEqual(binding['runtime']['resolved_path'],str(physical))
            self.assertEqual(binding['aliases_before'],binding['aliases_after'])
            self.assertNotEqual(binding['aliases_before']['configured'],binding['aliases_before']['runtime'])
            self.assertNotIn('link_target"',json.dumps(binding))
            self.assertEqual(command.call_count,1);launched.assert_not_called()
            self.write(self.raw/'setup/execute-status.json',dict(exit_code=0))
            original=(self.raw/'results.json').read_bytes();output=io.StringIO()
            with mock.patch.object(M.sys,'argv',['outer','--raw',str(self.raw),'--public',str(self.public)]), \
                 contextlib.redirect_stdout(output):
                self.assertEqual(M.main(),0)
            published=json.loads(output.getvalue())
            self.assertEqual(published['status'],'scanned');self.assertEqual(published['files'],38)
            self.assertEqual(published['capability_status'],'capability-only-complete')
            self.assertEqual((self.raw/'results.json').read_bytes(),original)
            self.assertEqual(M.read_json(self.public/'setup/execute-status.json'),dict(exit_code=0))
            self.assertEqual(published['actual_engine_calls'],0)
            for key in ('descendant_closure_eligible','timing_eligible','final_protocol_ready'):
                self.assertFalse(published[key])
            launched.assert_not_called()

    def test_configured_launch_spelling_cannot_substitute_for_runtime_spelling(self):
        with self.native_file_identity() as (selected,physical,pins), \
             mock.patch.object(M.sys,'executable',str(selected)), \
             mock.patch.object(M,'interpreter_alias') as aliases, \
             mock.patch.object(M.OBS,'interpreter_observation') as observation:
            value,output=self.early_execute('selected-python-mismatch')
            aliases.assert_not_called();observation.assert_not_called()
            safe=value['interpreter_admission_failure']['observed']
            self.assertIsNone(safe['physical_status']);self.assertIsNone(safe['configured_physical_status'])
            self.early_publish(value)

    def test_each_role_retarget_same_bytes_different_physical_file_refuses_and_scans(self):
        with self.native_file_identity() as (selected,physical,pins):
            configured=selected.parents[1];runtime=Path(pins['runtime_path'])
            for index,role in enumerate(('configured','runtime')):
                self.raw=self.root/f'raw-retarget-{index}';self.public=self.root/f'public-retarget-{index}'
                target=(configured if role=='configured' else runtime);original=os.readlink(target)
                alternate=self.root/f'alternate-{role}'
                if role=='configured':
                    alternate.mkdir();(alternate/'bin').mkdir()
                    (alternate/'bin/python3.14').write_bytes(physical.read_bytes())
                else:alternate.write_bytes(physical.read_bytes())
                self.replace_alias(target,str(alternate))
                value,output=self.early_execute('physical-python-mismatch')
                safe=value['interpreter_admission_failure']['observed']
                prefix='configured_' if role=='configured' else ''
                self.assertEqual(safe[prefix+'sha256'],pins['sha256'])
                self.assertNotEqual(safe[prefix+'resolved_path_sha256'],M.admission_text_hash(str(physical)))
                self.early_publish(value);self.replace_alias(target,original)

    def test_each_alias_replacement_with_same_final_target_refuses_between_physical_reads(self):
        with self.native_file_identity() as (selected,physical,pins):
            real=M.OBS.interpreter_observation
            for index,target in enumerate((selected.parents[1],Path(pins['runtime_path']))):
                self.raw=self.root/f'raw-replace-{index}';self.public=self.root/f'public-replace-{index}';calls=[]
                def observe(path):
                    row=real(path);calls.append(path)
                    if len(calls)==1:self.replace_alias(target)
                    return row
                with mock.patch.object(M.OBS,'interpreter_observation',side_effect=observe):
                    value,output=self.early_execute('physical-python-mismatch')
                safe=value['interpreter_admission_failure']['observed']
                self.assertEqual(safe['file_identity_sha256'],safe['configured_file_identity_sha256'])
                role='configured' if index==0 else 'runtime'
                self.assertNotEqual(safe[role+'_alias_before_sha256'],safe[role+'_alias_after_sha256'])
                self.early_publish(value)

    def test_alias_missing_broken_directory_and_loop_are_bounded_refusals(self):
        with self.native_file_identity() as (selected,physical,pins):
            runtime=Path(pins['runtime_path']);original=os.readlink(runtime)
            for index,kind in enumerate(('missing','broken','directory','loop')):
                self.raw=self.root/f'raw-alias-{index}';self.public=self.root/f'public-alias-{index}'
                runtime.unlink()
                if kind=='broken':runtime.symlink_to('missing-executable')
                elif kind=='directory':runtime.symlink_to(str(physical.parent))
                elif kind=='loop':runtime.symlink_to(runtime.name)
                with mock.patch.object(M.OBS,'interpreter_observation') as observation:
                    value,output=self.early_execute('physical-python-mismatch')
                observation.assert_not_called()
                self.assertIsNone(value['interpreter_admission_failure']['observed']['file_identity_sha256'])
                self.early_publish(value)
                if kind!='missing':runtime.unlink()
                runtime.symlink_to(original)

    def test_real_symlink_file_targets_with_directory_suffixes_refuse_full_admission(self):
        with self.native_file_identity() as (selected,physical,pins):
            runtime=Path(pins['runtime_path']);original=os.readlink(runtime)
            cases=(('relative-dot',original+'/.','interpreter-alias-entry'),
                   ('relative-slash',original+'/','interpreter-alias-entry'),
                   ('relative-parent',original+'/..','interpreter-alias-entry'),
                   ('relative-parent-file',original+'/../'+physical.name,'interpreter-alias-entry'),
                   ('absolute-dot',str(physical)+'/.','interpreter-alias-entry'),
                   ('absolute-slash',str(physical)+'/','interpreter-alias-entry'),
                   ('absolute-parent',str(physical)+'/..','interpreter-alias-entry'),
                   ('absolute-parent-file',str(physical)+'/../'+physical.name,'interpreter-alias-entry'),
                   ('directory-dot',str(physical.parent)+'/.','interpreter-alias-not-file'),
                   ('directory-slash',str(physical.parent)+'/','interpreter-alias-not-file'))
            for name,target,reason in cases:
                with self.subTest(case=name):
                    self.raw=self.root/f'raw-directory-suffix-{name}'
                    self.public=self.root/f'public-directory-suffix-{name}'
                    if name.startswith('absolute'):
                        alias=M.interpreter_alias(target)
                        self.assertEqual(alias['status'],'unavailable')
                        self.assertEqual(alias['failure_sha256'],M.admission_text_hash(reason))
                    self.replace_alias(runtime,target)
                    self.assertEqual(os.readlink(runtime),target)
                    with mock.patch.object(M.OBS,'interpreter_observation') as observation:
                        value,output=self.early_execute('physical-python-mismatch')
                    observation.assert_not_called()
                    safe=value['interpreter_admission_failure']['observed']
                    # 파일 뒤의 점·빈 조각·부모 탐색은 물리 관찰과 명령보다 먼저 거부한다.
                    for role,prefix in (('configured','configured_'),('runtime','')):
                        self.assertIsNone(safe[role+'_alias_before_sha256'])
                        self.assertIsNone(safe[role+'_alias_after_sha256'])
                        self.assertEqual(safe[role+'_alias_failure_sha256'],M.admission_text_hash(reason))
                        self.assertEqual(safe[prefix+'physical_status'],'unavailable')
                        self.assertIsNone(safe[prefix+'file_identity_sha256'])
                        self.assertIsNone(safe[prefix+'sha256'])
                    self.early_publish(value);self.replace_alias(runtime,original)

    def test_real_directory_dot_slash_and_parent_aliases_preserve_full_binding(self):
        with self.native_file_identity() as (selected,physical,pins):
            configured=selected.parents[1];runtime=Path(pins['runtime_path'])
            configured_target=os.readlink(configured);real=M.OBS.interpreter_observation
            cases=(('runtime-relative-dot-slash',runtime,
                    '.././Frameworks//Python.framework/Versions/3.14/bin/./python3.14'),
                   ('runtime-relative-parent',runtime,
                    '../Frameworks/Python.framework/Versions/3.14/bin/../bin/python3.14'),
                   ('runtime-absolute-dot-slash',runtime,str(physical.parent)+'//./'+physical.name),
                   ('runtime-absolute-parent',runtime,str(physical.parent)+'/../bin/'+physical.name),
                   ('configured-relative-dot',configured,configured_target+'/.'),
                   ('configured-relative-slash',configured,configured_target+'/'),
                   ('configured-absolute-dot-slash',configured,str(runtime.parents[1])+'//./'),
                   ('configured-absolute-parent',configured,str(runtime.parents[1])+'/../3.14.7/'))
            for name,alias,target in cases:
                with self.subTest(case=name):
                    original=os.readlink(alias);self.replace_alias(alias,target)
                    self.assertEqual(os.readlink(alias),target)
                    with mock.patch.object(M.OBS,'interpreter_observation',wraps=real) as observation, \
                         mock.patch.object(M,'command') as command,mock.patch.object(M.subprocess,'Popen') as launched:
                        binding=M.bind_interpreter()
                    command.assert_not_called();launched.assert_not_called()
                    self.assertEqual(observation.call_args_list,[mock.call(str(selected)),mock.call(str(runtime))])
                    self.assertTrue(M.interpreter_receipt_valid(binding))
                    self.assertEqual(binding['aliases_before'],binding['aliases_after'])
                    for role in ('configured','runtime'):
                        self.assertEqual(binding[role]['resolved_path'],str(physical))
                        self.assertEqual(binding[role]['sha256'],pins['sha256'])
                    role='configured' if alias==configured else 'runtime'
                    links=[row for row in binding['aliases_before'][role]['components']
                           if row['entry_type']=='symlink' and row['identity']==M.stat_identity(alias.lstat())]
                    self.assertEqual(len(links),1)
                    self.assertEqual(links[0]['link_target_bytes'],len(os.fsencode(target)))
                    self.assertEqual(links[0]['link_target_sha256'],hashlib.sha256(os.fsencode(target)).hexdigest())
                    self.replace_alias(alias,original)

    def test_raw_empty_and_dot_components_consume_exact_selected_and_link_budgets(self):
        with self.native_file_identity() as (selected,physical,pins), \
             mock.patch.object(M.OBS,'interpreter_observation') as observation, \
             mock.patch.object(M,'command') as command,mock.patch.object(M.subprocess,'Popen') as launched:
            self.assertEqual((M.ALIAS_COMPONENT_LIMIT,M.ALIAS_LINK_LIMIT,M.ALIAS_TARGET_LIMIT),(128,32,16384))
            runtime=Path(pins['runtime_path']);original=os.readlink(runtime)
            cases=(('selected-empty',None,'/',False),('selected-dot',None,'./',False),
                   ('relative-link-empty',original,'/',False),('relative-link-dot',original,'./',False),
                   ('absolute-link-empty',str(physical),'/',False),('absolute-link-dot',str(physical),'./',False),
                   ('selected-leading-empty',None,'/',True),('absolute-link-leading-empty',str(physical),'/',True))
            for name,base,token,leading in cases:
                if base is not None:self.replace_alias(runtime,base)
                path=str(physical) if base is None else str(runtime)
                baseline=M.interpreter_alias(path)
                self.assertEqual(baseline['status'],'available')
                padding=M.ALIAS_COMPONENT_LIMIT-len(baseline['components'])
                self.assertGreater(padding,0)
                prefix,leaf=(str(physical) if base is None else base).rsplit('/',1)
                for extra,status in ((0,'available'),(1,'unavailable')):
                    target=('/'+'/'*(padding+extra)+(str(physical) if base is None else base)[1:] if leading
                            else prefix+'/'+token*(padding+extra)+leaf)
                    if base is None:path=target
                    else:self.replace_alias(runtime,target)
                    with self.subTest(case=name,extra=extra):
                        row=M.interpreter_alias(path)
                        self.assertEqual(row['status'],status)
                        if status=='available':
                            self.assertEqual(len(row['components']),M.ALIAS_COMPONENT_LIMIT)
                            self.assertEqual(row['resolved_path_sha256'],M.admission_text_hash(str(physical)))
                            self.assertEqual(row['components'][-1]['identity'],M.stat_identity(physical.lstat()))
                        else:
                            reason='interpreter-alias-path' if base is None else 'interpreter-alias-component-limit'
                            self.assertEqual(row['failure_sha256'],M.admission_text_hash(reason))
                self.replace_alias(runtime,original)
            with mock.patch.object(M.os,'readlink',return_value=''):
                row=M.interpreter_alias(str(runtime))
            self.assertEqual(row['status'],'unavailable')
            self.assertEqual(row['failure_sha256'],M.admission_text_hash('interpreter-alias-target-limit'))
            observation.assert_not_called();command.assert_not_called();launched.assert_not_called()

    def test_raw_directory_alias_replacement_refuses_between_physical_reads(self):
        with self.native_file_identity() as (selected,physical,pins):
            real=M.OBS.interpreter_observation
            for role,target in (('configured',selected.parents[1]),('runtime',Path(pins['runtime_path']))):
                with self.subTest(role=role):
                    self.raw=self.root/f'raw-dot-replace-{role}';self.public=self.root/f'public-dot-replace-{role}'
                    original=os.readlink(target);prefix,leaf=original.rsplit('/',1);changed=prefix+'/./'+leaf;calls=[]
                    def observe(path):
                        row=real(path);calls.append(path)
                        if len(calls)==1:self.replace_alias(target,changed)
                        return row
                    with mock.patch.object(M.OBS,'interpreter_observation',side_effect=observe):
                        value,output=self.early_execute('physical-python-mismatch')
                    self.assertEqual(calls,[str(selected),pins['runtime_path']])
                    safe=value['interpreter_admission_failure']['observed']
                    self.assertEqual(safe['file_identity_sha256'],safe['configured_file_identity_sha256'])
                    self.assertEqual(safe['sha256'],pins['sha256']);self.assertEqual(safe['configured_sha256'],pins['sha256'])
                    self.assertIsNone(safe[role+'_alias_failure_sha256'])
                    self.assertNotEqual(safe[role+'_alias_before_sha256'],safe[role+'_alias_after_sha256'])
                    self.early_publish(value);self.replace_alias(target,original)

    def test_alias_expansion_limits_and_unreadable_edge_refuse_without_physical_observer(self):
        with self.native_file_identity():
            cases=(mock.patch.object(M,'ALIAS_COMPONENT_LIMIT',2),mock.patch.object(M,'ALIAS_LINK_LIMIT',0),
                   mock.patch.object(M,'ALIAS_TARGET_LIMIT',2),
                   mock.patch.object(M.os,'readlink',side_effect=OSError('token=private-sensitive-value')))
            for index,patch in enumerate(cases):
                self.raw=self.root/f'raw-bound-{index}';self.public=self.root/f'public-bound-{index}'
                with patch,mock.patch.object(M.OBS,'interpreter_observation') as observation:
                    value,output=self.early_execute('physical-python-mismatch')
                observation.assert_not_called();self.assertNotIn('private-sensitive-value',output)
                self.early_publish(value,private=('private-sensitive-value',))

    def test_same_size_hash_change_and_between_role_physical_identity_change_refuse(self):
        with self.native_file_identity() as (selected,physical,pins):
            body=physical.read_bytes();physical.write_bytes(b'x'*len(body))
            value,output=self.early_execute('physical-python-mismatch')
            safe=value['interpreter_admission_failure']['observed']
            self.assertEqual(safe['bytes'],pins['bytes']);self.assertNotEqual(safe['sha256'],pins['sha256'])
            self.early_publish(value);physical.write_bytes(body)
            self.raw=self.root/'raw-identity';self.public=self.root/'public-identity'
            real=M.OBS.interpreter_observation;calls=[]
            def observe(path):
                row=real(path);calls.append(path)
                if len(calls)==1:
                    replacement=physical.with_name('replacement');replacement.write_bytes(body);replacement.replace(physical)
                return row
            with mock.patch.object(M.OBS,'interpreter_observation',side_effect=observe):
                value,output=self.early_execute('physical-python-mismatch')
            safe=value['interpreter_admission_failure']['observed']
            self.assertEqual(safe['sha256'],safe['configured_sha256'])
            self.assertNotEqual(safe['file_identity_sha256'],safe['configured_file_identity_sha256'])
            self.early_publish(value)

    def test_each_role_malformed_identity_refuses_and_scans(self):
        with self.native_file_identity() as (selected,physical,pins):
            real=M.OBS.interpreter_observation
            for index,role in enumerate(('configured','runtime')):
                self.raw=self.root/f'raw-identity-{index}';self.public=self.root/f'public-identity-{index}'
                target=pins['selected_path' if role=='configured' else 'runtime_path']
                def observe(path):
                    row=real(path)
                    if path==target:row['file_identity'][0]=True
                    return row
                with mock.patch.object(M.OBS,'interpreter_observation',side_effect=observe):
                    value,output=self.early_execute('physical-python-mismatch')
                safe=value['interpreter_admission_failure']['observed']
                self.assertIsNone(safe[('configured_' if role=='configured' else '')+'file_identity_sha256'])
                self.early_publish(value)

    def test_same_interpreter_compares_every_role_alias_and_only_excludes_costs(self):
        with self.native_file_identity():
            before=M.bind_interpreter();after=copy.deepcopy(before)
            after['wall_seconds']+=1
            for role in ('configured','runtime'):after[role]['wall_seconds']+=.1
            self.assertTrue(M.same_interpreter(before,after))
            for role in ('configured','runtime'):
                for endpoint in ('aliases_before','aliases_after'):
                    changed=copy.deepcopy(after);changed[endpoint][role]['components'][0]['identity'][1]+=1
                    with self.subTest(role=role,endpoint=endpoint):self.assertFalse(M.same_interpreter(before,changed))
                changed=copy.deepcopy(after);changed[role]['file_identity'][0]=True
                self.assertFalse(M.same_interpreter(before,changed))
            for changed in (dict(after,extra=True),dict(after,wall_seconds=True)):
                self.assertFalse(M.same_interpreter(before,changed))

    def test_observed_alias_replacement_between_execute_endpoints_preserves_refusal(self):
        with self.native_file_identity() as (selected,physical,pins), \
             mock.patch.object(M,'bind_sources',side_effect=lambda sha,raw,env,phase:self.source_record(phase)), \
             mock.patch.object(M.subprocess,'Popen') as launched:
            def command(*args):
                row=self.mock_capability_command(*args);self.replace_alias(selected.parents[1]);return row
            with mock.patch.object(M,'command',side_effect=command):value=M.execute(self.raw,self.sha)
            self.assertEqual(value['status'],'incomplete');self.assertEqual(value['failure']['reason'],'input-identity-changed')
            self.assertFalse(M.same_interpreter(value['interpreter_before'],value['interpreter_after']))
            self.write(self.raw/'setup/execute-status.json',dict(exit_code=1))
            with mock.patch.object(M.NORMALIZER,'package') as package,self.assertRaisesRegex(ValueError,'interpreter-changed'):
                M.publish(self.raw,self.public)
            package.assert_not_called();launched.assert_not_called()

    def test_rehashed_alias_receipt_and_live_alias_change_during_publication_refuse(self):
        with self.native_file_identity() as (selected,physical,pins):
            self.interpreter=M.bind_interpreter();value,inner=self.complete_fixture();original=copy.deepcopy(value)
            for role in ('configured','runtime'):
                value=copy.deepcopy(original)
                for endpoint in ('aliases_before','aliases_after'):
                    value['interpreter_before'][endpoint][role]['components'][0]['identity'][1]+=1
                self.write(self.raw/'results.json',value)
                with self.subTest(role=role),mock.patch.object(M.NORMALIZER,'package') as package, \
                     self.assertRaisesRegex(ValueError,'interpreter-changed'):M.publish(self.raw,self.public)
                package.assert_not_called()
            self.write(self.raw/'results.json',original);real=M.NORMALIZER.package
            def package(args):
                manifest=real(args);self.replace_alias(Path(pins['runtime_path']));return manifest
            with mock.patch.object(M.NORMALIZER,'package',side_effect=package), \
                 self.assertRaisesRegex(ValueError,'interpreter-changed'):M.publish(self.raw,self.public)

    def test_runtime_argv_is_required_for_both_outer_and_actors_with_fixed_opt_workflow(self):
        value,inner=self.complete_fixture()
        changed=copy.deepcopy(inner);changed['cases'][1]['actors'][0]['argv'][0]=M.PYTHON['selected_path']
        with self.assertRaisesRegex(ValueError,'actor-argv-mismatch'):
            M.regrade(changed,value['command'],value['source_before'],sys.version)
        value['command']['argv'][0]=M.PYTHON['selected_path']
        self.write(self.raw/'setup/capability-command.json',value['command'])
        value['original_files']=M.inventory(self.raw);self.write(self.raw/'results.json',value)
        with mock.patch.object(M,'bind_interpreter',return_value=self.interpreter), \
             self.assertRaisesRegex(ValueError,'command-contract-mismatch'):M.verify_originals(self.raw)
        workflow=(M.ROOT/'.github/workflows/waitid-capability.yml').read_text()
        self.assertEqual(workflow.count(M.PYTHON['selected_path']+' -I -S -B'),2)
        self.assertNotIn(M.PYTHON['runtime_path'],workflow)

    def early_execute(self,reason):
        output=io.StringIO()
        with mock.patch.object(M.sys,'argv',['outer','--source-sha',self.sha,'--raw',str(self.raw)]), \
             contextlib.redirect_stdout(output),mock.patch.object(M,'command') as command, \
             mock.patch.object(M,'bind_sources') as sources,mock.patch.object(M.subprocess,'Popen') as launched:
            code=M.main()
        command.assert_not_called();sources.assert_not_called();launched.assert_not_called()
        self.assertEqual(code,1)
        self.write(self.raw/'setup/execute-status.json',dict(exit_code=code))
        value=M.read_json(self.raw/'results.json')
        self.assertEqual(value['status'],'incomplete');self.assertEqual(value['checkpoint'],'interpreter-admission-before')
        self.assertEqual(value['failure']['reason'],reason);self.assertEqual(value['original_files'],{})
        self.assertTrue(value['stable_originals']);self.assertNotIn('source_before',value)
        self.assertEqual(json.loads(output.getvalue())['failure'],value['failure'])
        return value,output.getvalue()

    def early_publish(self,value,*,exit_code=1,private=()):
        output=io.StringIO();original=(self.raw/'results.json').read_bytes()
        with mock.patch.object(M.sys,'argv',['outer','--raw',str(self.raw),'--public',str(self.public)]), \
             contextlib.redirect_stdout(output),mock.patch.object(M,'bind_interpreter') as rebound, \
             mock.patch.object(M,'bind_sources') as sources,mock.patch.object(M,'command') as command, \
             mock.patch.object(M.subprocess,'Popen') as launched:
            code=M.main()
        rebound.assert_not_called();sources.assert_not_called();command.assert_not_called();launched.assert_not_called()
        self.assertEqual(code,0);result=json.loads(output.getvalue())
        self.assertEqual(result['capability_status'],'incomplete');self.assertEqual(result['execute_exit_code'],exit_code)
        self.assertEqual(result['failure'],value['failure']);self.assertEqual(result['files'],2)
        self.assertEqual((self.raw/'results.json').read_bytes(),original)
        self.assertEqual(M.read_json(self.raw/'setup/execute-status.json'),dict(exit_code=exit_code))
        for row in (value,result,M.read_json(self.public/'results.json')):
            self.assertTrue(row['capability_only']);self.assertEqual(row['actual_engine_calls'],0)
            for key in ('descendant_closure_eligible','timing_eligible','final_protocol_ready'):self.assertFalse(row[key])
            for key in ('native_actor_launches','actual_launches','cases','source_before','verification'):self.assertNotIn(key,row)
        manifest=M.read_json(self.public/'manifest.json')
        self.assertEqual({row['path'] for row in manifest['files']},{'results.json','setup/execute-status.json'})
        for row in manifest['files']:
            self.assertEqual(row['original_raw_sha256'],hashlib.sha256((self.raw/row['path']).read_bytes()).hexdigest())
        text=output.getvalue()+original.decode()+''.join(path.read_text() for path in self.public.rglob('*') if path.is_file())
        for item in (str(self.root),*private):self.assertNotIn(item,text)
        return result

    def test_early_version_refusal_main_status_publisher_retains_incomplete(self):
        # 이전 소스에서도 출판 호출까지 도달하여 source_before 누락 자체를 첫 실패로 남긴다.
        with self.native_file_identity(),mock.patch.object(M.sys,'version_info',(3,14,8,'final',0)), \
             mock.patch.object(M,'command') as command,mock.patch.object(M,'bind_sources') as sources, \
             mock.patch.object(M.subprocess,'Popen') as launched:
            with mock.patch.object(M.sys,'argv',['outer','--source-sha',self.sha,'--raw',str(self.raw)]), \
                 contextlib.redirect_stdout(io.StringIO()):
                execute_code=M.main()
            self.assertEqual(execute_code,1)
            self.write(self.raw/'setup/execute-status.json',dict(exit_code=execute_code))
            original=(self.raw/'results.json').read_bytes();output=io.StringIO()
            with mock.patch.object(M.sys,'argv',['outer','--raw',str(self.raw),'--public',str(self.public)]), \
                 contextlib.redirect_stdout(output):
                publication_code=M.main()
            command.assert_not_called();sources.assert_not_called();launched.assert_not_called()
            self.assertEqual(publication_code,0);published=json.loads(output.getvalue())
            self.assertEqual(published['capability_status'],'incomplete')
            self.assertEqual(published['execute_exit_code'],execute_code)
            self.assertEqual(published['failure'],dict(type='ValueError',reason='native-python-version-mismatch'))
            self.assertEqual((self.raw/'results.json').read_bytes(),original)
            self.assertEqual(M.read_json(self.public/'setup/execute-status.json'),dict(exit_code=1))
            self.assertEqual({row['path'] for row in M.read_json(self.public/'manifest.json')['files']},
                             {'results.json','setup/execute-status.json'})
            for key in ('descendant_closure_eligible','timing_eligible','final_protocol_ready'):self.assertFalse(published[key])

    def test_changed_python_version_full_failure_chain_retains_primary_without_rebinding(self):
        with self.native_file_identity(),mock.patch.object(M.sys,'version_info',(3,14,8,'final',0)), \
             mock.patch.object(M.OBS,'interpreter_observation',wraps=M.OBS.interpreter_observation) as observation:
            value,output=self.early_execute('native-python-version-mismatch')
            self.assertEqual(value['interpreter_admission_failure']['observed']['python_version'],[3,14,8])
            self.assertEqual(value['interpreter_admission_failure']['expected']['python_version'],[3,14,7])
            self.early_publish(value)
        observation.assert_not_called()

    def test_changed_selected_executable_is_hash_only_and_never_observed_or_launched(self):
        with self.native_file_identity():
            alternate=self.root/'token=private-sensitive-value';alternate.write_bytes(b'owned alternate')
            with mock.patch.object(M.sys,'executable',str(alternate)), \
                 mock.patch.object(M.OBS,'interpreter_observation',wraps=M.OBS.interpreter_observation) as observation:
                value,output=self.early_execute('selected-python-mismatch')
                receipt=value['interpreter_admission_failure']
                self.assertEqual(receipt['observed']['selected_path_sha256'],hashlib.sha256(str(alternate).encode()).hexdigest())
                self.assertNotEqual(receipt['observed']['selected_path_sha256'],receipt['expected']['selected_path_sha256'])
                self.assertNotIn(str(alternate),output);self.early_publish(value,private=('private-sensitive-value',))
            observation.assert_not_called()

    def test_changed_real_executable_bytes_keep_helper_identity_in_full_failure_chain(self):
        with self.native_file_identity() as (selected,physical,pins):
            admitted=M.bind_interpreter();self.assertEqual(admitted['runtime']['sha256'],pins['sha256'])
            changed=b'token=private-sensitive-value';physical.write_bytes(changed)
            with mock.patch.object(M.OBS,'interpreter_observation',wraps=M.OBS.interpreter_observation) as observation:
                value,output=self.early_execute('physical-python-mismatch')
            self.assertEqual(observation.call_args_list,[mock.call(str(selected)),mock.call(pins['runtime_path'])])
            info=physical.stat();identity=[info.st_dev,info.st_ino,info.st_mode,info.st_size,info.st_mtime_ns,info.st_ctime_ns]
            observed=value['interpreter_admission_failure']['observed']
            self.assertEqual(observed['bytes'],len(changed));self.assertEqual(observed['sha256'],hashlib.sha256(changed).hexdigest())
            self.assertEqual(observed['file_identity_sha256'],M.digest(identity))
            self.early_publish(value,private=('private-sensitive-value',))

    def test_changed_real_resolved_target_keeps_original_pin_and_refuses(self):
        with self.native_file_identity() as (selected,physical,pins):
            alternate=self.root/'other-physical-python';alternate.write_bytes(physical.read_bytes())
            selected.unlink();selected.symlink_to(alternate)
            value,output=self.early_execute('physical-python-mismatch')
            receipt=value['interpreter_admission_failure']
            self.assertEqual(receipt['observed']['sha256'],pins['sha256'])
            self.assertNotEqual(receipt['observed']['resolved_path_sha256'],receipt['expected']['resolved_path_sha256'])
            self.early_publish(value)

    def test_unsupported_or_malformed_native_fields_are_bounded_or_unavailable_through_scanner(self):
        secret='token=private-sensitive-value /unknown/private/path person@example.invalid'
        cases=(('version',(3,14,secret),'native-python-version-mismatch','python_version',None),
               ('version',(3,14,7.0),'native-python-version-mismatch','python_version',None),
               ('platform',secret,'native-python-version-mismatch','platform',None),
               ('machine',secret,'native-os-mismatch','machine',None),
               ('release','25.7.0','native-os-mismatch','os_release','25.7.0'),
               ('release',secret,'native-os-mismatch','os_release',None),
               ('ImageOS','macos27','native-image-mismatch','image_os','macos27'),
               ('ImageOS',secret,'native-image-mismatch','image_os',None),
               ('ImageVersion','20260908.0351.1','native-image-mismatch','image_version','20260908.0351.1'),
               ('ImageVersion',secret,'native-image-mismatch','image_version',None))
        with self.native_file_identity():
            for index,(field,changed,reason,key,expected) in enumerate(cases):
                self.raw=self.root/f'raw-{index}';self.public=self.root/f'public-{index}'
                patch=(mock.patch.object(M.sys,'version_info',changed) if field=='version' else
                       mock.patch.object(M.sys,'platform',changed) if field=='platform' else
                       mock.patch.object(M.os,'uname',return_value=SimpleNamespace(
                           machine=changed if field=='machine' else 'arm64',release=changed if field=='release' else '25.6.0'))
                       if field in ('machine','release') else mock.patch.dict(os.environ,{field:changed}))
                with self.subTest(field=field,changed=changed),patch:
                    value,output=self.early_execute(reason)
                    self.assertEqual(value['interpreter_admission_failure']['observed'][key],expected)
                    self.assertNotIn(secret,output);self.early_publish(value,private=('private-sensitive-value','person@example.invalid'))

    def test_malformed_helper_fields_do_not_leak_or_promote_real_file_observation(self):
        secret='token=private-sensitive-value /unknown/private/path'
        changes=(dict(bytes=True),dict(bytes=1.0),dict(bytes=256*1024**2+1),dict(sha256=secret),
                 dict(status=secret),dict(selected_path=secret),dict(resolved_path=secret))
        with self.native_file_identity():
            real=M.OBS.interpreter_observation
            for index,change in enumerate(changes):
                self.raw=self.root/f'raw-{index}';self.public=self.root/f'public-{index}'
                def malformed(path):
                    row=real(path);row.update(change);return row
                with self.subTest(change=change),mock.patch.object(M.OBS,'interpreter_observation',side_effect=malformed):
                    value,output=self.early_execute('physical-python-mismatch')
                    self.assertNotIn(secret,output);self.early_publish(value,private=('private-sensitive-value',))

    def test_missing_or_malformed_real_helper_identity_refuses_through_full_failure_chain(self):
        with self.native_file_identity():
            real=M.OBS.interpreter_observation
            cases=('missing','null','short','tuple','boolean','float','negative','directory','oversize-mode','wrong-size')
            for index,case in enumerate(cases):
                self.raw=self.root/f'raw-{index}';self.public=self.root/f'public-{index}'
                def malformed(path):
                    row=real(path);identity=row['file_identity']
                    if case=='missing':del row['file_identity']
                    elif case=='null':row['file_identity']=None
                    elif case=='short':row['file_identity']=identity[:-1]
                    elif case=='tuple':row['file_identity']=tuple(identity)
                    elif case=='boolean':identity[0]=True
                    elif case=='float':identity[0]=1.0
                    elif case=='negative':identity[0]=-1
                    elif case=='directory':identity[2]=0o040700
                    elif case=='oversize-mode':identity[2]=2**80
                    elif case=='wrong-size':identity[3]+=1
                    return row
                with self.subTest(case=case),mock.patch.object(M.OBS,'interpreter_observation',side_effect=malformed):
                    value,output=self.early_execute('physical-python-mismatch')
                    observed=value['interpreter_admission_failure']['observed']
                    self.assertEqual(observed['physical_status'],'available')
                    self.assertIsNone(observed['file_identity_sha256'])
                    self.assertEqual(value['failure'],dict(type='ValueError',reason='physical-python-mismatch'))
                    self.early_publish(value)

    def test_real_helper_missing_file_failure_and_unexpected_error_are_safe(self):
        with self.native_file_identity() as (selected,physical,pins):
            physical.unlink()
            value,output=self.early_execute('physical-python-mismatch')
            self.assertEqual(value['interpreter_admission_failure']['observed']['physical_status'],'unavailable')
            self.early_publish(value)
            physical.write_bytes(b'owned interpreter identity fixture')
            self.raw=self.root/'error-raw';self.public=self.root/'error-public'
            message='token=private-sensitive-value /unknown/private/path'
            with mock.patch.object(M.OBS,'interpreter_observation',side_effect=OSError(message)):
                value,output=self.early_execute('interpreter-admission-observation-failed')
                self.assertEqual(value['failure']['message_sha256'],hashlib.sha256(message.encode()).hexdigest())
                self.assertNotIn(message,output);self.early_publish(value,private=('private-sensitive-value',))

    def test_early_admission_missing_receipts_never_get_secondary_keyerror(self):
        with self.native_file_identity(),mock.patch.object(M.sys,'version_info',(3,14,8)):
            value,output=self.early_execute('native-python-version-mismatch')
            del value['interpreter_admission_failure'];self.write(self.raw/'results.json',value)
            with mock.patch.object(M.NORMALIZER,'package') as package, \
                 self.assertRaisesRegex(ValueError,'missing-interpreter-admission-failure-receipt'):
                M.publish(self.raw,self.public)
            package.assert_not_called()
            (self.raw/'setup/execute-status.json').unlink()
            with self.assertRaises(FileNotFoundError):M.publish(self.raw,self.public)

    def test_early_admission_nonzero_shell_status_is_preserved_and_zero_boolean_refuse_first(self):
        with self.native_file_identity(),mock.patch.object(M.sys,'version_info',(3,14,8)):
            value,output=self.early_execute('native-python-version-mismatch')
            for code in (0,False,1.0):
                self.write(self.raw/'setup/execute-status.json',dict(exit_code=code))
                with self.subTest(code=code),mock.patch.object(M,'inventory') as inventory, \
                     mock.patch.object(M.NORMALIZER,'package') as package, self.assertRaisesRegex(ValueError,
                        'incomplete-with-successful-exit' if type(code) is int else 'workflow-exit-schema'):
                    M.publish(self.raw,self.public)
                inventory.assert_not_called();package.assert_not_called()
            self.write(self.raw/'setup/execute-status.json',dict(exit_code=125))
            self.early_publish(value,exit_code=125)

    def test_early_admission_rehashed_cost_scope_and_shell_range_refuse_before_material_reads(self):
        with self.native_file_identity(),mock.patch.object(M.sys,'version_info',(3,14,8)):
            original,output=self.early_execute('native-python-version-mismatch')
            cases=[('full_caller_wall_seconds_before_receipt',value,'early-admission-caller-wall')
                   for value in (-1,-.01,True,False,None,'private-arbitrary-value',{})]
            cases.extend((field,value,'early-admission-scope-text')
                         for field in ('interpreter_scope','command_schedule','cost_scope')
                         for value in ('private-arbitrary-value',None,True,{}))
            cases.extend(('exit_code',value,'early-admission-exit-code') for value in (-1,256,2**80))
            for field,item,reason in cases:
                value=copy.deepcopy(original);code=1
                if field=='exit_code':code=item
                else:value[field]=item
                self.write(self.raw/'results.json',value);self.write(self.raw/'setup/execute-status.json',dict(exit_code=code))
                with self.subTest(field=field,item=item),mock.patch.object(M,'inventory') as inventory, \
                     mock.patch.object(M.NORMALIZER,'package') as package,self.assertRaisesRegex(ValueError,reason):
                    M.publish(self.raw,self.public)
                inventory.assert_not_called();package.assert_not_called()
            for wall in (float('nan'),float('inf'),-float('inf')):
                value=copy.deepcopy(original);value['full_caller_wall_seconds_before_receipt']=wall
                self.write(self.raw/'results.json',value);self.write(self.raw/'setup/execute-status.json',dict(exit_code=1))
                with self.subTest(wall=wall),mock.patch.object(M,'inventory') as inventory, \
                     mock.patch.object(M.NORMALIZER,'package') as package,self.assertRaisesRegex(ValueError,'Non-finite JSON value'):
                    M.publish(self.raw,self.public)
                inventory.assert_not_called();package.assert_not_called()

    def test_early_admission_rejects_later_checkpoint_records_membership_and_promotions(self):
        with self.native_file_identity(),mock.patch.object(M.sys,'version_info',(3,14,8)):
            original,output=self.early_execute('native-python-version-mismatch')
            changes=(dict(checkpoint='source-before'),dict(interpreter_before=self.interpreter),dict(source_after={}),
                     dict(command={}),dict(capability_result={}),dict(verification={}),dict(native_actor_launches=0),
                     dict(actual_launches=0),dict(cases=[]),dict(status='capability-only-complete'),
                     dict(timing_eligible=True),dict(descendant_closure_eligible=True),dict(final_protocol_ready=True))
            for change in changes:
                value=copy.deepcopy(original);value.update(change);self.write(self.raw/'results.json',value)
                with self.subTest(change=change),mock.patch.object(M.NORMALIZER,'package') as package, \
                     self.assertRaises(ValueError):M.publish(self.raw,self.public)
                package.assert_not_called()
            self.write(self.raw/'results.json',original);(self.raw/'setup/unexpected.json').write_text('{}')
            with self.assertRaisesRegex(ValueError,'early-admission-member-set'):M.publish(self.raw,self.public)
            original['original_files']=M.inventory(self.raw);self.write(self.raw/'results.json',original)
            with self.assertRaisesRegex(ValueError,'early-admission-member-set'):M.publish(self.raw,self.public)

    def test_early_admission_receipt_schema_rejects_rehashed_arbitrary_values(self):
        with self.native_file_identity(),mock.patch.object(M.sys,'version_info',(3,14,8)):
            original,output=self.early_execute('native-python-version-mismatch')
            changes=(('observed','python_version',[3,True,8]),('observed','platform','arbitrary-private-value'),
                     ('observed','bytes',True),('observed','selected_path_sha256','/private/arbitrary'),
                     ('checks','native-python-version-mismatch',True),('expected','python_version',[3,14,8]))
            for group,key,item in changes:
                value=copy.deepcopy(original);value['interpreter_admission_failure'][group][key]=item
                self.write(self.raw/'results.json',value)
                with self.subTest(group=group,key=key),mock.patch.object(M.NORMALIZER,'package') as package, \
                     self.assertRaises(ValueError):M.publish(self.raw,self.public)
                package.assert_not_called()

    def test_later_partial_missing_source_or_interpreter_receipt_cannot_use_early_branch(self):
        value,inner=self.complete_fixture();value.update(status='incomplete',checkpoint='source-after',
                                                       failure=dict(type='ValueError',reason='later refusal'))
        self.write(self.raw/'setup/execute-status.json',dict(exit_code=1))
        source=value.pop('source_before');self.write(self.raw/'results.json',value)
        with self.assertRaisesRegex(ValueError,'missing-source-before-outside-early-admission'):M.publish(self.raw,self.public)
        value['source_before']=source;del value['interpreter_before'];self.write(self.raw/'results.json',value)
        with self.assertRaisesRegex(ValueError,'missing-interpreter-before-receipt'):M.publish(self.raw,self.public)

    def test_unproved_ownership_reads_only_outer_receipt_and_never_shell_streams_or_scanner(self):
        original,inner=self.complete_fixture();real=M.source_bytes
        cases=((False,{},'writer-not-proved'),(True,dict(ownership_uncertain=True),'owned-child-not-proved'),
               (True,dict(cleanup_root_unfinished=True),'owned-child-not-proved'),
               (True,dict(observed_returncode=None),'owned-child-not-proved'),
               (True,dict(status='incomplete',observed_returncode=1),'capability-actor-cleanup-not-proved'))
        for stable,changes,reason in cases:
            value=copy.deepcopy(original);value.update(status='incomplete',stable_originals=stable)
            value['command'].update(changes);self.write(self.raw/'results.json',value)
            with self.subTest(stable=stable,changes=changes),mock.patch.object(M,'source_bytes',wraps=real) as reads, \
                 mock.patch.object(M,'inventory') as inventory,mock.patch.object(M.NORMALIZER,'package') as package, \
                 self.assertRaisesRegex(ValueError,reason):M.publish(self.raw,self.public)
            self.assertEqual(reads.call_args_list,[mock.call(self.raw/'results.json')])
            inventory.assert_not_called();package.assert_not_called()

    def test_unfinished_or_uncertain_child_prevents_inventory_and_publication(self):
        for changes in (dict(cleanup_root_unfinished=True),dict(ownership_uncertain=True),dict(status='incomplete',observed_returncode=1)):
            raw=self.root/('raw-'+str(len(list(self.root.iterdir()))))
            row=dict(status='completed-zero',cleanup_root_unfinished=False,cleanup_errors=[],ownership_uncertain=False,observed_returncode=0)
            row.update(changes)
            with mock.patch.object(M,'bind_interpreter',return_value=self.interpreter), \
                 mock.patch.object(M,'bind_sources',return_value={'files':{}}) as sources, \
                 mock.patch.object(M,'command',return_value=row),mock.patch.object(M,'inventory') as inventory:
                value=M.execute(raw,self.sha)
            self.assertEqual(sources.call_count,1);inventory.assert_not_called()
            self.assertFalse(value['stable_originals']);self.assertEqual(value['status'],'incomplete')
            self.write(raw/'setup/execute-status.json',dict(exit_code=1))
            with mock.patch.object(M,'inventory') as inventory,mock.patch.object(M.NORMALIZER,'package') as package:
                with self.assertRaisesRegex(ValueError,'writer-not-proved'):M.publish(raw,raw.with_name(raw.name+'-public'))
            inventory.assert_not_called();package.assert_not_called()

    def test_command_exception_without_receipt_keeps_material_reads_disabled(self):
        for failed in ('source','capability'):
            raw=self.root/failed
            with mock.patch.object(M,'bind_interpreter',return_value=self.interpreter), \
                 mock.patch.object(M,'bind_sources',side_effect=OSError('receipt close') if failed=='source' else None,return_value={'files':{}}), \
                 mock.patch.object(M,'command',side_effect=OSError('receipt close')),mock.patch.object(M,'inventory') as inventory:
                value=M.execute(raw,self.sha)
            inventory.assert_not_called();self.assertFalse(value['stable_originals'])
            self.assertEqual(value['failure']['type'],'OSError')
            self.write(raw/'setup/execute-status.json',dict(exit_code=125))
            with mock.patch.object(M,'inventory') as inventory,mock.patch.object(M.NORMALIZER,'package') as package:
                with self.assertRaisesRegex(ValueError,'writer-not-proved'):M.publish(raw,raw.with_name(raw.name+'-public'))
            inventory.assert_not_called();package.assert_not_called()

    def test_workflow_has_only_two_metadata_one_capability_children_and_fixed_no_install_route(self):
        source=(M.ROOT/'.github/workflows/waitid-capability.yml').read_text()
        self.assertIn('timeout-minutes: 5',source);self.assertIn('contents: read',source)
        self.assertIn('persist-credentials: false',source);self.assertIn('retention-days: 14',source)
        self.assertIn('status=$?',source);self.assertIn('exit "$status"',source);self.assertIn('set -o noclobber',source)
        self.assertNotIn('pip install',source);self.assertNotIn('workflow_call:',source)
        self.assertEqual(source.count('--source-sha "$SOURCE_SHA"'),1)
        self.assertIn('python3 Scripts/test-native-waitid-capability.py -v',source)
        self.assertNotIn("python3 -m unittest discover -s Scripts -p 'test-native-waitid-capability.py' -v",source)
        tree=ast.parse(Path(M.__file__).read_text());execute=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='execute')
        self.assertEqual(sum(isinstance(n,ast.Call) and isinstance(n.func,ast.Name) and n.func.id=='bind_sources' for n in ast.walk(execute)),2)
        self.assertEqual(sum(isinstance(n,ast.Call) and isinstance(n.func,ast.Name) and n.func.id=='command' for n in ast.walk(execute)),1)


if __name__=='__main__':unittest.main()
