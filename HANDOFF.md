# Handoff

_Last updated: 2026-09-20_

현재 재개 정보만 담는다. 작업 규칙은 [AGENTS.md](AGENTS.md), 이전 세션의 원문·측정·판정은
[HANDOFF-HISTORY.md](HANDOFF-HISTORY.md)에 보존한다. 과거 Next Steps·미발행 표기는 당시 기록이다.

## Current Status

- cartograph **0.20.0**은 [GitHub](https://github.com/ictechgy/cartograph/releases/tag/0.20.0)와
  Homebrew에 발행됐다. 릴리스 소스는 `d7df412`, 브리지 확장 PR은
  [#123](https://github.com/ictechgy/cartograph/pull/123)이다.
- universal archive SHA256은 `833eb3c86deffc8e7c845297df57d41e35bb644bd5a943b09843e52075c6f072`.
  다운로드·arm64/x86_64·CLI 계약을 확인했고, 탭 [PR #49](https://github.com/ictechgy/homebrew-tap/pull/49)
  머지 뒤 호스트 upgrade·brew test도 통과했다. 이전 인증·설치 대기를 재개하지 않는다.
- Clang ObjC 그래프·실제 USR 보존과 Swift RN 전역 이벤트 추출이 포함된다. 일반 ObjC
  핸들러 스캔 전체나 RN 엔진·앱 런타임을 검증했다는 뜻은 아니다.
- Action 설치 예제는 영·한 README 모두 `ictechgy/cartograph@0.20.0`으로 고정한다.
  이 태그가 실제 `action.yml`을 포함함을 확인했다.
- 자매 발행본·왕복 검증의 최신 근거는 [isthmus HANDOFF](https://github.com/ictechgy/isthmus/blob/main/HANDOFF.md),
  사용법은 [README](README.md)를 따른다. 현재 branch·원격 머지 상태는 Git으로 확인한다.

## Next Steps

완료한 브리지 확장·0.20.0 발행·Homebrew 검증은 반복할 작업이 아니다. 이번 문서 정리 이후의
선택 후보는 다음과 같으며, 현재 사용자 요청 범위에서 필요한 항목만 진행한다.

- Action Marketplace 게시와 code scanning이 켜진 저장소의 SARIF 업로드 실측.
- public/fix/affected 코퍼스의 남은 골든·스킬 안내 보강. 기존 결과를 바꾸기 전 실제 입력을 확인한다.
- index DB 캐시 수명 관리와 `sourceCache` 메모리 계측. 성능 개선을 미리 단정하지 않는다.
- 경쟁 조사 C1~C5·S1~S6의 나머지 후보는 [과거 원장](HANDOFF-HISTORY.md#경쟁-조사--codegraph-대비-개선점-2026-09-18)과
  현재 코드를 대조한 뒤 범위를 선택한다. 런타임 텔레메트리는 연구 전용 보류다.

## Resume Prompt

HANDOFF.md와 적용 AGENTS.md를 읽고 branch/status를 확인해줘. cartograph 0.20.0의
GitHub·Homebrew 발행과 설치 검증은 완료됐어. README Action 예제도 0.20.0 태그를 사용해.
HANDOFF-HISTORY.md의 옛 Next Steps나 미발행 문구를 현재 지시로 되살리지 말고,
최신 사용자 요청과 실제 코드·PR·CI 근거로 다음 작업을 선택해. 사용자 파일을 보존하고
컴파일러 근거·분석 한계와 삭제 안전성 판정을 구분해.
