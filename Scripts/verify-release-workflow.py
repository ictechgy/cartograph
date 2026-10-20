#!/usr/bin/env python3
"""Execute the release workflow's actual shell offline; git and gh never reach a remote."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/release.yml"
SHA = "a" * 40
OTHER_SHA = "b" * 40
TAG_OBJECT = "c" * 40
VERSION = "0.26.0"
TAG_STEP = "Ensure the exact release tag after verification"
MAIN_STEP = "Require the release source on main"
MAIN_REF = "refs/remotes/origin/main"
# SHA로 고정한 checkout은 커밋 하나만 얕게 받아 origin/main이 없다. main까지 전체 이력을 받아 판정한다.
MAIN_FETCH = ["fetch", "--no-tags", "--unshallow", "origin", "+refs/heads/main:" + MAIN_REF]
# uses: 줄에서 참조만 뽑는다. 사람이 읽는 '# v7.0.1' 같은 버전 주석은 허용한다.
USES = re.compile(r"^[ \t]+(?:- )?uses:[ \t]*(\S+)[ \t]*(?:#.*)?$", re.MULTILINE)
PINNED_ACTION = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}")


def step(name):
    match = re.search(r"^      - name: " + re.escape(name) + r"\n(.*?)(?=^      - |\Z)",
                      WORKFLOW.read_text(), re.MULTILINE | re.DOTALL)
    if not match:
        raise AssertionError(f"Missing workflow step: {name}")
    return match.group(1)


def script(name):
    # 워크플로의 실제 셸을 추출한다. 복사한 구현을 테스트하지 않는다.
    lines = step(name).split("        run: |\n", 1)[1].splitlines(keepends=True)
    body = []
    for line in lines:
        if line.strip() and not line.startswith("          "):
            break
        body.append(line)
    return textwrap.dedent("".join(body))


MOCK = r'''import json
import os
from pathlib import Path
import sys

state_path = Path(os.environ["MOCK_STATE"])
state = json.loads(state_path.read_text())
command = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["MOCK_CALLS"], "a") as log:
    log.write(json.dumps({"command": command, "args": args,
                          "token": os.environ.get("GH_TOKEN", "")}) + "\n")

def save():
    state_path.write_text(json.dumps(state))

def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)

def error(message):
    # 실제 git은 판정이나 원격 읽기를 못 하면 1이 아니라 128로 끝난다.
    print(message, file=sys.stderr)
    sys.exit(128)

tag = "refs/tags/" + os.environ["VERSION"]
sha = os.environ["SOURCE_SHA"]
if command == "git":
    if args == ["rev-parse", "HEAD"]:
        print(state["head"])
    elif args == ["ls-remote", "--refs", "origin", tag]:
        if state.get("lookup_fail"):
            fail("mock remote lookup failed")
        if state["kind"] != "absent":
            print(state["tag_object"] if state["kind"] == "annotated" else state["tag_sha"], tag, sep="\t")
    elif args == ["fetch", "--no-tags", "--depth=1", "origin", tag]:
        if state.get("fetch_fail"):
            fail("mock fetch failed")
        if state["kind"] == "absent":
            fail("mock tag is absent")
        state["fetched"] = state.get("fetch_sha", state["tag_sha"])
        save()
    elif args == ["rev-parse", "FETCH_HEAD^{commit}"]:
        if state["kind"] == "blob":
            fail("mock tag does not peel to a commit")
        print(state["fetched"])
    elif args == ["status", "--porcelain", "--ignored", "--untracked-files=all"]:
        if state.get("status_fail"):
            fail("mock status failed")
        print(state.get("porcelain", ""), end="")
    elif args == ["fetch", "--no-tags", "--unshallow", "origin", "+refs/heads/main:refs/remotes/origin/main"]:
        if state.get("main_fetch_fail"):
            error("mock main fetch failed")
        state["main_fetched"] = True
        save()
    elif args[:2] == ["merge-base", "--is-ancestor"] and len(args) == 4:
        # 조상이면 0, 아니면 1, 판정할 수 없으면 128. origin/main은 받기 전에는 없다.
        commit, ref = args[2:]
        if state.get("merge_base_error") or ref != "refs/remotes/origin/main" or not state.get("main_fetched"):
            error("mock cannot resolve " + ref)
        if commit not in state["main"] + [state["head"]]:
            error("mock unknown commit " + repr(commit))
        sys.exit(0 if commit in state["main"] else 1)
    else:
        fail("Unrecognized git call: " + repr(args))
elif command == "gh":
    if args == ["api", "--method", "POST", "repos/" + os.environ["GITHUB_REPOSITORY"] + "/git/refs",
                "-f", "ref=" + tag, "-f", "sha=" + sha]:
        if state.get("create_race"):
            state.update(kind="lightweight", tag_sha="b" * 40)
            save()
            fail("mock conflicting tag appeared")
        if state.get("create_fail"):
            fail("mock create failed")
        if state["kind"] != "absent":
            fail("mock tag already exists")
        state.update(kind="lightweight", tag_sha=sha)
        save()
    elif args == ["release", "create", os.environ["VERSION"], os.environ["ARCHIVE"],
                  "--title", os.environ["VERSION"], "--notes-file", "notes.md", "--verify-tag"]:
        if state["kind"] == "absent":
            fail("mock release tag is absent")
        state["published"] = True
        save()
    else:
        fail("Unrecognized gh call: " + repr(args))
else:
    fail("Unrecognized mock executable")
'''


class ReleaseWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="cartograph-release-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        for name in ("git", "gh"):
            executable = bin_dir / name
            executable.write_text(f"#!{sys.executable}\n" + MOCK)
            executable.chmod(0o700)
        self.state_path = self.root / "state.json"
        self.calls_path = self.root / "calls.jsonl"
        self.calls_path.touch()
        self.env_path = self.root / "github-env"
        self.env_path.touch()
        self.source_path = self.root / "Sources/CartographCore/Cartograph.swift"
        self.source_path.parent.mkdir(parents=True)
        self.source_path.write_text(f'public static let version = "{VERSION}"\n')
        self.env = {
            **os.environ, "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
            "MOCK_STATE": str(self.state_path), "MOCK_CALLS": str(self.calls_path),
            "REQUESTED_SHA": SHA, "REQUESTED_TAG": VERSION, "GITHUB_SHA": SHA,
            "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
            "GITHUB_REF_NAME": "main", "GITHUB_ENV": str(self.env_path),
            "GITHUB_REPOSITORY": "ictechgy/cartograph", "VERSION": VERSION, "SOURCE_SHA": SHA,
            "GH_TOKEN": "offline-test-token", "ARCHIVE": f"cartograph-{VERSION}-macos-universal.tar.gz",
            "SHA256": "d" * 64,
        }
        self.reset_state()

    def reset_state(self, **changes):
        self.state_path.write_text(json.dumps({"head": SHA, "kind": "lightweight", "tag_sha": SHA,
                                              "tag_object": TAG_OBJECT, "main": [SHA], **changes}))
        self.calls_path.write_text("")

    def state(self):
        return json.loads(self.state_path.read_text())

    def calls(self):
        return [json.loads(line) for line in self.calls_path.read_text().splitlines()]

    def execute(self, name, **environment):
        return subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script(name)],
                              cwd=self.root, env={**self.env, **environment}, capture_output=True, text=True)

    def assert_passes(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_refuses(self, result, message=None):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("Unrecognized", result.stderr)
        if message:
            self.assertIn(message, result.stderr)
        self.assertFalse(self.state().get("published", False))

    def tag_then_release(self, **environment):
        result = self.execute(TAG_STEP, **environment)
        if result.returncode == 0:
            result = self.execute("Create the GitHub release", **environment)
        return result

    def test_manual_source_does_not_require_tag_before_checkout(self):
        workflow = WORKFLOW.read_text()
        self.assertRegex(workflow, r"source_sha:\n\s+description:.*\n\s+required: true\n\s+type: string")
        self.assertIn("ref: ${{ github.event.inputs.source_sha || github.sha }}", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertLess(workflow.index("Validate manual source input"), workflow.index("uses: actions/checkout"))
        self.assertIn("if: github.event_name == 'workflow_dispatch'", step("Validate manual source input"))

    def test_every_action_is_pinned_to_a_full_commit_sha(self):
        # 이 잡은 contents: write 토큰으로 게시한다. 태그가 옮겨져도 실행되는 액션 코드는 바뀌면 안 된다.
        workflow = WORKFLOW.read_text()
        references = USES.findall(workflow)
        self.assertTrue(references)
        self.assertEqual(len(references), len(re.findall(r"\buses\s*:", workflow)))
        for reference in references:
            with self.subTest(reference=reference):
                self.assertIsNotNone(PINNED_ACTION.fullmatch(reference), reference)

    def test_manual_input_accepts_only_exact_full_dispatch_sha(self):
        self.assert_passes(self.execute("Validate manual source input"))
        for value in ("", SHA[:12], "main", "g" * 40, SHA.upper(), SHA + "\n", OTHER_SHA):
            with self.subTest(source_sha=value):
                self.assert_refuses(self.execute("Validate manual source input", REQUESTED_SHA=value))
        self.assert_refuses(self.execute("Validate manual source input", GITHUB_SHA=OTHER_SHA))
        self.assertEqual(self.calls(), [])

    def test_resolve_accepts_manual_and_version_tag_push(self):
        self.assert_passes(self.execute("Resolve version"))
        self.assertEqual(self.env_path.read_text().splitlines(), [f"VERSION={VERSION}", f"SOURCE_SHA={SHA}"])
        self.env_path.write_text("")
        self.assert_passes(self.execute("Resolve version", GITHUB_EVENT_NAME="push", REQUESTED_TAG="",
                                      REQUESTED_SHA="", GITHUB_REF=f"refs/tags/{VERSION}", GITHUB_REF_NAME=VERSION))
        self.assertEqual(self.env_path.read_text().splitlines(), [f"VERSION={VERSION}", f"SOURCE_SHA={SHA}"])

    def test_resolve_refuses_bad_tag_source_event_and_version(self):
        cases = [{"REQUESTED_TAG": value} for value in ("", "v0.26.0", "0.26", "0.26.0-rc1", VERSION + "\n")]
        cases += [{"REQUESTED_SHA": value} for value in ("", SHA[:12], OTHER_SHA)]
        cases += [{"GITHUB_EVENT_NAME": "schedule"}, {"GITHUB_EVENT_NAME": "push"},
                  {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/tags/0.25.0"},
                  {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": f"refs/tags/{VERSION}", "GITHUB_SHA": OTHER_SHA}]
        for environment in cases:
            with self.subTest(environment=environment):
                self.assert_refuses(self.execute("Resolve version", **environment))
        self.reset_state(head=OTHER_SHA)
        self.assert_refuses(self.execute("Resolve version"), "Checked-out source")
        self.reset_state()
        self.source_path.write_text('public static let version = "0.25.0"\n')
        self.assert_refuses(self.execute("Resolve version"), "Cartograph.version")
        self.source_path.write_text("// missing declaration\n")
        self.assert_refuses(self.execute("Resolve version"))
        self.assertTrue(all(call["command"] == "git" for call in self.calls()))

    def test_resolve_refuses_a_changed_or_unreadable_checkout(self):
        # HEAD가 같아도 체크아웃 뒤에 바뀐 트리는 리뷰한 소스가 아니다. swift build가 읽는 무시 경로의 파일도
        # 거부하고, 걸린 경로를 로그에 남긴다. git이 실패해도 통과시키지 않는다.
        self.assert_passes(self.execute("Resolve version"))
        self.assertEqual([call["args"] for call in self.calls()],
                         [["rev-parse", "HEAD"], ["status", "--porcelain", "--ignored", "--untracked-files=all"]])
        for changes, message in (({"porcelain": " M Sources/CartographCore/Cartograph.swift\n"}, "local changes"),
                                 ({"porcelain": "?? Sources/Planted.swift\n"}, "local changes"),
                                 ({"porcelain": "!! .build/checkouts/swift-syntax/Sources/Planted.swift\n"
                                                "!! .swiftpm/configuration/mirrors.json\n"}, "local changes"),
                                 ({"status_fail": True}, "mock status failed")):
            with self.subTest(changes=changes):
                self.reset_state(**changes)
                self.env_path.write_text("")
                result = self.execute("Resolve version")
                self.assert_refuses(result, message)
                for line in changes.get("porcelain", "").splitlines():
                    self.assertIn(line, result.stderr)
                self.assertEqual(self.env_path.read_text(), "")
        # 걸린 경로는 앞 20줄만 보여 준다. 무시 디렉터리 하나가 로그를 덮지 않게 한다.
        self.reset_state(porcelain="".join(f"!! .build/File{index}.swift\n" for index in range(25)))
        result = self.execute("Resolve version")
        self.assert_refuses(result, "!! .build/File19.swift")
        self.assertNotIn("File20.swift", result.stderr)

    def test_release_source_must_be_on_main_for_both_triggers(self):
        # 리뷰를 거쳐 main에 머지된 커밋만 게시한다. 태그 push와 수동 실행 모두, 핫픽스 브랜치도 예외가 없다.
        # main의 끝이 아니어도 main 이력에 있으면 받아들이고, 없으면 원인과 해결 방향을 남기고 멈춘다.
        checks = [MAIN_FETCH, ["merge-base", "--is-ancestor", SHA, MAIN_REF]]
        for event in ("workflow_dispatch", "push"):
            for history, accepted in (([SHA], True), ([SHA, OTHER_SHA], True), ([OTHER_SHA], False)):
                with self.subTest(event=event, history=history):
                    self.reset_state(main=history)
                    result = self.execute(MAIN_STEP, GITHUB_EVENT_NAME=event)
                    if accepted:
                        self.assert_passes(result)
                    else:
                        self.assert_refuses(result, f"Release source {SHA} is not on main; merge the reviewed pull")
                    self.assertEqual([call["args"] for call in self.calls()], checks)

    def test_main_fetch_or_ancestry_failure_is_not_reported_as_off_main(self):
        # main을 받지 못하거나 git이 판정하지 못하면(128) '조상 아님'(1)과 다른 원인을 남기고 멈춘다.
        self.reset_state(main_fetch_fail=True)
        result = self.execute(MAIN_STEP)
        self.assert_refuses(result, "Could not fetch main")
        self.assertIn("mock main fetch failed", result.stderr)
        self.assertEqual([call["args"] for call in self.calls()], [MAIN_FETCH])
        for changes, environment in (({"merge_base_error": True}, {}), ({}, {"SOURCE_SHA": ""}),
                                     ({}, {"SOURCE_SHA": "e" * 40})):
            with self.subTest(changes=changes, environment=environment):
                self.reset_state(**changes)
                result = self.execute(MAIN_STEP, **environment)
                self.assert_refuses(result, "Could not check whether release source")
                self.assertIn("exited 128", result.stderr)
                self.assertNotIn("is not on main", result.stderr)

    def test_main_check_runs_for_every_trigger_before_any_build(self):
        # 조건 없이 돌아 두 트리거 모두를 막고, swift build가 체크아웃을 읽기 전에 끝난다. 토큰 없이 공개 이력을 읽는다.
        workflow = WORKFLOW.read_text()
        body = step(MAIN_STEP)
        self.assertNotRegex(body, r"(?m)^        (?:if|continue-on-error):")
        self.assertNotIn("TOKEN", body)
        before = workflow[:workflow.index("      - name: " + MAIN_STEP + "\n")].splitlines()
        commands = [line for line in before if not line.lstrip().startswith("#")]
        self.assertEqual([line for line in commands if re.search(r"\bswift\s+build\b", line)], [])
        # --unshallow는 얕은 checkout을 전제한다. checkout이 전체 이력을 받으면 git이 128로 거부한다.
        self.assertNotIn("fetch-depth", workflow)

    def test_absent_manual_tag_is_created_at_exact_sha_before_release(self):
        self.reset_state(kind="absent")
        self.assert_passes(self.tag_then_release())
        self.assertEqual(self.state()["tag_sha"], SHA)
        self.assertTrue(self.state()["published"])
        calls = self.calls()
        self.assertEqual([call["command"] for call in calls], ["git", "git", "gh", "git", "git", "gh"])
        self.assertEqual(calls[2]["args"], ["api", "--method", "POST", "repos/ictechgy/cartograph/git/refs",
                                          "-f", f"ref=refs/tags/{VERSION}", "-f", f"sha={SHA}"])
        self.assertEqual(calls[2]["token"], "offline-test-token")
        self.assertIn("--verify-tag", calls[-1]["args"])

    def test_existing_lightweight_and_annotated_tags_are_never_written(self):
        for kind in ("lightweight", "annotated"):
            for event in ("workflow_dispatch", "push"):
                with self.subTest(kind=kind, event=event):
                    self.reset_state(kind=kind)
                    self.assert_passes(self.tag_then_release(GITHUB_EVENT_NAME=event))
                    self.assertEqual(self.state()["tag_sha"], SHA)
                    self.assertEqual(self.state()["kind"], kind)
                    self.assertEqual([call["args"][0] for call in self.calls() if call["command"] == "gh"], ["release"])

    def test_different_commit_and_noncommit_tags_refuse_without_movement(self):
        for kind, commit in (("lightweight", OTHER_SHA), ("annotated", OTHER_SHA), ("blob", SHA)):
            with self.subTest(kind=kind):
                self.reset_state(kind=kind, tag_sha=commit)
                self.assert_refuses(self.tag_then_release(), "Release tag points to a different commit")
                self.assertEqual(self.state()["tag_sha"], commit)
                self.assertFalse(any(call["command"] == "gh" for call in self.calls()))

    def test_missing_push_tag_and_changed_head_refuse_before_creation(self):
        self.reset_state(kind="absent")
        self.assert_refuses(self.tag_then_release(GITHUB_EVENT_NAME="push"), "refusing to recreate")
        self.assertEqual(self.state()["kind"], "absent")
        self.assertFalse(any(call["command"] == "gh" for call in self.calls()))
        self.reset_state(head=OTHER_SHA, kind="absent")
        self.assert_refuses(self.tag_then_release())
        self.assertEqual([call["args"] for call in self.calls()], [["rev-parse", "HEAD"]])

    def test_lookup_creation_fetch_and_race_failures_are_terminal(self):
        for changes, message, creations in (
            ({"kind": "absent", "lookup_fail": True}, "mock remote lookup failed", 0),
            ({"kind": "absent", "create_fail": True}, "mock create failed", 1),
            ({"kind": "absent", "create_race": True}, "mock conflicting tag appeared", 1),
            ({"fetch_fail": True}, "mock fetch failed", 0),
            ({"kind": "absent", "fetch_fail": True}, "mock fetch failed", 1),
            ({"fetch_sha": OTHER_SHA}, "Release tag points to a different commit", 0),
        ):
            with self.subTest(changes=changes):
                self.reset_state(**changes)
                self.assert_refuses(self.tag_then_release(), message)
                writes = [call for call in self.calls() if call["command"] == "gh"]
                self.assertEqual(len(writes), creations)
                self.assertTrue(all(call["args"][:3] == ["api", "--method", "POST"] for call in writes))
                if changes.get("create_race"):
                    self.assertEqual(self.state()["tag_sha"], OTHER_SHA)
                    self.assertFalse(any(call["args"][0] == "fetch" for call in self.calls()))

    def test_gate_order_tokens_and_no_force_are_preserved(self):
        workflow = WORKFLOW.read_text()
        names = ["Resolve version", MAIN_STEP, "Build universal binary", "Package", "Verify the packaged binary",
                 TAG_STEP, "Create the GitHub release", "Update the Homebrew tap"]
        positions = [workflow.index("      - name: " + name + "\n") for name in names]
        self.assertEqual(positions, sorted(positions))
        for name in (TAG_STEP, "Create the GitHub release"):
            self.assertIn("          GH_TOKEN: ${{ github.token }}", step(name))
            self.assertNotRegex(step(name), r"(?m)^        if:")
        self.assertEqual(workflow.count("GH_TOKEN:"), 2)
        self.assertNotIn("HOMEBREW_TAP_TOKEN", step(TAG_STEP))
        self.assertNotRegex(script(TAG_STEP), r"--force|git\s+(?:push|tag|update-ref)|--method\s+(?:PATCH|DELETE)")
        self.assertIn('gh release create "$VERSION" "$ARCHIVE" --title "$VERSION" --notes-file notes.md --verify-tag',
                      script("Create the GitHub release"))
        self.assertIn('tags: ["[0-9]+.[0-9]+.[0-9]+"]', workflow)
        self.assertIn("cancel-in-progress: false", workflow)
        gate = script("Verify the packaged binary")
        for check in ("verify-cli-contract.sh", "verify-fixtures.sh", "verify-analysis-blindspots.py",
                      "verify-change-impact.py", "verify-runtime-contracts.py", "verify-runtime-discovery.py",
                      "verify-runtime-keypaths.py", "verify-runtime-registry.py", "verify-coredata-versions.py",
                      "verify-coredata-build-evidence.py", "verify-runtime-collection.py", "verify-runtime-window.py",
                      "verify-mcp.py"):
            self.assertIn(check, gate)
        self.assertIn('-verify_arch arm64', gate)
        self.assertIn('-verify_arch x86_64', gate)
        self.assertIn('cmp docs/QUERY-EVIDENCE.md', gate)
        self.assertIn('cp docs/QUERY-EVIDENCE.md docs/ENUM-CHANGE-REVIEW.md dist/cartograph/docs/',
                      script("Package"))
        self.assertIn('test -s "$RUNNER_TEMP/cartograph/docs/ENUM-CHANGE-REVIEW.md"', gate)
        self.assertIn('cmp docs/ENUM-CHANGE-REVIEW.md "$RUNNER_TEMP/cartograph/docs/ENUM-CHANGE-REVIEW.md"', gate)
        self.assertIn('python3 Scripts/verify-change-impact.py --cartograph "$RUNNER_TEMP/cartograph/cartograph"',
                      gate)


if __name__ == "__main__":
    unittest.main(verbosity=2)
