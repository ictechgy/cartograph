"""실제 bootstrap 영수증을 발신자가 저장한 정확한 환경 요청에 결합한다."""

from __future__ import annotations
import json
from pathlib import Path
import startup_profile as profile


def validate_profile(value):
    profile.require(
        isinstance(value, dict) and set(value) == {"schema_version", "surface", "platform", "addition"}, "profile-shape"
    )
    profile.validate_observation(
        dict(value, requested_environment={"keys": sorted(set(profile.FIXED) | profile.PRIVATE), "sha256": "0" * 64})
    )


def existing_environment(root, developer=None, runner_temp=None):
    root = Path(root).resolve(strict=True)
    environment = dict(profile.FIXED)
    environment.update(
        {key: str(root / name) for key, name in [("HOME", "home"), ("TMPDIR", "tmp"), ("XDG_CACHE_HOME", "cache")]}
    )
    if developer is not None:
        environment["DEVELOPER_DIR"] = str(Path(developer).resolve(strict=True))
    if runner_temp is not None:
        environment["RUNNER_TEMP"] = str(Path(runner_temp).resolve(strict=True))
    profile.environment_request(environment)
    return environment


def relation(config):
    """새 스키마에서만 관측된 인터프리터 관계를 실행 입력으로 사용한다."""
    import interpreter_relation

    return interpreter_relation.validate(
        config["interpreter_relation"], config["python"], config["code_files"], config["startup_profile"]
    )


def launch_interpreter(config):
    if config.get("schema_version") == 3:
        return relation(config)["requested_interpreter"]["selected_path"]
    return None


def launch_row(config, runtime_sha256, script, arguments, environment):
    validate_profile(config["startup_profile"])
    profile.require(type(config["schema_version"]) is int and config["schema_version"] in (2, 3), "profile-runtime-version")
    return dict(
        schema_version=1,
        role="bound-runtime-environment-request",
        runtime_sha256=runtime_sha256,
        script=str(script),
        script_sha256=config["code_files"][str(script)],
        arguments_sha256=profile.sha(json.dumps(arguments, separators=(",", ":")).encode()),
        startup_profile_sha256=profile.sha(profile.encoded(config["startup_profile"])),
        requested_environment=profile.environment_request(environment),
        **({"interpreter_relation_sha256": profile.sha(profile.encoded(relation(config))),
            "requested_interpreter": launch_interpreter(config)} if config["schema_version"] == 3 else {}),
    )


def launch_path(report):
    return Path(report).parent / "environment-request.json"


def write_launch(config, runtime_sha256, script, arguments, environment, report, boundary):
    if config.get("schema_version") == 1:
        return None
    boundary()
    path = launch_path(report)
    path.parent.mkdir(parents=True, exist_ok=True)
    value = launch_row(config, runtime_sha256, script, arguments, environment)
    profile.save(path, value)
    return profile.file_identity(path, profile.MAX_RECEIPT_BYTES)


def read_launch(config, runtime_sha256, script, arguments, report, expected_environment=None):
    path = launch_path(report)
    data, _ = profile.read_file(path, profile.MAX_RECEIPT_BYTES)
    row = profile.strict(data)
    required = {
        "schema_version",
        "role",
        "runtime_sha256",
        "script",
        "script_sha256",
        "arguments_sha256",
        "startup_profile_sha256",
        "requested_environment",
    }
    if config.get("schema_version") == 3:
        required |= {"interpreter_relation_sha256", "requested_interpreter"}
    profile.require(
        isinstance(row, dict)
        and set(row) == required
        and type(row["schema_version"]) is int
        and row["schema_version"] == 1
        and row["role"] == "bound-runtime-environment-request",
        "runtime-environment-request-shape",
    )
    profile.validate_environment_request(row["requested_environment"])
    validate_profile(config["startup_profile"])
    profile.require(
        row["runtime_sha256"] == runtime_sha256
        and row["script"] == str(script)
        and row["script_sha256"] == config["code_files"][str(script)]
        and row["arguments_sha256"] == profile.sha(json.dumps(arguments, separators=(",", ":")).encode())
        and row["startup_profile_sha256"] == profile.sha(profile.encoded(config["startup_profile"])),
        "runtime-environment-request-differs",
    )
    if config.get("schema_version") == 3:
        profile.require(
            row["interpreter_relation_sha256"] == profile.sha(profile.encoded(relation(config)))
            and row["requested_interpreter"] == launch_interpreter(config),
            "runtime-interpreter-request-differs",
        )
    if expected_environment is not None:
        profile.require(
            row["requested_environment"] == profile.environment_request(expected_environment),
            "runtime-launch-environment-differs",
        )
    return row, profile.sha(data)


def observe(config, row, environment):
    value = profile.observe_request(row["requested_environment"], environment)
    profile.verify_observation(value, row["requested_environment"], config["startup_profile"])
    return value


def verify_receipt(receipt, config, runtime_sha256, script, arguments, report, code, expected_environment):
    if config.get("schema_version") == 1:
        profile.require("startup_profile" not in config, "unexpected-legacy-profile")
        return
    profile.require(expected_environment is not None, "exact-launch-environment-required")
    row, digest = read_launch(config, runtime_sha256, script, arguments, report, expected_environment)
    profile.require(receipt.get("environment_request_sha256") == digest, "runtime-environment-receipt-differs")
    if config.get("schema_version") == 3:
        selected = relation(config)
        profile.require(
            receipt.get("interpreter_relation_sha256") == profile.sha(profile.encoded(selected)),
            "runtime-interpreter-relation-differs",
        )
        for phase in ["before"] + ([] if code == 125 else ["after"]):
            profile.require(
                profile.encoded(receipt.get("interpreter_" + phase)) == profile.encoded(selected["reported_interpreter"]),
                "runtime-reported-interpreter-differs",
            )
        profile.require(receipt.get("python", {}).get("path") == selected["reported_interpreter"]["selected_path"],
                        "runtime-reported-spelling-differs")
    for phase in ["before"] + ([] if code == 125 else ["after"]):
        profile.verify_observation(
            receipt.get("environment_" + phase), row["requested_environment"], config["startup_profile"]
        )
