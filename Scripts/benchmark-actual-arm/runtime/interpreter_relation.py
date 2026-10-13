"""선택한 원래 프로브의 요청·실제 보고 관계만 현재 실행에 결합한다."""

from __future__ import annotations

from pathlib import Path

import startup_profile as profile

SCOPE = "Exact selected original probe only; no unobserved spelling or native loader equivalence"
IDENTITY_FIELDS = {"selected_path", "resolved_path", "sha256", "bytes", "metadata"}


def same(left, right):
    return profile.encoded(left) == profile.encoded(right)


def requested_path(relation):
    """보고 별칭을 다음 실행 요청으로 바꾸지 않고 원래 선택 경로를 유지한다."""
    return relation["requested_interpreter"]["selected_path"]


def validate_identity(value):
    """경로의 물리적 일치만으로 새 별칭을 허용하지 않도록 전체 관측을 비교한다."""
    profile.require(isinstance(value, dict) and set(value) == IDENTITY_FIELDS, "interpreter-relation-identity-shape")
    profile.require(
        all(isinstance(value[key], str) for key in ["selected_path", "resolved_path"])
        and profile.valid_sha(value["sha256"])
        and type(value["bytes"]) is int
        and value["bytes"] >= 0
        and isinstance(value["metadata"], list)
        and len(value["metadata"]) == 6
        and all(type(item) is int for item in value["metadata"]),
        "interpreter-relation-identity-type",
    )
    profile.require(
        same(profile.interpreter(value["selected_path"]), value), "interpreter-relation-identity-changed"
    )


def validate(relation, python, code_files, accepted_profile):
    """봉인된 런타임 관계의 선택·프로필·소스를 재검사하되 관측을 만들어내지 않는다."""
    fields = {
        "schema_version", "role", "collection_sha256", "probe", "request_sha256", "observation_sha256",
        "process_sha256", "source_inputs_sha256", "startup_profile_sha256", "source_inputs",
        "requested_interpreter", "reported_interpreter", "scope",
    }
    profile.require(isinstance(relation, dict) and set(relation) == fields, "interpreter-relation-shape")
    profile.require(
        type(relation["schema_version"]) is int
        and relation["schema_version"] == 1
        and relation["role"] == "selected-probe-interpreter-relation"
        and relation["scope"] == SCOPE
        and type(relation["probe"]) is int
        and relation["probe"] in (1, 2),
        "interpreter-relation-version-or-scope",
    )
    profile.require(
        all(profile.valid_sha(relation[key]) for key in fields if key.endswith("_sha256")),
        "interpreter-relation-digest",
    )
    requested, reported = relation["requested_interpreter"], relation["reported_interpreter"]
    validate_identity(requested)
    validate_identity(reported)
    profile.require(profile.same_physical(requested, reported), "interpreter-relation-physical-differs")
    profile.require(
        same(python, dict(path=requested["selected_path"], sha256=requested["sha256"], bytes=requested["bytes"])),
        "interpreter-relation-requested-differs",
    )
    profile.require(
        relation["startup_profile_sha256"] == profile.sha(profile.encoded(accepted_profile)),
        "interpreter-relation-profile-differs",
    )
    inputs = relation["source_inputs"]
    profile.require(
        isinstance(inputs, dict)
        and 1 <= len(inputs) <= 64
        and all(isinstance(path, str) and profile.valid_sha(digest) for path, digest in inputs.items())
        and relation["source_inputs_sha256"] == profile.sha(profile.encoded(inputs))
        and isinstance(code_files, dict)
        and bool(code_files)
        and all(path in inputs and inputs[path] == digest for path, digest in code_files.items()),
        "interpreter-relation-source-differs",
    )
    profile.require(
        {path: value["sha256"] for path, value in profile.source_inputs([Path(path) for path in inputs]).items()}
        == inputs,
        "interpreter-relation-source-changed",
    )
    return relation


def verify_current(relation, python, code_files, accepted_profile, current):
    """실제로 보고된 경로는 선택 프로브에서 관측한 한 경로와 완전히 같아야 한다."""
    validate(relation, python, code_files, accepted_profile)
    actual = profile.interpreter(current)
    profile.require(same(actual, relation["reported_interpreter"]), "interpreter-relation-reported-differs")
    return actual


def from_collection(path, expected_sha256, environment, selected, import_target, sources):
    """원래 선택 프로브의 보존된 실제 관측만 사용하며 누락된 관측은 복원하지 않는다."""
    import profile_collection as collection

    path = Path(path)
    record = collection.verify_collection(
        path, expected_sha256, environment, selected, import_target, [Path(p) for p in sources]
    )
    number = len(record["probes"])
    entry = record["probes"][-1]
    projection = collection.interpreter_projection(path, entry, number, environment, import_target, sources)
    request_data, _ = profile.read_file(Path(entry["request_path"]), profile.MAX_RECEIPT_BYTES)
    profile.require(profile.sha(request_data) == projection["request_sha256"], "interpreter-relation-request-changed")
    request = profile.strict(request_data)
    profile.require(request["interpreter"]["selected_path"] == str(selected), "interpreter-relation-not-selected")
    relation = dict(
        schema_version=1,
        role="selected-probe-interpreter-relation",
        collection_sha256=expected_sha256,
        probe=number,
        **{key: projection[key] for key in ["request_sha256", "observation_sha256", "process_sha256"]},
        source_inputs_sha256=projection["source_inputs_sha256"],
        startup_profile_sha256=profile.sha(profile.encoded(record["accepted_profile"])),
        source_inputs=dict(sources),
        requested_interpreter=request["interpreter"],
        reported_interpreter=entry["observation"]["actual_interpreter"],
        scope=SCOPE,
    )
    profile.require(
        profile.sha(profile.read_file(path, profile.MAX_RECEIPT_BYTES)[0]) == expected_sha256,
        "interpreter-relation-collection-changed",
    )
    # 마지막 영수증 읽기 뒤에도 소스·디렉터리·요청 및 보고 인터프리터를 다시 확인한다.
    requested = relation["requested_interpreter"]
    validate(
        relation,
        dict(path=requested["selected_path"], sha256=requested["sha256"], bytes=requested["bytes"]),
        sources,
        record["accepted_profile"],
    )
    profile.guard(request)
    return relation
