#!/usr/bin/env python3
"""Owned mocks and temporary evidence only; never launch capability actors."""
import ast
import contextlib
import copy
import errno
import hashlib
import importlib.util
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
        self.interpreter=dict(M.PYTHON,status='available',file_identity=[1,2,3,34640,5,6],wall_seconds=.001)

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
                               argv=[M.PYTHON['selected_path'],'-I','-S','-B',str(M.HELPER),'--actor','11','14','1' if name=='term-ignore-then-kill' else '0'])
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
        command=self.command_record('capability-command',[M.PYTHON['selected_path'],'-I','-S','-B',str(M.HELPER),'--output',str(self.raw/'runs/capability')],150)
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
        self.complete_fixture();changed=copy.deepcopy(self.interpreter);changed['file_identity'][1]+=1
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
                    else: self.interpreter['file_identity'][1]+=1
                    return manifest
                with mock.patch.object(M,'bind_interpreter',side_effect=lambda:copy.deepcopy(self.interpreter)),mock.patch.object(M.NORMALIZER,'package',side_effect=publish):
                    with self.assertRaises(ValueError):M.publish(self.raw,self.public)
                if mode=='source':self.interpreter['file_identity'][1]-=1

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
