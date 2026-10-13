"""설치 영수증 추가 뒤에도 SDK 실행기가 검토한 정확한 바이트만 받아들이는지 확인한다."""

import hashlib
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent


def load(name):
    spec = importlib.util.spec_from_file_location("pin_" + name.replace("-", "_"), ROOT / name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RunnerPinTests(unittest.TestCase):
    def test_original_pin_refuses_successor_bytes(self):
        module = load("selector-runner-original.py")
        identity = module.file_identity(ROOT / "installer-successor.py", module.MAX_TEXT_BYTES, True)
        self.assertNotEqual(identity["sha256"], module.RUNNER_SHA256)

    def test_successor_pin_matches_approved_bytes_and_command_contract(self):
        module = load("selector-runner-successor.py")
        identity = module.file_identity(ROOT / "installer-successor.py", module.MAX_TEXT_BYTES, True)
        self.assertEqual(identity["sha256"], module.RUNNER_SHA256)
        self.assertEqual(identity["sha256"], "266d771fdff4e193c328c14487edc383079e4e44780c293a4ecbb405824c0dd2")
        namespace = {"__name__": "sdk_discovery_runner", "__file__": str(ROOT / "installer-successor.py")}
        exec(compile(identity["text"], namespace["__file__"], "exec"), namespace)
        self.assertTrue(callable(namespace["command"]))
        self.assertEqual(namespace["command"].__code__.co_argcount, 5)

    def test_selector_successor_changes_only_explicit_runner_pin(self):
        before = (ROOT / "selector-runner-original.py").read_text()
        after = (ROOT / "selector-runner-successor.py").read_text()
        self.assertEqual(
            after,
            before.replace(
                "7305066cdfa9acf17076d0ee7fe95d927883a2224ff1ba62c15eeb2e62807d50",
                "266d771fdff4e193c328c14487edc383079e4e44780c293a4ecbb405824c0dd2",
            ),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
