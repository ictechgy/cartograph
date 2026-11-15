#!/usr/bin/env python3
"""Verify the Claude Code plugin declares the skill and the MCP server the CLI actually serves.

The repository root is the plugin root. Claude Code reads `.claude-plugin/plugin.json`, loads `.mcp.json`
at the plugin root first and then merges the manifest's `mcpServers`; a later server of the same name
replaces an earlier one (https://code.claude.com/docs/en/plugins-reference, "mcpServers"). Plugin MCP
configurations substitute `${CLAUDE_PROJECT_DIR}` in `command`, `args` and `env`
(https://code.claude.com/docs/en/mcp, "Plugin-provided MCP servers").
"""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = Path(".claude-plugin/plugin.json")
SKILLS = "./Skills"
# 플러그인은 바이너리를 담지 않는다. PATH 의 cartograph 를 이름으로 띄우고(Homebrew·릴리스 설치),
# 분석 루트는 Claude Code 가 연 프로젝트로 고정한다. 플러그인 MCP 서버의 작업 디렉터리는 문서에 없으므로
# README 예시의 `--project .` 대신 문서화된 `${CLAUDE_PROJECT_DIR}` 를 쓴다.
EXPECTED_SERVERS = {
    "cartograph": {
        "command": "cartograph",
        "args": ["serve", "--project", "${CLAUDE_PROJECT_DIR}"],
    }
}
# 소스 텍스트 경보선(tripwire)이다. 선언한 하위 명령과 옵션의 문자열이 CLI 소스에 남아 있는지만 grep 한다.
# 바이너리가 그 인자를 받는다는 증명은 아니다 — 그것은 verify-mcp.py 가 실제 바이너리를 이 선언 그대로 띄워
# 확인한다(macOS CI·릴리스 게이트). 이 경보선은 빌드 없이 첫 CI 잡과 Linux 에서도 돌아, 이름을 바꾼 PR 에
# 매니페스트를 함께 고치라고 일찍 알린다. 표기만 바꿔도 울릴 수 있고, 그때는 아래 문자열을 고친다.
CLI_FACTS = (
    ("Sources/cartograph/Serve.swift", 'commandName: "serve"', "the serve subcommand"),
    ("Sources/cartograph/Serve.swift", "@OptionGroup var options: GlobalOptions", "serve's global options"),
    ("Sources/cartograph/CartographCommand.swift", "ServeCommand.self", "the serve subcommand registration"),
    ("Sources/cartograph/GlobalOptions.swift", '.customLong("project")', "the --project option"),
)


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False)


def manifest_problems(root):
    """Return every reason the plugin at `root` does not declare what Claude Code needs, in a fixed order."""
    path = root / MANIFEST
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return [f"{MANIFEST} is missing"]
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        return [f"{MANIFEST} is not valid JSON: {error}"]
    if not isinstance(manifest, dict):
        return [f"{MANIFEST} must be a JSON object"]
    problems = []
    if manifest.get("skills") != SKILLS:
        problems.append(f"{MANIFEST} skills must be {SKILLS!r}, found {canonical(manifest.get('skills'))}")
    if not (root / SKILLS / "cartograph/SKILL.md").is_file():
        problems.append("Skills/cartograph/SKILL.md is missing")
    problems += server_problems(manifest.get("mcpServers"))
    problems += root_declaration_problems(root)
    problems += cli_source_tripwires(root)
    return problems


def root_declaration_problems(root):
    """Refuse a root `.mcp.json` that the plugin would ship.

    The plugin root is the repository root, so a tracked `.mcp.json` is also the project MCP configuration of
    everyone who opens this repository, and Claude Code merges it with the manifest, where a server of the same
    name replaces it. A second declaration would drift silently. An untracked file is not distributed.
    """
    declaration = root / ".mcp.json"
    try:
        listed = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--", ".mcp.json"],
                                capture_output=True, check=False)
    except FileNotFoundError:
        listed = None
    if listed is None or listed.returncode != 0:
        # 추적 여부를 알 수 없으면 있는 것만으로 거부한다. 모르는 것을 통과로 읽지 않는다.
        if declaration.exists():
            return ["cannot tell whether .mcp.json at the plugin root is tracked (not a git work tree); "
                    f"remove it and declare MCP servers only in {MANIFEST} mcpServers"]
        return []
    if listed.stdout:
        return [f".mcp.json at the plugin root is tracked; declare MCP servers only in {MANIFEST} mcpServers"]
    return []


def server_problems(servers):
    if servers is None:
        return [f"{MANIFEST} declares no mcpServers; the plugin would ship the skill without the MCP server"]
    if not isinstance(servers, dict):
        return [f"{MANIFEST} mcpServers must be an inline map of server name to config, found {canonical(servers)}"]
    problems = []
    for name in sorted(set(servers) | set(EXPECTED_SERVERS)):
        expected, actual = EXPECTED_SERVERS.get(name), servers.get(name)
        if expected is None:
            problems.append(f"{MANIFEST} mcpServers declares an unexpected server {name!r}")
        elif actual is None:
            problems.append(f"{MANIFEST} mcpServers is missing the {name!r} server")
        elif actual != expected:
            problems.append(f"{MANIFEST} mcpServers.{name} must be {canonical(expected)}, found {canonical(actual)}")
    return problems


def cli_source_tripwires(root):
    problems = []
    for relative, fact, meaning in CLI_FACTS:
        try:
            source = (root / relative).read_text(encoding="utf-8")
        except FileNotFoundError:
            problems.append(f"{relative} is missing; the source-text tripwire cannot find {meaning}")
            continue
        if fact not in source:
            problems.append(f"source-text tripwire: {relative} no longer contains {fact!r} ({meaning}); "
                            f"update {MANIFEST} mcpServers with the CLI, or this fact if only the spelling changed")
    return problems


class PluginManifestTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="cartograph-plugin-test-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        # 실제 파일을 복사해 고친다. 검사 대상과 다른 사본을 손으로 만들지 않는다.
        for relative in [str(MANIFEST), "Skills/cartograph/SKILL.md"] + [fact[0] for fact in CLI_FACTS]:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, target)

    def manifest(self):
        return json.loads((self.root / MANIFEST).read_text(encoding="utf-8"))

    def write_manifest(self, manifest):
        (self.root / MANIFEST).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    def assert_refused(self, fragment):
        problems = manifest_problems(self.root)
        self.assertTrue(any(fragment in problem for problem in problems), problems)

    def test_repository_plugin_declares_the_skill_and_the_server(self):
        self.assertEqual(manifest_problems(ROOT), [])
        self.assertEqual(manifest_problems(self.root), [])

    def test_unreadable_manifest_is_refused(self):
        (self.root / MANIFEST).write_text('{"name": "cartograph",', encoding="utf-8")
        self.assert_refused("is not valid JSON")
        (self.root / MANIFEST).write_text("[]", encoding="utf-8")
        self.assert_refused("must be a JSON object")
        (self.root / MANIFEST).unlink()
        self.assert_refused("is missing")

    def test_missing_server_declaration_is_refused(self):
        manifest = self.manifest()
        del manifest["mcpServers"]
        self.write_manifest(manifest)
        self.assert_refused("declares no mcpServers")

    def test_every_other_server_shape_is_refused(self):
        # 문서는 파일 경로·번들·배열도 받지만, 이 저장소는 한 파일의 인라인 선언 하나만 정본으로 둔다.
        server = EXPECTED_SERVERS["cartograph"]
        cases = (
            ({"cartograph": {**server, "command": "${CLAUDE_PLUGIN_ROOT}/bin/cartograph"}}, "mcpServers.cartograph"),
            ({"cartograph": {**server, "command": "/opt/homebrew/bin/cartograph"}}, "mcpServers.cartograph"),
            ({"cartograph": {**server, "args": ["mcp"]}}, "mcpServers.cartograph"),
            ({"cartograph": {**server, "args": ["serve"]}}, "mcpServers.cartograph"),
            ({"cartograph": {**server, "args": ["serve", "--project", "."]}}, "mcpServers.cartograph"),
            ({"cartograph": {**server, "env": {"PATH": "/usr/bin"}}}, "mcpServers.cartograph"),
            ({"swift": server}, "missing the 'cartograph' server"),
            ({**EXPECTED_SERVERS, "extra": server}, "unexpected server 'extra'"),
            ("./.mcp.json", "must be an inline map"),
            ([EXPECTED_SERVERS], "must be an inline map"),
        )
        for servers, fragment in cases:
            with self.subTest(servers=servers):
                self.write_manifest({**self.manifest(), "mcpServers": servers})
                self.assert_refused(fragment)

    def test_a_second_declaration_at_the_plugin_root_is_refused_only_when_tracked(self):
        # 플러그인은 GitHub 저장소에서 설치되므로 배포되는 것은 추적 파일이다. 기여자가 자기 작업 트리에
        # 둔 추적되지 않는 .mcp.json 은 플러그인에 실리지 않으므로 막지 않는다.
        subprocess.run(["git", "-c", "init.templateDir=", "init", "--quiet", str(self.root)], check=True)
        declaration = self.root / ".mcp.json"
        declaration.write_text(json.dumps({"mcpServers": EXPECTED_SERVERS}), encoding="utf-8")
        self.assertEqual(manifest_problems(self.root), [])
        subprocess.run(["git", "-C", str(self.root), "add", "--", ".mcp.json"], check=True)
        self.assert_refused(".mcp.json at the plugin root is tracked")

    def test_a_root_declaration_outside_a_git_work_tree_is_refused(self):
        # 추적 여부를 알 수 없으면 있는 것만으로 거부한다. 모르는 것을 통과로 읽지 않는다.
        (self.root / ".mcp.json").write_text(json.dumps({"mcpServers": EXPECTED_SERVERS}), encoding="utf-8")
        self.assert_refused("cannot tell whether .mcp.json at the plugin root is tracked")

    def test_the_skill_pointer_is_kept(self):
        self.write_manifest({**self.manifest(), "skills": "./skills"})
        self.assert_refused("skills must be './Skills'")
        self.write_manifest({**self.manifest(), "skills": SKILLS})
        (self.root / "Skills/cartograph/SKILL.md").unlink()
        self.assert_refused("Skills/cartograph/SKILL.md is missing")

    def test_cli_source_without_the_declared_subcommand_or_option_trips(self):
        for relative, fact, _ in CLI_FACTS:
            with self.subTest(fact=fact):
                path = self.root / relative
                original = path.read_text(encoding="utf-8")
                path.write_text(original.replace(fact, "/* renamed */"), encoding="utf-8")
                self.assert_refused(f"no longer contains {fact!r}")
                path.write_text(original, encoding="utf-8")
        self.assertEqual(manifest_problems(self.root), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
