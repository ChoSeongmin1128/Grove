# Grove macOS app v0.2 구현 상태

구현일: 2026-09-02

## 실행 산출물

```text
dist/Grove.app
```

`scripts/package_app.sh release`가 Swift release binary, `Info.plist`, 사전 JSON,
마이크 entitlement, Core Audio 사용 설명, 제3자 고지를 `.app` bundle로 조립하고 ad-hoc signing과 signature 검증까지
수행합니다.

## 실제 동작

- 네이티브 SwiftUI macOS window와 Settings scene
- `회의 / 검토함 / 사전` sidebar
- 새 회의 sheet와 마이크 권한 진단
- 로컬 M4A 녹음, 경과 시간, input level, 저장 상태 HUD
- 선택형 Core Audio 시스템 출력 CAF + 마이크 M4A 분리 저장
- 주기적 capture manifest와 중단 세션 복구 표시
- 음성·영상 파일 picker import
- Apple `SpeechTranscriber(ko-KR)` 종료 후 전사
- 회의별 `AnalysisContext` 사전 적용 또는 사전 없음 선택
- Application Support 아래 meeting JSON과 원본 오디오 보존
- 회의록 / 대화 / 검토 segmented view
- confidence와 교정 원문 표시
- 회의록 claim에서 transcript source를 나타내는 evidence spine
- 50개 승인 사전 토글과 신규 용어 추가
- 원문 근거가 없는 회의록 claim 자동 생성 금지

## 시각 QA

릴리스 앱을 실제로 실행해 다음 화면을 macOS Accessibility tree와 window screenshot으로
확인했습니다.

1. 회의록: 결정·할 일과 근거 수, inspector 상태
2. 대화: 화자, 시간, confidence, 교정 전후, evidence rail
3. 사전: bundle에 포함된 50개 용어와 observed form
4. 새 회의: 제목, 사전 선택, 입력·저장 정보, 녹음 시작/취소
5. 파일 가져오기: macOS native file importer 표시

2026-09-02 실녹음 smoke test에서 시스템 출력 37.685초(1,808,896 frames,
3,533 buffers)와 마이크 37.823초(1,815,488 frames)를 각각 저장했습니다. 종료 후 Apple
한국어 전사가 두 채널을 `원격 오디오`와 `내 마이크` 발화로 분리 생성하는 것까지
확인했습니다. 이 결과는 짧은 기능 검증이며 60분 안정성 보증은 아닙니다.

## 다음 구현 경계

ScreenCaptureKit은 오디오 전용 녹음 경로에서 제거했습니다. 마이크만 모드는 마이크
권한만 사용하고, 선택형 system+mic 모드는 Core Audio process tap의 오디오 캡처 권한을
사용합니다. 화면/윈도우 영상 캡처 기능을 별도로 만들기 전에는 화면 녹화 권한을
요청하지 않습니다.

다음 단계는 Core Audio capture를 60분·장치 변경·sleep/lock·강제 종료 조건에서 검증한
뒤 아래 기능을 연결하는 것입니다.

1. Apple live progressive transcript
2. 정확 Apple 종료 후 pass
3. 선택 구간 WhisperKit pass
4. SpeakerKit/FluidAudio 비교 승자의 diarization
5. 근거가 있는 교정·결정·할 일 생성

현재 system+mic 모드는 두 파일이 실제로 생성되고 system buffer가 0이면 성공으로
처리하지 않습니다. 다만 CAF 기반 주기 manifest 복구는 구현됐어도 강제 종료 후 실제
복구와 장시간 clock drift는 아직 검증되지 않았습니다.
