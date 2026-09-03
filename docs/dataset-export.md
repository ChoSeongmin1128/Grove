# 검수 백업·평가 데이터 내보내기

상태: **Planned / 출력 계약, 미구현** · 버전: 0.1 · 2026-09-03

AI-assisted 문서입니다. 아래 exporter·snapshot·승인 검증은 아직 구현되지 않았습니다. [데이터 스키마](annotation-schema.md)와 [한국어 지침](labeling-guidelines-ko.md)을 함께 적용합니다.

## 출력과 구현 순서

| 출력 | 목적 | 시점/조건 |
|---|---|---|
| 일반 TXT/Markdown | 사람이 읽는 회의 기록 | 기존 기능과 별도 유지. 학습 정답 표시 금지 |
| Grove 검수 JSON 백업 | 초안 포함 무손실 보존/복원 | 작은 검수 베타 필수. ID·원형·출처·교정·검수·undo/redo 포함 |
| 불변 dataset snapshot + manifest | 특정 검수 상태/범위의 재현 가능한 고정 | 평가 데이터 단계. snapshotID와 교정 버전·증거·승인 버전 고정 |
| TSV | 검수 전사/제외 항목을 읽기 쉬운 표로 전달 | snapshot에서 파생. text만으로 정답 여부를 판단하지 않음 |
| RTTM + UEM | 독립 화자 활동 reference와 평가 범위 | 독립 활동 편집·완전성 검수 완료 후 |
| 모델별 ASR/diarization 학습 manifest | 모델별 입력 변환 | 후속 단계. 학습 승인·라이선스·분할 검사를 거친 adapter |

JSON 백업은 미검수/불명확 자료를 포함할 수 있습니다. **JSON 백업 ≠ 학습 정답**, 검수 완료 ≠ 학습/외부 제공 승인입니다. 특정 모델의 학습 형식을 앱의 정본 스키마로 삼지 않습니다.

## 목적별 포함 조건

| 목적 | 필요한 품질 근거 | 제외 또는 별도 처리 |
|---|---|---|
| ASR 구간 평가 | 실제 발화 텍스트·구간 경계 verified, 동일 audio/channel/timebase binding, 지침/정규화 고정. 기본 묶음은 비겹침도 확인 | legacy 의미 미확정 수정문, 문장 다듬기, 내용/끝 시각 불명확. 겹침은 기본 비겹침 묶음과 분리 |
| 회의 전체 ASR 평가 | 위 조건 + 선택 범위의 전사 완전성 검수 | 확인한 발화 몇 개만으로 전체 전사의 CER/WER라고 부르지 않음 |
| 화자 분리 평가 | 독립 활동의 화자·시각 verified + 활동/침묵 완전성 검수 범위 | 전사 문장 경계의 자동 RTTM 변환, 불명확 사람/경계, 미검수 공백 |
| 화자 포함 ASR 평가 | ASR 텍스트·시각·화자 배정·해당 범위 완전성 verified | CER와 DER의 단순 평균을 종합 오류율로 만들지 않음 |
| 학습용 변환 | 해당 목적의 품질 조건 + **명시적 학습 사용 승인** | 기본 미승인. 로컬 검수 허용만으로 학습 허용 추정 금지 |

한 목적에서 제외되더라도 다른 목적의 확인된 증거는 보존합니다. 예를 들어 알아듣지 못한 말도 사람·활동 시각이 확인되면 diarization 자료가 될 수 있습니다. 포함/제외량과 사유를 manifest에 남기며 조용히 누락하지 않습니다.

비겹침 여부는 검수된 활동/범위 근거로 판정합니다. 전사 행이 하나라는 이유만으로 단독 발화라고 가정하지 않습니다.

## UEM은 발화의 합집합이 아닙니다

pyannote의 evaluation map은 평가할 **오디오 범위**를 지정하며, DER에는 비발화를 발화로 잡은 false alarm도 포함됩니다. 따라서 검수한 침묵을 UEM에서 빼면 오검출 평가가 누락됩니다. [공식 Evaluation map / Components](https://pyannote.github.io/pyannote-metrics/basics.html#evaluation-map)

Grove 계획 규칙:

1. `activityCompleteness=verified`인 범위를 같은 음성·채널·시간기준별로 합칩니다. 이 범위는 사람이 확인한 침묵도 포함합니다.
2. 그 안의 활동/화자/경계 불명확·미검수 범위와 명시 제외 범위를 빼고 제외 사유를 기록합니다.
3. 남은 범위를 UEM으로 내보냅니다. RTTM은 그 범위에 해당하는 **확인된 활동**만 담고 겹친 화자는 유지합니다.
4. 확인된 침묵에는 RTTM 행이 없어도 됩니다. 미검수 구간에는 RTTM 행이 없다는 이유로 UEM을 만들지 않습니다.
5. 경계 변경·삭제·활동 수정으로 stale이 된 부분은 재검수 전 UEM에서 제외합니다. 넓은 승인 범위 전체를 무조건 버리지 말고 영향 부분과 이유를 명시합니다.

합성 예: 0–10초를 활동/침묵까지 검수했고 실제 말은2–4초만 있다면 UEM은0–10초, RTTM은2–4초 활동입니다. 6–7초가 불명확하면 UEM은0–6초와7–10초입니다. 발화2–4초만 검수했다면 다른 공백을 승인한 것으로 확장하지 않습니다.

평가에서 collar, 겹침 포함 여부, 매핑 정책, 라이브러리 버전을 고정합니다. 기준 발화량이0인 자료에 유효한 DER0%를 꾸며 넣지 않고 분모0/평가 불가와 오검출 시간 등을 구분합니다.

## 출력 필드와 무손실 기준

### JSON 백업

백업에는 exportKind=`grove-review-backup`, 백업 포맷 버전, 전체 교정 문서/현재 head, 불변 원본·모델 참조와 해시, 모든 항목 ID/출처, 검수 증거, 제외 사유, undo/redo, 지침 버전, 사용 승인 상태를 포함합니다.

음성 포함 여부를 명시합니다. 참조만 있는 JSON을 단독 완전복구 파일이라고 표시하지 않습니다. 원본/모델 파일을 외부 경로로 참조하면 required assets와 검증용 해시 목록을 함께 제공하고, 가져오기 시 없는 자산을 조용히 대체하지 않습니다.

### Snapshot manifest

snapshotID, 생성 시각, 선택 목적, audio hash/channel/timebase, modelRunIDs, correctionRevisionIDs, 유효 reviewEvidenceIDs, 지침/정규화/exporter 버전, 승인 버전, 포함/제외 IDs·범위·사유, 분할 그룹/역할, 각 파일 SHA256을 기록합니다.

작성 중 staging 결과는 완료 snapshot으로 노출하지 않습니다. 모든 파일/참조 검증 후 완료 명세를 발행하고, 실패 시 기존 snapshot과 현재 교정본은 그대로 유지합니다. 기존 snapshotID의 파일을 덮어쓰지 않습니다. 이후 교정·승인 변경은 새 snapshot에 반영합니다.

### TSV / RTTM / UEM

- TSV 필수 열: snapshotID, annotationID, audioAssetID, channelID, timebaseID, startTick/endTick, ticksPerSecond, start/end seconds, pseudonymousSpeakerID, verbatimText, textRole, 검수 축별 유효 상태, inclusionPurpose, exclusionReason, provenance 참조.
- 탭/줄바꿈/따옴표·한글·영문이 깨지지 않는 고정 인코딩/escaping을 정하고 재읽기 시험을 합니다. 표시용 반올림 시각만 저장하지 않습니다.
- RTTM은 전사 행이 아니라 SpeakerActivity에서 생성합니다. 익명 화자 ID와 겹침을 유지하고, channel/timebase를 잘못 합치지 않습니다.
- UEM/RTTM의 recording key와 channel 표기는 manifest에서 매핑합니다. 소비 도구가 다중 채널을 지원하지 않으면 채널별 recording key로 나누고 매핑을 남기며 하나로 섞지 않습니다.
- tick→초 표기는 exporter 버전으로 고정하고 interval 끝의 반올림·clip 정책을 기록합니다. 다시 읽은 시간이 허용 오차 내인지 검사합니다.
- 초기 ASR clip 변환은 검수된 비겹침을 기본으로 합니다. 생성 음성 clip은 파생물이며 원본 파일을 자르거나 덮어쓰지 않습니다.

## 분할·승인·개인정보

- 같은 회의에서 나온 클립은 기본적으로 같은 train/dev/holdout 그룹입니다. 같은 원본의 재가져오기·재전사·다른 모델 출력은 새 독립 표본이 아닙니다.
- originalSHA256과 원본 계보 그룹을 함께 검사합니다. 컨테이너 변환으로 바이트 해시가 바뀌었다고 같은 음성이 독립 holdout이 되지는 않습니다.
- 이미 반복 사용한 3분 파일은 **dev/regression**입니다. 이를 보고 모델/후처리/임계값/지침을 수정한 뒤 새 holdout 점수로 보고하지 않습니다.
- 새 회의 holdout을 따로 두고 사용 이력을 기록합니다. 새 사람 일반화가 목적이면 화자 단위 분리도 추가합니다. 적은 자료를 기계적으로8:1:1로 나누지 않습니다.
- 학습 승인 기본값은 `unapproved`입니다. 로컬 평가·학습·외부 제공 목적은 구분하고 선택 목적에 필요한 명시 승인을 확인합니다. 가명화된 이름은 음성 익명화가 아닙니다.
- 승인 철회는 이후 사용/내보내기 판단에 반영합니다. 기존 snapshot을 조용히 고쳐 과거 승인 이력을 지우지 않습니다. 원본/스냅샷 파기 정책은 별도 명시적 작업입니다.
- 공개 Git에는 코드·스키마·**합성 fixture만** 둡니다. 음성, 전사, 라벨, 검수 evidence, 임베딩, snapshot, 개인 경로/명단은 ignored 개인 데이터 영역에 둡니다. 내보내기 자체는 외부 업로드가 아닙니다.

## 완료 기준

- 미검수·stale·불명확·미승인 자료가 목적별 정답에 섞이지 않고, 제외량/사유가 재현됩니다.
- verified 침묵, 짧은 응답 누락, 겹침, 삭제 후 범위 재검수 사례를 합성 fixture로 검사합니다.
- JSON 왕복에서 원형/ID/undo/redo/출처/증거를 보존하고, TSV/RTTM/UEM 왕복에서 채널·시간·화자·겹침이 유지됩니다.
- 동일 snapshot과 고정 평가 설정으로 CER, 화자 혼동/누락/오검출/DER, 종합 지표를 각각 재현합니다. 잘못된 분모·중복 표본·reference leakage를 검사합니다.
- 저장 중 실패/재시작에서 미완성 snapshot이 완료로 보이지 않고 기존 원본·교정본·snapshot이 손상되지 않습니다. 이 검증이 끝나기 전에는 학습/평가 데이터 생산 완료라고 부르지 않습니다.
