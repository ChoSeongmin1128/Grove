#!/usr/bin/env python3
"""Build Grove's bounded technical comparison report artifact."""

from __future__ import annotations

import csv
import json
import sqlite3
from datetime import datetime
from pathlib import Path


ROOT = Path(__file__).parents[1]


def markdown(block_id: str, body: str, *, source_id: str | None = None) -> dict:
    block = {"id": block_id, "type": "markdown", "body": body}
    if source_id:
        block["sourceId"] = source_id
    return block


def source(source_id: str, label: str, table: str, description: str, definitions: list[str]) -> dict:
    return {
        "id": source_id,
        "label": label,
        "query": {
            "id": f"grove-{source_id}-2026-09-01",
            "description": description,
            "engine": "SQLite over Grove benchmark outputs",
            "executed_at": datetime.now().astimezone().isoformat(timespec="seconds"),
            "language": "sql",
            "sql": f"SELECT * FROM {table}",
            "tables_used": [table],
            "filters": [
                "AI Hub #132 D26/G02/S000009의 WAV 141개 전체",
                "Apple ko_KR 및 WhisperKit ko 고정",
                "각 엔진 모델 warm-up 이후 측정",
            ],
            "metric_definitions": definitions,
        },
    }


def main() -> None:
    summaries = json.loads((ROOT / "results/scored/summary.json").read_text())
    practical = json.loads((ROOT / "results/practical/summary.json").read_text())
    power = json.loads((ROOT / "results/resources/power-summary.json").read_text())
    resource_runs = {
        name: json.loads((ROOT / f"results/resources/{name}-full.json").read_text())
        for name in ("apple", "whisperkit")
    }
    generated_at = datetime.now().astimezone().isoformat(timespec="seconds")

    summaries_by_engine = {row["engine"]: row for row in summaries}
    engine_rows = []
    for key, label in (("apple", "Apple SpeechTranscriber"), ("whisperkit", "WhisperKit")):
        quality = summaries_by_engine[key]
        power_row = power["engines"][key]
        resource = resource_runs[key]
        engine_rows.append(
            {
                "engine": label,
                "items": quality["items"],
                "failures": quality["failures"],
                "cer": quality["cer"],
                "strict_cer": quality["strict_cer"],
                "exact_match_rate": quality["exact_match_rate"],
                "wall_seconds": power_row["timing"]["wall_seconds"],
                "rtf": power_row["audio_real_time_factor"],
                "mean_system_power_w": power_row["power"]["mean"]["combined_mw"] / 1000,
                "raw_system_energy_j": power_row["raw_system_energy_joules"],
                "incremental_energy_j": power_row["incremental_energy_joules"],
                "incremental_energy_per_audio_minute_j": power_row[
                    "incremental_energy_joules_per_audio_minute"
                ],
                "observable_included_peak_rss_mib": resource["included_peak_rss_kb"] / 1024,
                "frontend_max_rss_mib": power_row["timing"]["max_rss_bytes"] / 1024**2,
                "included_cpu_seconds": resource["included_cpu_seconds"],
                "dominant_compute": "CPU 중심, 시스템 Speech XPC 포함"
                if key == "apple"
                else "ANE 중심, 로드된 WhisperKit 서버 포함",
            }
        )

    speaker_rows = []
    with (ROOT / "results/scored/by_speaker.csv").open(encoding="utf-8") as source_file:
        for row in csv.DictReader(source_file):
            speaker_rows.append(
                {
                    "engine": "Apple SpeechTranscriber" if row["engine"] == "apple" else "WhisperKit",
                    "speaker": row["speaker"],
                    "items": int(row["items"]),
                    "cer": float(row["cer"]),
                    "mean_rtf": float(row["mean_rtf"]),
                }
            )

    hybrid = practical["fixed_threshold_hybrid"]
    scenario_rows = [
        {
            "scenario": "Apple만 사용",
            "cer": practical["quality"]["apple_cer"],
            "estimated_wall_seconds": power["engines"]["apple"]["timing"]["wall_seconds"],
            "estimated_incremental_energy_j": power["engines"]["apple"]["incremental_energy_joules"],
            "whisper_fallback_items": 0,
            "status": "실측",
        },
        {
            "scenario": "Apple + confidence 보조",
            "cer": hybrid["cer"],
            "estimated_wall_seconds": hybrid["estimated_sequential_wall_seconds"],
            "estimated_incremental_energy_j": hybrid["estimated_incremental_energy_joules"],
            "whisper_fallback_items": hybrid["selected_items"],
            "status": "동일 표본 추정",
        },
        {
            "scenario": "WhisperKit만 사용",
            "cer": practical["quality"]["whisper_cer"],
            "estimated_wall_seconds": power["engines"]["whisperkit"]["timing"]["wall_seconds"],
            "estimated_incremental_energy_j": power["engines"]["whisperkit"]["incremental_energy_joules"],
            "whisper_fallback_items": 141,
            "status": "실측",
        },
    ]
    length_rows = practical["quality"]["by_length"]

    database_path = ROOT / "results/report/benchmark.sqlite"
    database_path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(database_path)
    with connection:
        for table in ("engine_metrics", "speaker_metrics", "scenario_metrics", "length_metrics"):
            connection.execute(f"DROP TABLE IF EXISTS {table}")
        connection.execute(
            """CREATE TABLE engine_metrics (
                engine TEXT, items INTEGER, failures INTEGER, cer REAL, strict_cer REAL,
                exact_match_rate REAL, wall_seconds REAL, rtf REAL, mean_system_power_w REAL,
                raw_system_energy_j REAL, incremental_energy_j REAL,
                incremental_energy_per_audio_minute_j REAL,
                observable_included_peak_rss_mib REAL, frontend_max_rss_mib REAL,
                included_cpu_seconds REAL, dominant_compute TEXT
            )"""
        )
        connection.execute(
            "CREATE TABLE speaker_metrics (engine TEXT, speaker TEXT, items INTEGER, cer REAL, mean_rtf REAL)"
        )
        connection.execute(
            """CREATE TABLE scenario_metrics (
                scenario TEXT, cer REAL, estimated_wall_seconds REAL,
                estimated_incremental_energy_j REAL, whisper_fallback_items INTEGER, status TEXT
            )"""
        )
        connection.execute(
            "CREATE TABLE length_metrics (length_bin TEXT, items INTEGER, apple_cer REAL, whisper_cer REAL)"
        )
        connection.executemany(
            "INSERT INTO engine_metrics VALUES (:engine,:items,:failures,:cer,:strict_cer,:exact_match_rate,:wall_seconds,:rtf,:mean_system_power_w,:raw_system_energy_j,:incremental_energy_j,:incremental_energy_per_audio_minute_j,:observable_included_peak_rss_mib,:frontend_max_rss_mib,:included_cpu_seconds,:dominant_compute)",
            engine_rows,
        )
        connection.executemany(
            "INSERT INTO speaker_metrics VALUES (:engine,:speaker,:items,:cer,:mean_rtf)", speaker_rows
        )
        connection.executemany(
            "INSERT INTO scenario_metrics VALUES (:scenario,:cer,:estimated_wall_seconds,:estimated_incremental_energy_j,:whisper_fallback_items,:status)", scenario_rows
        )
        connection.executemany(
            "INSERT INTO length_metrics VALUES (:length_bin,:items,:apple_cer,:whisper_cer)", length_rows
        )
    connection.row_factory = sqlite3.Row
    datasets = {
        table: [dict(row) for row in connection.execute(f"SELECT * FROM {table}")]
        for table in ("engine_metrics", "speaker_metrics", "scenario_metrics", "length_metrics")
    }
    connection.close()

    quality_source = source(
        "quality-benchmark",
        "Grove Korean ASR scored benchmark",
        "engine_metrics",
        "141개 한국어 발화의 엔진별 문자 오류율과 처리 결과",
        [
            "CER = 전체 문자 삽입, 삭제, 치환 수 / 정답 문자 수; 문장부호와 띄어쓰기 제외",
            "표기/발음 대안은 AI Hub 라벨이 허용한 후보 중 최소 편집거리 사용",
            "paired bootstrap = 클립 141개 복원추출 10,000회",
        ],
    )
    resource_source = source(
        "resource-benchmark",
        "Grove powermetrics and process monitor run",
        "engine_metrics",
        "동일 음원 전체 처리 중 wall time, system-wide power, energy 및 관측 RSS",
        [
            "wall time = /usr/bin/time 실시간",
            "raw system energy = powermetrics 평균 combined power x wall time",
            "incremental energy = (실행 평균 combined power - 별도 idle 평균) x wall time",
            "observable included RSS = 앱/클라이언트와 식별 가능한 시스템 서비스의 각 peak RSS 합",
        ],
    )
    scenario_source = source(
        "scenario-analysis",
        "Grove practical hybrid simulation",
        "scenario_metrics",
        "Apple 최소 confidence 0.80 이하에만 WhisperKit을 적용한 동일 표본 시뮬레이션",
        [
            "hybrid CER = 선택 클립은 WhisperKit, 나머지는 Apple 전사를 사용한 corpus CER",
            "hybrid wall/energy = Apple 전체 실측 + 선택된 Whisper 처리시간 비중으로 환산한 추가 비용",
        ],
    )
    speaker_source = source(
        "speaker-benchmark",
        "Grove speaker slice",
        "speaker_metrics",
        "AI Hub 세션 메타데이터의 화자 ID별 CER",
        ["speaker CER = 해당 화자의 전체 편집 수 / 해당 화자의 전체 정답 문자 수"],
    )
    sources = [quality_source, resource_source, scenario_source, speaker_source]

    manifest = {
        "version": 1,
        "surface": "report",
        "title": "Grove 한국어 ASR 실사용 비교",
        "generatedAt": generated_at,
        "sources": sources,
        "blocks": [
            markdown("title", "# Grove 한국어 ASR 실사용 비교"),
            markdown(
                "technical-summary",
                "## 결론: 기본은 Apple, 품질 보정은 선택적 Whisper가 합리적입니다\n\n"
                "이 M4 Pro 시험에서 **WhisperKit은 CER 5.65%로 Apple 6.77%보다 1.12%p 정확했지만**, "
                "전체 처리에는 6.99배 오래 걸렸고 idle 보정 에너지는 3.20배 더 썼습니다. 단일 엔진이라면 "
                "실시간·배터리·낮은 사양 대응은 Apple, 무인 사후 최종본의 문자 정확도는 WhisperKit이 낫습니다.\n\n"
                "실제 Grove 구조는 Apple을 기본으로 두고 낮은 confidence 발화만 WhisperKit으로 재검토하는 편이 균형이 좋습니다. "
                "다만 이 혼합 결과는 동일 표본 시뮬레이션이므로 제품 기본값으로 확정할 근거는 아직 아닙니다.",
            ),
            markdown(
                "quality-finding",
                "## WhisperKit은 어려운 발화의 큰 오류를 더 줄였습니다\n\n"
                "WhisperKit은 57개 클립에서 우세했고 Apple은 23개, 동률은 61개였습니다. CER 20% 이상인 심한 오류도 "
                "Apple 11개, WhisperKit 7개였습니다. 예를 들어 Apple은 ‘선생님’을 ‘아버님’, ‘청각’을 ‘총각’으로 바꾼 반면 "
                "WhisperKit은 이 사례를 맞혔습니다. 반대로 ‘퍼스널 컴퓨터’를 영어로 표기한 Whisper 결과는 의미상 맞아도 CER에서 크게 불리했습니다. "
                "따라서 CER 우위는 유효하지만 회의록 의미 정확도 전체와 동일하지는 않습니다.",
                source_id="quality-benchmark",
            ),
            {"id": "quality-chart-block", "type": "chart", "chartId": "quality-chart"},
            markdown(
                "resource-finding",
                "## Apple은 순간 전력은 높았지만 훨씬 빨리 끝나 총 에너지가 적었습니다\n\n"
                "Apple 실행 중 시스템 평균 전력은 8.91W로 WhisperKit 5.02W보다 높았습니다. 그러나 989.8초 음원을 "
                "17.78초에 끝내 WhisperKit의 124.30초보다 6.99배 빨랐습니다. 그 결과 raw system energy는 "
                "158J 대 625J, idle 보정 에너지는 127J 대 407J였습니다. 배터리 관점에서는 평균 W보다 작업 전체 J가 중요하므로 "
                "이 시험에서는 Apple이 분명히 유리합니다.",
                source_id="resource-benchmark",
            ),
            {"id": "wall-chart-block", "type": "chart", "chartId": "wall-chart"},
            {"id": "energy-chart-block", "type": "chart", "chartId": "energy-chart"},
            markdown(
                "memory-finding",
                "## 관측 RSS는 비슷하며 Apple의 저사양 이점은 메모리보다 속도·에너지입니다\n\n"
                "식별 가능한 앱·서버·시스템 서비스의 peak RSS 합은 Apple 약 189MiB, WhisperKit 약 170MiB였습니다. "
                "Apple 앱 단독은 약 19MiB, Whisper 클라이언트는 약 32MiB였지만 둘 다 핵심 모델 실행이 별도 XPC·서버·ANE에 있어 "
                "단독 RSS 비교는 의미가 없습니다. Core ML 공유 메모리와 압축 메모리도 완전히 귀속되지 않으므로 ‘Apple이 메모리를 덜 쓴다’고 "
                "결론내릴 수 없습니다. 저사양 우위는 이번에 확실히 측정된 처리량과 에너지에서 나옵니다.",
                source_id="resource-benchmark",
            ),
            {"id": "resource-table-block", "type": "table", "tableId": "resource-table"},
            markdown(
                "hybrid-finding",
                "## confidence 보조 실행은 품질 손실을 작게 유지하며 비용을 줄일 가능성이 있습니다\n\n"
                "Apple 최소 confidence가 0.80 이하인 49개(34.8%)만 WhisperKit 결과로 교체하면 CER는 5.73%였습니다. "
                "WhisperKit 전체 실행의 5.65%보다 0.08%p 높지만, 순차 wall time은 약 64.4초(Whisper 전체의 51.8%), "
                "idle 보정 에너지는 약 280J(68.8%)로 추정됩니다. 최소 confidence와 Apple 클립 CER의 상관은 -0.25로 약하며, "
                "화자 제외 교차검증 CER는 5.79%였습니다. 즉 유용한 라우팅 신호이지만 강한 품질 보증 신호는 아닙니다.",
                source_id="scenario-analysis",
            ),
            {"id": "scenario-table-block", "type": "table", "tableId": "scenario-table"},
            markdown(
                "segment-finding",
                "## 엔진 우위는 화자와 발화 길이에 따라 바뀌었습니다\n\n"
                "WhisperKit은 화자 1·2·3에서 더 낮은 CER였지만 15개 클립뿐인 화자 8에서는 Apple 8.20%, WhisperKit 11.75%였습니다. "
                "3초 미만 발화는 Apple이 근소하게 나았고 8초 이상에서는 WhisperKit이 7.00% 대 5.26%로 우세했습니다. "
                "화자 표본 수가 15~59개로 불균형해 성별·연령 효과로 해석할 수 없습니다.",
            ),
            {"id": "speaker-table-block", "type": "table", "tableId": "speaker-table"},
            markdown(
                "scope",
                "## 측정 범위: 16분 29.8초의 독립 한국어 방송 발화\n\n"
                "대상은 AI Hub #132의 IT·일반·studio·broadcast 세션으로, 4화자의 16kHz mono WAV 141개입니다. "
                "문장부호와 띄어쓰기를 제거하고 AI Hub 표기/발음 대안을 허용한 corpus CER를 주 지표로 사용했습니다. "
                "Apple은 macOS의 설치된 ko_KR SpeechTranscriber 에셋, WhisperKit은 CLI 1.1.0의 "
                "large-v3-v20240930_626MB를 ko, temperature 0, worker 1, chunking none으로 실행했습니다.",
            ),
            markdown(
                "robustness",
                "## 재현성은 높지만 회의 품질 검증은 아직 아닙니다\n\n"
                "Apple 4회와 WhisperKit 3회의 141개 전사문은 엔진별로 완전히 동일했습니다. WhisperKit의 CER 우위에 대한 paired bootstrap "
                "95% 구간도 -2.01%p~-0.13%p였습니다. 그러나 powermetrics는 시스템 전체 추정치이며 idle 부하가 달라 raw와 idle 보정값을 함께 봐야 합니다. "
                "더 중요한 한계는 이 데이터가 연속 회의가 아니라는 점입니다. 화자 분리, 겹침 발화, 실시간 첫 결과 지연, 현대 개발 용어, 회의 요약과 액션아이템 품질은 측정하지 못했습니다.",
            ),
            markdown(
                "next-steps",
                "## Grove의 다음 구현·시험 순서\n\n"
                "1. **1차 PoC 기본 경로:** Apple 실시간 초안과 confidence를 저장합니다.\n"
                "2. **선택 보정 경로:** 최소 confidence 0.80 이하 구간만 WhisperKit으로 비동기 재전사하되 임계값을 설정으로 둡니다.\n"
                "3. **실제 회의 검증:** 3인 이상 한국어 개발회의 30~60분으로 speaker-attributed CER, DER, 겹침 구간 CER를 측정합니다.\n"
                "4. **회의록 평가:** 용어집 적용 전후의 핵심 용어 recall, 숫자·고유명사 정확도, 결정·액션아이템 누락률을 별도 채점합니다.\n"
                "5. **저사양 검증:** 8GB·16GB Apple Silicon에서 thermal state, memory pressure, 배터리 소모를 같은 스크립트로 재측정합니다.",
            ),
            markdown(
                "questions",
                "## 결론을 바꿀 수 있는 남은 질문\n\n"
                "- 실제 개발회의에서도 WhisperKit의 1.12%p CER 우위가 유지되는가?\n"
                "- confidence 임계값이 다른 화자·마이크에서도 같은 비용 대비 품질을 내는가?\n"
                "- Apple/Whisper 용어집·후처리가 의미 오류와 환각을 각각 얼마나 줄이는가?\n"
                "- 화자 분리는 오디오 채널 분리와 diarization 중 어느 쪽이 Grove의 실제 입력에서 더 정확한가?",
            ),
        ],
        "charts": [
            {
                "id": "quality-chart",
                "title": "엔진별 한국어 문자 오류율",
                "subtitle": "141개 발화의 corpus CER; 낮을수록 좋음",
                "type": "bar",
                "intent": "comparison",
                "dataset": "engine_metrics",
                "encodings": {"x": {"field": "engine"}, "y": {"field": "cer"}},
                "sourceId": "quality-benchmark",
            },
            {
                "id": "wall-chart",
                "title": "전체 음원 처리 wall time",
                "subtitle": "989.8초 음원 전체 처리; 낮을수록 빠름",
                "type": "bar",
                "intent": "comparison",
                "dataset": "engine_metrics",
                "encodings": {"x": {"field": "engine"}, "y": {"field": "wall_seconds"}},
                "sourceId": "resource-benchmark",
            },
            {
                "id": "energy-chart",
                "title": "전체 작업의 idle 보정 에너지",
                "subtitle": "별도 idle 평균을 뺀 system-wide 추정치; 낮을수록 좋음",
                "type": "bar",
                "intent": "comparison",
                "dataset": "engine_metrics",
                "encodings": {"x": {"field": "engine"}, "y": {"field": "incremental_energy_j"}},
                "sourceId": "resource-benchmark",
            },
        ],
        "tables": [
            {
                "id": "resource-table",
                "title": "엔진별 실측 자원 지표",
                "subtitle": "메모리는 식별 가능한 관련 프로세스의 peak RSS 합이며 완전한 모델 귀속값이 아님",
                "dataset": "engine_metrics",
                "columns": [
                    {"field": "engine", "label": "엔진", "type": "text"},
                    {"field": "wall_seconds", "label": "wall 초", "type": "number"},
                    {"field": "mean_system_power_w", "label": "평균 W", "type": "number"},
                    {"field": "incremental_energy_j", "label": "보정 J", "type": "number"},
                    {"field": "observable_included_peak_rss_mib", "label": "관측 peak MiB", "type": "number"},
                    {"field": "dominant_compute", "label": "주 실행 경로", "type": "text"},
                ],
                "defaultSort": {"field": "wall_seconds", "direction": "asc"},
                "sourceId": "resource-benchmark",
            },
            {
                "id": "scenario-table",
                "title": "실행 전략별 품질·비용",
                "subtitle": "Apple·Whisper는 실측, confidence 보조는 동일 표본 기반 추정",
                "dataset": "scenario_metrics",
                "columns": [
                    {"field": "scenario", "label": "전략", "type": "text"},
                    {"field": "cer", "label": "CER", "type": "percent"},
                    {"field": "estimated_wall_seconds", "label": "wall 초", "type": "number"},
                    {"field": "estimated_incremental_energy_j", "label": "보정 J", "type": "number"},
                    {"field": "whisper_fallback_items", "label": "Whisper 클립", "type": "number"},
                    {"field": "status", "label": "근거", "type": "text"},
                ],
                "defaultSort": {"field": "cer", "direction": "asc"},
                "sourceId": "scenario-analysis",
            },
            {
                "id": "speaker-table",
                "title": "엔진·화자별 문자 오류율",
                "subtitle": "화자별 클립 15~59개; 인구통계 효과로 해석하지 않음",
                "dataset": "speaker_metrics",
                "columns": [
                    {"field": "engine", "label": "엔진", "type": "text"},
                    {"field": "speaker", "label": "화자", "type": "text"},
                    {"field": "items", "label": "클립", "type": "number"},
                    {"field": "cer", "label": "CER", "type": "percent"},
                    {"field": "mean_rtf", "label": "평균 RTF", "type": "number"},
                ],
                "defaultSort": {"field": "speaker", "direction": "asc"},
                "sourceId": "speaker-benchmark",
            },
        ],
    }

    artifact = {
        "surface": "report",
        "manifest": manifest,
        "snapshot": {
            "version": 1,
            "status": "ready",
            "generatedAt": generated_at,
            "datasets": datasets,
        },
        "sources": sources,
    }
    output = ROOT / "results/report/artifact.json"
    output.write_text(json.dumps(artifact, ensure_ascii=False, indent=2) + "\n")
    print(output)


if __name__ == "__main__":
    main()
