# 첫 실행과 외부 연결

## 전사 방식

| 선택 | 처리 경로 | 설치 | 화자 구분 |
| --- | --- | --- | --- |
| 정밀 전사 / 화자 분리 | MOSS → Nemotron 3 | Grove가 고정 버전의 모델 약 1.9 GB를 준비 | 최대 8명 자동 구분 |
| Mac 기본 전사 | Apple SpeechTranscriber / SpeechAnalyzer | Grove 모델 없음. macOS 언어 자산이 없으면 Apple에서 준비 | 제공하지 않음 |

최초 선택과 새 녹음 기본값은 라이브러리에 저장한다. 녹음별 설정은 별도로 보존한다.
기존 설정에서 전사 방식이 없으면 MOSS로 해석한다. 기존 automatic 화자 경로는
Ultra8 / Community-1 정책을 유지하며, 명시적 선택도 보존한다.
Mac 기본 전사는 `transcriptionEngine=apple`, `diarizationPreference=none`으로 저장한다.
화자 미분리 결과를 단일 화자 추정 또는 화자 확인 완료로 위장하지 않는다.

## 모델 준비

실행 엔진은 앱 안에 포함한다. 사용자에게 Python, 별도 CLI나 개발 도구 설치를 요구하지 않는다.
모델은 `Application Support/Grove/Models`에, 중단된 수신 파일은 `Downloads`에 저장한다.
`ModelCatalog`가 저장소, 버전, 파일 크기와 SHA256의 정본이다.

1. 사용자가 시작하기를 누름
2. 필요한 저장 공간 확인
3. 기존 파일 검증, 부분 파일이 있으면 HTTP Range 이어받기
4. 서버가 Range를 무시하면 부분 파일만 비우고 다시 수신
5. 전체 크기 / SHA256 검증 후 모델 경로에 원자적으로 반영
6. 짧은 무음 파일로 MOSS / Nemotron 실행 검사
7. 모델 파일 상태와 실행 버전에 묶인 준비 완료 기록 저장

호환되는 앱 업데이트는 모델을 재사용한다. 실행기 또는 모델 계약이 바뀌면
준비 완료 버전을 갱신하고 다시 검사한다. 파일 검사는 URL의 수신 전 크기 캐시를
사용하지 않고 실제 파일 속성을 조회한다. 중단 / 종료 시 부분 파일을 유지한다.
준비 실행 검사는 설치와 실행 가능성만 확인하며 한국어 품질 평가를 대신하지 않는다.

## Calendar

Mac 기본 캘린더에 이미 연결된 계정을 EventKit으로 읽는다. Grove용 Google OAuth 앱 등록은 없다.
OS의 전체 캘린더 접근 권한을 요청하지만, Grove 코드는 일정을 작성 / 수정 / 삭제하지 않는다.
사용자가 선택한 캘린더만 대상으로 제목, 시작 / 종료 시각과 일정 식별자를 가져온다.
종일 일정, 취소와 참석 거절은 제외한다. Grove 실행 중에 시작 0 / 5 / 10분 전 알림을 제공한다.
알림의 녹음 시작 버튼은 대면 회의의 마이크 녹음만 시작한다. Meet 참여나 온라인 음성 수집은 없다.
알림의 닫기 / 5분 뒤 알림은 현재 앱 실행의 해당 일정 발생 건에 적용한다.

## Notion

연결 토큰은 Keychain에 보관한다. 본문이나 환경 설정 파일에 저장하지 않는다.
복사는 HTML 서식과 일반 텍스트를 함께 제공하며 계정 연결이 필요 없다.
검토한 전사문 / 현재 전사의 최초 원문을 선택할 수 있다. 원문 내보내기는 편집 / 분할 이력을
복제본에서 되돌리고, 기존 문서와 오디오를 수정하지 않는다.

페이지 하단에 회의록 추가는 다음 순서다.

1. 일반 부모 페이지 링크와 접근 권한 확인
2. 본문 마지막에 구분선이 없으면 Markdown API의 끝 삽입으로 추가
3. 날짜 / 회의 제목의 하위 페이지를 만들고 전체 전사문 저장
4. 생성한 페이지 ID를 로컬 기록에 보관하고 부모 관계 확인

원본 부모 본문을 전체 교체하지 않는다. 녹음 파일은 전송하지 않는다.
구분선은 `PATCH /v1/pages/{id}/markdown`의 끝 삽입을 사용한다. 문서 전체 읽기 / 치환은 피한다.
이 API의 `insert_content`는 지원 중인 이전 명령이며, 정확한 끝 삽입을 위해 제한적으로 사용한다.

생성 요청 전에 로컬 기록을 저장한다. 통신 결과가 불확실하면 자동으로 생성 요청을
반복하지 않는다. 사용자가 Notion에서 생성 결과를 확인하고 페이지 링크를 연결할 수 있다.
이미 추가한 녹음은 같은 페이지를 연다. 내용이나 대상이 달라지면 자동 덮어쓰기 대신 복사를 안내한다.
큰 부모 문서의 읽기가 잘렸거나 데이터베이스 링크이면 추가하지 않는다.
구분선 추가와 하위 페이지 생성은 별도 요청이므로 실패 시 구분선만 남을 수 있다.
다음 시도는 마지막 구분선을 확인해 중복 삽입을 피한다. 동시 편집 중 위치 보장은 추가 검증 대상이다.

## 구현 위치

| 기능 | 정본 |
| --- | --- |
| 초기 선택 | `FirstRunSetupView`, `MeetingSpeakerOptions` |
| 모델 / 이어받기 / 준비 검사 | `ModelCatalog`, `ModelManager`, `ModelDownload`, `ModelSmokeCheck` |
| Mac 기본 전사 | `AppleTranscriptionService`, `AppleTranscriptionPreparation` |
| 모델 실행 연결 | `BundledMeetingInferenceService`, `NativeInferenceBackend` |
| 일정 / 상단 알림 | `CalendarSchedule`, `MeetingReminderBanner` |
| Notion / 클립보드 | `NotionExport`, `NotionExportSheet` |

공식 계약: [Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer),
[EventKit 접근](https://developer.apple.com/documentation/eventkit/accessing-the-event-store),
[Notion Markdown API](https://developers.notion.com/guides/data-apis/working-with-markdown-content).
