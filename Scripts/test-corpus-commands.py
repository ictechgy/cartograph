#!/usr/bin/env python3
"""Keep corpus comparison strict while normalizing host-specific paths."""

import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path, PurePosixPath
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "corpus_commands", Path(__file__).with_name("verify-corpus-commands.py"))
CORPUS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CORPUS)
FIXTURE = Path(__file__).resolve().parents[1] / "Fixtures/FalsePositiveCorpus"


class CorpusComparisonTests(unittest.TestCase):
    def test_only_project_build_host_triples_are_normalized(self):
        fixture = PurePosixPath("/fixture")
        for arch in ("arm64", "x86_64"):
            value = f'/fixture/.build/{arch}-apple-macosx/debug/index/store'
            self.assertEqual(CORPUS.normalize(value, fixture), '<project>/.build/<triple>/debug/index/store')
        for value in ('/other/.build/arm64-apple-macosx/debug/index/store',
                      '/fixture/Sources/arm64-apple-macosx/value.swift',
                      '/fixture/.build/aarch64-unknown-linux-gnu/debug/index/store'):
            self.assertEqual(CORPUS.normalize(value, fixture), value.replace('/fixture', '<project>'))

    def test_new_limitations_are_present_in_every_affected_and_fix_golden(self):
        for name in ('expected-fix.json', 'expected-affected.json',
                     'expected-affected-changed.json', 'expected-affected-empty.json'):
            document = json.loads((FIXTURE / name).read_text(encoding='utf-8'))
            prefixes = [note.split(':', 1)[0] for note in document['limitations']]
            for required in ('index-selection', 'build-module-coverage',
                             'unknown-clang-module', 'unindexed-sources'):
                self.assertEqual(prefixes.count(required), 1, (name, required))

    def test_full_golden_comparison_rejects_lost_or_changed_unknown_evidence(self):
        expected = json.loads((FIXTURE / 'expected-fix.json').read_text(encoding='utf-8'))
        with tempfile.TemporaryDirectory(prefix='corpus-comparison-') as directory:
            fixture = Path(directory)
            (fixture / 'golden.json').write_text(
                json.dumps(expected, indent=2, sort_keys=True, ensure_ascii=False) + '\n', encoding='utf-8')
            with contextlib.redirect_stdout(io.StringIO()):
                CORPUS.compare(fixture, 'golden.json', expected)
            variants = []
            for i, note in enumerate(expected['limitations']):
                missing = copy.deepcopy(expected)
                missing['limitations'].pop(i)
                variants.append(missing)
                if note.startswith(('unknown-clang-module:', 'unindexed-sources:')):
                    changed = copy.deepcopy(expected)
                    changed['limitations'][i] = note.replace('19 ', '18 ').replace('21 of 38', '20 of 38')
                    self.assertNotEqual(changed, expected)
                    variants.append(changed)
            extra = copy.deepcopy(expected)
            extra['limitations'].append('unrecognized-input: input was not analyzed')
            variants.append(extra)
            changed_path = copy.deepcopy(expected)
            changed_path['limitations'] = [v.replace('Lib.swift', 'Other.swift')
                                          if 'Lib.swift' in v else v.replace('DeadPublisher.swift', 'Other.swift')
                                          for v in changed_path['limitations']]
            self.assertNotEqual(changed_path, expected)
            variants.append(changed_path)
            for variant in variants:
                with self.subTest(variant=variant['limitations']), self.assertRaises(AssertionError):
                    CORPUS.compare(fixture, 'golden.json', variant)


if __name__ == '__main__':
    unittest.main()
