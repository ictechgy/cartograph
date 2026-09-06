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
expect_status 64 "질의 대상과 배치 동시" query Foo --batch /dev/null
expect_status 64 "빈 질의 대상"        query ""
# 요청 파일이 잘못된 것은 인자의 문제다. 종료 코드 2 로 내면 CI 가 인덱스를 의심한다.
expect_status 64 "없는 배치 요청 파일"  query --batch "/tmp/cartograph-no-such-batch.json"
expect_status 64 "잘못된 브리지 형식"  bridges --format yaml
expect_status 64 "잘못된 브리지 대상"  bridges --target capacitor

echo "종료 코드 2 — 도구 실패"
MISSING="$(mktemp -d)"
printf '{ not json' > "$MISSING/broken.json"
printf '{}' > "$MISSING/badbatch.json"
printf '["Foo"]' > "$MISSING/batch.json"
expect_status 2 "인덱스 스토어 없음"   cycles --project "$MISSING"
expect_status 2 "없는 인덱스 경로"     cycles --index-store "$MISSING/nope"
expect_status 2 "브리지: 인덱스 없음"  bridges --project "$MISSING"
# 파일을 못 쓴 것과 순환을 찾은 것이 CI 에서 같은 신호가 되어서는 안 된다.
expect_status 2 "출력 파일 쓰기 실패"  graph --index-store "$MISSING/nope" -o "$MISSING/no/dir/out.dot"
expect_status 2 "깨진 베이스라인"      cycles --project "$MISSING" --baseline "$MISSING/broken.json"
# 외부 근거 파일은 지정했는데 없으면 조용히 넘어가지 않는다. 반영됐다고 믿고 지우면 앱이 깨진다.
expect_status 2 "없는 외부 근거 파일"  dead --project "$MISSING" --external-retentions "$MISSING/none.json"
expect_status 2 "깨진 외부 근거 파일"  dead --project "$MISSING" --external-retentions "$MISSING/broken.json"
# 요청 파일은 인덱스를 열기 전에 읽는다. 인덱스가 없는 프로젝트에서도 배치 오류가 먼저 난다.
expect_status 64 "배치 검사가 색인보다 먼저" query --batch "$MISSING/badbatch.json" --project "$MISSING"
expect_status 2 "배치도 인덱스는 필요"  query --batch "$MISSING/batch.json" --project "$MISSING"

# 인덱스가 열리기는 하는데 이 프로젝트를 하나도 모르는 상태. 스토어가 없는 것과 다르다.
# 이 경우가 조용히 0 으로 끝나면 --strict 가 0 줄을 분석하고 통과한다.
# 빌드 없이 만든다. 빈 스토어 디렉터리만 있으면 탐색은 성공하고 심볼은 0 개다.
EMPTY="$(mktemp -d)"
trap 'rm -rf "$MISSING" "$EMPTY"' EXIT
mkdir -p "$EMPTY/.build/index/store" "$EMPTY/Sources"
printf 'struct A {\n    func b() {}\n}\n' > "$EMPTY/Sources/A.swift"
expect_status 2 "빈 인덱스"            dead   --strict --project "$EMPTY"
expect_status 2 "빈 인덱스: cycles"    cycles --strict --project "$EMPTY"
expect_status 2 "빈 인덱스: rules"     rules  --strict --project "$EMPTY"

echo "종료 코드 0 — 빈 인덱스 탈출구"
expect_status 0 "빈 인덱스 허용"       dead --strict --project "$EMPTY" --allow-empty-index

echo "종료 코드 64 — 배치는 답을 다 내고 나서 실패한다"
BATCH="$(mktemp -d)"
trap 'rm -rf "$MISSING" "$BATCH"' EXIT
printf '["CartographError", "NoSuchDeclaration", "CodeGraph"]' > "$BATCH/mixed.json"
BATCH_OUT="$("$BINARY" query --batch "$BATCH/mixed.json" 2>/dev/null)"
BATCH_STATUS=$?
BATCH_ERR="$("$BINARY" query --batch "$BATCH/mixed.json" 2>&1 >/dev/null)"
if [[ "$BATCH_STATUS" -eq 64 ]]; then
    printf '  ok    64  배치에 없는 이름이 있으면 사용 오류\n'
else
    printf '  FAIL  %-3s 배치에 없는 이름이 있으면 사용 오류 (기대 64)\n' "$BATCH_STATUS"
    FAILURES=$((FAILURES + 1))
fi
# 실패해도 표준 출력은 완전해야 한다. 이것이 깨지면 스윕 한 건의 오타가 나머지 답을 버린다.
for needle in '"format" : "symbol-query-batch"' '"status" : "found"' '"status" : "notFound"'; do
    if grep -q -- "$needle" <<< "$BATCH_OUT"; then
        printf '  ok        종료 64 에도 결과가 나온다: %s\n' "$needle"
    else
        printf '  FAIL      종료 64 에도 결과가 나온다: %s 없음\n' "$needle"
        FAILURES=$((FAILURES + 1))
    fi
done
if grep -q -- "NoSuchDeclaration" <<< "$BATCH_ERR"; then
    printf '  ok        오류 메시지가 없는 이름을 지목한다\n'
else
    printf '  FAIL      오류 메시지가 없는 이름을 지목한다\n'
    FAILURES=$((FAILURES + 1))
fi

echo "출력 내용"
expect_output "cartograph"      "도움말에 도구 이름"           --help
expect_output "Exit codes"      "도움말에 종료 코드 표"        --help
expect_output "swift build"     "인덱스 없음 안내에 빌드 명령" cycles --project "$MISSING"
expect_output "--allow-empty-index" "빈 인덱스 안내에 탈출구"  dead --project "$EMPTY"
expect_output "in scope after"  "빈 인덱스 안내에 파일 수"     dead --project "$EMPTY"
# 아무것도 분석하지 않은 실행은 기계 형식에서도 조용하지 않아야 한다. 조용하면 CI 로그에서
# 깨끗한 실행과 바이트까지 같아진다.
expect_output "::notice"        "탈출구 실행이 GitHub Actions 형식에도 남는다" \
    dead --project "$EMPTY" --allow-empty-index --report-format github-actions

echo
if [[ "$FAILURES" -eq 0 ]]; then
    echo "통과"
else
    echo "실패 $FAILURES 건" >&2
    exit 1
fi
