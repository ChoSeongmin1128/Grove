use crate::capture::{self, Capture};
use crate::store::{self, CapturePhase, Manifest, Store, StoredMeeting};
use crate::{
    CoreError, Device, Meeting, MeetingStatus, Result, SessionSnapshot, SessionState, Snapshot,
};
use cpal::traits::DeviceTrait;
use std::collections::BTreeMap;
use std::path::PathBuf;

pub(crate) struct Engine {
    pub(crate) store: Store,
    pub(crate) meetings: BTreeMap<String, StoredMeeting>,
    pub(crate) capture: Option<Capture>,
    last_session: Option<SessionSnapshot>,
    revision: u64,
    pub(crate) quitting: bool,
}

impl Engine {
    pub fn open(root: PathBuf) -> Result<Self> {
        let store = Store::open(root)?;
        let mut meetings = store.load()?;
        store.recover(&mut meetings)?;
        Ok(Self {
            store,
            meetings,
            capture: None,
            last_session: None,
            revision: 0,
            quitting: false,
        })
    }

    pub fn meetings(&self) -> Vec<Meeting> {
        let mut meetings: Vec<_> = self
            .meetings
            .values()
            .map(|stored| stored.meeting.clone())
            .collect();
        meetings.sort_by(|a, b| {
            b.updated_at
                .cmp(&a.updated_at)
                .then_with(|| a.id.cmp(&b.id))
        });
        meetings
    }

    pub fn create_meeting(&mut self, title: String, notes: String) -> Result<Meeting> {
        if self.quitting {
            return Err(CoreError::Unavailable);
        }
        let stored = self.store.create(title, notes)?;
        let meeting = stored.meeting.clone();
        self.meetings.insert(meeting.id.clone(), stored);
        Ok(meeting)
    }

    pub fn update_meeting(&mut self, id: &str, title: String, notes: String) -> Result<Meeting> {
        if self.quitting {
            return Err(CoreError::Unavailable);
        }
        store::validate_id(id)?;
        store::validate_text(&title, &notes)?;
        let mut stored = self
            .meetings
            .get(id)
            .ok_or(CoreError::MeetingNotFound)?
            .clone();
        stored.meeting.title = title;
        stored.meeting.notes = notes;
        stored.meeting.updated_at = store::now();
        self.store.save(&stored)?;
        let meeting = stored.meeting.clone();
        self.meetings.insert(id.into(), stored);
        Ok(meeting)
    }

    pub fn devices(&self) -> Result<Vec<Device>> {
        capture::devices()
    }

    fn draft(&self, id: &str) -> Result<()> {
        if self.quitting {
            return Err(CoreError::Unavailable);
        }
        store::validate_id(id)?;
        if self.capture.is_some() {
            return Err(CoreError::RecordingBusy);
        }
        let stored = self.meetings.get(id).ok_or(CoreError::MeetingNotFound)?;
        if stored.meeting.status != MeetingStatus::Draft
            || stored.capture_id.is_some()
            || stored.meeting.audio.is_some()
        {
            return Err(CoreError::InvalidState(
                "기존 녹음은 덮어쓰지 않습니다. 새 회의를 만들어 주세요.".into(),
            ));
        }
        Ok(())
    }

    pub fn start(&mut self, meeting_id: &str, device_id: &str) -> Result<Snapshot> {
        self.draft(meeting_id)?;
        let (device, config, encoding) = capture::select_device(device_id)?;
        let id = device
            .id()
            .map_err(|_| CoreError::Audio("마이크를 찾을 수 없습니다.".into()))?
            .to_string();
        let name = device
            .description()
            .map_err(|_| CoreError::Audio("마이크 정보를 읽을 수 없습니다.".into()))?
            .name()
            .to_owned();
        let manifest = Manifest::new(
            meeting_id,
            &id,
            &name,
            config.sample_rate(),
            config.channels(),
            encoding,
        );
        let raw = self.store.prepare_capture(&manifest)?;
        let (mut capture, sink) = Capture::prepare(&self.store.root, manifest, raw)?;
        capture.attach_stream(&device, config, sink)?;
        if let Some(error) = capture.signals.error() {
            return Err(CoreError::Audio(error));
        }
        self.activate(capture)?;
        Ok(self.snapshot())
    }

    fn activate(&mut self, mut capture: Capture) -> Result<()> {
        self.draft(&capture.manifest.meeting_id)?;
        let mut stored = self
            .meetings
            .get(&capture.manifest.meeting_id)
            .ok_or(CoreError::MeetingNotFound)?
            .clone();
        stored.capture_id = Some(capture.manifest.session_id.clone());
        stored.meeting.status = MeetingStatus::Recording;
        stored.meeting.error = None;
        stored.meeting.updated_at = store::now();
        self.store.save(&stored)?;
        capture.begin();
        self.meetings.insert(stored.meeting.id.clone(), stored);
        self.last_session = None;
        self.capture = Some(capture);
        Ok(())
    }

    fn check_session(&self, session_id: &str) -> Result<()> {
        store::validate_id(session_id)?;
        if self
            .capture
            .as_ref()
            .map(|capture| capture.manifest.session_id.as_str())
            != Some(session_id)
        {
            return Err(CoreError::StaleSession);
        }
        Ok(())
    }

    pub fn pause(&mut self, session_id: &str) -> Result<Snapshot> {
        self.check_session(session_id)?;
        let capture = self.capture.as_mut().unwrap();
        if capture.manifest.phase == CapturePhase::Paused {
            return Ok(self.snapshot());
        }
        if let Err(error) = capture.pause() {
            let message = error.to_string();
            let _ = self.finish(CapturePhase::Interrupted, Some(message));
            return Err(error);
        }
        let id = capture.manifest.meeting_id.clone();
        if let Err(error) = self.save_phase(&id, MeetingStatus::Paused) {
            let _ = self.finish(CapturePhase::Interrupted, Some(error.to_string()));
            return Err(error);
        }
        Ok(self.snapshot())
    }

    pub fn resume(&mut self, session_id: &str) -> Result<Snapshot> {
        self.check_session(session_id)?;
        let capture = self.capture.as_ref().unwrap();
        if capture.manifest.phase == CapturePhase::Recording {
            return Ok(self.snapshot());
        }
        let id = capture.manifest.meeting_id.clone();
        self.save_phase(&id, MeetingStatus::Recording)?;
        if let Err(error) = self.capture.as_mut().unwrap().resume() {
            let _ = self.finish(CapturePhase::Interrupted, Some(error.to_string()));
            return Err(error);
        }
        Ok(self.snapshot())
    }

    fn save_phase(&mut self, id: &str, status: MeetingStatus) -> Result<()> {
        let mut stored = self
            .meetings
            .get(id)
            .ok_or(CoreError::MeetingNotFound)?
            .clone();
        stored.meeting.status = status;
        stored.meeting.updated_at = store::now();
        self.store.save(&stored)?;
        self.meetings.insert(id.into(), stored);
        Ok(())
    }

    pub fn stop(&mut self, session_id: &str) -> Result<Snapshot> {
        self.check_session(session_id)?;
        self.finish(CapturePhase::Completed, None)?;
        Ok(self.snapshot())
    }

    fn finish(&mut self, phase: CapturePhase, error: Option<String>) -> Result<()> {
        let capture = self.capture.take().ok_or(CoreError::StaleSession)?;
        let previous = session_snapshot(&capture.manifest, capture.frames());
        let outcome = match capture.finish(phase, error) {
            Ok(outcome) => outcome,
            Err(error) => {
                let message = error.to_string();
                let mut last = previous;
                last.state = SessionState::Interrupted;
                last.error = Some(message.clone());
                if let Some(stored) = self.meetings.get_mut(&last.meeting_id) {
                    stored.meeting.status = MeetingStatus::Interrupted;
                    stored.meeting.error = Some(message);
                    stored.meeting.updated_at = store::now();
                    let _ = self.store.save(stored);
                }
                self.last_session = Some(last);
                return Err(error);
            }
        };
        let mut stored = self
            .meetings
            .get(&outcome.manifest.meeting_id)
            .ok_or(CoreError::MeetingNotFound)?
            .clone();
        stored.meeting.status = if outcome.manifest.phase == CapturePhase::Completed {
            MeetingStatus::Completed
        } else {
            MeetingStatus::Interrupted
        };
        stored.meeting.audio = outcome.audio;
        stored.meeting.error = outcome.manifest.error.clone();
        stored.meeting.updated_at = store::now();
        let mut last = session_snapshot(&outcome.manifest, outcome.manifest.saved_frames);
        let saved = self.store.save(&stored);
        if let Err(error) = &saved {
            let message =
                format!("녹음 파일은 보관했지만 회의 정보를 저장하지 못했습니다: {error}");
            stored.meeting.status = MeetingStatus::Interrupted;
            stored.meeting.error = Some(message.clone());
            last.state = SessionState::Interrupted;
            last.error = Some(message);
        }
        self.meetings.insert(stored.meeting.id.clone(), stored);
        self.last_session = Some(last);
        saved
    }

    pub fn poll_capture(&mut self) {
        let error = self
            .capture
            .as_ref()
            .and_then(|capture| capture.signals.error());
        if let Some(error) = error {
            let _ = self.finish(CapturePhase::Interrupted, Some(error));
        }
    }

    pub fn snapshot(&mut self) -> Snapshot {
        self.revision = self.revision.saturating_add(1);
        Snapshot {
            revision: self.revision,
            meetings: self.meetings(),
            session: self
                .capture
                .as_ref()
                .map(|capture| session_snapshot(&capture.manifest, capture.frames()))
                .or_else(|| self.last_session.clone()),
        }
    }

    pub fn audio_path(&self, meeting_id: &str) -> Result<PathBuf> {
        store::validate_id(meeting_id)?;
        let meeting = &self
            .meetings
            .get(meeting_id)
            .ok_or(CoreError::MeetingNotFound)?
            .meeting;
        self.store.audio_path(meeting)
    }

    pub fn prepare_shutdown(&mut self, expected_session_id: Option<&str>) -> Result<Snapshot> {
        if self.quitting {
            return Ok(self.snapshot());
        }
        let active_id = self
            .capture
            .as_ref()
            .map(|capture| capture.manifest.session_id.as_str());
        if active_id != expected_session_id {
            return Err(CoreError::StaleSession);
        }
        self.quitting = true;
        if self.capture.is_some() {
            if let Err(error) = self.finish(CapturePhase::Completed, None) {
                self.quitting = false;
                return Err(error);
            }
        }
        Ok(self.snapshot())
    }

    pub fn shutdown(&mut self) {
        if self.capture.is_some() {
            let _ = self.finish(
                CapturePhase::Interrupted,
                Some("앱이 종료되어 녹음을 중단했습니다.".into()),
            );
        }
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn session_snapshot(manifest: &Manifest, frames: u64) -> SessionSnapshot {
    SessionSnapshot {
        id: manifest.session_id.clone(),
        meeting_id: manifest.meeting_id.clone(),
        device_id: manifest.device_id.clone(),
        device_name: manifest.device_name.clone(),
        state: match manifest.phase {
            CapturePhase::Prepared | CapturePhase::Recording => SessionState::Recording,
            CapturePhase::Paused => SessionState::Paused,
            CapturePhase::Completed => SessionState::Completed,
            CapturePhase::Interrupted => SessionState::Interrupted,
        },
        elapsed_ms: frames.saturating_mul(1000) / u64::from(manifest.sample_rate),
        saved_frames: frames,
        sample_rate: manifest.sample_rate,
        channels: manifest.channels,
        error: manifest.error.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::capture::CallbackSink;
    use crate::store::{checked_path, Encoding};
    use crate::CoreHandle;
    use std::fs;
    use std::io::Write;
    use uuid::Uuid;

    fn engine() -> (tempfile::TempDir, Engine) {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap().join("dev");
        let engine = Engine::open(root).unwrap();
        (temporary, engine)
    }

    fn synthetic(engine: &mut Engine, meeting_id: &str) -> (String, CallbackSink) {
        engine.draft(meeting_id).unwrap();
        let manifest = Manifest::new(meeting_id, "synthetic", "시험 입력", 1000, 1, Encoding::F32);
        let id = manifest.session_id.clone();
        let raw = engine.store.prepare_capture(&manifest).unwrap();
        let (capture, sink) = Capture::prepare(&engine.store.root, manifest, raw).unwrap();
        engine.activate(capture).unwrap();
        (id, sink)
    }

    #[test]
    fn handle_preserves_meeting_and_notes_without_accessing_audio() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap().join("dev");
        let handle = CoreHandle::open(&root).unwrap();
        let clone = handle.clone();
        let meeting = handle
            .create_meeting("긴 회의 제목", "한글 메모\n확정 전 내용")
            .unwrap();
        assert!(matches!(CoreHandle::open(&root), Err(CoreError::StoreBusy)));
        let before = handle.snapshot().unwrap();
        let changed = clone
            .update_meeting(&meeting.id, "변경한 제목", "수정한 메모")
            .unwrap();
        let after = handle.snapshot().unwrap();
        assert!(after.revision > before.revision);
        drop(handle);
        assert_eq!(clone.list_meetings().unwrap()[0], changed);
        drop(clone);
        let reopened = CoreHandle::open(&root).unwrap();
        assert_eq!(reopened.list_meetings().unwrap(), vec![changed]);
    }

    #[test]
    fn stale_session_cannot_pause_or_stop_another_recording() {
        let (_temporary, mut engine) = engine();
        let first = engine.create_meeting("첫 회의".into(), "".into()).unwrap();
        let second = engine
            .create_meeting("다음 회의".into(), "".into())
            .unwrap();
        let (first_id, mut sink) = synthetic(&mut engine, &first.id);
        assert!(matches!(
            engine.draft(&second.id),
            Err(CoreError::RecordingBusy)
        ));
        assert!(matches!(
            engine.pause(&Uuid::new_v4().to_string()),
            Err(CoreError::StaleSession)
        ));
        sink.write(&[0.25_f32.to_le_bytes(); 10].concat());
        engine.stop(&first_id).unwrap();
        drop(sink);
        let (second_id, _sink) = synthetic(&mut engine, &second.id);
        assert!(matches!(
            engine.stop(&first_id),
            Err(CoreError::StaleSession)
        ));
        assert_eq!(engine.snapshot().session.unwrap().id, second_id);
    }

    #[test]
    fn crash_recovery_uses_complete_raw_frames_and_keeps_notes() {
        let (temporary, mut engine) = engine();
        let meeting = engine
            .create_meeting("회의".into(), "직접 작성한 메모".into())
            .unwrap();
        let mut manifest = Manifest::new(
            &meeting.id,
            "synthetic",
            "시험 입력",
            1000,
            1,
            Encoding::F32,
        );
        let mut raw = engine.store.prepare_capture(&manifest).unwrap();
        raw.write_all(&[0.125_f32.to_le_bytes(); 123].concat())
            .unwrap();
        raw.write_all(&[1, 2]).unwrap();
        raw.sync_all().unwrap();
        drop(raw);
        manifest.phase = CapturePhase::Recording;
        manifest.saved_frames = 100;
        store::write_manifest(&engine.store.root, &manifest).unwrap();
        let stored = engine.meetings.get_mut(&meeting.id).unwrap();
        stored.capture_id = Some(manifest.session_id.clone());
        stored.meeting.status = MeetingStatus::Recording;
        engine.store.save(stored).unwrap();
        let root = engine.store.root.clone();
        drop(engine);
        let restored = Engine::open(root.clone()).unwrap();
        let meeting = &restored.meetings[&meeting.id].meeting;
        assert_eq!(meeting.status, MeetingStatus::Interrupted);
        assert_eq!(meeting.notes, "직접 작성한 메모");
        assert_eq!(meeting.audio.as_ref().unwrap().frames, 123);
        assert_eq!(
            hound::WavReader::open(restored.audio_path(&meeting.id).unwrap())
                .unwrap()
                .duration(),
            123
        );
        assert_eq!(
            fs::metadata(root.join(manifest.relative_dir()).join("audio.pcm"))
                .unwrap()
                .len(),
            494
        );
        drop(restored);
        drop(temporary);
    }

    #[test]
    fn interrupted_finalization_is_retried_after_transient_failure() {
        let (_temporary, mut engine) = engine();
        let meeting = engine
            .create_meeting("회의".into(), "직접 쓴 메모".into())
            .unwrap();
        let (id, mut sink) = synthetic(&mut engine, &meeting.id);
        let wav = engine
            .store
            .root
            .join(engine.capture.as_ref().unwrap().manifest.relative_dir())
            .join("audio.wav");
        fs::create_dir(&wav).unwrap();
        sink.write(&[0.5_f32.to_le_bytes(); 20].concat());
        engine.stop(&id).unwrap();
        let failed = &engine.meetings[&meeting.id].meeting;
        assert_eq!(failed.status, MeetingStatus::Interrupted);
        assert!(failed.audio.is_none());
        fs::remove_dir(&wav).unwrap();
        let root = engine.store.root.clone();
        drop(sink);
        drop(engine);
        let restored = Engine::open(root.clone()).unwrap();
        let repaired = &restored.meetings[&meeting.id].meeting;
        assert_eq!(repaired.status, MeetingStatus::Interrupted);
        assert_eq!(repaired.notes, "직접 쓴 메모");
        assert_eq!(repaired.audio.as_ref().unwrap().frames, 20);
        assert!(restored.audio_path(&meeting.id).unwrap().exists());
        assert_eq!(
            fs::metadata(wav.with_file_name("audio.pcm")).unwrap().len(),
            80
        );
    }

    #[test]
    fn invalid_interrupted_playback_is_preserved_and_regenerated() {
        let (_temporary, mut engine) = engine();
        let meeting = engine.create_meeting("회의".into(), "".into()).unwrap();
        let (_id, mut sink) = synthetic(&mut engine, &meeting.id);
        sink.write(&[0.5_f32.to_le_bytes(); 20].concat());
        engine.shutdown();
        let wav = engine.audio_path(&meeting.id).unwrap();
        let raw = wav.with_file_name("audio.pcm");
        let original = fs::read(&raw).unwrap();
        fs::write(&wav, b"invalid playback").unwrap();
        let root = engine.store.root.clone();
        drop(sink);
        drop(engine);
        let restored = Engine::open(root).unwrap();
        assert_eq!(
            restored.meetings[&meeting.id]
                .meeting
                .audio
                .as_ref()
                .unwrap()
                .frames,
            20
        );
        assert!(restored.audio_path(&meeting.id).unwrap().exists());
        assert_eq!(fs::read(raw).unwrap(), original);
        let backup = fs::read_dir(wav.parent().unwrap())
            .unwrap()
            .filter_map(|entry| entry.ok())
            .find(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with("audio.invalid.")
            })
            .unwrap();
        assert_eq!(fs::read(backup.path()).unwrap(), b"invalid playback");
    }

    #[test]
    fn missing_raw_is_reported_without_claiming_recovery() {
        let (_temporary, mut engine) = engine();
        let meeting = engine.create_meeting("회의".into(), "".into()).unwrap();
        let (_id, mut sink) = synthetic(&mut engine, &meeting.id);
        sink.write(&[0.5_f32.to_le_bytes(); 8].concat());
        engine.shutdown();
        let wav = engine.audio_path(&meeting.id).unwrap();
        let raw = wav.with_file_name("audio.pcm");
        fs::rename(&raw, raw.with_file_name("held.pcm")).unwrap();
        fs::rename(&wav, wav.with_file_name("held.wav")).unwrap();
        let root = engine.store.root.clone();
        drop(sink);
        drop(engine);
        let restored = Engine::open(root).unwrap();
        let meeting = &restored.meetings[&meeting.id].meeting;
        assert_eq!(meeting.status, MeetingStatus::Interrupted);
        assert!(meeting.audio.is_none());
        assert!(meeting
            .error
            .as_ref()
            .unwrap()
            .contains("원본 녹음을 읽을 수 없어"));
    }

    #[test]
    fn shutdown_finalizes_and_does_not_overwrite_recording() {
        let (_temporary, mut engine) = engine();
        let meeting = engine.create_meeting("회의".into(), "메모".into()).unwrap();
        let (_id, mut sink) = synthetic(&mut engine, &meeting.id);
        sink.write(&[0.5_f32.to_le_bytes(); 32].concat());
        let root = engine.store.root.clone();
        engine.shutdown();
        assert!(engine.capture.is_none());
        assert!(engine.audio_path(&meeting.id).unwrap().exists());
        assert!(engine.draft(&meeting.id).is_err());
        drop(sink);
        drop(engine);
        let restored = Engine::open(root).unwrap();
        let meeting = &restored.meetings[&meeting.id].meeting;
        assert_eq!(meeting.status, MeetingStatus::Interrupted);
        assert_eq!(meeting.audio.as_ref().unwrap().frames, 32);
    }

    #[test]
    fn prepare_shutdown_fences_new_start_and_checks_owner_atomically() {
        let (_temporary, mut engine) = engine();
        let first = engine.create_meeting("회의".into(), "".into()).unwrap();
        let second = engine
            .create_meeting("다음 회의".into(), "".into())
            .unwrap();
        let (session, mut sink) = synthetic(&mut engine, &first.id);
        sink.write(&[0.5_f32.to_le_bytes(); 8].concat());
        assert!(matches!(
            engine.prepare_shutdown(None),
            Err(CoreError::StaleSession)
        ));
        assert!(!engine.quitting);
        assert!(matches!(
            engine.prepare_shutdown(Some(&Uuid::new_v4().to_string())),
            Err(CoreError::StaleSession)
        ));
        let snapshot = engine.prepare_shutdown(Some(&session)).unwrap();
        assert!(engine.quitting);
        assert_eq!(snapshot.session.unwrap().state, SessionState::Completed);
        assert!(matches!(
            engine.draft(&second.id),
            Err(CoreError::Unavailable)
        ));
        assert!(engine.prepare_shutdown(None).is_ok());
    }

    #[test]
    fn last_handle_drop_finalizes_active_capture_before_reopen() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap().join("dev");
        let handle = CoreHandle::open(&root).unwrap();
        let meeting = handle.create_meeting("회의", "메모").unwrap();
        let meeting_id = meeting.id.clone();
        let (_session, mut sink) = handle
            .call(move |engine| Ok(synthetic(engine, &meeting_id)))
            .unwrap();
        sink.write(&[0.75_f32.to_le_bytes(); 10].concat());
        drop(handle);
        let restored = CoreHandle::open(&root).unwrap();
        let meeting = restored.list_meetings().unwrap().remove(0);
        assert_eq!(meeting.status, MeetingStatus::Interrupted);
        assert_eq!(meeting.audio.as_ref().unwrap().frames, 10);
        assert!(restored.audio_path(&meeting.id).unwrap().exists());
    }

    #[test]
    fn traversal_and_duplicate_identity_are_rejected() {
        let (_temporary, mut engine) = engine();
        let meeting = engine.create_meeting("회의".into(), "".into()).unwrap();
        assert!(engine
            .update_meeting("../meeting", "".into(), "".into())
            .is_err());
        assert!(checked_path(&engine.store.root, std::path::Path::new("../outside")).is_err());
        let duplicate_id = Uuid::new_v4().to_string();
        let duplicate_dir = engine.store.root.join("meetings").join(&duplicate_id);
        fs::create_dir(&duplicate_dir).unwrap();
        fs::copy(
            engine
                .store
                .root
                .join("meetings")
                .join(meeting.id)
                .join("meeting.json"),
            duplicate_dir.join("meeting.json"),
        )
        .unwrap();
        assert!(engine.store.load().is_err());
    }

    #[cfg(unix)]
    #[test]
    fn symlink_store_and_audio_paths_are_rejected() {
        use std::os::unix::fs::symlink;
        let (_temporary, mut engine) = engine();
        let meeting = engine.create_meeting("회의".into(), "".into()).unwrap();
        let (id, mut sink) = synthetic(&mut engine, &meeting.id);
        sink.write(&[0.5_f32.to_le_bytes(); 2].concat());
        engine.stop(&id).unwrap();
        let path = engine.audio_path(&meeting.id).unwrap();
        let elsewhere = engine.store.root.join("other.wav");
        fs::rename(&path, &elsewhere).unwrap();
        symlink(&elsewhere, &path).unwrap();
        assert!(engine.audio_path(&meeting.id).is_err());
        let link = engine.store.root.with_file_name("linked-dev");
        symlink(&engine.store.root, &link).unwrap();
        assert!(CoreHandle::open(link).is_err());
    }
}
