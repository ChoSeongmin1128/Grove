use crate::engine::Engine;
use crate::store::{self, CapturePhase, Encoding, Manifest};
use crate::{CoreError, Meeting, MeetingStatus, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::io::{BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TranscriptVersion {
    pub id: String,
    pub revision: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TranscriptSegment {
    pub id: String,
    pub start: f64,
    pub end: f64,
    pub original_text: String,
    pub text: String,
    #[serde(default)]
    pub speaker_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TranscriptSpeaker {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Transcript {
    pub version: TranscriptVersion,
    pub source_session_id: String,
    pub model: String,
    pub model_revision: String,
    #[serde(default)]
    pub speakers: Vec<TranscriptSpeaker>,
    pub segments: Vec<TranscriptSegment>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MossOutput {
    model: String,
    segments: Vec<MossSegment>,
    hit_token_limit: bool,
    has_unparsed_text: bool,
    processed_audio_frames: u64,
    input_audio_frames: u64,
    audio_duration_seconds: f64,
}

#[derive(Deserialize)]
struct MossSegment {
    start: f64,
    end: f64,
    text: String,
    speaker_id: Option<serde_json::Value>,
    #[serde(default, deserialize_with = "present_chunk")]
    asr_chunk: Option<serde_json::Value>,
}

fn present_chunk<'de, D>(
    deserializer: D,
) -> std::result::Result<Option<serde_json::Value>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    serde_json::Value::deserialize(deserializer).map(Some)
}

impl MossOutput {
    fn decode(raw: &[u8], duration: f64, session_id: &str, id: &str) -> Result<Transcript> {
        if raw.len() > 16 * 1024 * 1024 {
            return Err(CoreError::InvalidInput("전사 결과가 너무 큽니다.".into()));
        }
        let output: Self = serde_json::from_slice(raw)
            .map_err(|_| CoreError::InvalidInput("전사 결과를 읽을 수 없습니다.".into()))?;
        if output.model != "OpenMOSS-Team/MOSS-Transcribe-Diarize"
            || output.hit_token_limit
            || output.has_unparsed_text
            || output.input_audio_frames == 0
            || output.processed_audio_frames != output.input_audio_frames
            || !output.audio_duration_seconds.is_finite()
            || (output.audio_duration_seconds - duration).abs() > 0.5
            || (output.input_audio_frames as f64 / 16000.0 - duration).abs() > 0.5
        {
            return Err(CoreError::InvalidInput(
                "전사가 끝까지 완료되지 않았습니다. 원본 결과는 보관했습니다.".into(),
            ));
        }
        if output.segments.is_empty() {
            return Err(CoreError::InvalidInput(
                "인식된 발화가 없습니다. 원본 음성은 보관했습니다.".into(),
            ));
        }
        let mut segments = Vec::new();
        let mut speakers: Vec<TranscriptSpeaker> = Vec::new();
        let mut speaker_ids = BTreeSet::new();
        let chunked = output
            .segments
            .iter()
            .any(|segment| segment.asr_chunk.is_some());
        for segment in output.segments {
            if !segment.start.is_finite()
                || !segment.end.is_finite()
                || segment.start < 0.0
                || segment.end < segment.start
                || segment.end > duration + 0.5
                || segment.text.trim().is_empty()
                || segment.text.len() > 2 * 1024 * 1024
                || segment.text.contains('\0')
            {
                return Err(CoreError::InvalidInput(
                    "전사 구간 또는 시각이 올바르지 않습니다.".into(),
                ));
            }
            let model_label = model_speaker_id(segment.speaker_id.as_ref());
            let speaker_id = model_label
                .as_ref()
                .and_then(|label| match &segment.asr_chunk {
                    Some(value) => value
                        .as_u64()
                        .map(|chunk| format!("moss:chunk:{chunk}:{label}")),
                    None if !chunked => Some(label.clone()),
                    None => None,
                });
            let mut text = segment.text;
            if let Some(label) = &model_label {
                if let Some(body) = text.strip_prefix(&format!("[{label}] ")) {
                    text = body.to_owned();
                }
            }
            if let Some(label) = &speaker_id {
                if speaker_ids.insert(label.clone()) {
                    speakers.push(TranscriptSpeaker {
                        id: label.clone(),
                        name: format!("화자 {}", speakers.len() + 1),
                    });
                }
            }
            segments.push(TranscriptSegment {
                id: Uuid::new_v4().to_string(),
                start: segment.start.min(duration),
                end: segment.end.min(duration),
                original_text: text.clone(),
                text,
                speaker_id,
            });
        }
        Ok(Transcript {
            version: TranscriptVersion {
                id: id.into(),
                revision: 0,
            },
            source_session_id: session_id.into(),
            model: output.model,
            model_revision: serde_json::from_str::<serde_json::Value>(include_str!(
                "../../../Sources/GroveApp/Resources/Models/moss.json"
            ))
            .map_err(|e| CoreError::Storage(e.to_string()))?["revision"]
                .as_str()
                .unwrap_or_default()
                .into(),
            speakers,
            segments,
        })
    }
}

fn model_speaker_id(value: Option<&serde_json::Value>) -> Option<String> {
    match value? {
        serde_json::Value::String(label)
            if label.len() > 1
                && label.len() <= 64
                && label.starts_with('S')
                && label[1..].bytes().all(|b| b.is_ascii_digit()) =>
        {
            Some(label.clone())
        }
        serde_json::Value::Number(number) => number
            .as_u64()
            .filter(|id| *id > 0)
            .map(|id| format!("S{id}")),
        _ => None,
    }
}

fn validate_speakers(speakers: &[TranscriptSpeaker], assignments: &[Option<String>]) -> Result<()> {
    let mut ids = BTreeSet::new();
    for speaker in speakers {
        if speaker.id.is_empty()
            || speaker.id.len() > 128
            || !speaker
                .id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b':')
            || speaker.name.trim().is_empty()
            || speaker.name.len() > 256
            || speaker.name.chars().any(char::is_control)
            || !ids.insert(speaker.id.as_str())
        {
            return Err(CoreError::InvalidInput(
                "화자 이름 또는 ID가 올바르지 않습니다.".into(),
            ));
        }
    }
    if speakers.len() > 4096
        || assignments
            .iter()
            .flatten()
            .any(|id| !ids.contains(id.as_str()))
    {
        return Err(CoreError::InvalidInput(
            "화자 배정이 올바르지 않습니다.".into(),
        ));
    }
    Ok(())
}

fn transcript_dir(meeting_id: &str, transcript_id: &str) -> Result<PathBuf> {
    store::validate_id(meeting_id)?;
    store::validate_id(transcript_id)?;
    Ok(Path::new("meetings")
        .join(meeting_id)
        .join("transcripts")
        .join(transcript_id))
}

fn immutable_json(root: &Path, relative: &Path, value: &impl Serialize) -> Result<()> {
    let mut file = store::create_new(&store::checked_path(root, relative)?)?;
    serde_json::to_writer(&mut file, value).map_err(|e| CoreError::Storage(e.to_string()))?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    Ok(())
}

impl Engine {
    pub fn import_audio(
        &mut self,
        title: String,
        source: PathBuf,
        prepared: PathBuf,
    ) -> Result<Meeting> {
        if self.quitting {
            return Err(CoreError::Unavailable);
        }
        if self.capture.is_some() {
            return Err(CoreError::RecordingBusy);
        }
        if !source.is_absolute() || !prepared.is_absolute() {
            return Err(CoreError::InvalidInput(
                "음성 파일의 절대 경로가 필요합니다.".into(),
            ));
        }
        let mut wav = hound::WavReader::new(BufReader::new(store::open_read(&prepared)?))
            .map_err(|e| CoreError::Audio(e.to_string()))?;
        let spec = wav.spec();
        if spec.channels != 1
            || spec.sample_rate != 16000
            || spec.bits_per_sample != 16
            || spec.sample_format != hound::SampleFormat::Int
            || wav.duration() == 0
        {
            return Err(CoreError::Audio(
                "분석용 음성 형식이 올바르지 않습니다.".into(),
            ));
        }
        let source_file = store::open_read(&source)?;
        let metadata = source_file.metadata()?;
        let mut stored = self.store.create(title, String::new())?;
        let mut manifest = Manifest::new(
            &stored.meeting.id,
            "import",
            "파일 가져오기",
            16000,
            1,
            Encoding::I16,
        );
        let result = (|| -> Result<()> {
            let mut pcm = BufWriter::new(self.store.prepare_capture(&manifest)?);
            stored.capture_id = Some(manifest.session_id.clone());
            stored.meeting.status = MeetingStatus::Interrupted;
            self.store.save(&stored)?;
            let directory = manifest.relative_dir();
            let extension = source
                .extension()
                .and_then(|x| x.to_str())
                .unwrap_or("audio")
                .to_ascii_lowercase();
            if !["wav", "m4a", "mp3", "aac", "aiff", "aif", "caf", "audio"]
                .contains(&extension.as_str())
            {
                return Err(CoreError::Audio(
                    "지원하지 않는 음성 파일 형식입니다.".into(),
                ));
            }
            let destination = store::checked_path(
                &self.store.root,
                &directory.join(format!("source.{extension}")),
            )?;
            let mut original = store::create_new(&destination)?;
            let mut reader = source_file;
            let mut digest = Sha256::new();
            let mut buffer = [0u8; 64 * 1024];
            let mut bytes = 0u64;
            loop {
                let count = reader.read(&mut buffer)?;
                if count == 0 {
                    break;
                }
                original.write_all(&buffer[..count])?;
                digest.update(&buffer[..count]);
                bytes += count as u64;
            }
            original.sync_all()?;
            if bytes != metadata.len()
                || reader.metadata()?.modified().ok() != metadata.modified().ok()
            {
                return Err(CoreError::Audio(
                    "가져오는 동안 음성 파일이 변경되었습니다. 다시 선택해 주세요.".into(),
                ));
            }
            immutable_json(
                &self.store.root,
                &directory.join("source.json"),
                &serde_json::json!({"filename":source.file_name().and_then(|x| x.to_str()), "bytes":bytes,"sha256":format!("{:x}",digest.finalize())}),
            )?;
            for sample in wav.samples::<i16>() {
                pcm.write_all(
                    &sample
                        .map_err(|e| CoreError::Audio(e.to_string()))?
                        .to_le_bytes(),
                )?;
            }
            pcm.flush()?;
            pcm.get_ref().sync_all()?;
            drop(pcm);
            manifest.phase = CapturePhase::Completed;
            stored.meeting.audio = store::finalize_audio(&self.store.root, &mut manifest)?;
            stored.meeting.status = MeetingStatus::Completed;
            self.store.save(&stored)?;
            Ok(())
        })();
        if let Err(error) = &result {
            stored.meeting.status = MeetingStatus::Interrupted;
            stored.meeting.error = Some(error.to_string());
            let _ = self.store.save(&stored);
        }
        let meeting = stored.meeting.clone();
        self.meetings.insert(meeting.id.clone(), stored);
        result?;
        Ok(meeting)
    }

    pub fn transcript(&self, id: &str) -> Result<Option<Transcript>> {
        store::validate_id(id)?;
        let meeting = &self
            .meetings
            .get(id)
            .ok_or(CoreError::MeetingNotFound)?
            .meeting;
        let Some(transcript_id) = &meeting.transcript_id else {
            return Ok(None);
        };
        let directory = transcript_dir(id, transcript_id)?;
        let path = store::checked_path(&self.store.root, &directory.join("current.json"))?;
        let value: serde_json::Value = store::read_json(&path)?;
        let missing_speakers = value.get("speakers").is_none();
        let mut doc: Transcript = serde_json::from_value(value)
            .map_err(|_| CoreError::Storage("저장 정보의 형식이 올바르지 않습니다.".into()))?;
        if doc.version.id != *transcript_id
            || meeting.audio.as_ref().map(|a| a.session_id.as_str())
                != Some(doc.source_session_id.as_str())
        {
            return Err(CoreError::Storage(
                "전사와 원음의 연결이 올바르지 않습니다.".into(),
            ));
        }
        if missing_speakers
            && doc
                .segments
                .iter()
                .all(|segment| segment.speaker_id.is_none())
        {
            if let Some(audio) = &meeting.audio {
                let _ = (|| -> Result<()> {
                    let raw_path =
                        store::checked_path(&self.store.root, &directory.join("raw.json"))?;
                    let mut raw = Vec::new();
                    store::open_read(&raw_path)?
                        .take(16 * 1024 * 1024 + 1)
                        .read_to_end(&mut raw)?;
                    let original = MossOutput::decode(
                        &raw,
                        audio.frames as f64 / audio.sample_rate as f64,
                        &doc.source_session_id,
                        &doc.version.id,
                    )?;
                    if original.segments.len() != doc.segments.len()
                        || !original.segments.iter().zip(&doc.segments).all(|(a, b)| {
                            a.start == b.start
                                && a.end == b.end
                                && a.original_text == b.original_text
                        })
                    {
                        return Ok(());
                    }
                    doc.speakers = original.speakers;
                    for (segment, original) in doc.segments.iter_mut().zip(original.segments) {
                        segment.speaker_id = original.speaker_id;
                    }
                    Ok(())
                })();
            }
        }
        Ok(Some(doc))
    }

    pub fn commit_transcript(
        &mut self,
        id: &str,
        expected: Option<TranscriptVersion>,
        raw: Vec<u8>,
    ) -> Result<Transcript> {
        if self.quitting {
            return Err(CoreError::Unavailable);
        }
        store::validate_id(id)?;
        self.require_active_meeting(id)?;
        let mut stored = self
            .meetings
            .get(id)
            .ok_or(CoreError::MeetingNotFound)?
            .clone();
        let audio = stored.meeting.audio.as_ref().ok_or_else(|| {
            CoreError::InvalidState("먼저 녹음을 종료하거나 음성을 가져와 주세요.".into())
        })?;
        let transcript_id = Uuid::new_v4().to_string();
        let directory = transcript_dir(id, &transcript_id)?;
        store::ensure_directory(&store::checked_path(&self.store.root, &directory)?)?;
        let mut file = store::create_new(&store::checked_path(
            &self.store.root,
            &directory.join("raw.json"),
        )?)?;
        file.write_all(&raw)?;
        file.sync_all()?;
        let document = MossOutput::decode(
            &raw,
            audio.frames as f64 / audio.sample_rate as f64,
            &audio.session_id,
            &transcript_id,
        )?;
        immutable_json(&self.store.root, &directory.join("initial.json"), &document)?;
        if self.transcript(id)?.map(|d| d.version) != expected {
            return Err(CoreError::InvalidState("전사가 변경되어 새 결과를 적용하지 않았습니다. 기존 수정과 새 원문 결과는 보관했습니다.".into()));
        }
        store::write_json(&self.store.root, &directory.join("current.json"), &document)?;
        stored.meeting.transcript_id = Some(transcript_id);
        stored.meeting.updated_at = store::now();
        self.store.save(&stored)?;
        self.meetings.insert(id.into(), stored);
        Ok(document)
    }

    pub fn edit_transcript(
        &mut self,
        id: &str,
        expected: TranscriptVersion,
        texts: Vec<String>,
    ) -> Result<Transcript> {
        if self.quitting {
            return Err(CoreError::Unavailable);
        }
        self.require_active_meeting(id)?;
        let mut doc = self
            .transcript(id)?
            .ok_or_else(|| CoreError::InvalidState("저장할 전사가 없습니다.".into()))?;
        if doc.version != expected {
            return Err(CoreError::InvalidState(
                "전사가 변경되었습니다. 현재 입력을 보존하고 새로고침해 주세요.".into(),
            ));
        }
        if texts.len() != doc.segments.len()
            || texts.iter().map(String::len).sum::<usize>() > 2 * 1024 * 1024
            || texts.iter().any(|s| s.contains('\0'))
        {
            return Err(CoreError::InvalidInput(
                "전사 수정 내용이 올바르지 않습니다.".into(),
            ));
        }
        for (segment, text) in doc.segments.iter_mut().zip(texts) {
            segment.text = text;
        }
        self.save_transcript_edit(id, doc)
    }

    pub fn edit_speakers(
        &mut self,
        id: &str,
        expected: TranscriptVersion,
        speakers: Vec<TranscriptSpeaker>,
        assignments: Vec<Option<String>>,
    ) -> Result<Transcript> {
        if self.quitting {
            return Err(CoreError::Unavailable);
        }
        self.require_active_meeting(id)?;
        let mut doc = self
            .transcript(id)?
            .ok_or_else(|| CoreError::InvalidState("수정할 음성 기록이 없습니다.".into()))?;
        if doc.version != expected {
            return Err(CoreError::InvalidState(
                "음성 기록이 변경되었습니다. 현재 수정을 보존하고 다시 열어 주세요.".into(),
            ));
        }
        if assignments.len() != doc.segments.len() {
            return Err(CoreError::InvalidInput(
                "발언 수와 화자 배정 수가 다릅니다.".into(),
            ));
        }
        validate_speakers(&speakers, &assignments)?;
        if doc.speakers == speakers
            && doc
                .segments
                .iter()
                .map(|segment| &segment.speaker_id)
                .eq(assignments.iter())
        {
            return Ok(doc);
        }
        doc.speakers = speakers;
        for (segment, assignment) in doc.segments.iter_mut().zip(assignments) {
            segment.speaker_id = assignment;
        }
        self.save_transcript_edit(id, doc)
    }

    fn save_transcript_edit(&self, id: &str, mut doc: Transcript) -> Result<Transcript> {
        doc.version.revision = doc
            .version
            .revision
            .checked_add(1)
            .ok_or(CoreError::Unavailable)?;
        let directory = transcript_dir(id, &doc.version.id)?;
        immutable_json(
            &self.store.root,
            &directory.join(format!("edit-{}.json", Uuid::new_v4())),
            &doc,
        )?;
        store::write_json(&self.store.root, &directory.join("current.json"), &doc)?;
        Ok(doc)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    pub(crate) fn setup() -> (tempfile::TempDir, Engine, String, PathBuf) {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap();
        let wav_path = root.join("input.wav");
        let mut writer = hound::WavWriter::create(
            &wav_path,
            hound::WavSpec {
                channels: 1,
                sample_rate: 16000,
                bits_per_sample: 16,
                sample_format: hound::SampleFormat::Int,
            },
        )
        .unwrap();
        for _ in 0..16000 {
            writer.write_sample(100i16).unwrap();
        }
        writer.finalize().unwrap();
        let mut engine = Engine::open(root.join("store")).unwrap();
        let meeting = engine
            .import_audio("회의".into(), wav_path.clone(), wav_path.clone())
            .unwrap();
        (temp, engine, meeting.id, wav_path)
    }
    pub(crate) fn output() -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({"model":"OpenMOSS-Team/MOSS-Transcribe-Diarize","segments":[{"start":0.0,"end":1.0,"text":"[S1] 원문","speaker_id":"S1"}],"hitTokenLimit":false,"hasUnparsedText":false,"processedAudioFrames":16000,"inputAudioFrames":16000,"audioDurationSeconds":1.0})).unwrap()
    }
    fn speaker_output(labels: &[serde_json::Value]) -> Vec<u8> {
        let mut raw: serde_json::Value = serde_json::from_slice(&output()).unwrap();
        raw["segments"] = labels
            .iter()
            .enumerate()
            .map(|(index, label)| {
                serde_json::json!({"start":0.0,"end":1.0,"text":format!("예시 발언 {}",index + 1),"speaker_id":label})
            })
            .collect();
        serde_json::to_vec(&raw).unwrap()
    }
    fn chunk_output() -> Vec<u8> {
        let mut raw: serde_json::Value = serde_json::from_slice(&output()).unwrap();
        raw["segments"] = serde_json::json!([
            {"start":0.0,"end":0.2,"text":"[S1] 첫 구간","speaker_id":"S1","asr_chunk":0},
            {"start":0.2,"end":0.3,"text":"[S1] 같은 구간","speaker_id":"S1","asr_chunk":0},
            {"start":0.4,"end":0.5,"text":"[S1] 다음 구간","speaker_id":"S1","asr_chunk":1},
            {"start":0.6,"end":0.7,"text":"[S2] 다른 화자","speaker_id":2,"asr_chunk":1}
        ]);
        serde_json::to_vec(&raw).unwrap()
    }
    #[test]
    fn import_preserves_source_and_reopens_playback() {
        let (temp, engine, id, source) = setup();
        let bytes = std::fs::read(&source).unwrap();
        let meeting = &engine.meetings[&id].meeting;
        let audio = engine.audio_path(&id).unwrap();
        assert!(audio.is_file());
        let saved_source = engine
            .store
            .root
            .join("meetings")
            .join(&id)
            .join("sessions")
            .join(&meeting.audio.as_ref().unwrap().session_id)
            .join("source.wav");
        assert_eq!(std::fs::read(saved_source).unwrap(), bytes);
        drop(engine);
        let engine = Engine::open(temp.path().canonicalize().unwrap().join("store")).unwrap();
        assert!(engine.audio_path(&id).is_ok());
        assert_eq!(std::fs::read(source).unwrap(), bytes);
    }
    #[test]
    fn pre_transcript_meeting_reopens_without_rewriting_its_metadata() {
        let (_temp, engine, id, _) = setup();
        let root = engine.store.root.clone();
        let path = root.join("meetings").join(&id).join("meeting.json");
        let mut old: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        old["meeting"]
            .as_object_mut()
            .unwrap()
            .remove("transcriptId");
        let bytes = serde_json::to_vec(&old).unwrap();
        drop(engine);
        std::fs::write(&path, &bytes).unwrap();
        let reopened = Engine::open(root).unwrap();
        assert!(reopened.transcript(&id).unwrap().is_none());
        assert!(reopened.audio_path(&id).is_ok());
        assert_eq!(std::fs::read(path).unwrap(), bytes);
    }
    #[test]
    fn transcript_edits_are_versioned_and_raw_is_immutable_across_reopen() {
        let (temp, mut engine, id, _) = setup();
        let raw = output();
        let doc = engine.commit_transcript(&id, None, raw.clone()).unwrap();
        let edited = engine
            .edit_transcript(&id, doc.version.clone(), vec!["수정한 문장".into()])
            .unwrap();
        assert_eq!(edited.segments[0].original_text, "원문");
        assert!(engine
            .edit_transcript(&id, doc.version, vec!["stale".into()])
            .is_err());
        let raw_path = engine
            .store
            .root
            .join(transcript_dir(&id, &edited.version.id).unwrap())
            .join("raw.json");
        assert_eq!(std::fs::read(&raw_path).unwrap(), raw);
        drop(engine);
        let engine = Engine::open(temp.path().canonicalize().unwrap().join("store")).unwrap();
        let reopened = engine.transcript(&id).unwrap().unwrap();
        assert_eq!(reopened.version, edited.version);
        assert_eq!(reopened.segments[0].text, "수정한 문장");
        assert_eq!(std::fs::read(raw_path).unwrap(), raw);
    }
    #[test]
    fn late_retranscription_preserves_edits_and_candidate_raw() {
        let (_temp, mut engine, id, _) = setup();
        let first = engine.commit_transcript(&id, None, output()).unwrap();
        let edited = engine
            .edit_transcript(&id, first.version.clone(), vec!["수정".into()])
            .unwrap();
        assert!(engine
            .commit_transcript(&id, Some(first.version), output())
            .is_err());
        assert_eq!(
            engine.transcript(&id).unwrap().unwrap().version,
            edited.version
        );
        let dir = engine
            .store
            .root
            .join("meetings")
            .join(&id)
            .join("transcripts");
        assert_eq!(std::fs::read_dir(dir).unwrap().count(), 2);
    }
    #[test]
    fn incomplete_malformed_and_wrong_audio_outputs_do_not_replace_transcript() {
        let (_temp, mut engine, id, _) = setup();
        let first = engine.commit_transcript(&id, None, output()).unwrap();
        for field in [
            "hitTokenLimit",
            "hasUnparsedText",
            "inputAudioFrames",
            "audioDurationSeconds",
        ] {
            let mut bad: serde_json::Value = serde_json::from_slice(&output()).unwrap();
            bad[field] = match field {
                "inputAudioFrames" => 32000.into(),
                "audioDurationSeconds" => 10.into(),
                _ => true.into(),
            };
            assert!(engine
                .commit_transcript(
                    &id,
                    Some(first.version.clone()),
                    serde_json::to_vec(&bad).unwrap()
                )
                .is_err());
            assert_eq!(
                engine.transcript(&id).unwrap().unwrap().version,
                first.version
            );
        }
        assert!(engine
            .commit_transcript(&id, Some(first.version.clone()), b"invalid".to_vec())
            .is_err());
        assert_eq!(
            engine.transcript(&id).unwrap().unwrap().version,
            first.version
        );
    }
    #[test]
    fn model_speakers_preserve_clusters_and_unknown_metadata_does_not_lose_text() {
        let labels = vec![
            serde_json::json!("S02"),
            serde_json::json!("S1"),
            serde_json::json!("S02"),
            serde_json::json!(null),
            serde_json::json!({"invalid": true}),
            serde_json::json!("unknown"),
            serde_json::json!(3),
        ];
        let doc =
            MossOutput::decode(&speaker_output(&labels), 1.0, "session", "transcript").unwrap();
        assert_eq!(doc.segments.len(), labels.len());
        assert_eq!(
            doc.speakers,
            vec![
                TranscriptSpeaker {
                    id: "S02".into(),
                    name: "화자 1".into()
                },
                TranscriptSpeaker {
                    id: "S1".into(),
                    name: "화자 2".into()
                },
                TranscriptSpeaker {
                    id: "S3".into(),
                    name: "화자 3".into()
                },
            ]
        );
        assert_eq!(doc.segments[0].speaker_id.as_deref(), Some("S02"));
        assert_eq!(doc.segments[2].speaker_id.as_deref(), Some("S02"));
        assert!(doc.segments[3..6]
            .iter()
            .all(|segment| segment.speaker_id.is_none()));
        assert_eq!(doc.segments[4].text, "예시 발언 5");
        let many: Vec<_> = (1..=10)
            .map(|n| serde_json::json!(format!("S{n}")))
            .collect();
        assert_eq!(
            MossOutput::decode(&speaker_output(&many), 1.0, "s", "t")
                .unwrap()
                .speakers
                .len(),
            10
        );
    }
    #[test]
    fn independent_asr_chunks_never_link_reused_model_labels_automatically() {
        let doc = MossOutput::decode(&chunk_output(), 1.0, "session", "transcript").unwrap();
        let ids: Vec<_> = doc
            .segments
            .iter()
            .map(|segment| segment.speaker_id.as_deref())
            .collect();
        assert_eq!(
            ids,
            vec![
                Some("moss:chunk:0:S1"),
                Some("moss:chunk:0:S1"),
                Some("moss:chunk:1:S1"),
                Some("moss:chunk:1:S2")
            ]
        );
        assert_eq!(
            doc.speakers
                .iter()
                .map(|speaker| speaker.name.as_str())
                .collect::<Vec<_>>(),
            vec!["화자 1", "화자 2", "화자 3"]
        );
        assert_eq!(doc.segments[0].text, "첫 구간");
        assert_eq!(doc.segments[2].original_text, "다음 구간");
        validate_speakers(
            &doc.speakers,
            &doc.segments
                .iter()
                .map(|segment| segment.speaker_id.clone())
                .collect::<Vec<_>>(),
        )
        .unwrap();
        let single = MossOutput::decode(&output(), 1.0, "session", "transcript").unwrap();
        assert_eq!(single.segments[0].speaker_id.as_deref(), Some("S1"));
    }
    #[test]
    fn missing_or_invalid_chunk_scope_keeps_text_without_unscoped_identity_links() {
        let mut raw: serde_json::Value = serde_json::from_slice(&chunk_output()).unwrap();
        raw["segments"][0]["asr_chunk"] = serde_json::Value::Null;
        raw["segments"][1]["asr_chunk"] = (-1).into();
        raw["segments"][2]
            .as_object_mut()
            .unwrap()
            .remove("asr_chunk");
        raw["segments"][3]["asr_chunk"] = "1".into();
        let doc = MossOutput::decode(
            &serde_json::to_vec(&raw).unwrap(),
            1.0,
            "session",
            "transcript",
        )
        .unwrap();
        assert!(doc.speakers.is_empty());
        assert!(doc
            .segments
            .iter()
            .all(|segment| segment.speaker_id.is_none()));
        assert_eq!(doc.segments.len(), 4);
        assert_eq!(doc.segments[0].text, "첫 구간");
        let invalid_ids = speaker_output(&[
            serde_json::json!(0),
            serde_json::json!(-1),
            serde_json::json!(1.5),
        ]);
        let unknown = MossOutput::decode(&invalid_ids, 1.0, "session", "transcript").unwrap();
        assert!(unknown.speakers.is_empty());
        assert_eq!(unknown.segments.len(), 3);
    }
    #[test]
    fn legacy_chunk_labels_are_recovered_locally_and_manual_merge_is_explicit() {
        let (_temp, mut engine, id, _) = setup();
        let raw = chunk_output();
        let first = engine.commit_transcript(&id, None, raw.clone()).unwrap();
        let mut texts: Vec<_> = first
            .segments
            .iter()
            .map(|segment| segment.text.clone())
            .collect();
        texts[2] = "사용자가 고친 구간".into();
        let edited = engine.edit_transcript(&id, first.version, texts).unwrap();
        let directory = engine
            .store
            .root
            .join(transcript_dir(&id, &edited.version.id).unwrap());
        let current = directory.join("current.json");
        let mut old = serde_json::to_value(&edited).unwrap();
        old.as_object_mut().unwrap().remove("speakers");
        for segment in old["segments"].as_array_mut().unwrap() {
            segment.as_object_mut().unwrap().remove("speakerId");
        }
        let before = serde_json::to_vec(&old).unwrap();
        std::fs::write(&current, &before).unwrap();
        let recovered = engine.transcript(&id).unwrap().unwrap();
        assert_ne!(
            recovered.segments[0].speaker_id,
            recovered.segments[2].speaker_id
        );
        assert_eq!(recovered.segments[2].text, "사용자가 고친 구간");
        assert_eq!(recovered.segments[2].original_text, "다음 구간");
        assert_eq!(recovered.version, edited.version);
        assert_eq!(std::fs::read(&current).unwrap(), before);
        let merged = engine
            .edit_speakers(
                &id,
                recovered.version,
                vec![recovered.speakers[0].clone()],
                vec![recovered.segments[0].speaker_id.clone(); 4],
            )
            .unwrap();
        assert!(merged
            .segments
            .iter()
            .all(|segment| segment.speaker_id.as_deref() == Some("moss:chunk:0:S1")));
        assert_eq!(merged.segments[2].text, "사용자가 고친 구간");
        assert_eq!(std::fs::read(directory.join("raw.json")).unwrap(), raw);
    }
    #[test]
    fn speaker_only_changes_stale_the_summary_and_reject_late_results_without_losing_minutes() {
        let (_temp, mut engine, id, _) = setup();
        let source = engine.commit_transcript(&id, None, chunk_output()).unwrap();
        let draft = |source: Transcript, expected_id: Option<String>| crate::SummaryDraft {
            source,
            expected_id,
            text: "예시 회의록 [1]".into(),
            provenance: crate::SummaryProvenance {
                model: "test".into(),
                model_revision: "1".into(),
                model_sha256: "a".repeat(64),
                runtime: "test".into(),
                prompt_version: "test".into(),
                template: "minutes".into(),
            },
            receipt: serde_json::json!({"finish_reason":"stop"}),
        };
        let first = engine
            .commit_summary(&id, draft(source.clone(), None))
            .unwrap();
        assert!(!engine.summary(&id).unwrap().unwrap().stale);
        let root = engine.store.root.clone();
        let archive = root
            .join("meetings")
            .join(&id)
            .join("summaries")
            .join(&first.id)
            .join("run.json");
        let original_minutes = std::fs::read(&archive).unwrap();
        let texts: Vec<_> = source
            .segments
            .iter()
            .map(|segment| segment.text.clone())
            .collect();
        let assignments: Vec<_> = source
            .segments
            .iter()
            .map(|segment| segment.speaker_id.clone())
            .collect();
        let mut names = source.speakers.clone();
        names[0].name = "진행자".into();
        let renamed = engine
            .edit_speakers(&id, source.version.clone(), names, assignments.clone())
            .unwrap();
        assert!(engine.summary(&id).unwrap().unwrap().stale);
        assert_eq!(
            renamed
                .segments
                .iter()
                .map(|segment| segment.text.clone())
                .collect::<Vec<_>>(),
            texts
        );
        assert!(engine
            .commit_summary(&id, draft(source, Some(first.id.clone())))
            .is_err());
        assert_eq!(engine.summary(&id).unwrap().unwrap().document.id, first.id);
        assert_eq!(std::fs::read(&archive).unwrap(), original_minutes);
        let second = engine
            .commit_summary(&id, draft(renamed.clone(), Some(first.id)))
            .unwrap();
        assert!(!engine.summary(&id).unwrap().unwrap().stale);
        let mut next_assignments = assignments;
        next_assignments[2] = renamed.segments[0].speaker_id.clone();
        let reassigned = engine
            .edit_speakers(
                &id,
                renamed.version.clone(),
                renamed.speakers.clone(),
                next_assignments,
            )
            .unwrap();
        assert!(engine.summary(&id).unwrap().unwrap().stale);
        assert!(engine
            .commit_summary(&id, draft(renamed, Some(second.id.clone())))
            .is_err());
        assert_eq!(engine.summary(&id).unwrap().unwrap().document.id, second.id);
        let third = engine
            .commit_summary(&id, draft(reassigned.clone(), Some(second.id)))
            .unwrap();
        drop(engine);
        let reopened = Engine::open(root).unwrap();
        let minutes = reopened.summary(&id).unwrap().unwrap();
        assert_eq!(minutes.document.id, third.id);
        assert!(!minutes.stale);
        assert_eq!(
            reopened.transcript(&id).unwrap().unwrap().version,
            reassigned.version
        );
        assert_eq!(std::fs::read(archive).unwrap(), original_minutes);
    }
    #[test]
    fn speaker_rename_merge_split_and_restore_are_versioned_without_changing_content() {
        let (_temp, mut engine, id, _) = setup();
        let raw = speaker_output(&[serde_json::json!("S1"), serde_json::json!("S2")]);
        let original = engine.commit_transcript(&id, None, raw.clone()).unwrap();
        let edited = engine
            .edit_transcript(
                &id,
                original.version,
                vec!["수정한 발언".into(), "두 번째 발언".into()],
            )
            .unwrap();
        let saved_segments = serde_json::to_value(&edited.segments).unwrap();
        let saved_speakers = edited.speakers.clone();
        let saved_assignments: Vec<_> = edited
            .segments
            .iter()
            .map(|segment| segment.speaker_id.clone())
            .collect();
        let mut renamed_speakers = edited.speakers.clone();
        renamed_speakers[0].name = "진행자".into();
        let renamed = engine
            .edit_speakers(
                &id,
                edited.version.clone(),
                renamed_speakers,
                saved_assignments.clone(),
            )
            .unwrap();
        assert_eq!(renamed.version.revision, edited.version.revision + 1);
        assert_eq!(
            serde_json::to_value(&renamed.segments).unwrap(),
            saved_segments
        );
        assert!(engine
            .edit_transcript(
                &id,
                edited.version,
                vec!["오래된 수정".into(), "오래된 수정".into()]
            )
            .is_err());
        let merged = engine
            .edit_speakers(
                &id,
                renamed.version,
                vec![renamed.speakers[0].clone()],
                vec![Some("S1".into()), Some("S1".into())],
            )
            .unwrap();
        let split_id = Uuid::new_v4().to_string();
        let mut split_speakers = merged.speakers.clone();
        split_speakers.push(TranscriptSpeaker {
            id: split_id.clone(),
            name: "새 화자".into(),
        });
        let split = engine
            .edit_speakers(
                &id,
                merged.version,
                split_speakers,
                vec![Some("S1".into()), Some(split_id)],
            )
            .unwrap();
        assert_eq!(split.segments[0].text, "수정한 발언");
        assert_eq!(split.segments[0].original_text, "예시 발언 1");
        let restored = engine
            .edit_speakers(&id, split.version, saved_speakers, saved_assignments)
            .unwrap();
        assert_eq!(
            serde_json::to_value(&restored.segments).unwrap(),
            saved_segments
        );
        let same = engine
            .edit_speakers(
                &id,
                restored.version.clone(),
                restored.speakers.clone(),
                restored
                    .segments
                    .iter()
                    .map(|segment| segment.speaker_id.clone())
                    .collect(),
            )
            .unwrap();
        assert_eq!(same.version, restored.version);
        let root = engine.store.root.clone();
        let raw_path = root
            .join(transcript_dir(&id, &restored.version.id).unwrap())
            .join("raw.json");
        assert_eq!(std::fs::read(&raw_path).unwrap(), raw);
        drop(engine);
        let reopened = Engine::open(root)
            .unwrap()
            .transcript(&id)
            .unwrap()
            .unwrap();
        assert_eq!(reopened.version, restored.version);
        assert_eq!(reopened.speakers, restored.speakers);
        assert_eq!(
            serde_json::to_value(reopened.segments).unwrap(),
            saved_segments
        );
    }
    #[test]
    fn invalid_or_stale_speaker_edits_do_not_replace_current_document() {
        let (_temp, mut engine, id, _) = setup();
        let doc = engine.commit_transcript(&id, None, output()).unwrap();
        let before = serde_json::to_vec(&doc).unwrap();
        for (speakers, assignments) in [
            (doc.speakers.clone(), vec![]),
            (doc.speakers.clone(), vec![Some("missing".into())]),
            (
                vec![doc.speakers[0].clone(), doc.speakers[0].clone()],
                vec![Some("S1".into())],
            ),
            (
                vec![TranscriptSpeaker {
                    id: "../invalid".into(),
                    name: "화자".into(),
                }],
                vec![None],
            ),
            (
                vec![TranscriptSpeaker {
                    id: "S1".into(),
                    name: " ".into(),
                }],
                vec![None],
            ),
            (
                vec![TranscriptSpeaker {
                    id: "S1".into(),
                    name: "줄\n바꿈".into(),
                }],
                vec![None],
            ),
            (
                vec![TranscriptSpeaker {
                    id: "S1".into(),
                    name: "a".repeat(257),
                }],
                vec![None],
            ),
        ] {
            assert!(engine
                .edit_speakers(&id, doc.version.clone(), speakers, assignments)
                .is_err());
            assert_eq!(
                serde_json::to_vec(&engine.transcript(&id).unwrap().unwrap()).unwrap(),
                before
            );
        }
        let changed = engine
            .edit_speakers(&id, doc.version.clone(), vec![], vec![None])
            .unwrap();
        assert!(engine
            .edit_speakers(&id, doc.version, changed.speakers, vec![None])
            .is_err());
    }
    #[test]
    fn old_document_recovers_speakers_from_raw_without_writing_or_losing_user_edits() {
        let (_temp, mut engine, id, _) = setup();
        let raw = output();
        let first = engine.commit_transcript(&id, None, raw.clone()).unwrap();
        let edited = engine
            .edit_transcript(&id, first.version, vec!["사용자 수정".into()])
            .unwrap();
        let root = engine.store.root.clone();
        let directory = root.join(transcript_dir(&id, &edited.version.id).unwrap());
        let current = directory.join("current.json");
        let mut old = serde_json::to_value(&edited).unwrap();
        old.as_object_mut().unwrap().remove("speakers");
        for segment in old["segments"].as_array_mut().unwrap() {
            segment.as_object_mut().unwrap().remove("speakerId");
        }
        let before = serde_json::to_vec(&old).unwrap();
        std::fs::write(&current, &before).unwrap();
        drop(engine);
        let mut engine = Engine::open(root.clone()).unwrap();
        let recovered = engine.transcript(&id).unwrap().unwrap();
        assert_eq!(recovered.version, edited.version);
        assert_eq!(recovered.segments[0].id, edited.segments[0].id);
        assert_eq!(recovered.segments[0].text, "사용자 수정");
        assert_eq!(recovered.segments[0].original_text, "원문");
        assert_eq!(recovered.segments[0].speaker_id.as_deref(), Some("S1"));
        assert_eq!(recovered.speakers[0].name, "화자 1");
        assert_eq!(std::fs::read(&current).unwrap(), before);
        assert_eq!(std::fs::read(directory.join("raw.json")).unwrap(), raw);
        let cleared = engine
            .edit_speakers(&id, recovered.version, vec![], vec![None])
            .unwrap();
        drop(engine);
        let engine = Engine::open(root).unwrap();
        let reopened = engine.transcript(&id).unwrap().unwrap();
        assert_eq!(reopened.version, cleared.version);
        assert!(reopened.speakers.is_empty());
        assert!(reopened.segments[0].speaker_id.is_none());
    }
    #[test]
    fn old_document_without_usable_raw_remains_readable_without_invented_speakers() {
        let (_temp, mut engine, id, _) = setup();
        let doc = engine.commit_transcript(&id, None, output()).unwrap();
        let directory = engine
            .store
            .root
            .join(transcript_dir(&id, &doc.version.id).unwrap());
        let mut old = serde_json::to_value(&doc).unwrap();
        old.as_object_mut().unwrap().remove("speakers");
        old["segments"][0]
            .as_object_mut()
            .unwrap()
            .remove("speakerId");
        std::fs::write(
            directory.join("current.json"),
            serde_json::to_vec(&old).unwrap(),
        )
        .unwrap();
        std::fs::write(directory.join("raw.json"), b"unreadable").unwrap();
        let recovered = engine.transcript(&id).unwrap().unwrap();
        assert_eq!(recovered.segments[0].text, "원문");
        assert!(recovered.speakers.is_empty());
        assert!(recovered.segments[0].speaker_id.is_none());
        let mut mismatch: serde_json::Value = serde_json::from_slice(&output()).unwrap();
        mismatch["segments"][0]["text"] = "다른 원문".into();
        std::fs::write(
            directory.join("raw.json"),
            serde_json::to_vec(&mismatch).unwrap(),
        )
        .unwrap();
        assert!(engine.transcript(&id).unwrap().unwrap().speakers.is_empty());
    }
}
