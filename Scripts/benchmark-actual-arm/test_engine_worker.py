"""독립 선택자 계약과 중단 코드를 엔진 진입점 경계에서 확인한다."""

import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import engine_worker as worker

current = worker
primitive = worker.primitive
adapter = worker.adapter
ROOT = Path(__file__).resolve().parent


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.queries = [dict(id=f"q{i}", context="module", signature=f"f{i}()", max_depth=5) for i in range(10)]

    def test_distinct_semantic_queries_pass(self):
        worker.selectors(self.queries)

    def test_duplicate_semantic_seed_is_not_hidden_by_distinct_id(self):
        self.queries[1]["signature"] = self.queries[0]["signature"]
        with self.assertRaises(ValueError):
            worker.selectors(self.queries)

    def test_gold_and_oracle_query_fields_refuse(self):
        for key in ("expected", "oracle", "answers"):
            queries = json.loads(json.dumps(self.queries))
            queries[0][key] = []
            with self.assertRaises(ValueError):
                worker.selectors(queries)

    def test_boolean_depth_and_mixed_depth_refuse(self):
        for value in (True, 3):
            queries = json.loads(json.dumps(self.queries))
            queries[0]["max_depth"] = value
            with self.assertRaises(ValueError):
                worker.selectors(queries)

    def test_input_hash_refusal_happens_before_guard_or_engine(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "input.json"
            path.write_text(json.dumps(dict(queries=self.queries)))
            with mock.patch.object(worker.primitive.generation, "verify") as guard:
                with self.assertRaises(ValueError):
                    worker.execute(path, "0" * 64)
                guard.assert_not_called()

    def test_incomplete_worker_preserves125(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "input.json"
            path.write_text(json.dumps(dict(queries=self.queries)))
            with mock.patch.object(worker.primitive.generation, "verify"), mock.patch.object(
                worker.primitive, "execute_worker", return_value=dict(status="incomplete")
            ):
                self.assertEqual(worker.execute(path, hashlib.sha256(path.read_bytes()).hexdigest()), 125)


    def test_current_baseline_override_is_scoped_and_restored(self):
        for arm in ("baseline", "cartograph"):
            with self.subTest(arm=arm), tempfile.TemporaryDirectory() as root:
                path = Path(root) / "input.json"
                path.write_text(json.dumps(dict(queries=self.queries, arm=arm)))
                original = worker.primitive.baseline_discovery
                def execute(config):
                    selected = worker.discover if arm == "baseline" else original
                    self.assertIs(worker.primitive.baseline_discovery, selected)
                    return dict(status="ok")
                with mock.patch.object(worker.primitive.generation, "verify"), mock.patch.object(
                    worker.primitive, "execute_worker", side_effect=execute
                ):
                    self.assertEqual(worker.execute(path, hashlib.sha256(path.read_bytes()).hexdigest()), 0)
                self.assertIs(worker.primitive.baseline_discovery, original)

    def test_current_baseline_override_restores_after_failure(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "input.json"
            path.write_text(json.dumps(dict(queries=self.queries, arm="baseline")))
            original = worker.primitive.baseline_discovery
            with mock.patch.object(worker.primitive.generation, "verify"), mock.patch.object(
                worker.primitive, "execute_worker", side_effect=RuntimeError("synthetic failure")
            ):
                with self.assertRaisesRegex(RuntimeError, "synthetic failure"):
                    worker.execute(path, hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertIs(worker.primitive.baseline_discovery, original)


class Recorder:
    def __init__(self, root, texts):
        self.root = root
        self.texts = texts
        self.names = []

    def capture(self, command, cwd, name):
        self.names.append(name)
        return self.texts[name]


class FileDependencyCoverageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.project = self.root / "Project"
        self.source = "Sources/BridgeKit/Core.m"
        self.umbrella = "Sources/BridgeKit/include/BridgeKit.h"
        self.headers = ["Sources/BridgeKit/include/CGCore.h", "Sources/BridgeKit/include/CGQuoteEngine.h"]
        self.contents = {
            self.source: "int f(int x) { return x; }\nint g(int x) { return x; }\n",
            self.umbrella: '#include "CGCore.h"\n#import "CGQuoteEngine.h"\n',
            self.headers[0]: "int f(int x);\n",
            self.headers[1]: "int g(int x);\n",
        }
        for relative, text in self.contents.items():
            path = self.project / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.config = dict(
            project=str(self.project),
            store=str(self.root / "IndexStore"),
            contexts={path: ["BridgeKit"] for path in self.contents},
            accepted_sources={},
            index_dump="index-dump",
            library="libIndexStore",
            expected_outputs=[dict(
                output=str(self.root / "Core.o"), source=str(self.project / self.source),
                module="", provider="clang", target="arm64-apple-ios16.0-simulator",
                sysroot=str(self.root / "SDK"),
                project_headers=[str(self.project / path) for path in [self.umbrella, *self.headers]],
            )],
        )
        self.seal()
        self.units = {
            "main": self.unit("main", main=True),
            "module": self.unit("module", main=False),
        }
        self.units["main"]["dependencies"] = [
            dict(kind="Unit", scope="user", module="BridgeKit", path=str(self.root / "BridgeKit.pcm"), name="module"),
            self.dependency("Record", self.source, "main-record"),
        ]
        self.units["module"]["dependencies"] = [
            self.dependency("Record", self.headers[0], "f-record"),
            self.dependency("Record", self.headers[1], "g-record"),
            self.dependency("File", self.umbrella, None, "BridgeKit"),
        ]
        store = Path(self.config["store"]) / "v5/units"
        store.mkdir(parents=True)
        for name in self.units:
            (store / name).touch()
        self.catalog = adapter.source_catalog(self.project, self.config["contexts"])

    def seal(self):
        self.config["accepted_sources"] = primitive.source_snapshot(self.project)

    def unit(self, name, main):
        metadata = {key: "" for key in adapter.UNIT_FIELDS}
        metadata.update({
            "Module": "" if main else "BridgeKit",
            "Has Main File": "true" if main else "false",
            "Main File": str(self.project / self.source) if main else "",
            "Output File": str(self.root / ("Core.o" if main else "BridgeKit.pcm")),
            "Target": "arm64-apple-ios16.0-simulator", "Sysroot": str(self.root / "SDK"),
            "Working Directory": str(self.project), "Provider Identifier": "clang",
            "Is System": "false", "Is Module": "false" if main else "true", "Is Debug": "true",
        })
        return dict(name=name, metadata=metadata, dependencies=[], includes=[])

    def dependency(self, kind, relative, name, module=""):
        return dict(kind=kind, scope="user", module=module, path=str(self.project / relative), name=name)

    def selection(self):
        return adapter.select_units(self.units, self.config["expected_outputs"])

    def coverage(self, selected=None):
        selected = self.selection() if selected is None else selected
        covered = {adapter.relative_path(self.project, row["absolute_path"]) for row in selected["records"]}
        return current.file_only_coverage(self.config, self.catalog, self.units, selected, covered)

    def recorder(self, label):
        texts = {}
        for name, unit in self.units.items():
            rows = [f"{key}: {value}" for key, value in unit["metadata"].items()]
            rows.append("Dependencies:")
            for row in unit["dependencies"]:
                rows.append(" | ".join(str(row[key]) for key in ("kind", "scope", "module", "path", "name")
                                       if row[key] not in ("", None)))
            texts["units/" + name] = "\n".join(rows) + "\n"
        texts["records/main-record"] = (
            "Symbols:\nf | function | f-usr | definition\ng | function | g-usr | definition\n"
            "Occurrences:\n1:5 | f | function | f-usr | definition\n2:5 | g | function | g-usr | definition\n"
        )
        for name, symbol in [("f-record", "f"), ("g-record", "g")]:
            texts["records/" + name] = (
                f"Symbols:\n{symbol} | function | {symbol}-usr | declaration\n"
                f"Occurrences:\n1:5 | {symbol} | function | {symbol}-usr | declaration\n"
            )
        return Recorder(self.root / label, texts)

    def test_exact_fixture_umbrella_has_sealed_record_backed_includes(self):
        fixture = ROOT.parents[1] / "Fixtures/IndexStoreCLIBenchmark/mixed-ios-validation/fixture"
        for path in [self.umbrella, *self.headers]:
            (self.project / path).write_bytes((fixture / path).read_bytes())
        self.seal()
        self.catalog = adapter.source_catalog(self.project, self.config["contexts"])
        evidence = self.coverage()
        self.assertEqual(evidence, [dict(
            path=self.umbrella, sha256=hashlib.sha256((self.project / self.umbrella).read_bytes()).hexdigest(),
            includes=self.headers, unit="module", root_units=["main"],
            coverage="file-dependency-only-without-callable-declarations",
        )])

    def test_frozen_red_current_green_preserves_records_without_fabrication(self):
        with self.assertRaisesRegex(ValueError, "Active record/source manifest mismatch"):
            primitive.baseline_discovery(self.config, self.catalog, self.recorder("frozen"))
        recorder = self.recorder("current")
        graph = current.discover(self.config, self.catalog, recorder)
        self.assertEqual(len(graph["bindings"]), 2)
        self.assertEqual(graph["unresolved"], [])
        provenance = json.loads((recorder.root / "provenance.json").read_text())
        self.assertEqual(provenance["adapter_version"], current.ADAPTER_VERSION)
        self.assertEqual(len(provenance["active_records"]), 3)
        self.assertFalse(any(row["absolute_path"].endswith("/BridgeKit.h") for row in provenance["active_records"]))
        self.assertEqual([row["path"] for row in provenance["file_only_headers"]], [self.umbrella])
        self.assertEqual(sorted(name for name in recorder.names if name.startswith("records/")),
                         ["records/f-record", "records/g-record", "records/main-record"])

    def test_existing_path_without_file_dependency_refuses(self):
        self.units["module"]["dependencies"].pop()
        with self.assertRaisesRegex(ValueError, "dependency is missing"):
            self.coverage()

    def test_orphan_module_file_does_not_supply_active_coverage(self):
        self.units["main"]["dependencies"].pop(0)
        with self.assertRaises(ValueError):
            self.coverage()

    def test_include_without_record_refuses_even_if_file_dependency_exists(self):
        selected = self.selection()
        selected["records"] = [row for row in selected["records"] if row["name"] != "f-record"]
        covered = set(self.config["contexts"]) - {self.umbrella}
        with self.assertRaisesRegex(ValueError, "same-unit Record"):
            current.file_only_coverage(self.config, self.catalog, self.units, selected, covered)

    def test_record_in_different_unit_is_not_equivalent(self):
        selected = self.selection()
        selected["records"][1]["unit"] = "main"
        with self.assertRaisesRegex(ValueError, "same-unit Record"):
            self.coverage(selected)

    def test_each_active_root_requires_its_own_record_witness(self):
        self.units["main2"] = copy.deepcopy(self.units["main"])
        self.units["main2"]["metadata"]["Output File"] = str(self.root / "Core2.o")
        self.config["expected_outputs"].append(dict(self.config["expected_outputs"][0], output=str(self.root / "Core2.o")))
        selected = self.selection()
        target = next(row for row in selected["records"] if row["name"] == "f-record")
        target["root_units"].remove("main2")
        with self.assertRaisesRegex(ValueError, "every active root"):
            self.coverage(selected)

    def test_system_file_dependency_refuses(self):
        self.units["module"]["dependencies"][-1]["scope"] = "system"
        with self.assertRaisesRegex(ValueError, "active user Clang"):
            self.coverage()

    def test_module_context_and_root_provenance_must_be_exact(self):
        selected = self.selection()
        changes = [("Module", "Wrong"), ("Provider Identifier", "swift"), ("Is System", "true"),
                   ("Is Module", "false"), ("Has Main File", "true")]
        for key, value in changes:
            with self.subTest(key=key):
                original = self.units["module"]["metadata"][key]
                self.units["module"]["metadata"][key] = value
                with self.assertRaises(ValueError):
                    self.coverage(selected)
                self.units["module"]["metadata"][key] = original
        for roots in [[], ["unknown"], ["main", "main"]]:
            with self.subTest(roots=roots):
                changed = copy.deepcopy(selected)
                changed["files"][0]["root_units"] = roots
                with self.assertRaises(ValueError):
                    self.coverage(changed)

    def test_target_and_sdk_must_match_each_accepted_root(self):
        for key, value in [("Target", "arm64-apple-ios16.0"), ("Sysroot", str(self.root / "WrongSDK"))]:
            with self.subTest(key=key):
                selected = self.selection()
                old = self.units["module"]["metadata"][key]
                self.units["module"]["metadata"][key] = value
                with self.assertRaisesRegex(ValueError, "target or SDK"):
                    self.coverage(selected)
                self.units["module"]["metadata"][key] = old

    def test_changed_umbrella_bytes_are_not_accepted(self):
        (self.project / self.umbrella).write_text('#include "CGCore.h"\n')
        with self.assertRaisesRegex(ValueError, "accepted bytes"):
            self.coverage()

    def test_absolute_escaping_unknown_and_duplicate_includes_refuse(self):
        for spelling in ["/CGCore.h", "../CGCore.h", "./CGCore.h", "Missing.h", "CGCore.h\"\n#include \"CGCore.h"]:
            with self.subTest(spelling=spelling):
                (self.project / self.umbrella).write_text(f'#include "{spelling}"\n')
                self.seal()
                with self.assertRaises(ValueError):
                    self.coverage()

    def test_conditional_macro_declaration_and_body_text_refuse_even_if_sealed(self):
        for added in ["#if YES\n#endif\n", "#define X 1\n", "int hidden(void);\n", "void hidden() {}\n",
                      "#include <CGCore.h>\n", "#include HEADER\n", "/* declaration */\n"]:
            with self.subTest(added=added):
                (self.project / self.umbrella).write_text(self.contents[self.umbrella] + added)
                self.seal()
                with self.assertRaisesRegex(ValueError, "exclusively quoted"):
                    self.coverage()

    def test_catalog_declaration_prevents_file_only_coverage(self):
        self.catalog.append(dict(path=self.umbrella))
        with self.assertRaisesRegex(ValueError, "without source declarations"):
            self.coverage()

    def test_declaration_bearing_missing_header_record_remains_strict(self):
        self.units["module"]["dependencies"].pop(0)
        selected = self.selection()
        covered = set(self.config["contexts"]) - {self.headers[0]}
        with self.assertRaisesRegex(ValueError, "without source declarations"):
            current.file_only_coverage(self.config, self.catalog, self.units, selected, covered)

    def test_undeclared_and_deleted_dependencies_remain_strict(self):
        self.units["module"]["dependencies"].append(self.dependency("File", "Sources/Unknown.h", None, "BridgeKit"))
        with self.assertRaisesRegex(ValueError, "deleted/undeclared"):
            current.discover(self.config, self.catalog, self.recorder("unknown"))
        self.units["module"]["dependencies"].pop()
        (self.project / self.headers[0]).unlink()
        with self.assertRaisesRegex(ValueError, "unknown/deleted"):
            current.discover(self.config, self.catalog, self.recorder("deleted"))

    def test_ambiguous_file_or_record_dependency_refuses(self):
        for key in ["files", "records"]:
            with self.subTest(key=key):
                selected = self.selection()
                row = selected[key][0] if key == "files" else next(r for r in selected[key] if r["name"] == "f-record")
                selected[key].append(copy.deepcopy(row))
                with self.assertRaises(ValueError):
                    self.coverage(selected)

    def test_main_source_still_requires_a_record(self):
        self.units["main"]["dependencies"].pop()
        with self.assertRaisesRegex(ValueError, "header without source declarations"):
            current.discover(self.config, self.catalog, self.recorder("missing-main"))

    def test_changed_deleted_or_aliased_include_target_refuses(self):
        target = self.project / self.headers[0]
        target.write_text("int changed(void);\n")
        with self.assertRaisesRegex(ValueError, "accepted bytes"):
            self.coverage()
        target.unlink()
        with self.assertRaisesRegex(ValueError, "missing or aliased"):
            self.coverage()
        target.symlink_to(self.project / self.headers[1])
        with self.assertRaisesRegex(ValueError, "missing or aliased"):
            self.coverage()

    def test_empty_header_and_unreachable_unit_refuse(self):
        (self.project / self.umbrella).write_text("\n")
        self.seal()
        with self.assertRaisesRegex(ValueError, "no independently witnessed includes"):
            self.coverage()
        (self.project / self.umbrella).write_text(self.contents[self.umbrella])
        self.seal()
        selected = self.selection()
        selected["reachable_units"].remove("module")
        with self.assertRaisesRegex(ValueError, "active user Clang"):
            self.coverage(selected)


if __name__ == "__main__":
    unittest.main(verbosity=2)
