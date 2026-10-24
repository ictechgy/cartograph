#!/usr/bin/env bash
#
# 문서화한 CLI 계약이 실제로 지켜지는지 확인한다.
#
# 사용법:
#   Scripts/verify-cli-contract.sh [바이너리 경로]
#
# 필요 도구: 빌드된 cartograph, python3, jq (README 배치 예제 검증),
# xcrun swiftc (베이스라인 계약에 쓸 실제 인덱스).
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
for subcommand in graph cycles dead fix query impact affected snapshot runtime check serve dataflow bridges schema routes metrics rules baseline init skill; do
    expect_status 0 "$subcommand --help" "$subcommand" --help
done
expect_status 0 "runtime plan --help" runtime plan --help
expect_status 0 "runtime check --help" runtime check --help
expect_status 0 "runtime discover --help" runtime discover --help
expect_status 0 "runtime collect --help" runtime collect --help
expect_status 0 "runtime prepare-coredata --help" runtime prepare-coredata --help
expect_status 0 "serve EOF 종료(빌드 불필요)" serve
expect_output "--rn-events" "RN 이벤트 플래그 도움말" bridges --help

echo "종료 코드 64 — 사용 오류"
expect_status 64 "알 수 없는 옵션"     --no-such-option
expect_status 64 "알 수 없는 하위 명령" no-such-command
expect_status 64 "RN 이벤트와 Basic 동시" bridges --rn-events --messages
expect_status 64 "RN 이벤트와 Flutter 스트림 동시" bridges --rn-events --events
expect_status 64 "RN 이벤트에 Flutter target" bridges --rn-events --target flutter
expect_status 64 "잘못된 열거형 값"    graph --level galaxy
expect_status 64 "잘못된 형식 값"      dead --report-format yaml
expect_status 64 "변경 줄에는 기준 필요" dead --since-lines
expect_status 64 "변경 줄에는 빈 기준 거부" dead --since-lines --since ""
expect_status 64 "변경 줄은 dead 전용" cycles --since HEAD --since-lines
expect_status 64 "변경 줄과 설명 동시" dead --since HEAD --since-lines --explain Foo
expect_status 64 "파일 요약은 JSON 전용" dead --file-summary --report-format text
expect_status 64 "생성 제안은 JSON 전용" dead --generated-suggestions --report-format sarif
expect_status 64 "파일 요약과 설명 동시" dead --file-summary --explain Foo
expect_status 64 "생성 제안과 설명 동시" dead --generated-suggestions --explain Foo
expect_status 64 "질의 대상 누락"      query
expect_status 64 "영향 선택자 누락"    impact
expect_status 64 "값 흐름 대상 누락"    dataflow
expect_status 64 "0 이하의 깊이"       query Foo --depth 0
expect_status 64 "0 이하의 값 흐름 예산" dataflow Foo --max-contexts 0
expect_status 64 "값 흐름 호출 깊이 범위" dataflow Foo --call-depth 9
expect_status 64 "질의 대상과 배치 동시" query Foo --batch /dev/null
expect_status 64 "미사용과 level 동시"   dead --level module
expect_status 64 "수정과 level 동시"     fix --level module
expect_status 64 "수정과 형식 동시"      fix --report-format text
expect_status 64 "수정 잘못된 형식"      fix --format yaml
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
expect_status 64 "순회 문서와 파일 선택" impact --file Sources/App.swift --format language-traversal
expect_status 64 "순회 문서와 과거 스냅샷" impact Foo --format language-traversal --before /dev/null
expect_status 64 "순회 문서 결과 수 범위" impact Foo --format language-traversal --limit 100001
expect_status 64 "순회 문서 잘못된 시각" impact Foo --format language-traversal --generated-at yesterday
expect_status 64 "순회 방향만 단독"     impact Foo --direction dependencies
expect_status 64 "순회 잘못된 방향"     impact Foo --format language-traversal --direction sideways
expect_status 64 "순회 root 제어 문자"   impact "$(printf 'Foo\001')" --format language-traversal
expect_status 64 "순회 revision 단독"   impact Foo --revision abc
expect_status 64 "순회 빈 revision"     impact Foo --format language-traversal --revision ""
expect_status 64 "테스트 영향 선택자 누락" affected
expect_status 64 "테스트 영향 선택자 혼용" affected Foo --file Sources/App.swift
expect_status 64 "테스트 영향과 level 동시" affected Foo --level module
expect_status 64 "테스트 영향과 형식 동시" affected Foo --report-format json
expect_status 64 "테스트 영향과 strict 동시" affected Foo --strict
expect_status 64 "테스트 영향 잘못된 형식" affected Foo --format yaml
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
expect_status 64 "스냅샷 0 MiB 예산" snapshot --snapshot-max-mib 0
expect_status 64 "스냅샷 상한 초과 예산" snapshot --snapshot-max-mib 1025
expect_status 64 "비교 없는 스냅샷 예산" impact Foo --snapshot-max-mib 512
expect_status 64 "과거 비교 상한 초과 예산" impact Foo --before /dev/null --snapshot-max-mib 1025
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
expect_status 64 "자기 간선에 해상도 없음" graph --include-self-loops
expect_status 64 "자기 간선과 롤업 동시" graph --include-self-loops --level module
expect_status 64 "자기 간선과 선언 투영 동시" graph --include-self-loops --level symbol --format json \
  --declaration-projection --primary-module Main
expect_status 64 "브리지와 형식 동시"    bridges --report-format json
expect_status 64 "브리지와 strict 동시"  bridges --strict
expect_status 64 "스키마와 형식 동시"    schema --report-format json
expect_status 64 "스키마와 strict 동시"  schema --strict
expect_status 64 "스키마와 since 동시"   schema --since HEAD
expect_status 64 "스키마와 level 동시"   schema --level module
expect_status 64 "잘못된 스키마 형식"    schema --format yaml
expect_status 64 "호출과 형식 동시"      routes --report-format json
expect_status 64 "호출과 strict 동시"    routes --strict
expect_status 64 "호출과 since 동시"     routes --since HEAD
expect_status 64 "호출과 level 동시"     routes --level module
expect_status 64 "잘못된 호출 형식"      routes --format yaml
expect_status 64 "빈 호출 서비스"        routes --service ""
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
# route-call 의 본체는 구문 스캔이다. 자동 탐색이 스토어를 못 찾으면 USR 없이 문서를 낸다.
expect_status 0 "호출: 인덱스 없음"    routes --project "$MISSING"
expect_output '"target" : "http"' "호출: 사실 0건도 http 문서" routes --project "$MISSING"
expect_status 2 "호출: 명시한 인덱스 경로 없음" routes --project "$MISSING" --index-store "$MISSING/nope"
# 선언 파일을 지정했는데 못 읽으면 조용히 0건을 내지 않는다. 소비자는 그것을 "호출 없음"으로 읽는다.
expect_status 2 "호출: 없는 선언 파일" routes --project "$MISSING" --wrappers "$MISSING/none.json"
expect_status 2 "호출: 깨진 선언 파일" routes --project "$MISSING" --wrappers "$MISSING/broken.json"
# 라이브러리 규칙은 선언 없이 동작한다. Moya case 하나가 사실 하나이고 path 의 `?` 는 `%3F` 로 전송된다.
mkdir -p "$MISSING/moya"
cat > "$MISSING/moya/API.swift" <<'SWIFT'
import Moya
enum API: TargetType {
    case search
    var baseURL: URL { URL(string: "https://api.example.com/v1")! }
    var path: String { "users/search?draft" }
    var method: Moya.Method { .get }
    var task: Task { .requestPlain }
    var headers: [String: String]? { nil }
}
SWIFT
expect_output '"channel" : "/v1/users/search%3Fdraft"' "호출: 선언 없는 Moya 타겟" routes --project "$MISSING/moya"
# 파일을 못 쓴 것과 순환을 찾은 것이 CI 에서 같은 신호가 되어서는 안 된다.
# 실제 쓰기 실패는 아래 "빈 인덱스" 픽스처 다음에서 검증한다 — 없는 부모
# 디렉터리는 -o 가 만들어 주므로 경로만으로는 실패하지 않는다.
expect_status 2 "깨진 베이스라인"      cycles --project "$MISSING" --baseline "$MISSING/broken.json"
# 이름 붙인 베이스라인 파일이 없으면 인자의 문제다(64). 조용히 건너뛰면 억제가 전부 사라지고, 2 로 끝나면 CI 는
# 인덱스를 의심한다. 인덱스를 열기 전에 확인하므로 인덱스가 없는 이 프로젝트에서도 64 다. 이름을 붙이지 않은 기본
# 파일(.cartograph-baseline.json)은 없어도 된다 — 위의 "인덱스 스토어 없음" 이 그 경우다.
for reader in dead cycles metrics rules fix check; do
    expect_status 64 "없는 베이스라인: $reader" "$reader" --project "$MISSING" --baseline "$MISSING/none.json"
done
expect_status 64 "없는 베이스라인: query" query Foo --project "$MISSING" --baseline "$MISSING/none.json"
mkdir -p "$MISSING/named"
printf 'baseline_path: none.json\n' > "$MISSING/named/.cartograph.yml"
expect_status 64 "설정의 baseline_path 가 가리키는 파일 없음" check --strict --project "$MISSING/named"
expect_status 64 "서버: 없는 --baseline 은 시작 전에 거부" serve --baseline "$MISSING/none.json"
# 세션은 첫 도구 호출 때 설정을 읽는다. 설정의 baseline_path 는 그때 도구 결과의 오류로 드러난다.
expect_status 0 "서버: 설정의 baseline_path 는 시작을 막지 않는다" serve --project "$MISSING/named"
# 외부 근거 파일은 지정했는데 없으면 조용히 넘어가지 않는다. 반영됐다고 믿고 지우면 앱이 깨진다.
expect_status 2 "없는 외부 근거 파일"  dead --project "$MISSING" --external-retentions "$MISSING/none.json"
expect_status 2 "깨진 외부 근거 파일"  dead --project "$MISSING" --external-retentions "$MISSING/broken.json"
# 요청 파일은 인덱스를 열기 전에 읽는다. 인덱스가 없는 프로젝트에서도 배치 오류가 먼저 난다.
expect_status 64 "배치 검사가 색인보다 먼저" query --batch "$MISSING/badbatch.json" --project "$MISSING"
expect_status 64 "배치 질의와 since 동시" query --batch "$MISSING/batch.json" --since HEAD
expect_status 2 "배치도 인덱스는 필요"  query --batch "$MISSING/batch.json" --project "$MISSING"

# FIFO를 부모 셸에서 직접 열면 회귀가 전체 검사를 멈춘다. 제한 시간은 바이너리 자식에만 건다.
python3 - "$BINARY" "$MISSING" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
limit = 1024 * 1024
prefix = '["한글"]'.encode()
failures = 0
with tempfile.TemporaryDirectory(prefix="batch-read-", dir=sys.argv[2]) as temporary:
    root = Path(temporary)
    missing_index = root / "missing-index"
    cases = []
    for name, size, status in [
        ("ordinary", len(prefix), 2),
        ("exact-limit", limit, 2),
        ("limit-plus-one", limit + 1, 64),
        ("larger-file", limit * 4, 64),
    ]:
        path = root / f"{name}.json"
        path.write_bytes(prefix + b" " * (size - len(prefix)))
        reason = str(missing_index) if status == 2 else f"the file exceeds {limit} bytes"
        cases.append((name, path, status, reason))
        link = root / f"{name}-link.json"
        link.symlink_to(path)
        cases.append((f"{name}-symlink", link, status, reason))

    fifo = root / "requests.fifo"
    os.mkfifo(fifo)
    for name, path in [("directory", root), ("device", Path("/dev/null")), ("fifo", fifo)]:
        cases.append((name, path, 64, "Cannot read the batch requests at"))
        link = root / f"{name}-link"
        link.symlink_to(path)
        cases.append((f"{name}-symlink", link, 64, "Cannot read the batch requests at"))

    for name, path, expected_status, reason in cases:
        try:
            result = subprocess.run(
                [binary, "query", "--batch", str(path), "--project", str(root),
                 "--index-store", str(missing_index)],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10,
            )
        except subprocess.TimeoutExpired:
            print(f"  FAIL      배치 {name}: 10초 안에 종료하지 않았다")
            failures += 1
            continue
        if (result.returncode == expected_status and not result.stdout
                and reason in result.stderr and "not a JSON array" not in result.stderr
                and f"the file is {limit + 1} bytes" not in result.stderr):
            print(f"  ok    {result.returncode:<3} 배치 {name}")
        else:
            print(f"  FAIL  {result.returncode:<3} 배치 {name} (기대 {expected_status}): {result.stderr}")
            failures += 1
sys.exit(bool(failures))
PY
if [[ "$?" -ne 0 ]]; then
    FAILURES=$((FAILURES + 1))
fi

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
expect_status 64 "빈 인덱스 순회 root 없음" impact Missing --format language-traversal \
    --project "$EMPTY" --allow-empty-index
# --roots-from 은 인덱스를 열기 전에 읽고 검사한다. 형식·내용 오류는 전부 사용 오류(64)다.
printf '# 주석\n\ns:Missing\n' > "$EMPTY/roots.txt"
printf 's:A\001\n' > "$EMPTY/roots-control.txt"
printf '# 주석뿐\n' > "$EMPTY/roots-empty.txt"
printf '["s:A", 1]' > "$EMPTY/roots-bad.json"
head -c 16777217 /dev/zero | tr '\0' ' ' > "$EMPTY/roots-large.txt"
ROOTS_ARGS=(--format language-traversal --project "$EMPTY" --allow-empty-index)
expect_status 64 "순회 root 파일 없음"      impact "${ROOTS_ARGS[@]}" --roots-from "$EMPTY/none.txt"
expect_status 64 "순회 root 파일 제어 문자" impact "${ROOTS_ARGS[@]}" --roots-from "$EMPTY/roots-control.txt"
expect_status 64 "순회 root 파일 비어 있음" impact "${ROOTS_ARGS[@]}" --roots-from "$EMPTY/roots-empty.txt"
expect_status 64 "순회 root 파일 JSON 위반" impact "${ROOTS_ARGS[@]}" --roots-from "$EMPTY/roots-bad.json"
expect_status 64 "순회 root 파일 16MiB 초과" impact "${ROOTS_ARGS[@]}" --roots-from "$EMPTY/roots-large.txt"
expect_status 64 "빈 표준 입력 root"        impact "${ROOTS_ARGS[@]}" --roots-from -
expect_status 64 "root 파일은 순회 문서 전용" impact --roots-from "$EMPTY/roots.txt" --project "$EMPTY" --allow-empty-index
# 해석하지 못한 root 도 문서에 싣고 나서 64 로 끝난다. 사용 오류와 구분하려고 문서의 root id 를 본다.
expect_output '"id" : "s:Missing"' "root 파일의 root 가 문서에 실린다" impact "${ROOTS_ARGS[@]}" --roots-from "$EMPTY/roots.txt"
STDIN_OUT="$(printf 's:FromStdin\n' | "$BINARY" impact s:First "${ROOTS_ARGS[@]}" --roots-from - 2>/dev/null)"
if grep -q -- '"id" : "s:First"' <<< "$STDIN_OUT" && grep -q -- '"id" : "s:FromStdin"' <<< "$STDIN_OUT"; then
    printf '  ok        표준 입력 root 가 위치 인자 root 와 함께 실린다\n'
else
    printf '  FAIL      표준 입력 root 가 위치 인자 root 와 함께 실린다\n'
    FAILURES=$((FAILURES + 1))
fi
# 목적지를 디렉터리로 준다. 파일로 못 쓰는 자리이므로 이 실패는 진짜 쓰기 실패다.
expect_status 2 "출력 파일 쓰기 실패"  graph --project "$EMPTY" --allow-empty-index -o "$EMPTY"

# 설정 파일의 baseline_path 는 읽기 위치일 뿐, 쓰기 목적지가 아니다. 분석 대상
# 저장소의 설정에 절대 경로를 심어 두고 baseline 을 돌리면 그 파일이 덮여써졌다.
CFG="$(mktemp -d "${TMPDIR:-/tmp}/contract.XXXXXX")"
# 아래 "베이스라인" 절의 픽스처. swiftc 가 인덱스에 남기는 경로와 표기가 같도록 링크를 푼 경로를 쓴다.
# MOVED 는 같은 프로젝트를 다른 경로에 체크아웃한 자리(CI)다. ROOTED 는 설정 파일 경로 절의 픽스처다.
DEBT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/contract.XXXXXX")" && pwd -P)"
MOVED="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/contract.XXXXXX")" && pwd -P)"
ROOTED="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/contract.XXXXXX")" && pwd -P)"
trap 'rm -rf "$MISSING" "$EMPTY" "$CFG" "$DEBT" "$MOVED" "$ROOTED"' EXIT
printf 'baseline_path: /tmp/cartograph-hostile-baseline.json\n' > "$CFG/.cartograph.yml"
expect_status 64 "설정의 baseline_path 로는 쓰지 않는다" \
    baseline --project "$CFG" --index-store "$EMPTY/.build/index/store" --allow-empty-index
expect_status 0 "쓰기 목적지를 명시하면 기록한다" \
    baseline --project "$EMPTY" --allow-empty-index --write "$EMPTY/baseline.json"
# baseline_path 를 먼저 커밋하고 그 자리에 처음 기록하는 흐름. 기록과 베이스라인을 읽지 않는 명령은 파일이 아직
# 없어도 돌고, 베이스라인을 읽는 명령은 기록이 생길 때까지 64 로 멈춘다.
mkdir -p "$CFG/named"
printf 'baseline_path: recorded.json\n' > "$CFG/named/.cartograph.yml"
NAMED_ARGS=(--project "$CFG/named" --index-store "$EMPTY/.build/index/store" --allow-empty-index)
expect_status 64 "기록 전: 베이스라인을 읽는 명령"     dead "${NAMED_ARGS[@]}"
expect_status 0 "기록 전: 베이스라인을 읽지 않는 명령"  graph "${NAMED_ARGS[@]}"
expect_status 0 "없는 baseline_path 자리에 처음 기록"  baseline "${NAMED_ARGS[@]}" --write "$CFG/named/recorded.json"
expect_status 0 "기록 뒤: 베이스라인을 읽는 명령"      dead "${NAMED_ARGS[@]}"

echo "종료 코드 0 — 빈 인덱스 탈출구"
expect_status 0 "빈 인덱스 허용"       dead --strict --project "$EMPTY" --allow-empty-index

echo "종료 코드 0 — 베이스라인이 기록한 기존 부채"
# README 는 baseline 을 "새 문제만 빌드를 실패시키는" 도입 경로로 약속한다. check 는 모듈·타입 두 레벨
# 순환에 베이스라인을 적용하는데, baseline 이 설정 레벨(module)만 기록하면 Swift 에서 실제로 생기는 타입
# 순환이 baseline 뒤에도 check --strict 를 계속 세운다. fix 도 베이스라인이 받아들인 발견은 건드리지 않는다고
# 약속하므로 baseline 이 쓰지 않는 import 를 기록해야 드라이런 fix --strict 가 기존 import 로 실패하지 않는다.
# 실제 인덱스가 필요해 swiftc 로 한 파일을 색인한다. import 는 Foundation 보다 모듈 캐시를 짓는 시간이 짧은
# Darwin 이다.
mkdir -p "$DEBT/Sources" "$MOVED/Sources"
cat > "$DEBT/Sources/Debt.swift" <<'SWIFT'
import Darwin

struct Left {
    func next() -> Right { Right() }
}

struct Right {
    func next() -> Left { Left() }
}
SWIFT
# 체크아웃 디렉터리 하나의 Sources/Debt.swift 를 색인한다. 모듈 캐시는 모든 체크아웃이 함께 쓴다.
# 둘째 인자를 주면 그 자리에 스토어를 둔다(기본은 자동 탐색이 찾는 .build/index/store).
index_debt() {
    xcrun swiftc -c -parse-as-library -module-name Debt -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
        -module-cache-path "$DEBT/ModuleCache" -index-store-path "${2:-$1/.build/index/store}" \
        "$1/Sources/Debt.swift" -o "$1/Debt.o" > "$1/swiftc.log" 2>&1
}
cp "$DEBT/Sources/Debt.swift" "$MOVED/Sources/Debt.swift"
if index_debt "$DEBT" && index_debt "$MOVED"; then
    # 기록 전에는 실패해야 아래의 0 이 아무것도 검사하지 않은 0 이 아니다.
    expect_status 1 "기록 전: 타입 순환"   cycles --level type --strict --project "$DEBT"
    expect_status 1 "기록 전: 통합 검사"   check --strict --project "$DEBT"
    expect_status 1 "기록 전: 순환 설명"   cycles --explain Left --level type --strict --project "$DEBT"
    expect_status 1 "기록 전: 수정 계획"   fix --strict --project "$DEBT"
    expect_status 0 "기존 부채 기록"       baseline --project "$DEBT" --write "$DEBT/.cartograph-baseline.json"
    expect_status 0 "기록 뒤: 통합 검사"   check --strict --project "$DEBT"
    expect_status 0 "기록 뒤: 타입 순환"   cycles --level type --strict --project "$DEBT"
    # 목록과 설명이 같은 베이스라인에 반대 판정을 내면 "아직 게이트에 걸리는가"를 묻는 스크립트가 속는다.
    expect_status 0 "기록 뒤: 순환 설명"   cycles --explain Left --level type --strict --project "$DEBT"
    expect_status 0 "기록 뒤: 수정 계획"   fix --strict --project "$DEBT"
    # 커밋한 베이스라인은 다른 경로의 체크아웃(CI)에서도 맞아야 한다. import 지문이 기록한 기계의 절대
    # 경로(사용자 홈 포함)를 품으면 그 경로가 커밋되고, 옮긴 자리에서는 하나도 맞지 않는다.
    if grep -qF -- "$DEBT" "$DEBT/.cartograph-baseline.json"; then
        printf '  FAIL      베이스라인에 기록한 체크아웃의 절대 경로가 남는다\n'
        FAILURES=$((FAILURES + 1))
    else
        printf '  ok        베이스라인에 기록한 체크아웃의 절대 경로가 남지 않는다\n'
    fi
    cp "$DEBT/.cartograph-baseline.json" "$MOVED/.cartograph-baseline.json"
    expect_status 0 "옮긴 체크아웃: 통합 검사" check --strict --project "$MOVED"
    expect_status 0 "옮긴 체크아웃: 수정 계획" fix --strict --project "$MOVED"
else
    printf '  FAIL      베이스라인 계약에 쓸 인덱스를 만들지 못했다 (xcrun swiftc):\n'
    cat "$DEBT/swiftc.log" "$MOVED/swiftc.log" 2>/dev/null | sed 's/^/            /'
    FAILURES=$((FAILURES + 1))
fi

echo "설정 파일의 인덱스 경로 — 실행한 자리가 아니라 프로젝트 루트 기준"
# 이 스크립트는 저장소 루트에서 --project 로 다른 디렉터리를 분석한다. 모노레포 루트에서 하위 앱을 분석하는
# CI(공식 액션)와 같은 모양이다. 설정의 상대 경로를 작업 디렉터리 기준으로 풀면 스토어를 저장소 루트에서 찾아
# 종료 코드 2 로 끝나고, 프로젝트 루트 기준이면 타입 순환을 찾아 1 로 끝난다. 스토어는 `xcodebuild
# -derivedDataPath DerivedData` 가 남기는 평면 배치에 둔다.
mkdir -p "$ROOTED/Sources"
cp "$DEBT/Sources/Debt.swift" "$ROOTED/Sources/Debt.swift"
if index_debt "$ROOTED" "$ROOTED/DerivedData/Index.noindex/DataStore"; then
    printf 'derived_data_path: DerivedData\n' > "$ROOTED/.cartograph.yml"
    expect_status 1 "derived_data_path 는 프로젝트 루트 기준" cycles --level type --strict --project "$ROOTED"
    printf 'index_store_path: DerivedData/Index.noindex/DataStore\n' > "$ROOTED/.cartograph.yml"
    expect_status 1 "index_store_path 는 프로젝트 루트 기준" cycles --level type --strict --project "$ROOTED"
else
    printf '  FAIL      설정 경로 계약에 쓸 인덱스를 만들지 못했다 (xcrun swiftc):\n'
    sed 's/^/            /' "$ROOTED/swiftc.log" 2>/dev/null
    FAILURES=$((FAILURES + 1))
fi

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

echo "README — dead 리포트에서 배치 요청 추출"
# 문서의 셸 코드를 그대로 실행한다. CLI 만 대역으로 바꾸고 jq 필터와 분기는 실제로 돈다.
# JSONDiagnosticReporter 의 문서 모양과 AnalysisDiagnostics 의 합성 subject 를 함께 고정한다.
# 에이전트는 이 예시를 프로젝트 루트에서 그대로 돌린다. 중간 파일은 실행마다 mktemp -d 가 만든
# 비공개 디렉터리에만 쓰고 작업 트리에는 아무것도 남기지 않는지도 함께 본다.
if python3 - <<'PY'
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile


assert shutil.which("jq"), "README sweep regression requires jq"


def diagnostic(rule, subject):
    return {
        "ruleIdentifier": rule, "severity": "warning", "message": "Fixture finding",
        "subject": subject, "details": [],
        "location": {"path": "Sources/App.swift", "line": 1, "column": 1},
    }


unused = [diagnostic("unused-symbol", f"s:3App{len(f'Type{i}')}Type{i}V") for i in range(1001)]
non_symbols = [
    diagnostic("unused-import", "import:Sources/App.swift:Foundation"),
    diagnostic("superfluous-ignore", "s:3App4LiveV|ignore"),
    diagnostic("superfluous-ignore", "ignore:file:Sources/App.swift"),
]
cases = [
    ("mixed", non_symbols[:1] + unused[:1] + non_symbols[1:] + unused[1:2], unused[:2]),
    ("clean", [], []),
    ("non-symbol-only", non_symbols, []),
    ("1000", unused[:1000], unused[:1000]),
    ("1001", unused, unused),
]
stub = '''cartograph() {
    if [[ "$*" == "dead --report-format json" ]]; then
        cat "$SWEEP_REPORT"
    elif [[ $# -eq 3 && "$1" == "query" && "$2" == "--batch" ]]; then
        printf '%s\\n' "$3" > "$SWEEP_QUERY_PATH"
        cat "$3" >> "$SWEEP_QUERY"
    else
        return 97
    fi
}
'''
for readme in ("README.md", "README.ko.md"):
    match = re.search(r"<!-- dead-to-batch-example -->\n```bash\n(.*?)\n```", Path(readme).read_text(), re.S)
    assert match is not None, f"{readme}: documented sweep is missing"
    for name, diagnostics, selected in cases:
        expected = [item["subject"] for item in selected]
        with tempfile.TemporaryDirectory(prefix="cartograph-sweep-") as temp:
            work = Path(temp)
            # 스윕을 돌리는 체크아웃 대역과 mktemp 가 쓸 임시 디렉터리를 나눈다.
            checkout = work / "checkout"
            private_tmp = work / "tmp"
            checkout.mkdir()
            private_tmp.mkdir()
            report = work / "report.json"
            query = work / "query.json"
            query_path = work / "query-path.txt"
            report.write_text(json.dumps({
                "tool": "cartograph", "version": "fixture", "command": "dead",
                "subject": "symbol graph", "suppressedCount": 0, "diagnostics": diagnostics,
            }))
            result = subprocess.run(
                ["bash", "-c", stub + match[1]], cwd=checkout, capture_output=True, text=True, timeout=10,
                env={**os.environ, "TMPDIR": str(private_tmp), "SWEEP_REPORT": str(report),
                     "SWEEP_QUERY": str(query), "SWEEP_QUERY_PATH": str(query_path)},
            )
            assert result.returncode == (64 if len(expected) > 1000 else 0), (readme, name, result.stderr)
            # 작업 트리의 고정 이름은 같은 이름의 파일을 덮어쓰고, 커밋될 파일을 남기고,
            # 같은 체크아웃의 병렬 세션끼리 서로의 요청을 덮어쓴다.
            assert not any(checkout.iterdir()), (readme, name, "sweep wrote into the working directory")
            sweeps = list(private_tmp.glob("cartograph-sweep.*"))
            assert len(sweeps) == 1, (readme, name, "expected one mktemp directory", sweeps)
            assert stat.S_IMODE(sweeps[0].stat().st_mode) == 0o700, (readme, name, "sweep directory is not private")
            requests = sweeps[0] / "requests.json"
            assert json.loads(requests.read_text()) == expected, (readme, name)
            if 0 < len(expected) <= 1000:
                assert query_path.read_text() == f"{requests}\n", (readme, name, "query read another file")
                assert json.loads(query.read_text()) == expected, (readme, name, "query requests")
            else:
                assert not query.exists(), (readme, name, "unexpected query")
            if len(expected) > 1000:
                # 셸 변수는 다음 명령까지 남지 않는다. 나눌 파일의 위치는 안내 문장이 알려야 한다.
                assert str(requests) in result.stderr, (readme, name, "split message must name the file")
            print(f"  ok        {readme}: {name}")
PY
then
    :
else
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

if python3 Scripts/verify-since-lines.py --cartograph "$BINARY"; then
    echo "  ok    변경 줄 Git/컴파일러/CLI 회귀"
else
    FAILURES=$((FAILURES + 1))
fi

echo
if [[ "$FAILURES" -eq 0 ]]; then
    echo "통과"
else
    echo "실패 $FAILURES 건" >&2
    exit 1
fi
