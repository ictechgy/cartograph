#!/usr/bin/env python3
"""`cartograph routes` 출력과 recorded.json 을 대조해 합의 표(Markdown)를 출력한다.

사용법: cartograph routes --project experiments/http-client-oracle > routes.json
        python3 experiments/http-client-oracle/compare.py routes.json

CI 가 도는 검사는 cartograph 의 HTTPClientOracleTests 다. 이 스크립트는 실제 CLI(인덱스 USR 포함)로 같은
대조를 사람이 읽는 표로 만든다. 하나라도 어긋나면 종료 코드 1 이다.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
UNRESERVED = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")


def normalize(path):
    """정규 템플릿 표기: unreserved 인코딩은 디코드하고 나머지 hex 는 대문자."""
    def repl(match):
        char = chr(int(match.group(1), 16))
        return char if char in UNRESERVED else "%" + match.group(1).upper()
    return re.sub(r"%([0-9A-Fa-f]{2})", repl, path)


def matches(template, anchor, path):
    expected = template[1:].split("/")
    actual = normalize(path)[1:].split("/")
    if anchor == "root" and len(expected) != len(actual):
        return False
    if anchor == "base" and len(expected) > len(actual):
        return False
    return all((e == "{}" and a) or e == a for e, a in zip(expected, actual[len(actual) - len(expected):]))


def markers():
    found = {}
    source_dir = os.path.join(HERE, "Sources", "OracleClient")
    for name in sorted(os.listdir(source_dir)):
        relative = f"Sources/OracleClient/{name}"
        with open(os.path.join(source_dir, name), encoding="utf-8") as handle:
            for number, line in enumerate(handle, start=1):
                if "// oracle: " not in line:
                    continue
                for token in line.split("// oracle: ", 1)[1].split():
                    case_id, _, case_name = token.partition("@")
                    found[case_id] = (relative, number, case_name or None)
    return found


def main():
    with open(sys.argv[1], encoding="utf-8") as handle:
        facts = json.load(handle)["facts"]
    with open(os.path.join(HERE, "recorded.json"), encoding="utf-8") as handle:
        recorded = json.load(handle)
    marks = markers()
    print("| case | recorded | route-call | agree |")
    print("|---|---|---|---|")
    failures = 0
    for record in recorded["records"]:
        path, line, case_name = marks[record["case"]]
        candidates = [f for f in facts if f["location"]["path"] == path and f["location"]["line"] == line
                      and (case_name is None or f.get("symbol", {}).get("qualifiedName", "").endswith("." + case_name))]
        fact = candidates[0] if len(candidates) == 1 else None
        agree = bool(fact) and not fact["dynamic"] and fact.get("method") == record["method"] \
            and matches(fact["channel"], fact["pathAnchor"], record["path"])
        failures += 0 if agree else 1
        described = f'{fact.get("method", "?")} `{fact["channel"]}` ({fact["pathAnchor"]})' if fact else "missing"
        print(f'| {record["case"]} | {record["method"]} `{record["path"]}` | {described} | {"yes" if agree else "NO"} |')
    print(f"\n{len(recorded['records']) - failures}/{len(recorded['records'])} agree")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
