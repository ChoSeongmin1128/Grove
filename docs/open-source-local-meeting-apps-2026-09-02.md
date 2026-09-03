# 오픈소스 로컬 회의 앱 조사

상태: 공개 저장소 조사 + 관련 3개 저장소 shallow source audit

최종 확인일: 2026-09-03

> 이 문서는 AI가 공개 저장소와 공식 문서를 읽고 작성한 조사 문서입니다. 2026-09-03에
> Meeting Transcriber, Muesli, diarize를 shallow clone하여 아래 고정 commit의 관련 소스를
> 확인했지만 build·실행·한국어 품질 검증은 하지 않았습니다. 기능 설명을 동작 보증으로
> 해석하지 마세요.

## 조사 기준

Grove와 비교하기 위해 다음 조건을 우선했습니다.

- macOS 데스크톱 앱 또는 macOS를 1급 지원
- 마이크와 시스템 오디오 녹음
- 로컬 ASR
- 화자 분리 또는 화자 확인 workflow
- transcript 편집·검색·TXT/Markdown export
- OSI 계열 오픈소스 라이선스와 실제 공개 코드
- 최근 공개 저장소 활동, 배포와 테스트 근거

GitHub star와 README는 참고값일 뿐 품질·보안·한국어 정확도의 근거가 아닙니다. 별도 표기가
없는 star 수는 확인 시점의 GitHub 화면 값이며 변동합니다.

## 결론

Grove를 다른 프로젝트로 대체하거나 하나를 fork하는 방향은 권하지 않습니다. 참고 우선순위는
다음이 적절합니다.

1. `pasrom/meeting-transcriber` — 녹음·화자 분리·배포·실기기 E2E의 기술 참고
2. `elien666/diarize` — 화자 library, 구간 재지정·분할·병합과 로컬 schema 참고
3. `Muesli-HQ/muesli` — 네이티브 macOS 제품 구조, export와 로컬 모델 경계 참고
4. `fastrepl/anarlog` — meeting library, editor, local data와 선택형 cloud 경계 참고
5. `Zackriya-Solutions/meetily` — 대중적인 onboarding·cross-platform 사례만 참고
6. Tacet, Loqui, Damso — 설계 아이디어 참고, 아직 의존하거나 fork할 성숙도는 아님

Grove는 macOS 26 네이티브 SwiftUI, Core Audio process tap, Apple Speech 기본 경로, 보존되는
원음, 수동 화자 교정과 단순 TXT/Markdown export에 집중하는 편이 낫습니다. calendar, bot,
MCP, chat, 여러 ASR provider는 핵심 흐름이 안정된 뒤 별도 단계로 둡니다.

## 주요 후보 비교

| 프로젝트 | 확인 시점 규모 | 기술·기능 | 장점 | 주의점 | Grove 판단 |
|---|---:|---|---|---|---|
| Meeting Transcriber | 154 stars, MIT | Swift 6, SwiftUI, Core Audio tap, WhisperKit, Parakeet, FluidAudio offline·Sortformer, dual-track diarization, Markdown protocol | Grove와 가장 가까운 네이티브 구조, echo 진단, known voice, Homebrew와 Apple Silicon E2E | 자동 회의 감지와 menu bar 중심, 권한·의존성 범위가 큼 | 최우선 코드 감사 대상 |
| diarize | 0 stars, MIT | Swift 6, SwiftUI, FluidAudio 0.14.5, GRDB/FTS5, 구간 재지정·분할·화자 병합, Markdown/JSON | Grove가 요구한 화자 수정과 cross-meeting embedding schema가 가장 직접적 | 공개 사용자·release 검증이 사실상 없고 README 주장 범위가 큼 | schema·수정 UX만 선별 참고 |
| Muesli | 1.1k stars, MIT | Swift/AppKit/SwiftUI, Core Audio tap, FluidAudio, WhisperKit·Apple Speech 등, Markdown/PDF export, CLI | 네이티브 제품, source channel 분리, raw transcript read-only 계약, export가 구체적 | dictation·calendar·iCloud·다수 실험 모델까지 범위가 과도함 | 기능 계약과 UX 참고 |
| Anarlog, 구 Hyprnote | 9.2k stars, community MIT | Tauri 2, React/TypeScript, Rust, SQLite+local files, Markdown export, local/선택형 cloud | library·editor·plugin/data architecture가 가장 풍부 | 매우 큰 monorepo, enterprise 상용 경계, 현재 char 제품과 다른 코드, SwiftUI에 직접 재사용하기 어려움 | UX·schema만 참고 |
| Meetily Community | 30.2k stars, 556 commits, MIT | Tauri, Rust backend, Next.js UI, Whisper/Parakeet, macOS·Windows DMG | 사용자와 contributor가 많고 설치 흐름이 성숙 | README와 제품 문서 사이 기능 경계가 다름. advanced export·speaker identification·diarization 일부가 Pro 또는 예정 기능 | 기능 존재를 코드 확인 없이 믿지 않음 |
| Tacet | 0 stars, MIT | Electron, Python, Swift ScreenCaptureKit helper, Whisper, ECAPA-TDNN, Markdown | appendable Markdown, opt-in voice registry, privacy 문서 | packaged release 미완성, unsigned DMG, Node+Python+Swift 설치, Screen Recording 요구 | 아이디어만 참고 |
| Loqui | 3 stars, MIT | Electron, Swift helper, Python sidecar, faster-whisper, sherpa-onnx, append-only transcript, read-only MCP | 원시 transcript와 derived diarized 파일 분리, crash-isolated worker, typed IPC | 릴리스와 사용자 검증 부족, audio 원본 자동 삭제는 Grove 방침과 충돌, ScreenCaptureKit 사용 | 데이터 불변식·테스트 아이디어 참고 |
| Damso | 6 stars, 30 commits, MIT | SwiftUI+Python, mlx-whisper, sherpa-onnx, speaker confirmation, Markdown files | 화자별 음성 sample을 듣고 이름을 확인하는 workflow가 명확 | 매우 초기 단계, agent CLI에 transcript 자동 전송하는 경계가 Grove와 다름 | 화자 확인 UX만 참고 |

## 1. Meeting Transcriber

저장소: <https://github.com/pasrom/meeting-transcriber>

가장 직접적인 비교 대상입니다. 공개 README와 소스 트리에서 다음을 확인했습니다.

- macOS 14.2+ Swift 6 executable app
- `CATapDescription` 기반 앱 오디오와 마이크 dual recording
- WhisperKit과 Parakeet TDT v3 선택
- FluidAudio `OfflineDiarizer`와 overlap-aware Sortformer
- 시스템 오디오와 마이크를 별도 diarization
- 회의 간 voice embedding matching
- Markdown protocol과 record-only mode
- Homebrew Cask 배포
- Swift test, lint/analyzer, self-hosted Apple Silicon에서 실제 모델 E2E
- 실제 `.app`과 simulated meeting을 구동하는 별도 app E2E

관련 근거:

- README: <https://github.com/pasrom/meeting-transcriber>
- Package.swift: <https://github.com/pasrom/meeting-transcriber/blob/main/app/MeetingTranscriber/Package.swift>
- 모델 E2E: <https://github.com/pasrom/meeting-transcriber/blob/main/.github/workflows/e2e.yml>
- 앱 E2E: <https://github.com/pasrom/meeting-transcriber/blob/main/.github/workflows/e2e-app.yml>

2026-09-03 감사 commit: `d73f35ed5a1d5a47068a9bf05b8d670d974e7a05`

소스에서는 README보다 더 중요한 다음 방어 로직을 확인했습니다.

- `withSpeakers(exactly:)`를 사용해 예상 화자 수가 단순 최대값이 되지 않도록 강제
- offline VBx와 4-speaker Sortformer를 선택 가능하게 분리
- Sortformer 결과에서 겹침 frame을 제외한 뒤 WeSpeaker centroid를 재추출
- mic/system echo bleed를 10초 window 상관으로 판정하고 오염 embedding을 격리

이 로직은 비슷한 두 화자의 병합 문제에 직접 관련되지만, 해당 threshold가 Grove의 한국어
회의에도 맞는다는 근거는 아닙니다.

### 참고할 부분

- `DualSourceRecorder`처럼 capture와 downstream pipeline을 분리한 구조
- `DiarizationProcess`와 background `PipelineQueue`
- source별 channel health와 RMS 진단
- model fixture E2E와 실제 app E2E를 나눈 검증 구조
- audio persistence policy와 record-only mode
- vocabulary를 app setting으로 분리한 구조

### 그대로 가져오지 않을 부분

- Teams/Zoom/Webex 자동 감지와 Accessibility 권한
- browser meeting 자동 감지
- 녹음을 자동 시작하는 option
- Claude CLI protocol generation
- Grove가 아직 필요로 하지 않는 LocalVQE binary dependency

Grove에 코드를 복사하려면 MIT notice와 해당 파일의 출처를 남기고, WhisperKit, FluidAudio,
LocalVQE와 모델별 라이선스를 따로 검토해야 합니다. 구조 아이디어만 다시 구현할 때도 원본
코드와의 실질적 유사성을 검토합니다.

## 2. diarize

저장소: <https://github.com/elien666/diarize>

2026-09-03 감사 commit: `39f8948c49355870a45eb80ac5271f72c6656051`

- FluidAudio offline diarization과 segment별 256차원 embedding 저장
- mic/system channel을 별도 diarization한 뒤 `local`/`remote` prefix로 병합
- cross-recording speaker matching을 centroid 하나가 아닌 top-K embedding vote로 수행
- 화자 이름 변경, 구간 재지정·분할, duplicate identity 병합
- GRDB migration, FTS5, Markdown/JSON renderer

Grove의 화자 수정 data model과 가장 가깝지만 2026-09-03 현재 GitHub star 0, fork 2,
공개 issue 0이라 실사용 검증 근거는 약합니다. 코드를 dependency로 삼기보다 migration,
speaker store와 correction command의 계약을 참고하는 수준이 적절합니다.

## 3. Muesli

저장소: <https://github.com/Muesli-HQ/muesli>

Grove와 같은 네이티브 macOS 계열에서 제품 기능이 가장 넓습니다.

- Swift, AppKit과 SwiftUI
- Core Audio process tap 기본, ScreenCaptureKit fallback
- 마이크와 시스템 오디오 분리
- FluidAudio 기반 remote speaker diarization
- Markdown과 PDF save panel export
- `rawTranscript` read-only, `formattedNotes`만 agent write-back
- local SQLite와 JSON-first CLI
- Apple Speech, WhisperKit, Parakeet, Qwen3-ASR 등 다양한 model provider

근거: <https://github.com/Muesli-HQ/muesli>

2026-09-03 감사 commit: `a070956a4e2dd1c044cb4c045918b402aa6b8972`

### 참고할 부분

- raw transcript를 수정 불가능한 source로 두는 데이터 계약
- `micAudioPath`, `systemAudioPath`를 명시한 meeting schema
- export format picker와 Markdown serialization
- 앱 bundle 안의 CLI와 JSON schema version
- local provider와 hosted provider를 UI에서 명확히 구분하는 방식

### 그대로 가져오지 않을 부분

- dictation, Quill, calendar, iCloud, iPhone bridge를 한 번에 포함한 범위
- 다수 실험 ASR을 동시에 노출하는 model catalog
- 녹음·전사 핵심보다 agent 기능이 앞서는 정보구조

Grove는 Apple Speech와 현재 실측 WhisperKit 정도로 model surface를 제한하고, 엔진 확장은
내부 protocol로만 열어 두는 편이 낫습니다.

## 4. Anarlog

저장소: <https://github.com/fastrepl/anarlog>

Hyprnote에서 이름이 바뀐 local-first meeting notetaker입니다. 현재 생산성 제품 `char`와는
별도 코드베이스입니다.

- Tauri v2 desktop app, React/TypeScript UI와 Rust backend
- local SQLite와 plain local files
- Markdown export
- transcription provider와 intelligence provider 분리
- cloud sync와 hosted AI는 opt-in
- community application은 MIT, `enterprise/`는 상용 라이선스

### 참고할 부분

- meeting library와 editor 중심 정보구조
- transcript, manual memo와 generated note를 분리하는 schema
- local storage와 optional sync의 명시적 경계
- plugin, export와 migration이 분리된 architecture

### 주의점

- 저장소가 매우 크고 enterprise·billing·web·mobile까지 섞여 있습니다.
- Grove SwiftUI에 코드를 직접 가져오는 이점이 작습니다.
- community MIT와 enterprise commercial 경계를 파일 단위로 확인해야 합니다.

따라서 UI 흐름과 schema 아이디어만 참고하고 dependency나 fork 대상으로 삼지 않습니다.

## 5. Meetily

저장소: <https://github.com/Zackriya-Solutions/meetily>

가장 큰 커뮤니티를 가진 후보지만 기능 확인에 주의가 필요합니다.

- Community app은 MIT, Tauri + Rust + Next.js
- macOS Apple Silicon DMG와 Windows installer 제공
- local Whisper/Parakeet와 optional Ollama/cloud summary provider
- 30.2k stars, 3.3k forks, 556 commits

그러나 Community README는 advanced export, speaker identification와 일부 diarization을 Pro 또는
coming-soon으로 설명합니다. 별도 Meetily 문서는 Markdown·DOCX·PDF export와 beta diarization을
소개하므로 Community와 Pro 기능이 섞였을 가능성이 있습니다.

결론적으로 Meetily의 star 수를 Grove 기능 채택 근거로 사용하지 않습니다. Community code의
실제 branch와 release tag에서 기능을 다시 확인하기 전에는 speaker/export 구현 참고 대상에서
제외합니다.

## 6. 신생 설계 참고 후보

### Tacet

<https://github.com/Tacetapp/tacet>

Whisper+ECAPA-TDNN, opt-in voice registry와 Markdown vault는 흥미롭지만 확인 시점 0 stars,
packaged release 미완성, unsigned DMG와 복합 Node/Python/Swift 환경입니다.

### Loqui

<https://github.com/joaquingit1/loqui>

`transcript.live.md`를 append-only로 유지하고 diarized transcript와 summary를 derived file로
분리하는 불변식은 좋습니다. diarization worker가 죽어도 앱 전체가 죽지 않는 process isolation과
typed IPC도 참고할 만합니다. 다만 확인 시점 3 stars이고, 원본 audio를 처리 후 자동 삭제하는
정책은 Grove의 원본 보존 방향과 다릅니다.

### Damso

<https://github.com/modakbul-gongbang/damso>

각 speaker card에서 짧은 sample을 듣고 후보 이름을 선택하는 confirmation UX는 Grove 요구에
가깝습니다. 그러나 확인 시점 6 stars, 30 commits로 초기 단계입니다. transcript를 agent CLI로
보내는 자동 흐름도 local-only 기본값으로 그대로 가져오면 안 됩니다.

## 보조 전사 앱

### Buzz

<https://github.com/chidiwilliams/buzz>

오프라인 Whisper, 파일 import, transcript 검색·재생, TXT/SRT/VTT export가 있는 성숙한
cross-platform transcription GUI입니다. 회의별 사람 관리와 speaker correction app은 아니므로
Grove 전체 구조의 기준은 아니지만 file import와 export viewer 회귀 테스트에 참고할 수 있습니다.

### Screenpipe

<https://github.com/screenpipe/screenpipe>

24시간 화면·오디오 기록과 local search를 다루는 별도 제품입니다. 현재 라이선스는 commercial
source-available이며 OSI 오픈소스로 부르기 어렵습니다. Grove는 24시간 screen capture와 월 수십
GB 저장 모델을 필요로 하지 않으므로 범위에서 제외합니다.

## Grove에 반영할 설계 원칙

### 도입 가치가 높은 항목

- 현재 Grove는 마이크 녹음과 파일 가져오기만 지원하며 system-output capture는 도입하지 않음
- 기존 이중 채널 파일은 출처를 보존해 읽되 신규 녹음 경로와 혼동하지 않음
- raw transcript, diarized transcript, corrected transcript와 summary를 별도 revision으로 관리
- meeting-local speaker cluster와 확인된 person profile 분리
- speaker sample 재생 후 이름 확인
- Markdown/TXT를 정식 serializer로 export
- pipeline stage가 실패해도 원본과 이전 결과는 유지
- 실제 model fixture E2E와 packaged app smoke를 분리

### 현재 도입하지 않을 항목

- 자동 calendar join과 자동 녹음
- ScreenCaptureKit fallback
- Accessibility participant scraping
- AI chat과 MCP
- agent CLI 자동 전송
- iCloud/cloud sync
- 여러 ASR model을 사용자에게 동시에 노출
- voiceprint의 자동 장기 저장

## 한국어 검증 한계

조사한 저장소 중 한국어 실제 다화자 개발 회의에 대해 다음을 함께 공개한 프로젝트는 확인하지
못했습니다.

- 한국어 CER
- speaker-attributed CER
- DER
- 겹침 발화 오류
- 60분 capture gap과 channel drift
- M4 Pro 외 저사양 Mac의 memory·energy

`Korean supported`, `multilingual`, `speaker diarization`은 세 기능이 함께 정확하다는 뜻이 아닙니다.
Grove는 후보 코드를 도입하더라도 사용이 승인된 독립적인 한국어 평가 자료로 별도 release gate를 유지해야 합니다.

## 다음 검증 제안

Meeting Transcriber, Muesli, diarize의 shallow source audit는 수행했습니다. 다음 단계는 코드를
복사하는 것이 아니라 동일한 평가 조건으로 후보 pipeline을 실행하는 것입니다. 개인 회의에서
도출된 결과는 이 공개 문서에 포함하지 않습니다. 현재 제품 상태는 `handoff.md`를 확인하십시오.

1. SpeakerKit/pyannote Community-1의 DER/JER를 독립적인 화자 정답과 비교
2. FluidAudio offline VBx와 Sortformer 4-speaker를 같은 RTTM 기준으로 비교
3. MOSS-Transcribe-Diarize MLX를 speaker-attributed CER/cpCER 보조 후보로 비교
4. 구간·cluster 재지정, 병합과 Undo를 Grove 자체 versioned schema로 구현

외부 코드나 diarization dependency를 새로 도입할 때는 실행 가능성과 품질 검증을 분리합니다.
현재 기본 프리셋은 베타 제품 정책이며, 그 자체를 일반적인 정확도 우위로 해석하지 않습니다.
