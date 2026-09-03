# Grove v0.3 — 화자 교정 중심 앱 계획

작성/조사일: 2026-09-03
상태: 초기 목표 사양을 보존한 계획 문서. 현재 구현·설치 상태는 `handoff.md`를 확인한다.

> 아래는 전체 목표 사양이며 모든 항목이 구현된 것은 아니다. 공개 문서에는 개인 회의에서 얻은
> 측정값·전사 품질 진단·참조 정답을 포함하지 않는다. 제품 정책과 정확도 검증은 별개다.

> AI가 작성한 작업 문서다. 현재 사용자 결정, 실제 코드, 고정된 모델 출력과 테스트를 우선한다.
> 공개 제품 도움말은 기능 참고이며 해당 제품의 품질·사용성 우위를 검증한 결과가 아니다.

## 1. 확정 방향과 아직 결정하지 않은 것

초기 선택은 MOSS 전사 + Sortformer streaming 화자 분리였다. 이후 사용자가 승인한 베타의 자동
정책은 MOSS + Ultra8(인원 미입력 또는 1–8명), MOSS + Community-1 exact(9명 이상)이며
Sortformer streaming은 수동 선택으로 유지한다. 이는 품질 우승 주장이 아니라 사용자 승인 정책이다.
상세한 제약은 `ultra8-option-and-speaker-count.md`를 따른다. 다음 기능을 핵심 범위로 둔다.

- 녹음·파일 가져오기 → 화자별 전사 → 원음을 들으며 교정 → 화자 포함 복사/TXT/Markdown 저장
- 한 발화의 화자 변경, 한 화자의 전체 발화 변경, 화자 이름 수정
- 개인·조직 용어를 제품 기본값에 하드코딩하지 않는 범용 앱
- 장시간 한글 읽기에 적합한 중립적인 서체·디자인
- 하나의 macOS 앱. 사용자에게 Python·Homebrew·CLI 설치를 요구하지 않는 것을 목표로 한다.

### 사용자 결정

| ID | 질문 | 권고/영향 |
|---|---|---|
| D1 | 5명 이상 회의 지원 | 필요. 엔진별 최대 화자 수와 실제 정확도 검증을 분리한다. 특정 인원수의 평가를 다른 인원수의 품질로 일반화하지 않는다. |
| D2 | 실시간 자막 | 불필요. 종료 후 정확 전사를 기본으로 한다. 임시 실시간 전사·이중 전사 UI를 이번 버전에서 제외한다. |
| D3 | AI 요약·결정·할 일 | 필수 아님. 어설픈 기능은 제거한다는 사용자 결정에 따라 이번 버전에서 제외하고 전사·교정·저장에 집중한다. |

추가로 사용자는 발화별 본문 수정도 명시했고 나머지는 권장안으로 진행하도록 승인했다.
화자 이름은 기본적으로 회의 안에서만 적용하고,
회의 간 음성 신원 자동 기억·클라우드 공유·캘린더·자동 녹음·AI 채팅은 별도 요구 전까지 제외한다.

## 2. 초기 구현 과제

아래는 계획 작성 시점의 수정 대상이다. 현재 구현 여부는 소스와 handoff를 확인한다.

| 현재 사실 | 근거 | 계획 |
|---|---|---|
| 제목에 `.serif`가 명시됨 | `MeetingDetailView.swift`, `LibraryHomeView.swift`, `NewMeetingSheet.swift`, `ReviewViews.swift` | 제목과 본문을 중립적인 Pretendard 중심으로 통일 |
| 정보 inspector가 항상 열림 | `MeetingDetailView.swift`의 `.inspector(isPresented: .constant(true))` | 기본 닫힘, 참석자/세부 정보 버튼으로 필요할 때 열기 |
| 화자는 단순 문자열 | `Models.swift`의 `TranscriptSegment.speaker` | source, engine cluster, 사용자가 보는 speaker ID를 분리 |
| 전사는 읽기용 `Text`, 구조적 편집 명령 없음 | `TranscriptView.swift` | 발화 편집·재배정·선택·Undo를 명령 단위로 구현 |
| 복사/TXT/Markdown exporter 없음 | 관련 소스 검색 | 동일 renderer로 클립보드와 파일 내용 일치 보장 |
| 재생기가 `meeting.audioPath`만 읽고 끝 구간에서 멈추지 않음 | `AudioPlayerController.swift` | 듀얼 소스 공통 재생 타임라인, 구간 반복, seek·속도·종료 처리 |
| JSON decode 실패를 빈 목록으로 대체하고 저장 오류를 무시함 | `GroveStore.swift` | 오류를 표시하고 원본 보존. 실패한 migration 위에 빈 데이터 저장 금지 |
| 개인 사전을 공개 배포와 분리해야 함 | `scripts/package_app.sh` 패키징 계약 | 개인 설정을 번들에서 제외하고 Application Support에서만 읽기, 깨끗한 checkout 패키징 테스트 |

개인 사전은 로컬에 보존하고 공개 소스·배포 번들에 포함하지 않는다.

## 3. 웹 조사에서 채택하는 UX

### 회의 앱

- 클로바노트는 참석자 이름에서 다른 참석자를 지정하고 적용 범위를 한 구간·그 이후 같은 화자·전체로
  고르는 흐름을 제공한다. Grove에서도 범위를 명확히 보이되, 이름 변경과 다른 사람으로 재배정을 분리한다.
  [참석자/음성 기록 편집](https://help.naver.com/service/24269/contents/12829?lang=ko&osType=PC)
- 클로바노트의 다운로드는 참석자와 발화 시각 포함 여부를 선택한다. Grove의 복사와 내보내기도 같은
  옵션을 공유하고 결과 미리보기를 제공한다.
  [파일 다운로드](https://help.naver.com/service/24269/contents/12831?lang=ko&osType=PC)
- Tiro 공개 화면의 문서/원본 분리와 명시적인 복사 동작을 참고한다. 실시간 성능·정확도 마케팅 수치를
  Grove 보증으로 인용하지 않으며, 클라우드 공유·템플릿·채팅까지 한꺼번에 가져오지 않는다.
  [Tiro 공개 제품 화면](https://tiro.ooo/ko/)
- Otter는 텍스트·화자 편집 후 요약 재생성을 별도로 안내한다. Grove도 미래 요약에 transcript revision을
  기록하고 수정 시 오래된 요약임을 표시한다. 원래 요약을 덮어쓰는 정책은 채택하지 않는다.
  [요약 재생성](https://help.otter.ai/hc/en-us/articles/25846455610263-Regenerate-the-summary)

### 일반 UI/UX 원칙의 적용

- 상태 가시성: 실제 녹음 상태, 파일 보존, 다운로드/전사/화자 처리 단계, 오류와 재시도를 구분한다.
- 오류 예방: 전체 화자 변경의 범위·개수를 보이고 기본 범위는 한 발화로 둔다.
- 사용자 통제: 구조적 변경은 한 번의 Undo로 되돌리고 원문·원음을 보존한다.
- 인지 부담 축소: 자주 쓰는 복사·화자 버튼은 보이게 두고 엔진·신뢰도·사전 디버깅은 세부 정보로 옮긴다.
- 표준 준수: macOS의 텍스트 선택·IME·Cmd-C·Cmd-Z 동작을 임의로 가로채지 않는다.

위 원칙은 Jakob Nielsen의 휴리스틱을 Grove 작업에 적용한 설계 판단이다.
[NN/g](https://www.nngroup.com/articles/ten-usability-heuristics/),
[Apple Undo/Redo](https://developer.apple.com/design/human-interface-guidelines/undo-and-redo),
[macOS 설계](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)

## 4. 시각 방향: 차분한 문서형 편집기

### 서체

- Pretendard 1.3.9 Regular/Medium/SemiBold를 앱 번들에 포함하고 프로세스 범위로 등록한다.
  사용자 시스템 폰트를 설치·교체하지 않고 CDN에 의존하지 않는다.
- 한글 본문 15pt/Regular, 화자명 13pt/Medium, 회의 제목 22pt/SemiBold를 첫 시안으로 삼는다.
  메뉴·표준 OS 컨트롤은 네이티브 system font를 존중한다.
- 세리프 제목, 본문 장식 자간, 숫자 이외의 모노스페이스를 제거한다. 줄간격과 폭을 폰트와 함께 조정한다.
- 읽기 크기 확대, 최대 200%에서 레이아웃·편집·복사 동작을 검증한다. macOS에 iOS식 Dynamic Type이
  자동 적용된다고 가정하지 않고 앱 내 읽기 크기 설정을 제공한다.
- OFL 라이선스/저작권 고지를 번들에 포함한다. 현재 공개 최신 릴리스는 2023-11-05의 v1.3.9로 확인했다.

[Pretendard 릴리스](https://github.com/orioncactus/pretendard/releases/tag/v1.3.9),
[라이선스](https://github.com/orioncactus/pretendard/blob/v1.3.9/LICENSE),
[Apple Typography](https://developer.apple.com/design/human-interface-guidelines/typography)

### 초기 색상·형태 토큰

라이트 시안의 제안값: Canvas `#F5F6F7`, Document `#FFFFFF`, Ink `#24282C`, Secondary `#6B737B`,
Grove accent `#39765D`, Selection `#E7F0EB`. 실제 구현에서는 semantic light/dark 값과 대비를 검증한다.

- 회의 내용은 불투명하고 중립적인 문서 표면에 둔다. 초록색을 전체 배경에 깔지 않는다.
- 기존 도토리 아이콘은 유지하고 accent는 선택/재생 상태 위주로 사용한다.
- 화자 색은 작은 점·이름 옆 표시 정도로 제한한다. 다자 대화를 좌우 채팅 말풍선으로 표현하지 않는다.
- 문단마다 카드·그림자·세로 장식 rail을 붙이지 않는다. 수정 이력은 필요할 때만 펼친다.
- Liquid Glass는 OS navigation/control 범위에 한정하고 전사 본문에 반투명 효과를 덧씌우지 않는다.
  [Apple Materials](https://developer.apple.com/design/human-interface-guidelines/materials)

### 화면 구조

```text
┌ 회의 목록 ────────┬ 회의 제목                 검색  참석자  복사▾  저장 ┐
│ 녹음 / 가져오기   │ 전사                 [요약: D3에 따라 후속]        │
│ 검색             │ 전체 · 화자 1 · 화자 2 · …                         │
│ 오늘             │                                                     │
│ 회의 목록        │ 00:00  화자 1 ▾                                     │
│ …                │        전사 본문 …                                   │
│                  │                                                     │
│                  │ 00:05  화자 2 ▾                                     │
│                  │        전사 본문 …                                   │
│                  ├ 재생/일시정지 ───── 시간축 ───── 현재 / 전체   1× ┤
└──────────────────┴─────────────────────────────────────────────────────┘
```

참석자 패널은 버튼으로만 열고 화면 폭이 좁아지면 접는다. 기본 화면은 목록 + 전사의 2열이다.
처리 완료 후 기본 탭도 전사로 한다. 작동하지 않는 요약 탭이나 빈 분석 위젯을 먼저 보여주지 않는다.

초기 디자인 검토에서는 같은 Pretendard로 문서형 기본안과 조금 더 촘촘한 편집형을 비교한다.
서로 다른 테스트 앱을 여러 개 설치하지 않고 하나의 격리된 개발 preview에서만 비교한다.
`frontend-design`의 의도적인 선택·절제는 참고하되, 독특한 서체나 장식을 요구하는 규칙으로 쓰지 않는다.

## 5. 화자 교정 계약

### 이름 변경과 재배정은 다른 동작

| 동작 | 영향 |
|---|---|
| 화자 이름 변경 | 같은 회의의 해당 speaker ID 표시명만 바뀜. 텍스트·원음·자동 군집은 불변 |
| 이 발화만 다른 화자로 | 현재 segment 하나의 사용자 배정만 변경 |
| 이후의 같은 화자 | 현재 시각 이후, 현재 그 speaker ID에 배정된 segment만 변경. 다른 화자는 유지 |
| 이 회의의 해당 화자 전체 | 필터 밖을 포함해 현재 그 speaker ID에 배정된 전체 segment 변경 |
| 새 화자 추가 | 새 회의 내 speaker ID 생성 후 선택 범위에 배정. 음성 모델 학습으로 오해시키지 않음 |

이름이 같다고 사람을 자동 병합하지 않는다. 자동 cluster label, 사용자가 붙인 표시명, 입력 채널은 별개다.

### 동작 흐름

1. 발화의 화자명을 누른다.
2. 기존 참석자 또는 새 화자를 선택한다. 각 화자는 대표 구간을 짧게 들어 확인할 수 있다.
3. 적용 범위를 선택한다. 기본은 **이 발화만**이다.
4. 전체/이후 변경은 `화자 2 → 화자 1`과 실제 영향을 받는 발화 개수를 미리 보인다.
5. 적용 후 결과를 즉시 표시하고 `화자 변경 취소`를 제공한다. 여러 발화 변경도 Undo 한 번이다.

필터링은 보기 기능일 뿐 전체 변경 대상을 축소하지 않는다. 반대로 다중 선택 변경은 선택한 segment만
대상으로 한다. 한 발화를 A→B로 바꾼 뒤 나머지 A 전체를 C로 바꿔도 이미 B인 발화는 바뀌지 않아야 한다.
구조 변경 시점의 segment ID 집합을 저장해 이후 필터/정렬 변경과 Undo 결과가 엇갈리지 않게 한다.

한 MOSS 발화 안에 실제 두 사람이 포함되면 전체 화자 한 명을 붙이는 것으로 해결되지 않는다.
현재 재생 위치와 텍스트 커서를 사용한 수동 발화 분할을 제공하되, 문자 비율로 정확한 시각을 만들어내지
않는다. 모델 겹침·원본 segment와 parent 관계를 보존한다. 처음부터 겹침을 삭제하거나 입력 인원수에 강제 배정하지 않는다.

## 6. 텍스트 편집·재생·검색

- 읽기 상태와 발화 편집 상태를 구분하고, 텍스트 선택 자체가 재생을 시작하지 않게 한다.
- 시각/재생 버튼은 해당 발화로 이동한다. 구간 반복, 재생 속도, 전역 진행 위치를 일관되게 유지한다.
- 한글 IME와 선택/붙여넣기/Undo는 AppKit `NSTextView` 기반 편집 컴포넌트를 먼저 검증한다.
  일반 Enter를 저장 단축키로 가로채지 않는다. 편집 완료는 명시 버튼/Cmd-Enter, Esc는 조합 취소를 우선한다.
- 텍스트 편집 중 Space와 Cmd-C는 편집기에 전달한다. 재생/발화 복사 단축키가 가로채지 않는다.
- 인접 발화를 여러 개 선택하는 방식은 Shift/Command 선택으로 제공하고 텍스트 선택과 구분한다.
- 검색은 본문과 화자 이름을 대상으로 하며, 일치 구간으로 이동하고 현재 검색/화자 필터를 명확히 표시한다.
- 평균 confidence 퍼센트를 모든 문장에 표시하지 않는다. MOSS와 Sortformer 값을 같은 신뢰도 척도로
  바꾸지 않고, 혼합 화자/겹침/미배정 같은 구체적 이유로 `확인 필요`를 표시한다.

## 7. 복사와 내보내기

하나의 `TranscriptRenderer`로 클립보드·TXT·Markdown을 만든다. 화면의 최신 텍스트 수정과 화자 이름을
모두 적용하고 원문 비교용 텍스트는 기본 출력에서 제외한다.

- `전체 대화 복사`, `선택 발화 복사`, `현재 필터 결과 복사`를 구분하며 개수를 표시한다.
- 기본은 화자 포함. 시각 포함 여부와 TXT/Markdown 형식은 옵션으로 두고 마지막 선택을 기억한다.
- 일반 텍스트를 드래그한 상태의 Cmd-C는 기존 macOS처럼 선택 텍스트만 복사한다.
  화자 포함 복사는 명시 버튼/메뉴 또는 선택된 발화의 복사 명령이다.
- 파일 저장은 NSSavePanel, UTF-8, 안전한 파일명, 덮어쓰기 확인, 취소 시 기존 파일 보존을 보장한다.
- 화자 이름의 Markdown 특수문자·개행, 한글 조합형/완성형, 이모지, 겹침 발화 순서를 테스트한다.
- 화자 변경 후 다른 이름이 복사되는 문제가 없도록 렌더링 시 ID→현재 이름을 해석한다.
- 수정 후 생성되는 요약이 있다면 사용한 transcript revision을 표시한다. 오래된 요약을 최신 전사인 것처럼
  자동 복사하지 않는다.

실제 녹음과 무관한 표준 텍스트 예시는 다음 정도로 단순하게 둔다.

```text
[00:00] 화자 1
발화 내용

[00:05] 화자 2
발화 내용
```

## 8. 엔진·실행 구조

```text
SwiftUI 앱 (녹음·재생·문서·교정)
  └ 작업 조정기 → 번들 내 headless Swift inference worker
       ├ 공통 분석 오디오 준비 (16 kHz mono + 원본 시각 매핑)
       ├ MOSS/MLX: 텍스트와 발화 시각
       ├ 선택된 diarizer: 전체 시간축의 익명 화자 구간
       └ 최대 시간 겹침 배정 → 검토 가능한 전사 revision
```

사용자에게 보이는 앱은 하나이고 helper는 창을 띄우지 않는다. 추론 프로세스 오류가 녹음과 편집을 같이
종료시키지 않도록 분리한다. localhost 웹 서버를 열지 않고 제한된 typed IPC를 사용한다.
Python 연구 환경을 그대로 앱 의존성으로 만들지 않는다. Swift 경로가 동등성/배포 검증에 실패하면
임의로 Python sidecar로 전환하지 않고 별도 의사결정을 요청한다.

### 최신 코드 확인 결과와 고정 전략

- MLXAudio Swift 최신 공개 릴리스는 v0.1.3(2026-07-09)이며 해당 tag에 MOSS 구현이 있다.
  현재 main `b917ab5486cdb0dde9ca2c1b7a55821796856be2`도 확인했다.
  Package.swift는 Swift tools 6.2, macOS 14 이상을 선언하지만 Grove의 기존 macOS 26 요구는 유지한다.
- FluidAudio 공개 릴리스 v0.15.6(2026-08-19)와 소스 revision
  `5c19d5e12320e22bbfb7a1877b089d2665a69add`를 검토 대상으로 기록했다.
  버전 숫자만 보고 서로 다른 구현의 출력이 같다고 가정하지 않는다.
- MOSS Swift main의 `maxTokens=2048`, `chunkDuration=1800` 같은 기본값과 앱 설정은 구분한다.
  모델 버전·decode cap·청크 조건을 명시하고 꼬리 발화 누락 및 토큰 한도 종료를 실패/부분 결과로 처리해야 한다.
- Sortformer streaming과 fused-offline은 별도 실행 조건으로 검증하고 서로 대체 가능한 것으로 가정하지 않는다.
- 라이브러리와 모델은 검증된 revision/checksum으로 고정한다. MLXAudio의 MIT, FluidAudio의 Apache-2.0,
  모델별 라이선스와 transitive notices를 각각 확인한다.

[MOSS Swift 구현/사용법](https://github.com/Blaizzy/mlx-audio-swift/tree/v0.1.3/Sources/MLXAudioSTT/Models/MossTranscribeDiarize),
[MLXAudio 릴리스](https://github.com/Blaizzy/mlx-audio-swift/releases/tag/v0.1.3),
[FluidAudio 릴리스](https://github.com/FluidInference/FluidAudio/releases/tag/v0.15.6),
[Sortformer 제약](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md)

### 실행·자료 보존 규칙

- 첫 모델 준비는 크기/저장 위치를 알리고 재개 가능한 다운로드 및 checksum 검증을 제공한다.
  모델 미준비 상태에서도 녹음은 가능하고 처리는 대기한다. 모델을 앱 번들과 함께 중복 설치하지 않는다.
- 원본 채널은 보존하고 분석용 파생 오디오만 만든다. 마이크/시스템의 공통 clock·offset·echo를 검증한다.
  서로 다른 시간축의 결과를 단순 이어 붙이지 않는다. mono 파일 시험은 듀얼 소스 검증을 대신하지 못한다.
- MOSS 자체 화자 표식은 raw에 남기되 최종 화자 source로 사용하지 않는다. 선택된 diarizer의 전체 회의
  cluster를 기준으로 한다. MOSS 청크마다 생기는 라벨 초기화가 사람 ID 초기화로 번지지 않게 한다.
- 동시에 여러 대형 모델을 상주시킬 필요는 없다. 기본은 순차 처리/unload, 작업 한 개이며 추후 자원 실측으로 조정한다.
- UI 상태는 `녹음 중 / 처리 대기 / 전사 중 / 화자 정리 중 / 완료 / 확인 필요 / 실패`로 구분한다.
  실제 측정할 수 없는 진행률·남은 시간을 임의 생성하지 않는다.
- 취소/앱 종료 시 원본과 완료된 단계는 보존한다. 재시작은 지원되는 단계 경계에서 재개하며,
  저장하지 않은 모델 내부 토큰 상태를 복원하는 것처럼 표시하지 않는다.
- 자동 cloud fallback, 전사 원문 telemetry, 이름 기반 자동 voice enrollment는 없다.

## 9. 저장 형식과 수정 이력

현재 단일 `meetings.json`에 모든 전사를 함께 저장하는 구조를 다음처럼 나눈다.

- 가벼운 회의 catalog: 제목·날짜·상태·활성 revision
- 회의별 폴더: 원본 채널, capture manifest, engine runs, transcript revisions, edits
- `sourceChannelID`: 마이크/시스템/가져온 파일
- `speakerClusterID`: 특정 diarizer run의 자동 군집
- `speakerID`: 이번 회의에서 사용자가 보고 수정하는 사람 식별자
- `speakerName`: speaker ID의 표시명, null이면 기본 화자명
- segment ID: 텍스트/시각 anchor. 교정·배정은 raw와 별도의 overlay/명령 이력

raw text, raw 겹침 구간, 모델 시각은 덮어쓰지 않는다. text correction, speaker reassignment,
rename, split/merge를 버전 있는 명령으로 저장하고 atomic write·직렬화된 저장 actor를 사용한다.
catalog는 회의 document에서 재구성 가능하게 하며 저장 실패를 성공 UI로 표시하지 않는다.

재전사는 새 revision을 만들고 기존 수동 교정을 자동으로 버리지 않는다. 결과 전환은 사용자 확인 후 한다.
발화 ID가 달라진 새 revision에 이전 교정을 억지로 옮기지 않으며 이후 자동 이관이 필요하면 별도 검증한다.

v0.2 migration은 원래 JSON을 백업하고 전체 성공 검증 후 새 catalog를 채택한다. 기존 source 문자열을
실제 사람 이름으로 자동 승격하지 않는다. 기존 한 문단 전사도 그대로 열리고, 새 화자 분리는 재처리로만 만든다.

## 10. 구현 단계와 통과 조건

### G0 — 네이티브 엔진 및 5명 이상 후보 검증

- D1–D3 확정 완료. 동일 모델/설정으로 Swift MOSS + Sortformer harness 구현
- 가변 인원용 native diarization 후보를 조사하고 인원수·녹음 조건이 다른 평가 자료로 시험
- 적절한 화자 주석 자료가 없으면 해당 조건의 검증을 미완료로 표시하고 다른 조건의 결과로 대체하지 않음
- 새 앱 설치 없이 CLI harness로 텍스트 CER·화자 혼동/DER·cpCER를 각각 비교. 공개 테스트에는 합성 자료를 사용
- 모델 download/Metal resource/code signing/취소/토큰 한도/말미 누락 검증
- Python 결과와 차이가 나면 원인 확인 전 모델 품질이 유지됐다고 보고하지 않음

### G1 — 데이터·패키징 안전성

- 개인 사전 번들 복사 제거 및 clean-checkout 패키징 테스트
- v0.2 migration, 회의별 revision, jobs/checkpoints, 오류 처리
- headless worker와 앱의 역할 분리, raw 보존, 듀얼 오디오 재생·분석 시간축 검증

### G2 — UI 시안 확정

- Pretendard 문서형/밀도 높은 편집형을 같은 한 창에서 비교
- 목록·전사·참석자 popover·범위 확인·복사 미리보기의 실제 상호작용 검토
- 사용자가 선택한 안으로 고정한 뒤 전체 화면을 구현

### G3 — 편집 기능

- 한 발화/이후 같은 화자/전체 화자 재배정, 이름 변경, 새 화자, 다중 선택, Undo/Redo
- 한글 텍스트 수정, 검색·화자 필터, 구간 재생·반복, 혼합 발화 분할
- 필터가 켜진 전체 변경, 동일 이름, 이전 개별 교정, Undo 순서의 회귀 테스트

### G4 — 복사·저장·작업 상태

- 동일 renderer의 TXT/Markdown 및 speaker/timestamp 옵션
- 선택·필터·전체 범위, Unicode·Markdown 특수문자, 파일 덮어쓰기·취소 검증
- 긴 처리/다운로드/취소/실패/복구 상태와 원본 보존 확인

### G5 — 통합 검증·앱 교체

- 텍스트·화자·종합 오류율을 별도 유지. 모델 단독 시간 합계를 통합 실측으로 쓰지 않음
- 실제 30/60분 한국어 회의, 입력 소스·겹침·짧은 발화·말미 누락·취소를 검증
- 목표 하드웨어별로 통합 warm/cold wall, process RSS, 시스템 memory pressure 측정
- 8/16GB 지원은 해당 기기 확인 전 보증하지 않음
- 1,000개 이상 발화의 scroll/편집/검색, 200% 글자 확대, light/dark, 키보드·VoiceOver 점검
- Swift/Python 회귀 테스트, 공개 clean build, helper/resource signing, 실제 .app smoke test
- 녹음 중인 앱은 덮어쓰지 않고 검증 후 `/Applications/Grove.app` 하나만 교체. 중복 앱·임시 모델/빌드 정리

시간 약속은 G0 결과 전에 고정하지 않는다. 각 단계는 완료 근거와 남은 한계를 handoff에 기록한다.

## 11. 완료 기준 요약

1. 한 발화 변경이 다른 발화를 바꾸지 않는다.
2. 전체 변경은 명시한 개수만 바꾸고 Undo 한 번으로 원래대로 돌아간다.
3. 이름 변경 후 화면·복사·파일의 화자명이 일치한다.
4. 재전사·저장 오류·프로세스 종료에도 원음과 수동 교정이 남는다.
5. 실사용자는 Python/CLI를 설치하지 않고 한 앱에서 작업한다.
6. 첫 화면에 조직 예시·모델 디버깅·작동하지 않는 요약 UI가 없다.
7. 개인 사전·음성·전사·화자 프로필이 배포 번들과 공개 Git에 포함되지 않는다.
