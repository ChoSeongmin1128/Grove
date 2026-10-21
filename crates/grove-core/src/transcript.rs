use crate::engine::Engine;
use crate::store::{self, CapturePhase, Encoding, Manifest};
use crate::{CoreError, Meeting, MeetingStatus, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Transcript {
    pub version: TranscriptVersion,
    pub source_session_id: String,
    pub model: String,
    pub model_revision: String,
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
            let mut text = segment.text;
            if let Some(serde_json::Value::String(label)) = segment.speaker_id {
                if label.starts_with('S')
                    && label.len() > 1
                    && label[1..].bytes().all(|b| b.is_ascii_digit())
                {
                    if let Some(body) = text.strip_prefix(&format!("[{label}] ")) {
                        text = body.to_owned();
                    }
                }
            }
            segments.push(TranscriptSegment {
                id: Uuid::new_v4().to_string(),
                start: segment.start.min(duration),
                end: segment.end.min(duration),
                original_text: text.clone(),
                text,
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
            segments,
        })
    }
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
        let path = store::checked_path(
            &self.store.root,
            &transcript_dir(id, transcript_id)?.join("current.json"),
        )?;
        let doc: Transcript = store::read_json(&path)?;
        if doc.version.id != *transcript_id
            || meeting.audio.as_ref().map(|a| a.session_id.as_str())
                != Some(doc.source_session_id.as_str())
        {
            return Err(CoreError::Storage(
                "전사와 원음의 연결이 올바르지 않습니다.".into(),
            ));
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
}
