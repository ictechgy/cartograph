"""초기 제어기 import도 캐시 대신 고정된 로컬 소스 바이트만 실행한다."""

import contextlib
import importlib.machinery
import os
from pathlib import Path
import stat

MAX_SOURCE_BYTES = 4 * 1024**2
ENGINE_SOURCES = [
    "correctness_controller.py",
    "publish_correctness.py",
    "source_import_policy.py",
    "runtime/vendor/normalize_evidence.py",
    "installation_binding.py",
    "selected_launch.py",
    "profile_collection.py",
    "runtime/startup_profile.py",
    "runtime/startup_binding.py",
    "runtime/interpreter_relation.py",
    "state_inputs.py",
    "state_worker.py",
    "engine_worker.py",
    "selector_contract.py",
    "attempt_receipts.py",
    "runtime/runtime_bootstrap.py",
    "runtime/runtime_identity.py",
    "runtime/isolated_measure.py",
    "runtime/vendor/sdk_content_seal.py",
    "runtime/vendor/process_tree_measure.py",
    "runtime/vendor/discovery_receipts.py",
    "primitive/arm_sessions.py",
    "primitive/generation_inputs.py",
    "primitive/vendor/command_runner.py",
    "primitive/vendor/mixed/adapter/mixed_adapter.py",
    "primitive/vendor/mixed/adapter/observe_mixed.py",
    "primitive/vendor/mixed/compiler_generations.py",
    "primitive/vendor/mixed/score_calls.py",
    "primitive/vendor/mixed/validation_common.py",
    "primitive/vendor/process_tree_measure.py",
]
EARLY_SOURCES = ENGINE_SOURCES + ["contract_prerequisites.py", "contract_suite.py", "runtime_publication.py"]


def read_source(path):
    before = path.lstat()
    identity = lambda row: (row.st_dev, row.st_ino, row.st_mode, row.st_size, row.st_mtime_ns, row.st_ctime_ns)
    if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= MAX_SOURCE_BYTES:
        raise ValueError("Initial source is not a bounded regular file")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if identity(os.fstat(fd)) != identity(before):
            raise ValueError("Initial source changed before read")
        parts = []
        total = 0
        while total <= MAX_SOURCE_BYTES:
            chunk = os.read(fd, min(65536, MAX_SOURCE_BYTES + 1 - total))
            if not chunk:
                break
            parts.append(chunk)
            total += len(chunk)
        if (
            total != before.st_size
            or identity(os.fstat(fd)) != identity(before)
            or identity(path.lstat()) != identity(before)
        ):
            raise ValueError("Initial source changed during read")
        return b"".join(parts)
    finally:
        os.close(fd)


@contextlib.contextmanager
def guarded_imports(root):
    root = Path(root).resolve(strict=True)
    allowed = {str(root / name) for name in EARLY_SOURCES}
    original = importlib.machinery.SourceFileLoader.get_code
    original_sourceless = importlib.machinery.SourcelessFileLoader.get_code
    original_create = importlib.machinery.ExtensionFileLoader.create_module
    original_exec = importlib.machinery.ExtensionFileLoader.exec_module

    def local(loader):
        lexical = Path(loader.path).absolute()
        physical = lexical.resolve(strict=True)
        return lexical, physical, lexical.is_relative_to(root) or physical.is_relative_to(root)

    def source(loader, fullname):
        lexical, physical, selected = local(loader)
        if not selected:
            return original(loader, fullname)
        if lexical != physical or str(physical) not in allowed:
            raise ValueError("Unbound initial local source")
        return compile(read_source(physical), str(physical), "exec")

    def bytecode(loader, fullname):
        if local(loader)[2]:
            raise ValueError("Unbound initial local bytecode")
        return original_sourceless(loader, fullname)

    def native_create(loader, spec):
        if local(loader)[2]:
            raise ValueError("Unbound initial local native extension")
        return original_create(loader, spec)

    def native_exec(loader, module):
        if local(loader)[2]:
            raise ValueError("Unbound initial local native extension")
        return original_exec(loader, module)

    importlib.machinery.ExtensionFileLoader.create_module = native_create
    importlib.machinery.ExtensionFileLoader.exec_module = native_exec
    importlib.machinery.SourceFileLoader.get_code = source
    importlib.machinery.SourcelessFileLoader.get_code = bytecode
    try:
        yield
    finally:
        importlib.machinery.SourceFileLoader.get_code = original
        importlib.machinery.SourcelessFileLoader.get_code = original_sourceless
        importlib.machinery.ExtensionFileLoader.create_module = original_create
        importlib.machinery.ExtensionFileLoader.exec_module = original_exec
