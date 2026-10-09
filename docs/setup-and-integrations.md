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

저장 위치의 링크 형식과 페이지 / 데이터베이스 구분은 [링크 처리 계약](notion-link-handling.md)을 따른다.
현재 앱 주소, 기존 주소, 공개 사이트의 ID 포함 주소와 앱 scheme을 같은 페이지 ID로 정규화한다.
ID 없는 공개 주소나 모호한 페이지 미리보기는 내부 페이지의 공유 링크를 요청한다.

기본 연결은 공식 Notion MCP의 OAuth / PKCE다. Grove가 비밀키 없는 공개 클라이언트를
동적으로 등록하고 macOS 인증 창에서 로그인한다. 인증 중계 서버, 별도 CLI / Node 설치,
Notion 개발자 포털에서 수동 앱 등록을 요구하지 않는다. 토큰 입력은 고급 연결 방식으로 유지한다.

특정 워크스페이스, 조직이나 이메일 허용 목록을 두지 않는다. 워크스페이스 / 사용자 식별자는
인증 응답에서 받고, 저장할 부모 페이지는 사용자가 입력한다. OAuth 로그인은 선택한
워크스페이스의 사용자 권한으로 동작한다. Grove는 입력한 페이지와 생성한 회의록에만 요청한다.
권한 범위는 REST 공개 연결의 페이지 선택과 다르므로 두 인증 방식을 같은 것으로 설명하지 않는다.
향후 REST 공개 OAuth를 추가하면 배포 범위는 `Any workspace`로 설정한다.

공개 클라이언트 ID를 재사용하고, access / refresh 토큰과 만료 시각을 Keychain의 한 항목에
저장한다. 토큰 갱신은 연결별로 한 번만 실행하며, 회전된 토큰 쌍을 저장한 뒤 사용한다.
갱신 실패 / 저장 실패로 상태가 불확실하면 재연결을 요청하고 같은 refresh 토큰을 반복 사용하지 않는다.
로그인 취소나 늦은 콜백이 기존 연결을 덮어쓰지 않는다. 연결 해제는 이 Mac의 연결 정보를 삭제한다.
macOS 인증 완료 콜백은 MainActor 밖에서도 호출될 수 있다. 콜백 자체를 Sendable로 선언하고
결과 전달 / 세션 정리는 MainActor로 이동한다. 취소와 브라우저 오류를 구분하며 재시도를 허용한다.
Notion의 연결 권한 자체를 철회하려면 Notion 설정에서 관리한다.
저장 위치는 OAuth 워크스페이스 / 사용자별로 기억하고, 기존 수동 토큰의 저장 위치는 유지한다.
이전 토큰은 그대로 읽고, 새 연결을 저장할 때 원자적으로 새 형식으로 바꾼다. 새 형식 저장 후에는
beta18 이하의 Notion 연결 리더와 호환되지 않으며, 앱을 내릴 경우 다시 연결해야 한다.

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
OAuth는 `notion-update-page`의 `insert_content` / `position=end`와 `notion-create-pages`를
사용한다. 토큰 연결은 `PATCH /v1/pages/{id}/markdown`의 끝 삽입을 사용한다.
MCP의 `insert_content` 본문은 `content`에 전달한다. `new_str`는 전체 본문 치환에
사용하는 필드이며 삽입 요청에 혼용하지 않는다. JSON-RPC의 잘못된 메서드 / 인자와
도구의 validation_error는 확정 거부로 처리한다. 그 밖의 쓰기 오류는 결과 불확실로
보존하고, 서버 오류만 보고 새 페이지를 자동으로 다시 만들지 않는다.
문서 전체 치환은 하지 않는다. MCP 응답은 데이터로만 해석하며 내용을 명령으로 실행하지 않는다.
동기 생성 결과에 페이지 ID가 없으면 성공으로 처리하지 않는다. 비동기 갱신은 완료 확인 후
다음 단계로 진행하며, 경고 / 잘린 본문은 실패 처리한다.

생성 요청 전에 로컬 기록을 저장한다. 통신 결과가 불확실하면 자동으로 생성 요청을
반복하지 않는다. 사용자가 Notion에서 생성 결과를 확인하고 페이지 링크를 연결할 수 있다.
이미 추가한 녹음은 같은 페이지를 연다. 내용이나 대상이 달라지면 자동 덮어쓰기 대신 복사를 안내한다.
큰 부모 문서의 읽기가 잘렸거나 데이터베이스 링크이면 추가하지 않는다.
구분선 추가와 하위 페이지 생성은 별도 요청이므로 실패 시 구분선만 남을 수 있다.
다음 시도는 마지막 구분선을 확인해 중복 삽입을 피한다. 동시 편집 중 위치 보장은 추가 검증 대상이다.

구분선 요청 전에도 로컬 기록에 `dividerPending` 단계를 먼저 저장한다. 결과를 확인하지
못한 요청은 앱을 다시 열어도 재전송하지 않는다. 결과 확인은 부모 본문을 읽기만 하며,
마지막 구분선이 확인되면 `creationPending`을 저장하고 회의록 생성으로 진행한다.
기존 단계 필드가 없는 불확실한 생성 기록은 그대로 불확실한 생성으로 취급한다.

## 구현 위치

화면 제목이나 버튼만으로 알 수 있는 내용은 설명문으로 반복하지 않는다.
홍보 문구와 설치 내부 절차는 기본 화면에 넣지 않는다. 모델 용량, 화자 구분 지원,
권한, 알림 조건과 오류 해결처럼 선택과 사용에 필요한 정보만 표시한다.

| 기능 | 정본 |
| --- | --- |
| 초기 선택 | `FirstRunSetupView`, `MeetingSpeakerOptions` |
| 모델 / 이어받기 / 준비 검사 | `ModelCatalog`, `ModelManager`, `ModelDownload`, `ModelSmokeCheck` |
| Mac 기본 전사 | `AppleTranscriptionService`, `AppleTranscriptionPreparation` |
| 모델 실행 연결 | `BundledMeetingInferenceService`, `NativeInferenceBackend` |
| 일정 / 상단 알림 | `CalendarSchedule`, `MeetingReminderBanner` |
| Notion / 클립보드 | `NotionConnection`, `NotionOAuth`, `NotionMCPClient`, `NotionExport`, `NotionExportSheet` |

공식 계약: [Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer),
[EventKit 접근](https://developer.apple.com/documentation/eventkit/accessing-the-event-store),
[Notion Markdown API](https://developers.notion.com/guides/data-apis/working-with-markdown-content),
[Notion MCP 클라이언트 인증](https://developers.notion.com/guides/mcp/build-mcp-client).

## 팀원 목소리와 참석자

- 폴더의 팀원에서 이름 추가 / 변경, 예문과 자유 발화 녹음, 등록 / 삭제 지원
- 목소리 모델은 등록 요청 때 약 15.3 MB를 별도로 준비. 기본 전사 모델 준비와 분리
- 녹음 전 참석자 선택은 선택 사항. 이름이나 게스트 인원도 추가 가능
- 참석 인원은 화자 수 옵션을 바꾸지 않음. Calendar 녹음도 같은 준비 화면 사용
- 자동 이름 연결은 다른 날의 실제 팀원 / 미등록 화자 평가 전까지 비활성
- 상세 계약과 개발용 검증 입력: [목소리 등록과 이름 연결](automatic-speaker-identification.md)
