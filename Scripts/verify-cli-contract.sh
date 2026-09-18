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

    "$BINARY" "$@" < /dev/null > /dev/null 2>&1
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
for subcommand in graph cycles dead query impact snapshot runtime check serve dataflow bridges metrics rules baseline init skill; do
    expect_status 0 "$subcommand --help" "$subcommand" --help
done
expect_status 0 "runtime plan --help" runtime plan --help
expect_status 0 "runtime check --help" runtime check --help
expect_status 0 "runtime discover --help" runtime discover --help
expect_status 0 "runtime collect --help" runtime collect --help
expect_status 0 "runtime prepare-coredata --help" runtime prepare-coredata --help
expect_status 0 "serve EOF 종료(빌드 불필요)" serve

echo "종료 코드 64 — 사용 오류"
expect_status 64 "알 수 없는 옵션"     --no-such-option
expect_status 64 "알 수 없는 하위 명령" no-such-command
expect_status 64 "잘못된 열거형 값"    graph --level galaxy
expect_status 64 "잘못된 형식 값"      dead --report-format yaml
expect_status 64 "질의 대상 누락"      query
expect_status 64 "영향 선택자 누락"    impact
expect_status 64 "값 흐름 대상 누락"    dataflow
expect_status 64 "0 이하의 깊이"       query Foo --depth 0
expect_status 64 "0 이하의 값 흐름 예산" dataflow Foo --max-contexts 0
expect_status 64 "값 흐름 호출 깊이 범위" dataflow Foo --call-depth 9
expect_status 64 "질의 대상과 배치 동시" query Foo --batch /dev/null
expect_status 64 "미사용과 level 동시"   dead --level module
expect_status 64 "질의와 level 동시"     query Foo --level module
expect_status 64 "값 흐름과 level 동시"  dataflow Foo --level module
expect_status 64 "값 흐름과 since 동시"  dataflow Foo --since HEAD
expect_status 64 "값 흐름은 JSON 전용"    dataflow Foo --report-format text
expect_status 64 "값 흐름과 strict 동시"  dataflow Foo --strict
expect_status 64 "질의와 형식 동시"      query Foo --report-format text
expect_status 64 "질의와 strict 동시"    query Foo --strict
expect_status 64 "영향 선택자 혼용"      impact Foo --file Sources/App.swift
expect_status 64 "영향과 since 동시"     impact Foo --since HEAD
expect_status 64 "영향과 level 동시"     impact Foo --level module
expect_status 64 "영향과 형식 동시"     impact Foo --report-format json
expect_status 64 "영향과 strict 동시"   impact Foo --strict
expect_status 64 "영향 깊이 범위"       impact Foo --depth 0
expect_status 64 "영향 결과 수 범위"    impact Foo --limit 10001
expect_status 64 "영향 잘못된 형식"     impact Foo --format yaml
expect_status 64 "영향 trace 실행 파일 누락" impact Foo --trace /dev/null
expect_status 64 "영향 trace 없는 실행 파일" impact Foo --executable /dev/null
expect_status 64 "영향 과거와 trace 혼용" impact Foo --before /dev/null --trace /dev/null --executable /dev/null
expect_status 64 "런타임 발견 한도 범위" runtime discover --limit 0
expect_status 64 "런타임 발견 since 거부" runtime discover --since HEAD
expect_status 64 "런타임 발견 trace 실행 파일 누락" runtime discover --trace /dev/null
expect_status 64 "런타임 발견 trace와 모델 빌드 근거 혼용" runtime discover \
    --trace /dev/null --executable /dev/null --coredata-build-evidence /dev/null
expect_status 64 "영향 trace와 모델 빌드 근거 혼용" impact Foo \
    --trace /dev/null --executable /dev/null --coredata-build-evidence /dev/null
expect_status 64 "Core Data 준비 출력 누락" runtime prepare-coredata \
    --model /tmp/Store.xcdatamodel --container Store --executable /dev/null
expect_status 64 "Core Data 준비 빈 모델 경로" runtime prepare-coredata \
    --model "" --container Store --executable /dev/null --output /dev/null
expect_status 64 "Core Data 준비 빈 모델 이름" runtime prepare-coredata \
    --model /tmp/Store.xcdatamodel --container "" --executable /dev/null --output /dev/null
expect_status 64 "Core Data 준비 빈 모듈" runtime prepare-coredata \
    --model /tmp/Store.xcdatamodel --container Store --module "" --executable /dev/null --output /dev/null
expect_status 64 "Core Data 준비 빈 생성 소스" runtime prepare-coredata \
    --model /tmp/Store.xcdatamodel --container Store --generated-source "" --executable /dev/null --output /dev/null
expect_status 64 "런타임 수집 실행 파일 누락" runtime collect --output /dev/null
expect_status 64 "런타임 수집 출력 누락" runtime collect --executable /dev/null
expect_status 64 "런타임 수집 시간 범위" runtime collect --executable /dev/null --output /dev/null --timeout 0
expect_status 64 "런타임 수집 strict 거부" runtime collect --executable /dev/null --output /dev/null --strict
expect_status 64 "관측 구간 0 거부" runtime collect --executable /dev/null --output /dev/null --duration 0
expect_status 64 "관측 구간 timeout 초과" runtime collect --executable /dev/null --output /dev/null --timeout 1 --duration 1
expect_status 64 "관측 구간 비유한값 거부" runtime collect --executable /dev/null --output /dev/null --duration nan
expect_status 64 "시뮬레이터 bundle 누락" runtime collect --executable /dev/null --output /dev/null --simulator 00000000-0000-0000-0000-000000000000
expect_status 64 "시뮬레이터 기기 누락" runtime collect --executable /dev/null --output /dev/null --bundle-id dev.cartograph.Probe
expect_status 64 "시뮬레이터 별칭 거부" runtime collect --executable /dev/null --output /dev/null --simulator booted --bundle-id dev.cartograph.Probe
expect_status 64 "통합 검사와 level 동시" check --level module
expect_status 64 "서버와 since 동시" serve --since HEAD
expect_status 64 "서버와 level 동시" serve --level type
expect_status 64 "서버와 strict 동시" serve --strict
expect_status 64 "서버와 출력 파일 동시" serve --output /dev/null
expect_status 64 "서버와 리포트 형식 동시" serve --report-format json
expect_status 64 "서버 빈 모델 근거 경로" serve --coredata-build-evidence ""
expect_status 64 "서버 음수 재검증 간격" serve --session-freshness-interval=-1
expect_status 64 "서버 무한 재검증 간격" serve --session-freshness-interval=inf
expect_status 64 "서버 비수 재검증 간격" serve --session-freshness-interval=nan
expect_status 64 "서버 상한 초과 재검증 간격" serve --session-freshness-interval=86401
expect_status 0 "서버 0초 재검증 간격 수용" serve --session-freshness-interval=0
expect_status 0 "서버 상한 재검증 간격 수용" serve --session-freshness-interval=86400
expect_status 64 "스냅샷과 since 동시" snapshot --since HEAD
expect_status 64 "스냅샷과 level 동시" snapshot --level type
expect_status 64 "스냅샷과 strict 동시" snapshot --strict
expect_status 64 "스냅샷과 베이스라인 동시" snapshot --baseline /dev/null
expect_status 64 "스냅샷과 리포트 형식 동시" snapshot --report-format json
expect_status 64 "빈 스냅샷 리비전" snapshot --revision ""
expect_status 64 "스냅샷 빈 모델 근거 경로" snapshot --coredata-build-evidence ""
expect_status 64 "런타임 계획 계약 누락" runtime plan --executable /dev/null
expect_status 64 "런타임 계획 실행 파일 누락" runtime plan --contracts /dev/null
expect_status 64 "런타임 검사 관측 누락" runtime check --contracts /dev/null --executable /dev/null
expect_status 64 "런타임 검사 실행 파일 누락" runtime check --contracts /dev/null --observations /dev/null
expect_status 64 "런타임과 since 동시" runtime plan --contracts /dev/null --executable /dev/null --since HEAD
expect_status 64 "런타임과 level 동시" runtime plan --contracts /dev/null --executable /dev/null --level type
expect_status 64 "런타임과 형식 동시" runtime plan --contracts /dev/null --executable /dev/null --report-format text
expect_status 64 "런타임과 베이스라인 동시" runtime plan --contracts /dev/null --executable /dev/null --baseline /dev/null
expect_status 64 "그래프와 형식 동시"    graph --report-format json
expect_status 64 "그래프와 strict 동시"  graph --strict
expect_status 64 "브리지와 형식 동시"    bridges --report-format json
expect_status 64 "브리지와 strict 동시"  bridges --strict
expect_status 64 "베이스라인과 형식 동시" baseline --report-format json
expect_status 64 "베이스라인과 strict 동시" baseline --strict
expect_status 64 "설명과 테스트 전용 동시" dead --explain Foo --report-test-only
expect_status 64 "브리지와 level 동시"   bridges --level module
expect_status 64 "베이스라인과 level 동시" baseline --level module
expect_status 64 "질의와 since 동시"     query Foo --since HEAD
expect_status 64 "그래프와 since 동시"   graph --since HEAD
expect_status 64 "브리지와 since 동시"   bridges --since HEAD
expect_status 64 "설명과 since 동시"     dead --explain Foo --since HEAD
expect_status 64 "순환 설명과 since 동시" cycles --explain Foo --since HEAD
expect_status 64 "규칙 설명과 since 동시" rules --explain Foo --since HEAD
expect_status 64 "빈 질의 대상"        query ""
# 요청 파일이 잘못된 것은 인자의 문제다. 종료 코드 2 로 내면 CI 가 인덱스를 의심한다.
expect_status 64 "없는 배치 요청 파일"  query --batch "/tmp/cartograph-no-such-batch.json"
expect_status 64 "잘못된 브리지 형식"  bridges --format yaml
expect_status 64 "잘못된 브리지 대상"  bridges --target capacitor

echo "종료 코드 2 — 도구 실패"
MISSING="$(mktemp -d "${TMPDIR:-/tmp}/contract.XXXXXX")"
printf '{ not json' > "$MISSING/broken.json"
printf '{}' > "$MISSING/badbatch.json"
printf '["Foo"]' > "$MISSING/batch.json"
expect_status 2 "인덱스 스토어 없음"   cycles --project "$MISSING"
expect_status 2 "값 흐름: 인덱스 없음" dataflow Foo --project "$MISSING"
expect_status 2 "없는 인덱스 경로"     cycles --index-store "$MISSING/nope"
expect_status 2 "브리지: 인덱스 없음"  bridges --project "$MISSING"
expect_status 2 "통합 검사: 인덱스 없음" check --project "$MISSING" --strict
expect_status 2 "스냅샷: 인덱스 없음" snapshot --project "$MISSING"
# 파일을 못 쓴 것과 순환을 찾은 것이 CI 에서 같은 신호가 되어서는 안 된다.
# 실제 쓰기 실패는 아래 "빈 인덱스" 픽스처 다음에서 검증한다 — 없는 부모
# 디렉터리는 -o 가 만들어 주므로 경로만으로는 실패하지 않는다.
expect_status 2 "깨진 베이스라인"      cycles --project "$MISSING" --baseline "$MISSING/broken.json"
# 외부 근거 파일은 지정했는데 없으면 조용히 넘어가지 않는다. 반영됐다고 믿고 지우면 앱이 깨진다.
expect_status 2 "없는 외부 근거 파일"  dead --project "$MISSING" --external-retentions "$MISSING/none.json"
expect_status 2 "깨진 외부 근거 파일"  dead --project "$MISSING" --external-retentions "$MISSING/broken.json"
# 요청 파일은 인덱스를 열기 전에 읽는다. 인덱스가 없는 프로젝트에서도 배치 오류가 먼저 난다.
expect_status 64 "배치 검사가 색인보다 먼저" query --batch "$MISSING/badbatch.json" --project "$MISSING"
expect_status 64 "배치 질의와 since 동시" query --batch "$MISSING/batch.json" --since HEAD
expect_status 2 "배치도 인덱스는 필요"  query --batch "$MISSING/batch.json" --project "$MISSING"

# 인덱스가 열리기는 하는데 이 프로젝트를 하나도 모르는 상태. 스토어가 없는 것과 다르다.
# 이 경우가 조용히 0 으로 끝나면 --strict 가 0 줄을 분석하고 통과한다.
# 빌드 없이 만든다. 빈 스토어 디렉터리만 있으면 탐색은 성공하고 심볼은 0 개다.
EMPTY="$(mktemp -d "${TMPDIR:-/tmp}/contract.XXXXXX")"
mkdir -p "$EMPTY/.build/index/store" "$EMPTY/Sources"
printf 'struct A {\n    func b() {}\n}\n' > "$EMPTY/Sources/A.swift"
expect_status 2 "빈 인덱스"            dead   --strict --project "$EMPTY"
expect_status 2 "빈 인덱스: cycles"    cycles --strict --project "$EMPTY"
expect_status 2 "빈 인덱스: rules"     rules  --strict --project "$EMPTY"
expect_status 2 "빈 인덱스: check"     check --strict --project "$EMPTY"
expect_status 2 "빈 인덱스: snapshot"  snapshot --project "$EMPTY"
expect_status 64 "빈 인덱스 영향 대상 없음" impact Missing --project "$EMPTY" --allow-empty-index
# 목적지를 디렉터리로 준다. 파일로 못 쓰는 자리이므로 이 실패는 진짜 쓰기 실패다.
expect_status 2 "출력 파일 쓰기 실패"  graph --project "$EMPTY" --allow-empty-index -o "$EMPTY"

# 설정 파일의 baseline_path 는 읽기 위치일 뿐, 쓰기 목적지가 아니다. 분석 대상
# 저장소의 설정에 절대 경로를 심어 두고 baseline 을 돌리면 그 파일이 덮여써졌다.
CFG="$(mktemp -d "${TMPDIR:-/tmp}/contract.XXXXXX")"
trap 'rm -rf "$MISSING" "$EMPTY" "$CFG"' EXIT
printf 'baseline_path: /tmp/cartograph-hostile-baseline.json\n' > "$CFG/.cartograph.yml"
expect_status 64 "설정의 baseline_path 로는 쓰지 않는다" \
    baseline --project "$CFG" --index-store "$EMPTY/.build/index/store" --allow-empty-index
expect_status 0 "쓰기 목적지를 명시하면 기록한다" \
    baseline --project "$EMPTY" --allow-empty-index --write "$EMPTY/baseline.json"

echo "종료 코드 0 — 빈 인덱스 탈출구"
expect_status 0 "빈 인덱스 허용"       dead --strict --project "$EMPTY" --allow-empty-index

echo "종료 코드 64 — 배치는 답을 다 내고 나서 실패한다"
# 이 스크립트는 인덱스가 없는 체크아웃에서도 돈다. 릴리스 워크플로가 압축을 푼 바이너리로
# 다시 돌리는 자리가 그렇다. `--project` 없이 배치를 부르면 현재 디렉터리를 분석하려다
# 종료 코드 2 로 끝나고, 그러면 이 검사가 재는 것은 배치가 아니라 인덱스의 존재다.
# 위에서 만든 빈 인덱스 픽스처를 탈출구와 함께 쓴다. 세 이름 전부 notFound 가 되고,
# 그것이 확인하려던 것 — 답을 다 내고 나서 실패한다 — 을 그대로 보여 준다.
printf '["CartographError", "NoSuchDeclaration", "CodeGraph"]' > "$EMPTY/mixed.json"
BATCH_ARGS=(query --batch "$EMPTY/mixed.json" --project "$EMPTY" --allow-empty-index)
BATCH_OUT="$("$BINARY" "${BATCH_ARGS[@]}" 2>/dev/null)"
BATCH_STATUS=$?
BATCH_ERR="$("$BINARY" "${BATCH_ARGS[@]}" 2>&1 >/dev/null)"
if [[ "$BATCH_STATUS" -eq 64 ]]; then
    printf '  ok    64  배치에 없는 이름이 있으면 사용 오류\n'
else
    printf '  FAIL  %-3s 배치에 없는 이름이 있으면 사용 오류 (기대 64)\n' "$BATCH_STATUS"
    FAILURES=$((FAILURES + 1))
fi
# 실패해도 표준 출력은 완전해야 한다. 이것이 깨지면 스윕 한 건의 오타가 나머지 답을 버린다.
# `found` 결과는 인덱스가 있어야 나오므로 여기서 재지 않는다. 단위 테스트가 덮는다.
for needle in '"format" : "symbol-query-batch"' '"status" : "notFound"' '"version" : 1'; do
    if grep -q -- "$needle" <<< "$BATCH_OUT"; then
        printf '  ok        종료 64 에도 결과가 나온다: %s\n' "$needle"
    else
        printf '  FAIL      종료 64 에도 결과가 나온다: %s 없음\n' "$needle"
        FAILURES=$((FAILURES + 1))
    fi
done
# 요청 셋이 전부 결과로 돌아왔는지. 하나가 없어서 나머지를 버리면 이 수가 준다.
BATCH_RESULTS="$(grep -c '"requested"' <<< "$BATCH_OUT")"
if [[ "$BATCH_RESULTS" -eq 3 ]]; then
    printf '  ok        요청 셋이 모두 결과로 돌아온다\n'
else
    printf '  FAIL      요청 셋이 모두 결과로 돌아온다 (%s 개)\n' "$BATCH_RESULTS"
    FAILURES=$((FAILURES + 1))
fi
if grep -q -- "NoSuchDeclaration" <<< "$BATCH_ERR"; then
    printf '  ok        오류 메시지가 없는 이름을 지목한다\n'
else
    printf '  FAIL      오류 메시지가 없는 이름을 지목한다\n'
    FAILURES=$((FAILURES + 1))
fi

echo "출력 내용"
expect_output "cartograph"      "도움말에 도구 이름"           --help
expect_output "--since cannot be combined with query" "since 거부에 이유" query Foo --since HEAD
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
