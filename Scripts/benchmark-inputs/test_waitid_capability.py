#!/usr/bin/env python3
"""No actors: temporary files, injected handles and ledger/source checks only."""
import ast
import contextlib
import copy
import json
import os
from pathlib import Path
import signal
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock

import waitid_capability as M


def mock_native_primitives(module):
    """Pure mocks only: fill absent names, preserve available native objects, restore absence."""
    stack=contextlib.ExitStack()
    values=dict(P_PID=1,WEXITED=4,WNOWAIT=16777216,WNOHANG=1,CLD_EXITED=1,CLD_KILLED=2,CLD_DUMPED=3)
    def unavailable(*_args):raise OSError(38,'mock native primitive unavailable')
    values['waitid']=unavailable
    for name,value in values.items():
        if not hasattr(module,name):stack.enter_context(mock.patch.object(module,name,value,create=True))
    return stack


class CapabilityControls(unittest.TestCase):
    def setUp(self):
        self.native_mocks=mock_native_primitives(M.os);self.addCleanup(self.native_mocks.close)
        self.temp = tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def case(self):
        return M.OwnedCase(self.root, "authored", time.monotonic()+120, [0])

    def actor(self, case, pid=101, terminal=True):
        process = mock.Mock(pid=pid)
        process.wait.return_value = 0 if terminal else -signal.SIGKILL
        observed = dict(pid=pid, code=os.CLD_EXITED, status=0, signo=signal.SIGCHLD, expected_wait_returncode=0)
        row = dict(process=process,pid=pid,control=31,ready=32,started=time.monotonic(),
                   terminal=observed if terminal else None,reap_count=0,audit_finished_before_reap=False,signal_after_reap=False)
        case.actors.append(row)
        return row

    def test_mock_placeholders_preserve_available_primitives_and_restore_absence(self):
        native=lambda *args: None
        fake=SimpleNamespace(WEXITED=91,waitid=native)
        with mock_native_primitives(fake):
            self.assertIs(fake.waitid,native);self.assertEqual(fake.WEXITED,91)
            self.assertTrue(hasattr(fake,'WNOWAIT'))
        self.assertIs(fake.waitid,native);self.assertFalse(hasattr(fake,'WNOWAIT'))
        absent=SimpleNamespace()
        with mock_native_primitives(absent):self.assertTrue(callable(absent.waitid))
        self.assertFalse(hasattr(absent,'waitid'))
        with mock.patch.object(M,'os',absent),mock.patch.object(M.sys,'platform','darwin'), \
             self.assertRaisesRegex(M.CapabilityFailure,'native-waitid-unavailable'):
            M.api_admission()

    def test_exact_twelve_cases_thirteen_launches_and_fixed_subcases(self):
        self.assertEqual(M.CASES, (("native-api-admission",0),("normal-zero",1),("normal-seven",1),
            ("signal-exit",1),("timeout-then-term",1),("term-ignore-then-kill",1),("owned-pair-complete",2),
            ("root-exit-member-live",2),("owned-member-escape",2),("synchronized-fast-exits",2),
            ("injected-observation-refusals",0),("invalid-ledger-refusals",0)))
        self.assertEqual(sum(n for _,n in M.CASES),13)
        self.assertEqual((M.WATCHDOG_SECONDS,M.CASE_SECONDS,M.SUITE_SECONDS,M.OUTER_SECONDS),(5,10,120,150))
        self.assertEqual([row["name"] for row in M.injected_refusals()],list(M.OBSERVATION_NEGATIVES))
        self.assertEqual(M.invalid_ledgers(),list(M.LEDGER_NEGATIVES))

    def test_injected_refusal_controls_fail_if_target_operation_swallows_error(self):
        for name in ("observe_terminal", "enumerated_census", "require_owned_census"):
            with self.subTest(name=name),mock.patch.object(M,name,return_value=None), \
                 self.assertRaisesRegex(M.CapabilityFailure,"injected-refusal-missing"):
                M.injected_refusals()
        with mock.patch.object(M,"observe_terminal",side_effect=OSError(2,"wrong error")), \
             self.assertRaisesRegex(M.CapabilityFailure,"wrong-injected-os-refusal"):
            M.injected_refusals()

    def test_cleanup_required_cases_keep_incomplete_observation_status(self):
        for name,key,code in (("timeout-then-term","expected_observation_timeout",-signal.SIGTERM),
                              ("term-ignore-then-kill","expected_term_resistance",-signal.SIGKILL)):
            case=mock.Mock(name=name);case.name=name
            root=dict(pid=101);case.actors=[root];case.launch.return_value=root
            case.census.return_value=[dict(pid=101,process_group=101,session=100)]
            case.observe.side_effect=[M.ObservationTimeout("expected"),dict(expected_wait_returncode=code)]
            result=M.execute_case(case)
            self.assertTrue(result[key])
            self.assertTrue(result["observed_tree_status"].startswith("incomplete-"))

    def test_pair_cases_have_distinct_sequential_and_joint_release_traces(self):
        traces={}
        for name in ("owned-pair-complete","synchronized-fast-exits"):
            case=mock.Mock();case.name=name
            root,peer=dict(pid=101),dict(pid=102);case.actors=[root,peer]
            case.launch.side_effect=[root,peer]
            case.census.return_value=[dict(pid=101,process_group=101,session=100),dict(pid=102,process_group=101,session=100)]
            trace=[]
            case.send.side_effect=lambda actor,command: trace.append(("release",actor["pid"]))
            def observe(actor):
                trace.append(("observe",actor["pid"]))
                return dict(expected_wait_returncode=0)
            case.observe.side_effect=observe
            M.execute_case(case);traces[name]=trace
        self.assertEqual(traces["owned-pair-complete"],[("release",102),("observe",102),("release",101),("observe",101)])
        self.assertEqual(traces["synchronized-fast-exits"],[("release",102),("release",101),("observe",101),("observe",102)])

    def test_unsupported_admission_stops_before_launch_and_marks_all_later_cases(self):
        with mock.patch.object(M.sys,"platform","linux"), mock.patch.object(M.subprocess,"Popen") as launched:
            result=M.run(self.root/"evidence")
        launched.assert_not_called()
        self.assertEqual(result["actual_launches"],0)
        self.assertEqual(result["status"],"incomplete")
        self.assertEqual([r["status"] for r in result["cases"]],["incomplete"]+["not-started"]*11)
        self.assertTrue(result["capability_only"])
        for key in ("descendant_closure_eligible","timing_eligible","final_protocol_ready"):
            self.assertIs(result[key],False)
        self.assertEqual(json.loads((self.root/"evidence/results.json").read_text()),result)

    def test_missing_native_api_refuses_without_fallback(self):
        with mock.patch.object(M.sys,"platform","darwin"),mock.patch.object(M.os,"waitid",None):
            with self.assertRaisesRegex(M.CapabilityFailure,"native-waitid-unavailable"):
                M.api_admission()

    def test_terminal_normal_and_signal_status_agree_with_final_wait(self):
        for code,status,expected in ((os.CLD_EXITED,0,0),(os.CLD_EXITED,7,7),(os.CLD_KILLED,15,-15),(os.CLD_DUMPED,6,-6)):
            row=M.terminal(101,SimpleNamespace(si_pid=101,si_status=status,si_code=code,si_signo=signal.SIGCHLD))
            self.assertEqual(row["expected_wait_returncode"],expected)
            self.assertTrue(M.verify_ledger(dict(terminal=row,wait_returncode=expected,audit_finished_before_reap=True,
                                                signal_after_reap=False,reap_count=1)))
        for changes in (dict(si_pid=102),dict(si_pid=True),dict(si_status=True),dict(si_status=-1),
                        dict(si_code=999),dict(si_signo=signal.SIGTERM)):
            values=dict(si_pid=101,si_status=0,si_code=os.CLD_EXITED,si_signo=signal.SIGCHLD);values.update(changes)
            with self.subTest(changes=changes),self.assertRaises(M.CapabilityFailure):
                M.terminal(101,SimpleNamespace(**values))

    def test_blocking_observation_uses_wnowait_without_any_reap(self):
        case=self.case();row=self.actor(case,terminal=False)
        found=SimpleNamespace(si_pid=101,si_status=0,si_code=os.CLD_EXITED,si_signo=signal.SIGCHLD)
        with mock.patch.object(M.os,"waitid",return_value=found) as waitid, \
             mock.patch.object(M.signal,"signal"),mock.patch.object(M.signal,"setitimer"):
            result=case.observe(row)
        waitid.assert_called_once_with(os.P_PID,101,os.WEXITED|os.WNOWAIT)
        row["process"].wait.assert_not_called();row["process"].poll.assert_not_called()
        self.assertEqual(row["reap_count"],0)
        self.assertEqual(result["expected_wait_returncode"],0)

    def test_nonblocking_member_observation_and_errors_are_not_success(self):
        case=self.case();row=self.actor(case,terminal=False)
        with mock.patch.object(M.os,"waitid",return_value=None) as waitid, \
             mock.patch.object(M.signal,"signal"),mock.patch.object(M.signal,"setitimer"):
            self.assertIsNone(case.observe(row,nonblocking=True))
        waitid.assert_called_once_with(os.P_PID,101,os.WEXITED|os.WNOWAIT|os.WNOHANG)
        for error in (OSError("native refusal"),M.ObservationTimeout("deadline")):
            with mock.patch.object(M.os,"waitid",side_effect=error), \
                 mock.patch.object(M.signal,"signal"),mock.patch.object(M.signal,"setitimer"),self.assertRaises(type(error)):
                case.observe(row)
        self.assertIsNone(row["terminal"])
        row["process"].wait.assert_not_called()

    def test_deadline_prevents_launch_and_observation(self):
        case=self.case();case.deadline=time.monotonic()-1
        with mock.patch.object(M.subprocess,"Popen") as launch,self.assertRaisesRegex(M.CapabilityFailure,"case-deadline"):
            case.launch()
        launch.assert_not_called()
        row=self.actor(case,terminal=False)
        with mock.patch.object(M.os,"waitid") as waitid,mock.patch.object(M.signal,"signal"), \
             mock.patch.object(M.signal,"setitimer"),self.assertRaises(M.CapabilityFailure):
            case.observe(row)
        waitid.assert_not_called()

    def test_launch_registers_owned_handle_before_deferred_cancellation(self):
        case=self.case();process=mock.Mock(pid=101)
        def launch(*args,**kwargs):
            self.assertEqual(kwargs["process_group"],0)
            self.assertEqual(kwargs["pass_fds"],(11,14))
            self.assertNotIn("preexec_fn",kwargs)
            case.cancel(signal.SIGTERM,None)
            return process
        with mock.patch.object(M.os,"pipe",side_effect=[(11,12),(13,14)]),mock.patch.object(M.os,"close"), \
             mock.patch.object(M.subprocess,"Popen",side_effect=launch),mock.patch.object(case,"ack") as ready:
            with self.assertRaises(M.Cancelled):case.launch()
        ready.assert_not_called()
        self.assertIs(case.actors[0]["process"],process)
        self.assertEqual(case.launch_counter,[1])
        process.wait.assert_not_called();process.poll.assert_not_called()

    def test_launch_failure_closes_all_four_pipe_ends(self):
        case=self.case()
        with mock.patch.object(M.os,"pipe",side_effect=[(11,12),(13,14)]),mock.patch.object(M.os,"close") as closed, \
             mock.patch.object(M.subprocess,"Popen",side_effect=OSError("launch failed")):
            with self.assertRaises(OSError):case.launch()
        self.assertEqual({c.args[0] for c in closed.call_args_list},{11,12,13,14})
        self.assertFalse(case.actors)
        self.assertEqual(case.launch_counter,[0])

    def test_cleanup_closes_group_signals_before_first_reap(self):
        case=self.case();rows=[self.actor(case,pid=101),self.actor(case,pid=102)]
        for row in rows:
            def wait(*_args,**_kwargs):
                self.assertTrue(case.audit_finished)
                with self.assertRaises(M.CapabilityFailure):case.signal_group(signal.SIGTERM)
                return 0
            row["process"].wait.side_effect=wait
        with mock.patch.object(M.os,"close"),mock.patch.object(M.os,"killpg") as group, \
             mock.patch.object(M.os,"kill") as individual:
            result=case.finish()
        group.assert_not_called();individual.assert_not_called()
        self.assertEqual(result["unfinished"],[])
        for row in rows:self.assertTrue(M.verify_ledger(row))
        # A reused numeric group must not reopen signalling after the anchor was reaped.
        with mock.patch.object(M.os,"getpgid",return_value=101) as lookup, \
             mock.patch.object(M.os,"killpg") as reused_group, self.assertRaises(M.CapabilityFailure):
            case.signal_group(signal.SIGTERM)
        lookup.assert_not_called();reused_group.assert_not_called()

    def test_cleanup_uses_individual_handles_even_when_census_is_unavailable(self):
        case=self.case();row=self.actor(case,terminal=False)
        with mock.patch.object(case,"census",side_effect=AssertionError("must not be consulted")), \
             mock.patch.object(M.os,"getpgid",side_effect=AssertionError("must not be consulted")), \
             mock.patch.object(M.os,"close"),mock.patch.object(M.os,"kill") as kill:
            result=case.finish()
        kill.assert_called_once_with(101,signal.SIGKILL)
        row["process"].wait.assert_called_once()
        self.assertEqual(result["unfinished"],[])
        self.assertIsNone(row["terminal"])
        with self.assertRaises(M.CapabilityFailure):M.verify_ledger(row)

    def test_cleanup_failure_preserves_unfinished_identity(self):
        case=self.case();row=self.actor(case,terminal=False)
        row["process"].wait.side_effect=M.subprocess.TimeoutExpired("owned",2)
        with mock.patch.object(M.os,"close"),mock.patch.object(M.os,"kill",side_effect=PermissionError("denied")):
            result=case.finish()
        self.assertEqual([r["step"] for r in result["errors"]],["individual-kill","individual-reap"])
        self.assertEqual(result["unfinished"],[101])
        self.assertEqual(row["reap_count"],0)

    def test_actor_watchdog_precedes_readiness_and_survives_term_ignore(self):
        source=Path(M.__file__).read_text();tree=ast.parse(source)
        actor=next(node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name=="actor_main")
        calls=[node for node in ast.walk(actor) if isinstance(node,ast.Call)]
        alarms=[node for node in calls if isinstance(node.func,ast.Attribute) and node.func.attr=="alarm"]
        self.assertEqual(len(alarms),1)
        self.assertEqual(ast.unparse(alarms[0].args[0]),"WATCHDOG_SECONDS")
        self.assertLess(alarms[0].lineno,next(node.lineno for node in calls if isinstance(node.func,ast.Attribute) and node.func.attr=="write"))
        owned=next(node for node in tree.body if isinstance(node,ast.ClassDef) and node.name=="OwnedCase")
        prohibited={"poll","communicate","send_signal","terminate","kill","__del__"}
        for node in ast.walk(owned):
            if isinstance(node,ast.Call) and isinstance(node.func,ast.Attribute) and ast.unparse(node.func.value).endswith('[\'process\']'):
                self.assertNotIn(node.func.attr,prohibited)


if __name__ == "__main__":
    unittest.main()
