#!/usr/bin/env bash
#
# 오탐 코퍼스를 실제로 컴파일해 분석 결과를 고정한다.
#
# 단위 테스트는 손으로 만든 스냅샷 위에서 돈다. 그래서 "컴파일러가 인덱스에
# 무엇을 남기는가"는 검증하지 못하고, 이 저장소에서 찾아낸 오탐은 전부 그
# 지점에 있었다. 여기서는 진짜로 빌드한 뒤 발견 목록을 통째로 비교한다.
#
# 정확히 일치를 요구하는 이유: 새 오탐이 생기는 것과 잡던 것을 놓치는 것을
# 모두 잡아야 한다. 한쪽만 보면 나머지 절반이 조용히 지나간다.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$REPO_ROOT/Fixtures/FalsePositiveCorpus"
CARTOGRAPH="${1:-}"

if [ -z "$CARTOGRAPH" ]; then
    CARTOGRAPH="$(swift build --package-path "$REPO_ROOT" -c release --show-bin-path)/cartograph"
fi
if [ ! -x "$CARTOGRAPH" ]; then
    echo "실행 파일을 찾지 못했습니다: $CARTOGRAPH" >&2
    exit 2
fi

echo "픽스처를 빌드합니다(인덱스 스토어가 필요합니다)."
swift build --package-path "$FIXTURE" --build-tests >/dev/null

# 캐시가 결과를 가리지 않도록 매번 새로 분석한다. 캐시 자체는 별도 테스트가 있다.
rm -rf "${TMPDIR:-/tmp}/cartograph-syntax-cache"

actual_unused="$(
    "$CARTOGRAPH" dead --project "$FIXTURE" --report-format json 2>/dev/null |
        python3 -c "
import json, sys
document = json.load(sys.stdin)
names = sorted(d['message'] for d in document['diagnostics'] if d['ruleIdentifier'] == 'unused-symbol')
print('\n'.join(names))
"
)"
expected_unused="$(cat "$FIXTURE/expected-unused.txt")"

if [ "$actual_unused" != "$expected_unused" ]; then
    echo "미사용 보고가 기대와 다릅니다." >&2
    diff <(echo "$expected_unused") <(echo "$actual_unused") || true
    exit 1
fi
echo "  ok  미사용 보고 $(echo "$expected_unused" | grep -c .)건이 기대와 일치"

actual_test_only="$(
    "$CARTOGRAPH" dead --project "$FIXTURE" --report-test-only --report-format json 2>/dev/null |
        python3 -c "
import json, sys
document = json.load(sys.stdin)
names = sorted(d['message'] for d in document['diagnostics'] if d['ruleIdentifier'] == 'test-only-symbol')
print('\n'.join(names))
"
)"
expected_test_only="$(cat "$FIXTURE/expected-test-only.txt")"

if [ "$actual_test_only" != "$expected_test_only" ]; then
    echo "테스트 전용 보고가 기대와 다릅니다." >&2
    diff <(echo "$expected_test_only") <(echo "$actual_test_only") || true
    exit 1
fi
echo "  ok  테스트 전용 보고 $(echo "$expected_test_only" | grep -c .)건이 기대와 일치"

# public 선언은 전부 보존되어야 한다. 구문 정보가 붙지 않은 선언만 여기서 드러난다.
# 백틱 이름·실패 가능 이니셜라이저·속성이 윗줄인 선언·지역 선언에 가려진 멤버가
# 전부 이 한 줄에 걸린다. 그것이 이 저장소가 실제로 겪은 오탐의 형태다.
# 남는 것은 `private` 로 선언한 것뿐이고, 그 목록도 함께 고정한다.
actual_retained="$(
    "$CARTOGRAPH" dead --project "$FIXTURE" --retain-public --report-format json 2>/dev/null |
        python3 -c "
import json, sys
document = json.load(sys.stdin)
names = sorted(d['message'] for d in document['diagnostics'] if d['ruleIdentifier'] == 'unused-symbol')
print('\n'.join(names))
"
)"
expected_retained="$(cat "$FIXTURE/expected-retain-public.txt")"

if [ "$actual_retained" != "$expected_retained" ]; then
    echo "--retain-public 보고가 기대와 다릅니다. 구문 정보가 붙지 않은 선언이 있습니다." >&2
    diff <(echo "$expected_retained") <(echo "$actual_retained") || true
    exit 1
fi
echo "  ok  --retain-public 보고가 기대와 일치(public 선언의 접근 수준이 제대로 읽힘)"

echo
echo "통과"
