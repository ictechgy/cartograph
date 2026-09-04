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

# 언어 경계. 스캐너가 구문에서 뽑은 사실에 진짜 인덱스의 USR 이 붙는지는 여기서만 확인된다.
# 생성 시각·도구 버전·절대 경로는 실행마다 다르므로 자리 표시자로 바꿔 통째로 비교한다.
actual_bridges="$(
    "$CARTOGRAPH" bridges --project "$FIXTURE" 2>/dev/null |
        python3 -c "
import json, sys
document = json.load(sys.stdin)
document['generatedAt'] = '<generatedAt>'
document['tool']['version'] = '<version>'
project = document['project']
document['project'] = '<project>'
for fact in document['facts']:
    fact['location']['path'] = fact['location']['path'].replace(project, '<project>')
print(json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False))
"
)"
expected_bridges="$(cat "$FIXTURE/expected-bridges.json")"

if [ "$actual_bridges" != "$expected_bridges" ]; then
    echo "브리지 사실이 기대와 다릅니다." >&2
    diff <(echo "$expected_bridges") <(echo "$actual_bridges") || true
    exit 1
fi
echo "  ok  브리지 사실이 기대와 일치(구문의 리터럴에 인덱스의 USR 이 붙음)"

# 혼합 프로젝트에서도 isthmus 0.1에 넘길 Flutter 문서를 분리할 수 있어야 한다.
flutter_bridges="$("$CARTOGRAPH" bridges --project "$FIXTURE" --target flutter 2>/dev/null)"
python3 -c "
import json, sys
document = json.loads(sys.argv[1])
assert document['target'] == 'flutter'
assert document['facts']
assert {fact['kind'] for fact in document['facts']} <= {'channel-register', 'method-handle'}
assert not any(item.lower().lstrip().startswith('mixed-targets') for item in document['limitations'])
" "$flutter_bridges"
echo "  ok  --target flutter 가 혼합 프로젝트에서 Flutter 사실만 분리"

react_native_bridges="$("$CARTOGRAPH" bridges --project "$FIXTURE" --target react-native 2>/dev/null)"
python3 -c "
import json, sys
document = json.loads(sys.argv[1])
assert document['target'] == 'react-native'
assert document['facts']
assert {fact['kind'] for fact in document['facts']} <= {'module-export', 'method-handle', 'component-export'}
assert not any(item.lower().lstrip().startswith('mixed-targets') for item in document['limitations'])
" "$react_native_bridges"
echo "  ok  --target react-native 가 혼합 프로젝트에서 RN 사실만 분리"

# isthmus 가 돌려준 보존 근거를 걸면 Dart 가 부르는 핸들러가 보고에서 빠져야 한다.
# 이 목록은 위의 미사용 목록과 달라야 한다. 같다면 파일이 아무 일도 하지 않은 것이다.
actual_with_retentions="$(
    "$CARTOGRAPH" dead --project "$FIXTURE" --report-format json \
        --external-retentions "$FIXTURE/external-retentions.json" 2>/dev/null |
        python3 -c "
import json, sys
document = json.load(sys.stdin)
names = sorted(d['message'] for d in document['diagnostics'] if d['ruleIdentifier'] == 'unused-symbol')
print('\n'.join(names))
"
)"
expected_with_retentions="$(cat "$FIXTURE/expected-unused-with-retentions.txt")"

if [ "$actual_with_retentions" != "$expected_with_retentions" ]; then
    echo "--external-retentions 보고가 기대와 다릅니다." >&2
    diff <(echo "$expected_with_retentions") <(echo "$actual_with_retentions") || true
    exit 1
fi
if [ "$actual_with_retentions" = "$actual_unused" ]; then
    echo "--external-retentions 가 보고를 바꾸지 않았습니다. 근거 파일이 반영되지 않았습니다." >&2
    exit 1
fi
echo "  ok  --external-retentions 보고가 기대와 일치(경계 너머의 호출자가 핸들러를 살림)"

# 근거는 답의 일부다. 살아남았다는 말만 하고 누가 불렀는지 빠지면 사용자는 파일을 열어야 한다.
explanation="$(
    "$CARTOGRAPH" dead --project "$FIXTURE" --external-retentions "$FIXTURE/external-retentions.json" \
        --explain CameraBridge 2>/dev/null
)"
if ! grep -q "evidence: dart lib/camera.dart:42 invokes 'takePhoto' on channel 'com.example/camera'" <<< "$explanation"; then
    echo "--explain 이 외부 근거를 문장으로 만들지 못했습니다:" >&2
    echo "$explanation" >&2
    exit 1
fi
echo "  ok  --explain 이 외부 근거를 문장으로 만듦"

# Objective-C 소스는 인덱스로 분석되지 않는다. 그 사실이 실제 프로젝트에서 세어져 나와야 한다.
# 이 저장소 밖의 iOS 프로젝트는 전부 순수 Swift 라 .m 이 없었고, 이 한계가 실제로 뜨는지는
# 여기서만 확인된다.
limitations="$(
    "$CARTOGRAPH" query CameraBridge --project "$FIXTURE" 2>/dev/null |
        python3 -c "import json, sys; print('\n'.join(json.load(sys.stdin)['limitations']))"
)"
if ! grep -q "^objective-c-sources: 1 file(s) are not analysed" <<< "$limitations"; then
    echo "query 의 limitations 에 objective-c-sources 가 없습니다:" >&2
    echo "$limitations" >&2
    exit 1
fi
echo "  ok  Objective-C 소스 1개가 limitations 에 세어짐"

echo
echo "통과"
