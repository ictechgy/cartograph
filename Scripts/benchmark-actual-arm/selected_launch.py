"""원래 설치가 선택한 동일한 물리 인터프리터로 측정 자식을 한 번만 교체한다."""

from __future__ import annotations

import json
import os
from pathlib import Path
import time

import installation_binding as installation
import attempt_receipts
import startup_profile
import profile_collection

ROOT = Path(__file__).resolve().parent
require = installation.require
read = installation.read
ARGUMENTS = ("repository", "lifecycle", "setup", "measurement", "scratch_root")
SCOPE = "One installation-selected exec or direct launch; all work remains inside original outer child wall"


def same(left, right):
    return json.dumps(left, sort_keys=True, allow_nan=False) == json.dumps(right, sort_keys=True, allow_nan=False)


def arguments(args):
    values = {name: str(getattr(args, name)) for name in ARGUMENTS}
    if getattr(args, "startup_profile_sha256", None) is not None:
        values["startup_profile_sha256"] = args.startup_profile_sha256
    return values


def command(args, interpreter):
    argv = [str(interpreter), "-I", "-S", "-B", str(ROOT / "correctness_controller.py"), "--execute"]
    for name, value in arguments(args).items():
        argv += ["--" + name.replace("_", "-"), value]
    return argv


def private_environment(root, create=False):
    """이미 감독기가 만든 고정 환경과 비교하며 상속 키를 추가하지 않는다."""
    root = Path(root).resolve(strict=True)
    base = root / "actual-arm-correctness-attempt/private-preparation"
    result = dict(PATH="/usr/bin:/bin:/usr/sbin:/sbin", LANG="C", LC_ALL="C", TZ="UTC", PYTHONDONTWRITEBYTECODE="1")
    for key, name in [("HOME", "home"), ("TMPDIR", "tmp"), ("XDG_CACHE_HOME", "cache")]:
        path = base / name
        if create:
            path.mkdir(parents=True)
        require(path.is_dir() and path.resolve(strict=True) == path, "Private launch environment directory differs")
        result[key] = str(path)
    result["RUNNER_TEMP"] = str(root)
    return result


def observation(path):
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts, "Interpreter spelling must be explicit")
    resolved = path.resolve(strict=True)
    before = resolved.stat()
    metadata = lambda info: [info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns]
    identity = installation.runtime.file_identity(path)
    require(
        path.resolve(strict=True) == resolved and metadata(resolved.stat()) == metadata(before),
        "Interpreter changed during launch observation",
    )
    return dict(selected_path=str(path), resolved_path=str(resolved), file_identity=metadata(before), **identity)


def selected_binding(args):
    result, _ = read(args.measurement)
    row = result.get("install_interpreter")
    require(
        isinstance(row, dict) and isinstance(row.get("before"), dict),
        "Prospective installation interpreter receipt required",
    )
    value = row["before"].get("selected_path")
    require(isinstance(value, str) and value and Path(value).is_absolute(), "Invalid original selected interpreter")
    selected = Path(value)
    binding = installation.bind(args.measurement, args.repository, selected)
    return selected, binding


def identity(binding):
    package = binding["package"]
    return dict(
        inputs=binding["inputs"],
        python=binding["python"],
        source_hashes=binding["source_hashes"],
        package=dict(
            target=package["target"],
            content_sha256=package["content"]["content_sha256"],
            projection_sha256=package["projection_sha256"],
        ),
    )


def paths(root):
    root = Path(root).resolve(strict=True)
    attempt = root / "actual-arm-correctness-attempt"
    require(attempt.is_dir() and attempt.resolve(strict=True) == attempt, "Owned launch attempt directory differs")
    return attempt / "selected-launch-request.json", attempt / "selected-launch-observation.json"


def validate_request(args, request, binding, sources):
    require(
        isinstance(request, dict)
        and set(request)
        == {
            "schema_version",
            "role",
            "mode",
            "arguments",
            "replacement_command",
            "initial_interpreter",
            "selected_interpreter",
            "installation",
            "source_sha256",
            "preparation_wall_seconds",
            "scope",
            *({"startup_profile"} if getattr(args, "startup_profile_sha256", None) is not None else set()),
        },
        "Selected launch request shape differs",
    )
    require(
        type(request["schema_version"]) is int and request["schema_version"] == 1, "Selected launch version differs"
    )
    require(
        request["role"] == "installation-selected-launch-request" and request["scope"] == SCOPE,
        "Selected launch scope differs",
    )
    require(request["mode"] in {"direct", "one-exec"}, "Selected launch mode differs")
    selected = Path(binding["python"]["path"])
    require(same(request["arguments"], arguments(args)), "Selected launch arguments changed")
    require(same(request["replacement_command"], command(args, selected)), "Selected launch command changed")
    require(same(request["installation"], identity(binding)), "Selected launch installation changed")
    require(same(request["source_sha256"], sources), "Selected launch source changed")
    initial, accepted = request["initial_interpreter"], request["selected_interpreter"]
    require(same(accepted, observation(selected)), "Selected launch selected identity changed")
    require(
        isinstance(initial, dict) and isinstance(initial.get("selected_path"), str),
        "Selected launch initial identity differs",
    )
    require(same(initial, observation(Path(initial["selected_path"]))), "Selected launch initial identity changed")
    require(
        {k: v for k, v in initial.items() if k != "selected_path"}
        == {k: v for k, v in accepted.items() if k != "selected_path"},
        "Different physical interpreter cannot be selected",
    )
    require(
        (request["mode"] == "direct") is (initial["selected_path"] == str(selected)), "Selected launch mode disagrees"
    )
    if getattr(args, "startup_profile_sha256", None) is not None:
        require(
            same(request["startup_profile"], startup_binding(args, Path(args.scratch_root), sources)),
            "Selected launch startup profile changed",
        )
    installation.cost(request["preparation_wall_seconds"])


def verify(args, root, sources):
    request_path, observed_path = paths(root)
    request, request_ref = read(request_path)
    selected, binding = selected_binding(args)
    validate_request(args, request, binding, sources)
    observed, observed_ref = read(observed_path)
    require(
        isinstance(observed, dict)
        and set(observed)
        == {
            "schema_version",
            "role",
            "status",
            "request_sha256",
            "actual_interpreter",
            "installation",
            "source_sha256",
            "verification_wall_seconds",
            "scope",
            *(
                {"startup_profile", "environment_observation"}
                if getattr(args, "startup_profile_sha256", None) is not None
                else set()
            ),
        },
        "Selected launch observation shape differs",
    )
    require(
        type(observed["schema_version"]) is int and observed["schema_version"] == 1,
        "Selected launch observation version differs",
    )
    require(
        observed["role"] == "installation-selected-launch-observation"
        and observed["status"] == "selected-interpreter-bound"
        and observed["scope"] == SCOPE,
        "Selected launch observation status differs",
    )
    require(observed["request_sha256"] == request_ref["sha256"], "Selected launch request changed")
    require(same(observed["actual_interpreter"], observation(selected)), "Selected launch actual interpreter differs")
    require(
        same(observed["installation"], identity(binding)) and same(observed["source_sha256"], sources),
        "Selected launch final bindings differ",
    )
    if getattr(args, "startup_profile_sha256", None) is not None:
        startup = startup_binding(args, root, sources)
        require(same(observed["startup_profile"], startup), "Selected launch observed profile changed")
        startup_profile.verify_observation(
            observed["environment_observation"], startup["requested_environment"], startup["accepted_profile"]
        )
    installation.cost(observed["verification_wall_seconds"])
    for ref in [request_ref, observed_ref]:
        require(read(Path(ref["path"]))[1] == ref, "Selected launch receipt changed during verification")
    return dict(request=request, observation=observed, request_ref=request_ref, observation_ref=observed_ref)


def startup_binding(args, root, sources):
    digest = getattr(args, "startup_profile_sha256", None)
    if digest is None:
        return None
    selected, _ = selected_binding(args)
    path = Path(root) / "actual-arm-correctness-attempt/startup-profile/results.json"
    record = profile_collection.verify_collection(
        path,
        digest,
        private_environment(root),
        selected,
        ROOT / "correctness_controller.py",
        [Path(p) for p in sources],
    )
    return dict(
        collection_sha256=digest,
        accepted_profile=record["accepted_profile"],
        requested_environment=record["requested_environment"],
    )


def request_projection(args, root, sources):
    """관측 영수증 없이도 요청 자체를 재검증하되 실행 여부는 결론 내리지 않는다."""
    request_path, _ = paths(root)
    request, reference = read(request_path)
    _, binding = selected_binding(args)
    validate_request(args, request, binding, sources)
    require(read(request_path)[1] == reference, "Selected launch request changed")
    return dict(
        status="bound-request",
        mode=request["mode"],
        request_sha256=reference["sha256"],
        source_inputs_sha256=startup_profile.sha(startup_profile.encoded(sources)),
    )


def bind_current(args, root, current, source_hashes):
    """기존 bind의 거부를 바꾸지 않고 검증된 요청 문맥만 그 실패에 붙인다."""
    try:
        return installation.bind(args.measurement, args.repository, Path(current))
    except attempt_receipts.InterpreterSpellingMismatch as error:
        try:
            sources = source_hashes()
            projected = request_projection(args, root, sources)
            marker = getattr(args, "selected_launch_sha256", None)
            require(
                (marker is None and projected["mode"] == "direct")
                or (marker == projected["request_sha256"] and projected["mode"] == "one-exec"),
                "Selected launch marker differs",
            )
            require(same(source_hashes(), sources), "Selected launch source changed")
            error.summary["selected_request"] = projected
        except (OSError, ValueError, TypeError, KeyError, RuntimeError):
            pass
        raise


def prepare(args, root, current, source_hashes, save, *, execve=os.execve, environment=None):
    """표시된 선택 경로가 또 달라지면 재시도 없이 원래 bind 오류를 그대로 보존한다."""
    started = time.perf_counter()
    expected_environment = private_environment(root)
    environment = dict(os.environ) if environment is None else dict(environment)
    startup = startup_binding(args, root, source_hashes())
    if startup is None:
        if environment != expected_environment:
            raise attempt_receipts.PrivateEnvironmentMismatch(expected_environment, environment)
    else:
        actual = startup_profile.observe_request(startup["requested_environment"], environment)
        startup_profile.verify_observation(actual, startup["requested_environment"], startup["accepted_profile"])
    request_path, observed_path = paths(root)
    marker = getattr(args, "selected_launch_sha256", None)
    if marker is not None:
        require(
            isinstance(marker, str) and installation.runtime.SEAL.valid_sha(marker), "Invalid selected launch marker"
        )
        require(not observed_path.exists(), "Selected launch observation already exists")
        request, reference = read(request_path)
        require(reference["sha256"] == marker and request.get("mode") == "one-exec", "Selected launch marker differs")
        # 교체 프로세스의 실제 보고 경로로 기존 엄격한 설치 조건을 다시 실행한다.
        binding = bind_current(args, root, current, source_hashes)
        validate_request(args, request, binding, source_hashes())
    else:
        require(not request_path.exists() and not observed_path.exists(), "Selected launch request already exists")
        selected, binding = selected_binding(args)
        actual, accepted = observation(current), observation(selected)
        require(
            {k: v for k, v in actual.items() if k != "selected_path"}
            == {k: v for k, v in accepted.items() if k != "selected_path"},
            "Different physical interpreter cannot be selected",
        )
        request = dict(
            schema_version=1,
            role="installation-selected-launch-request",
            mode="direct" if str(current) == str(selected) else "one-exec",
            arguments=arguments(args),
            replacement_command=command(args, selected),
            initial_interpreter=actual,
            selected_interpreter=accepted,
            installation=identity(binding),
            source_sha256=source_hashes(),
            preparation_wall_seconds=time.perf_counter() - started,
            scope=SCOPE,
            **({"startup_profile": startup} if startup is not None else {}),
        )
        save(request_path, request)
        request_read, reference = read(request_path)
        require(same(request_read, request), "Selected launch request changed")
        _, rebound = selected_binding(args)
        validate_request(args, request, rebound, source_hashes())
        if request["mode"] == "one-exec":
            execve(
                str(selected),
                request["replacement_command"] + ["--selected-launch-sha256", reference["sha256"]],
                expected_environment,
            )
            raise RuntimeError("Selected launch exec unexpectedly returned")
        binding = bind_current(args, root, current, source_hashes)
    observed = dict(
        schema_version=1,
        role="installation-selected-launch-observation",
        status="selected-interpreter-bound",
        request_sha256=reference["sha256"],
        actual_interpreter=observation(current),
        installation=identity(binding),
        source_sha256=source_hashes(),
        verification_wall_seconds=time.perf_counter() - started,
        scope=SCOPE,
        **(
            {
                "startup_profile": startup,
                "environment_observation": startup_profile.observe_request(
                    startup["requested_environment"], environment
                ),
            }
            if startup is not None
            else {}
        ),
    )
    require(
        observed["actual_interpreter"]["selected_path"] == binding["python"]["path"],
        "Prior interpreter spellings differ",
    )
    save(observed_path, observed)
    record = verify(args, root, source_hashes())
    return binding, record
