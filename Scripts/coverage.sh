#!/usr/bin/env bash
#
# 테스트를 커버리지와 함께 실행하고 최소 기준을 넘는지 확인한다.
#
# 사용법:
#   Scripts/coverage.sh                 # 기본 임계값으로 검사
#   Scripts/coverage.sh --min 90        # 임계값 지정
#   Scripts/coverage.sh --skip-test     # 이미 돌린 결과로 검사만
#   Scripts/coverage.sh --report        # 파일별 커버리지 전체 출력
#
# 기준선은 프로덕션 코드(Sources/)만 본다. 테스트 코드와 의존성,
# 테스트 전용 지원 모듈을 분모에 넣으면 숫자가 실제 검증 수준을 가린다.
#
# CLI 껍데기와 인덱스 스토어 입출력 경계는 단위 테스트로 덮기 어렵다.
# 그 부분은 CI 에서 실제 빌드된 도구로 이 저장소 자신을 분석해 검증한다.
# 숫자를 올리려고 의미 없는 테스트를 쓰는 것보다 그쪽이 실제 보증이 크다.

set -euo pipefail

MINIMUM="${COVERAGE_MINIMUM:-90}"
SKIP_TEST=0
SHOW_REPORT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --min) MINIMUM="$2"; shift 2 ;;
        --skip-test) SKIP_TEST=1; shift ;;
        --report) SHOW_REPORT=1; shift ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/.."

if [[ "$SKIP_TEST" -eq 0 ]]; then
    echo "==> swift test --enable-code-coverage"
    swift test --enable-code-coverage
fi

# SwiftPM 이 만들어 주는 codecov JSON 은 테스트 번들 하나만 반영한다.
# 타깃별로 .xctest 가 따로 생기는 구성에서는 모듈 절반이 통째로 빠져
# 커버리지가 실제보다 높게 보인다. 모든 번들을 함께 넘겨 직접 내보낸다.
CODECOV_DIR="$(dirname "$(swift test --show-codecov-path | tail -1)")"
PROFDATA="$CODECOV_DIR/default.profdata"
PRODUCTS_DIR="$(dirname "$CODECOV_DIR")"

if [[ ! -f "$PROFDATA" ]]; then
    echo "커버리지 프로파일을 찾지 못했습니다: $PROFDATA" >&2
    echo "먼저 'swift test --enable-code-coverage' 를 실행하세요." >&2
    exit 2
fi

BINARIES=()
while IFS= read -r bundle; do
    name="$(basename "$bundle" .xctest)"
    binary="$bundle/Contents/MacOS/$name"
    [[ -f "$binary" ]] || binary="$bundle/$name"
    [[ -f "$binary" ]] && BINARIES+=("$binary")
done < <(find "$PRODUCTS_DIR" -maxdepth 1 -name "*.xctest")

if [[ ${#BINARIES[@]} -eq 0 ]]; then
    echo "테스트 번들을 찾지 못했습니다: $PRODUCTS_DIR" >&2
    exit 2
fi

OBJECT_ARGS=()
for binary in "${BINARIES[@]:1}"; do
    OBJECT_ARGS+=(-object "$binary")
done

COVERAGE_JSON="$(mktemp -t cartograph-coverage)"
trap 'rm -f "$COVERAGE_JSON"' EXIT

echo "==> llvm-cov export (${#BINARIES[@]} test bundles)"
# macOS 기본 bash 3.2 는 set -u 아래에서 빈 배열 확장을 미정의 변수로 본다.
# 테스트 타깃이 하나뿐인 프로젝트에서 여기서 죽는다.
xcrun llvm-cov export \
    "${BINARIES[0]}" \
    ${OBJECT_ARGS[@]+"${OBJECT_ARGS[@]}"} \
    -instr-profile "$PROFDATA" \
    -ignore-filename-regex='/(Tests|checkouts|\.build)/' \
    "$(pwd)/Sources" > "$COVERAGE_JSON"

MINIMUM="$MINIMUM" SHOW_REPORT="$SHOW_REPORT" python3 - "$COVERAGE_JSON" <<'PYTHON'
import json
import os
import sys

# 분모에서 제외할 경로 조각.
# - Tests/ 와 의존성 체크아웃은 우리가 검증하려는 대상이 아니다.
# - TestSupport 는 테스트에서만 쓰는 도구라 자기 자신을 검증할 대상이 아니다.
EXCLUDED_FRAGMENTS = ("/Tests/", "/checkouts/", "/.build/", "/CartographTestSupport/")

minimum = float(os.environ["MINIMUM"])
show_report = os.environ["SHOW_REPORT"] == "1"

with open(sys.argv[1]) as handle:
    report = json.load(handle)

files = [
    entry
    for entry in report["data"][0]["files"]
    if "/Sources/" in entry["filename"]
    and not any(fragment in entry["filename"] for fragment in EXCLUDED_FRAGMENTS)
]

if not files:
    print("커버리지 대상 파일이 없습니다.", file=sys.stderr)
    sys.exit(2)

covered = sum(entry["summary"]["lines"]["covered"] for entry in files)
total = sum(entry["summary"]["lines"]["count"] for entry in files)
percent = (covered / total * 100) if total else 100.0


def display_name(path):
    marker = "/Sources/"
    return path[path.index(marker) + len(marker):] if marker in path else path


rows = sorted(
    (
        (
            display_name(entry["filename"]),
            entry["summary"]["lines"]["percent"],
            entry["summary"]["lines"]["count"] - entry["summary"]["lines"]["covered"],
        )
        for entry in files
    ),
    key=lambda row: row[1],
)

visible = rows if show_report else [row for row in rows if row[1] < minimum]
if visible:
    heading = "파일별 커버리지" if show_report else f"임계값({minimum:.0f}%) 미만 파일"
    print(f"\n{heading}:")
    width = max(len(row[0]) for row in visible)
    for name, file_percent, missed in visible:
        print(f"  {name.ljust(width)}  {file_percent:6.2f}%  ({missed} lines uncovered)")

print(f"\n라인 커버리지: {percent:.2f}% ({covered}/{total}) · 파일 {len(files)}개 · 기준 {minimum:.0f}%")

if percent < minimum:
    print(f"실패: 커버리지 {percent:.2f}% 가 기준 {minimum:.0f}% 에 미치지 못합니다.", file=sys.stderr)
    sys.exit(1)

print("통과")
PYTHON
