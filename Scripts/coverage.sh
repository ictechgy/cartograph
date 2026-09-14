#!/usr/bin/env bash
#
# 테스트를 커버리지와 함께 실행하고 최소 기준을 넘는지 확인한다.
#
# 사용법:
#   Scripts/coverage.sh                 # 기본 임계값으로 검사
#   Scripts/coverage.sh --min 90        # 임계값 지정
#   Scripts/coverage.sh --skip-test     # 입력이 바뀌지 않은 기존 결과로 검사만
#   Scripts/coverage.sh --report        # 파일별 커버리지 전체 출력
#   Scripts/coverage.sh --unit-only     # CLI 실행 프로파일 없이 단위 테스트만 집계
#
# 기준선은 프로덕션 코드(Sources/)만 본다. 테스트 코드와 의존성,
# 테스트 전용 지원 모듈을 분모에 넣으면 숫자가 실제 검증 수준을 가린다.
#
# CLI 껍데기와 인덱스 스토어 입출력 경계는 단위 테스트로 덮기 어렵다.
# 그 부분은 계측된 CLI로 실제 코퍼스·수집·MCP 하네스를 실행해 검증하고 프로파일을 합친다.
# 단위 테스트 비율도 별도로 출력하며, 파일을 분모에서 빼거나 실행하지 않은 줄을 성공으로 세지 않는다.

set -euo pipefail

MINIMUM="${COVERAGE_MINIMUM:-90}"
SKIP_TEST=0
SHOW_REPORT=0
UNIT_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --min) MINIMUM="$2"; shift 2 ;;
        --skip-test) SKIP_TEST=1; shift ;;
        --report) SHOW_REPORT=1; shift ;;
        --unit-only) UNIT_ONLY=1; shift ;;
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

# 별도 프로세스로 실행한 CLI 하네스도 계측된 같은 제품의 코드다. 단위 테스트 수치와
# 섞어 숨기지 않도록 먼저 단위 비율을 기록하고, 실제 실행 프로파일을 별도로 합친다.
UNIT_PROFDATA="$PROFDATA"
if [[ "$UNIT_ONLY" -eq 0 ]]; then
    CARTOGRAPH_BINARY="$PRODUCTS_DIR/cartograph"
    if [[ ! -x "$CARTOGRAPH_BINARY" ]]; then
        echo "계측된 CLI를 찾지 못했습니다: $CARTOGRAPH_BINARY" >&2
        exit 2
    fi
    if [[ "$SKIP_TEST" -eq 0 ]]; then
        INTEGRATION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cartograph-coverage-integration.XXXXXX")"
        echo "==> instrumented CLI integration checks ($INTEGRATION_DIR)"
        if [[ -n "${GITHUB_ENV:-}" ]]; then
            printf 'CARTOGRAPH_COVERAGE_DIR=%s\n' "$INTEGRATION_DIR" >> "$GITHUB_ENV"
        fi
        # 실패한 하네스의 출력을 CI에도 남겨 임시 디렉터리 소실 후에도 원인을 볼 수 있게 한다.
        run_integration() {
            local name="$1"
            shift
            if "$@" > "$INTEGRATION_DIR/$name.log" 2>&1; then
                return 0
            else
                local status=$?
                echo "Integration check failed: $name (exit $status)" >&2
                tail -n 100 "$INTEGRATION_DIR/$name.log" >&2
                return "$status"
            fi
        }
        export LLVM_PROFILE_FILE="$INTEGRATION_DIR/cli-%p.profraw"
        run_integration cli Scripts/verify-cli-contract.sh "$CARTOGRAPH_BINARY"
        run_integration discovery python3 Scripts/verify-runtime-discovery.py --cartograph "$CARTOGRAPH_BINARY" \
            --output-dir "$INTEGRATION_DIR/discovery"
        run_integration keypaths python3 Scripts/verify-runtime-keypaths.py --cartograph "$CARTOGRAPH_BINARY" \
            --output-dir "$INTEGRATION_DIR/keypaths"
        run_integration registry python3 Scripts/verify-runtime-registry.py --cartograph "$CARTOGRAPH_BINARY" \
            --output-dir "$INTEGRATION_DIR/registry"
        run_integration coredata-versions python3 Scripts/verify-coredata-versions.py --cartograph "$CARTOGRAPH_BINARY" \
            --output-dir "$INTEGRATION_DIR/coredata-versions"
        run_integration coredata-build python3 Scripts/verify-coredata-build-evidence.py --cartograph "$CARTOGRAPH_BINARY" \
            --output-dir "$INTEGRATION_DIR/coredata-build"
        run_integration collection python3 Scripts/verify-runtime-collection.py --cartograph "$CARTOGRAPH_BINARY" \
            --output-dir "$INTEGRATION_DIR/collection"
        run_integration window python3 Scripts/verify-runtime-window.py --cartograph "$CARTOGRAPH_BINARY" \
            --output-dir "$INTEGRATION_DIR/window"
        run_integration mcp python3 Scripts/verify-mcp.py --cartograph "$CARTOGRAPH_BINARY" \
            --output-dir "$INTEGRATION_DIR/mcp"
        unset LLVM_PROFILE_FILE
        PROFILES=("$INTEGRATION_DIR"/*.profraw)
        if [[ ! -f "${PROFILES[0]}" ]]; then
            echo "통합 검사가 계측 프로파일을 남기지 않았습니다." >&2
            exit 2
        fi
        xcrun llvm-profdata merge -sparse "$UNIT_PROFDATA" "${PROFILES[@]}" \
            -o "$CODECOV_DIR/with-integration.profdata"
    fi
    PROFDATA="$CODECOV_DIR/with-integration.profdata"
    [[ -f "$PROFDATA" ]] || { echo "통합 프로파일이 없습니다. --unit-only 또는 전체 검사를 실행하세요." >&2; exit 2; }
    OBJECT_ARGS+=(-object "$CARTOGRAPH_BINARY")
fi

if [[ "$SKIP_TEST" -eq 1 ]]; then
    # 프로파일의 존재만 확인하면 새 소스·바이너리에 옛 실행을 붙여 초록불을 낼 수 있다.
    # 디렉터리 시각도 확인하여 소스 삭제·이름 변경을 놓치지 않는다.
    python3 - "$UNIT_PROFDATA" "$PROFDATA" "$UNIT_ONLY" "${BINARIES[@]}" <<'PYTHON'
from pathlib import Path
import subprocess
import sys

unit, selected = map(Path, sys.argv[1:3])
try:
    inputs = [Path(value) for value in sys.argv[4:]]
    for name in ["Sources", "Tests", "Scripts", "Skills"]:
        directory = Path(name)
        if directory.exists():
            inputs.extend([directory, *directory.rglob("*")])
    # fixture 빌드 디렉터리 목록을 또 만들지 않고 저장소의 ignore 계약을 재사용한다.
    fixtures = Path("Fixtures")
    if fixtures.exists():
        listed = subprocess.run(
            ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "Fixtures"],
            capture_output=True, text=True, errors="surrogateescape"
        )
        if listed.returncode == 0:
            fixture_inputs = {fixtures}
            for name in filter(None, listed.stdout.split("\0")):
                path = Path(name)
                fixture_inputs.add(path)
                fixture_inputs.update(parent for parent in path.parents if parent != Path("."))
            inputs.extend(fixture_inputs)
        else:
            # Git 메타데이터가 없는 소스 배포본은 제외 범위를 추측하지 않는다.
            inputs.extend([fixtures, *fixtures.rglob("*")])
    inputs.extend(Path(".").glob("Package.*"))
    if Path(".gitignore").exists():
        inputs.append(Path(".gitignore"))
    unit_date = unit.stat().st_mtime_ns
    selected_date = selected.stat().st_mtime_ns
    stale = any(path.stat().st_mtime_ns > unit_date for path in inputs)
    stale |= selected_date < unit_date
    if sys.argv[3] == "0":
        stale |= (unit.parent.parent / "cartograph").stat().st_mtime_ns > selected_date
    if stale:
        raise ValueError("inputs are newer than the recorded execution")
except (OSError, ValueError):
    print("Coverage inputs changed or are unavailable. Run Scripts/coverage.sh without --skip-test.", file=sys.stderr)
    sys.exit(2)
PYTHON
fi

COVERAGE_JSON="$(mktemp -t cartograph-coverage)"
trap 'rm -f "$COVERAGE_JSON"' EXIT

echo "==> llvm-cov export (${#BINARIES[@]} test bundles, integration=$((1 - UNIT_ONLY)))"
# macOS 기본 bash 3.2 는 set -u 아래에서 빈 배열 확장을 미정의 변수로 본다.
# 테스트 타깃이 하나뿐인 프로젝트에서 여기서 죽는다.
xcrun llvm-cov export \
    "${BINARIES[0]}" \
    ${OBJECT_ARGS[@]+"${OBJECT_ARGS[@]}"} \
    -instr-profile "$PROFDATA" \
    -ignore-filename-regex='/(Tests|checkouts|\.build)/' \
    "$(pwd)/Sources" > "$COVERAGE_JSON"

if [[ "$UNIT_ONLY" -eq 0 ]]; then
    UNIT_JSON="$(mktemp -t cartograph-unit-coverage)"
    # 테스트 번들만 내보내 기존 측정과 같은 분모의 수치를 별도로 보존한다.
    UNIT_OBJECT_ARGS=()
    for binary in "${BINARIES[@]:1}"; do UNIT_OBJECT_ARGS+=(-object "$binary"); done
    xcrun llvm-cov export "${BINARIES[0]}" ${UNIT_OBJECT_ARGS[@]+"${UNIT_OBJECT_ARGS[@]}"} \
        -instr-profile "$UNIT_PROFDATA" -ignore-filename-regex='/(Tests|checkouts|\.build)/' \
        "$(pwd)/Sources" > "$UNIT_JSON"
    python3 - "$UNIT_JSON" <<'PYTHON'
import json, sys
files = [f for f in json.load(open(sys.argv[1]))["data"][0]["files"]
         if "/Sources/" in f["filename"] and not any(x in f["filename"]
         for x in ["/Tests/", "/checkouts/", "/.build/", "/CartographTestSupport/"])]
covered = sum(f["summary"]["lines"]["covered"] for f in files)
total = sum(f["summary"]["lines"]["count"] for f in files)
print(f"단위 테스트만: {covered / total * 100:.2f}% ({covered}/{total}); 아래 게이트는 실제 CLI 통합 실행 포함")
PYTHON
    rm -f "$UNIT_JSON"
fi

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
