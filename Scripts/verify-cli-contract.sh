#!/usr/bin/env bash
#
# 문서화한 CLI 계약이 실제로 지켜지는지 확인한다.
#
# 사용법:
#   Scripts/verify-cli-contract.sh [바이너리 경로]
#
# 종료 코드 표는 README 와 --help 에 적혀 있고, 상수로도 정의되어 있다. 그런데
# 상수를 단언하는 테스트는 상수가 실제 동작과 맞는지는 말해 주지 않는다.
# 실제로 --help 가 종료 코드 2 로 실패한 적이 있고, 단위 테스트는 전부 통과했다.
# 이 스크립트는 빌드된 바이너리를 직접 실행해 계약을 검증한다.

set -uo pipefail

cd "$(dirname "$0")/.."
BINARY="${1:-$(swift build --show-bin-path)/cartograph}"

if [[ ! -x "$BINARY" ]]; then
    echo "실행 파일을 찾지 못했습니다: $BINARY" >&2
    exit 2
fi

FAILURES=0

# 인자 목록과 기대 종료 코드를 받아 실제 코드와 비교한다.
expect_status() {
    local expected="$1"
    local description="$2"
    shift 2

    "$BINARY" "$@" > /dev/null 2>&1
    local actual=$?

    if [[ "$actual" -eq "$expected" ]]; then
        printf '  ok    %-3s %s\n' "$actual" "$description"
    else
        printf '  FAIL  %-3s %s (기대 %s)\n' "$actual" "$description" "$expected"
        FAILURES=$((FAILURES + 1))
    fi
}

# 출력에 특정 문자열이 있는지 확인한다.
#
# 파이프로 grep 에 넘기면 pipefail 때문에 도구의 종료 코드가 파이프라인 결과를
# 덮어써, grep 이 찾았는데도 실패로 보인다. 출력을 먼저 변수에 담는다.
expect_output() {
    local needle="$1"
    local description="$2"
    shift 2

    local output
    output="$("$BINARY" "$@" 2>&1)" || true

    if grep -q -- "$needle" <<< "$output"; then
        printf '  ok        %s\n' "$description"
    else
        printf '  FAIL      %s ("%s" 없음)\n' "$description" "$needle"
        FAILURES=$((FAILURES + 1))
    fi
}

echo "CLI 계약 검증: $BINARY"

echo "종료 코드 0 — 정상"
expect_status 0 "--help"              --help
expect_status 0 "--version"           --version
expect_status 0 "인자 없음(도움말)"    
for subcommand in graph cycles dead query bridges metrics rules baseline init skill; do
    expect_status 0 "$subcommand --help" "$subcommand" --help
done

echo "종료 코드 64 — 사용 오류"
expect_status 64 "알 수 없는 옵션"     --no-such-option
expect_status 64 "알 수 없는 하위 명령" no-such-command
expect_status 64 "잘못된 열거형 값"    graph --level galaxy
expect_status 64 "잘못된 형식 값"      dead --report-format yaml
expect_status 64 "질의 대상 누락"      query
expect_status 64 "0 이하의 깊이"       query Foo --depth 0
expect_status 64 "잘못된 브리지 형식"  bridges --format yaml
expect_status 64 "잘못된 브리지 대상"  bridges --target capacitor

echo "종료 코드 2 — 도구 실패"
MISSING="$(mktemp -d)"
trap 'rm -rf "$MISSING"' EXIT
printf '{ not json' > "$MISSING/broken.json"
expect_status 2 "인덱스 스토어 없음"   cycles --project "$MISSING"
expect_status 2 "없는 인덱스 경로"     cycles --index-store "$MISSING/nope"
expect_status 2 "브리지: 인덱스 없음"  bridges --project "$MISSING"
# 파일을 못 쓴 것과 순환을 찾은 것이 CI 에서 같은 신호가 되어서는 안 된다.
expect_status 2 "출력 파일 쓰기 실패"  graph --index-store "$MISSING/nope" -o "$MISSING/no/dir/out.dot"
expect_status 2 "깨진 베이스라인"      cycles --project "$MISSING" --baseline "$MISSING/broken.json"
# 외부 근거 파일은 지정했는데 없으면 조용히 넘어가지 않는다. 반영됐다고 믿고 지우면 앱이 깨진다.
expect_status 2 "없는 외부 근거 파일"  dead --project "$MISSING" --external-retentions "$MISSING/none.json"
expect_status 2 "깨진 외부 근거 파일"  dead --project "$MISSING" --external-retentions "$MISSING/broken.json"

echo "출력 내용"
expect_output "cartograph"      "도움말에 도구 이름"           --help
expect_output "Exit codes"      "도움말에 종료 코드 표"        --help
expect_output "swift build"     "인덱스 없음 안내에 빌드 명령" cycles --project "$MISSING"

echo
if [[ "$FAILURES" -eq 0 ]]; then
    echo "통과"
else
    echo "실패 $FAILURES 건" >&2
    exit 1
fi
