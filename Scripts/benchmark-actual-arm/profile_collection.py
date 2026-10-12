"""한 설치의 최대 두 실행 경로를 관측하며 원래 요청·프로세스 비용을 보존한다."""

from __future__ import annotations

import math
from pathlib import Path
import sys
import time
import startup_profile as probe


def interpreter_projection(path, entry, number, environment, import_target, sources):
    """원래 저장된 프로브 관측만 재결합하며 과거에 없는 관측은 복구하지 않는다."""
    folder = Path(path).parent / ("spelling-%04d" % number)
    request_path, report = folder / "request.json", folder / "observation.json"
    probe.require(
        isinstance(entry, dict)
        and {"observation", "observation_identity", "process_identity", "stdout_identity", "stderr_identity"}
        <= set(entry),
        "probe-historical-observation-unavailable",
    )
    references = []

    def retained(source):
        data, _ = probe.read_file(source, probe.MAX_RECEIPT_BYTES)
        references.append((source, probe.file_identity(source, probe.MAX_RECEIPT_BYTES)))
        probe.require(
            dict(sha256=probe.sha(data), bytes=len(data))
            == {key: references[-1][1][key] for key in ("sha256", "bytes")},
            "probe-projection-input-changed",
        )
        return data

    data = retained(request_path)
    request = probe.strict(data)
    digest = probe.sha(data)
    spelling = entry["requested_command"][0]
    expected = probe.request(environment, spelling, import_target, [Path(p) for p in sources])
    probe.require(probe.encoded(request) == probe.encoded(expected), "probe-projection-request-differs")
    probe.require(
        entry["request_path"] == str(request_path) and entry["request_sha256"] == digest,
        "probe-projection-request-hash-differs",
    )
    probe.require(
        {name: value["sha256"] for name, value in request["source_inputs"].items()} == sources,
        "probe-projection-source-differs",
    )
    argv = [
        spelling,
        "-I",
        "-S",
        "-B",
        str(Path(probe.__file__).resolve()),
        "--request",
        str(request_path),
        "--sha256",
        digest,
        "--report",
        str(report),
    ]
    phase = entry["process"]
    probe.require(
        entry["requested_command"] == argv
        and phase["command"] == argv
        and phase["cwd"] == str(Path(path).parent)
        and entry["terminal_guard"] == {"status": "passed"},
        "probe-projection-process-request-differs",
    )
    process = probe.strict(retained(folder / "process.json"))
    probe.require(
        probe.encoded(process) == probe.encoded(phase) and references[-1][1] == entry["process_identity"],
        "probe-projection-process-differs",
    )
    for kind in ("stdout", "stderr"):
        source = folder / ("process." + kind)
        retained(source)
        probe.require(
            phase[kind] == str(source) and references[-1][1] == entry[kind + "_identity"],
            "probe-projection-log-differs",
        )
    observed_data = retained(report)
    observed = probe.strict(observed_data)
    observation_identity = dict(sha256=probe.sha(observed_data), bytes=len(observed_data))
    probe.require(
        probe.encoded(observed) == probe.encoded(entry["observation"])
        and observation_identity == entry["observation_identity"],
        "probe-projection-observation-differs",
    )
    verify_record(observed, request, digest, phase)
    probe.require(
        isinstance(request["interpreter"]["selected_path"], str)
        and isinstance(observed["actual_interpreter"]["selected_path"], str),
        "probe-projection-spelling-type",
    )
    probe.guard(request)
    for source, reference in references:
        probe.require(
            probe.file_identity(source, probe.MAX_RECEIPT_BYTES) == reference, "probe-projection-input-changed"
        )
    probe.guard(request)
    return dict(
        status="verified-observation",
        probe=number,
        request_sha256=digest,
        observation_sha256=observation_identity["sha256"],
        process_sha256=entry["process_identity"]["sha256"],
        source_inputs_sha256=probe.sha(probe.encoded(sources)),
        requested_spelling_sha256=probe.sha(
            request["interpreter"]["selected_path"].encode("utf-8", errors="surrogatepass")
        ),
        reported_spelling_sha256=probe.sha(
            observed["actual_interpreter"]["selected_path"].encode("utf-8", errors="surrogatepass")
        ),
        physical_identity_equal=probe.same_physical(request["interpreter"], observed["actual_interpreter"]),
    )


def completed(phase):
    return (
        isinstance(phase, dict)
        and phase.get("completed") is True
        and type(phase.get("returncode")) is int
        and 0 <= phase["returncode"] <= 255
        and phase["returncode"] != 125
        and type(phase.get("observed_returncode")) is int
        and phase["observed_returncode"] == phase["returncode"]
    )


def verify_record(row, request, request_sha256, phase):
    probe.require(
        completed(phase) and phase["returncode"] == 0 and phase.get("passed") is True, "probe-process-not-passed"
    )
    probe.require(
        isinstance(row, dict)
        and set(row)
        == {
            "schema_version",
            "role",
            "status",
            "exit_code",
            "request_sha256",
            "early",
            "after_import",
            "terminal_guard",
            "actual_interpreter",
            "wall_seconds_before_receipt",
        },
        "probe-observation-shape",
    )
    probe.require(
        type(row["schema_version"]) is int
        and row["schema_version"] == 1
        and row["role"] == "prospective-python-startup-observation"
        and row["status"] == "passed"
        and type(row["exit_code"]) is int
        and row["exit_code"] == 0
        and row["request_sha256"] == request_sha256
        and row["terminal_guard"] == {"status": "passed"},
        "probe-observation-not-passed",
    )
    probe.require(
        type(row["wall_seconds_before_receipt"]) in (int, float)
        and math.isfinite(row["wall_seconds_before_receipt"])
        and row["wall_seconds_before_receipt"] >= 0,
        "probe-cost-invalid",
    )
    probe.require(probe.same_physical(row["actual_interpreter"], request["interpreter"]), "probe-interpreter-differs")
    accepted = probe.profile(row["early"])
    for key in ["early", "after_import"]:
        probe.verify_observation(row[key], request["environment"], accepted)
    return accepted


def collect(environment, initial, selected, import_target, sources, output, runner):
    """수집과 모든 정상 종료 확인을 한 준비 구간에 포함하고 환경값은 보존하지 않는다."""
    started = time.perf_counter()
    environment = dict(environment)
    expected = probe.environment_request(environment)
    spellings = list(dict.fromkeys([str(initial), str(selected)]))
    identities = [probe.interpreter(path) for path in spellings]
    probe.require(
        all(probe.same_physical(item, identities[0]) for item in identities), "different-profile-interpreters"
    )
    output = Path(output)
    probe.require(
        output.is_absolute()
        and output.parent.is_dir()
        and output.parent.resolve() == output.parent
        and not output.exists()
        and not output.is_symlink(),
        "profile-output-boundary",
    )
    inputs = [Path(p) for p in sources] + [Path(import_target)]
    inputs += [Path(i[k]) for i in identities for k in ["selected_path", "resolved_path"]]
    inputs += [Path(environment[k]) for k in probe.PRIVATE | (set(environment) & {"DEVELOPER_DIR"})]
    for path in inputs:
        for candidate in [path.absolute(), path.resolve()]:
            probe.require(
                not (output == candidate or output.is_relative_to(candidate) or candidate.is_relative_to(output)),
                "profile-input-overlap",
            )
    probe.require(Path(__file__).resolve() in sources, "unbound-profile-collector")
    requests = [probe.request(environment, path, Path(import_target), sources) for path in spellings]
    output.mkdir()
    result = dict(
        schema_version=1,
        role="prospective-startup-profile-collection",
        status="failed",
        exit_code=1,
        final_evidence=False,
        requested_environment=expected,
        probes=[],
        accepted_profile=None,
    )
    try:
        for index, request in enumerate(requests, 1):
            folder = output / ("spelling-%04d" % index)
            folder.mkdir()
            request_path, report = folder / "request.json", folder / "observation.json"
            probe.save(request_path, request)
            data, _ = probe.read_file(request_path, probe.MAX_RECEIPT_BYTES)
            request_sha256 = probe.sha(data)
            argv = [
                request["interpreter"]["selected_path"],
                "-I",
                "-S",
                "-B",
                str(Path(probe.__file__).resolve()),
                "--request",
                str(request_path),
                "--sha256",
                request_sha256,
                "--report",
                str(report),
            ]
            phase = runner(argv, output, folder / "process", environment, 30)
            item = dict(
                request_sha256=request_sha256,
                request_path=str(request_path),
                requested_command=argv,
                process=phase,
                terminal_guard={"status": "not-run"},
            )
            result["probes"].append(item)
            if not completed(phase):
                result.update(status="incomplete", exit_code=125)
                item["terminal_guard"] = dict(status="unavailable", reason="incomplete-process")
                break
            try:
                probe.guard(request)
                probe.require(
                    probe.read_file(request_path, probe.MAX_RECEIPT_BYTES)[0] == data, "profile-request-changed"
                )
                probe.require(probe.environment_request(environment) == expected, "profile-environment-changed")
                item["terminal_guard"] = dict(status="passed")
            except Exception as error:
                item["terminal_guard"] = dict(
                    status="failed", failure_type=type(error).__name__, failure_sha256=probe.sha(str(error).encode())
                )
                raise
            probe.require(
                phase.get("command") == argv and phase.get("cwd") == str(output), "profile-process-request-differs"
            )
            actual_phase, _ = probe.read_file(folder / "process.json", probe.MAX_RECEIPT_BYTES)
            probe.require(
                probe.encoded(probe.strict(actual_phase)) == probe.encoded(phase), "profile-process-receipt-differs"
            )
            item["process_identity"] = probe.file_identity(folder / "process.json", probe.MAX_RECEIPT_BYTES)
            for kind in ["stdout", "stderr"]:
                path = Path(str(folder / "process") + "." + kind)
                probe.require(phase[kind] == str(path), "profile-log-boundary")
                item[kind + "_identity"] = probe.file_identity(path, probe.MAX_RECEIPT_BYTES)
            if phase["returncode"] != 0 or phase.get("passed") is not True:
                break
            value, _ = probe.read_file(report, probe.MAX_RECEIPT_BYTES)
            observation = probe.strict(value)
            accepted = verify_record(observation, request, request_sha256, phase)
            item["observation"] = observation
            item["observation_identity"] = dict(sha256=probe.sha(value), bytes=len(value))
            if result["accepted_profile"] is not None:
                probe.require(result["accepted_profile"] == accepted, "spelling-profile-disagreement")
            result["accepted_profile"] = accepted
        if len(result["probes"]) == len(requests) and all("observation" in item for item in result["probes"]):
            for request, item in zip(requests, result["probes"]):
                probe.guard(request)
                request_data, _ = probe.read_file(Path(item["request_path"]), probe.MAX_RECEIPT_BYTES)
                probe.require(probe.sha(request_data) == item["request_sha256"], "profile-request-changed")
                for kind in ["stdout", "stderr"]:
                    path = Path(item["process"][kind])
                    probe.require(
                        probe.file_identity(path, probe.MAX_RECEIPT_BYTES) == item[kind + "_identity"],
                        "profile-log-changed",
                    )
                probe.require(
                    probe.file_identity(Path(item["request_path"]).parent / "process.json", probe.MAX_RECEIPT_BYTES)
                    == item["process_identity"],
                    "profile-process-changed",
                )
                data, _ = probe.read_file(
                    Path(item["request_path"]).parent / "observation.json", probe.MAX_RECEIPT_BYTES
                )
                probe.require(
                    dict(sha256=probe.sha(data), bytes=len(data)) == item["observation_identity"],
                    "profile-observation-changed",
                )
            for request in requests:
                probe.guard(request)
            result.update(status="passed", exit_code=0)
    except KeyboardInterrupt:
        result.update(status="incomplete", exit_code=125, failure_category="interrupt")
    except Exception as error:
        result.update(
            status="failed",
            exit_code=1,
            failure_type=type(error).__name__,
            failure_sha256=probe.sha(str(error).encode()),
        )
    if result["status"] != "passed":
        result["accepted_profile"] = None
    result["wall_seconds_before_receipt"] = time.perf_counter() - started
    result["scope"] = (
        "Python environment mapping only; exact outgoing environments unchanged; native cached state unproved"
    )
    probe.save(output / "results.json", result)
    return result


def verify_collection(path, expected_sha256, environment, selected, import_target, sources):
    """요약이 아닌 실제 두 프로브·발신 요청·입력 정체성을 매번 재결합한다."""
    path = Path(path)
    original, _ = probe.read_file(path, probe.MAX_RECEIPT_BYTES)
    probe.require(probe.sha(original) == expected_sha256, "startup-collection-changed")
    result = probe.strict(original)
    probe.require(
        isinstance(result, dict)
        and type(result.get("schema_version")) is int
        and result["schema_version"] == 1
        and result.get("role") == "prospective-startup-profile-collection"
        and result.get("status") == "passed"
        and type(result.get("exit_code")) is int
        and result["exit_code"] == 0
        and result.get("final_evidence") is False,
        "startup-collection-not-passed",
    )
    probe.require(
        set(result)
        == {
            "schema_version",
            "role",
            "status",
            "exit_code",
            "final_evidence",
            "requested_environment",
            "probes",
            "accepted_profile",
            "wall_seconds_before_receipt",
            "scope",
        },
        "startup-collection-shape",
    )
    probe.require(
        type(result["wall_seconds_before_receipt"]) in (int, float)
        and math.isfinite(result["wall_seconds_before_receipt"])
        and result["wall_seconds_before_receipt"] >= 0
        and result["scope"]
        == "Python environment mapping only; exact outgoing environments unchanged; native cached state unproved",
        "startup-collection-cost-or-scope",
    )
    probe.require(result["requested_environment"] == probe.environment_request(environment), "startup-launch-differs")
    records = result["probes"]
    probe.require(isinstance(records, list) and 1 <= len(records) <= 2, "startup-probe-count")
    spellings = [entry["requested_command"][0] for entry in records]
    probe.require(
        len(set(spellings)) == len(spellings) and spellings[-1] == str(selected), "startup-spelling-inventory"
    )
    selected_identity = probe.interpreter(selected)
    bindings = []
    requests = []
    for number, entry in enumerate(records, 1):
        probe.require(
            isinstance(entry, dict)
            and set(entry)
            == {
                "request_sha256",
                "request_path",
                "requested_command",
                "process",
                "terminal_guard",
                "process_identity",
                "stdout_identity",
                "stderr_identity",
                "observation",
                "observation_identity",
            },
            "startup-probe-evidence-shape",
        )
        folder = path.parent / ("spelling-%04d" % number)
        request_path, report = folder / "request.json", folder / "observation.json"
        data, _ = probe.read_file(request_path, probe.MAX_RECEIPT_BYTES)
        request = probe.strict(data)
        wanted = probe.request(environment, spellings[number - 1], Path(import_target), sources)
        probe.require(probe.encoded(request) == probe.encoded(wanted), "startup-request-inputs-differ")
        probe.require(
            probe.same_physical(request["interpreter"], selected_identity), "startup-physical-interpreter-differs"
        )
        probe.require(
            entry["request_path"] == str(request_path) and entry["request_sha256"] == probe.sha(data),
            "startup-request-differs",
        )
        argv = [
            spellings[number - 1],
            "-I",
            "-S",
            "-B",
            str(Path(probe.__file__).resolve()),
            "--request",
            str(request_path),
            "--sha256",
            probe.sha(data),
            "--report",
            str(report),
        ]
        probe.require(
            entry["requested_command"] == argv
            and entry["process"]["command"] == argv
            and entry["process"]["cwd"] == str(path.parent),
            "startup-process-command-differs",
        )
        phase_data, _ = probe.read_file(folder / "process.json", probe.MAX_RECEIPT_BYTES)
        probe.require(
            probe.encoded(probe.strict(phase_data)) == probe.encoded(entry["process"]),
            "startup-process-receipt-differs",
        )
        probe.require(
            probe.file_identity(folder / "process.json", probe.MAX_RECEIPT_BYTES) == entry["process_identity"],
            "startup-process-identity-differs",
        )
        for kind in ["stdout", "stderr"]:
            source = Path(str(folder / "process") + "." + kind)
            probe.require(entry["process"][kind] == str(source), "startup-log-path-differs")
            probe.require(
                probe.file_identity(source, probe.MAX_RECEIPT_BYTES) == entry[kind + "_identity"],
                "startup-log-identity-differs",
            )
        data, _ = probe.read_file(report, probe.MAX_RECEIPT_BYTES)
        observed = probe.strict(data)
        probe.require(
            probe.encoded(observed) == probe.encoded(entry["observation"])
            and dict(sha256=probe.sha(data), bytes=len(data)) == entry["observation_identity"],
            "startup-observation-differs",
        )
        accepted = verify_record(observed, request, entry["request_sha256"], entry["process"])
        probe.require(
            accepted == result["accepted_profile"] and entry["terminal_guard"] == {"status": "passed"},
            "startup-profile-disagreement",
        )
        requests.append(request)
        for source in [
            request_path,
            report,
            folder / "process.json",
            folder / "process.stdout",
            folder / "process.stderr",
        ]:
            bindings.append((source, probe.file_identity(source, probe.MAX_RECEIPT_BYTES)))
    probe.require(probe.read_file(path, probe.MAX_RECEIPT_BYTES)[0] == original, "startup-collection-changed")
    for source, expected in bindings:
        probe.require(probe.file_identity(source, probe.MAX_RECEIPT_BYTES) == expected, "startup-evidence-changed")
    for request in requests:
        probe.guard(request)
    return result
