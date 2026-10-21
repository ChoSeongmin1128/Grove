use grove_core::{CoreHandle, SessionState, Snapshot};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex, OnceLock,
};
use std::thread::{self, JoinHandle};
use std::time::Duration;
use uuid::Uuid;

const MODEL: &str = include_str!("../../../../Sources/GroveApp/Resources/Models/moss.json");

fn platform_supported() -> bool {
    static SUPPORTED: OnceLock<bool> = OnceLock::new();
    *SUPPORTED.get_or_init(|| {
        cfg!(all(target_os = "macos", target_arch = "aarch64"))
            && Command::new("/usr/bin/sw_vers")
                .arg("-productVersion")
                .output()
                .ok()
                .filter(|output| output.status.success())
                .and_then(|output| String::from_utf8(output.stdout).ok())
                .and_then(|version| version.trim().split('.').next()?.parse::<u32>().ok())
                .is_some_and(|major| major >= 26)
    })
}

#[derive(Deserialize)]
pub(super) struct ModelFile {
    pub(super) name: String,
    pub(super) bytes: u64,
    pub(super) sha256: String,
}
#[derive(Deserialize)]
pub(super) struct Model {
    pub(super) repository: String,
    pub(super) revision: String,
    pub(super) files: Vec<ModelFile>,
}

#[derive(Clone, Serialize, Default, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Progress {
    pub revision: u64,
    pub id: Option<String>,
    pub kind: String,
    pub meeting_id: Option<String>,
    pub status: String,
    pub message: String,
    pub bytes: u64,
    pub total_bytes: u64,
    pub model_bytes: u64,
    pub model_ready: bool,
    pub supported: bool,
    pub summary_supported: bool,
    pub summary_ready: bool,
    pub summary_bytes: u64,
    pub model_stage: Option<String>,
}
fn meeting_models_ready(progress: &Progress) -> Result<(), String> {
    if !progress.supported {
        return Err("이 환경에서는 음성 인식을 아직 사용할 수 없습니다.".into());
    }
    if !progress.model_ready {
        return Err("음성 인식을 먼저 준비해 주세요.".into());
    }
    Ok(())
}
struct Running {
    id: String,
    cancel: Arc<AtomicBool>,
    handle: JoinHandle<()>,
}

#[derive(Default)]
struct RecordingTranscription {
    attempted: HashSet<String>,
}

impl RecordingTranscription {
    fn claim(&mut self, snapshot: &Snapshot) -> Option<String> {
        let session = snapshot.session.as_ref()?;
        if session.state != SessionState::Completed {
            return None;
        }
        let meeting = snapshot
            .meetings
            .iter()
            .find(|meeting| meeting.id == session.meeting_id)?;
        if meeting.audio.as_ref()?.session_id != session.id
            || !self.attempted.insert(session.id.clone())
        {
            return None;
        }
        Some(session.meeting_id.clone())
    }
}

pub struct Processing {
    pub(super) root: PathBuf,
    pub(super) resources: PathBuf,
    progress: Mutex<Progress>,
    running: Mutex<Option<Running>>,
    recording_transcription: Mutex<RecordingTranscription>,
    shutting_down: AtomicBool,
}

pub(super) fn message(error: impl std::fmt::Display) -> String {
    error.to_string()
}
pub(super) fn cancelled(cancel: &AtomicBool) -> Result<(), String> {
    if cancel.load(Ordering::Acquire) {
        Err("처리를 취소했습니다.".into())
    } else {
        Ok(())
    }
}
pub(super) async fn interruptible<F: std::future::Future>(
    cancel: &AtomicBool,
    future: F,
) -> Result<F::Output, String> {
    tokio::pin!(future);
    loop {
        cancelled(cancel)?;
        tokio::select! { result = &mut future => return Ok(result), _ = tokio::time::sleep(Duration::from_millis(100)) => () }
    }
}

pub(super) fn directory(root: &Path, relative: &str) -> Result<PathBuf, String> {
    let mut path = root.to_path_buf();
    for part in Path::new(relative).components() {
        if !matches!(part, std::path::Component::Normal(_)) {
            return Err("저장 경로가 올바르지 않습니다.".into());
        }
        path.push(part);
        match fs::symlink_metadata(&path) {
            Ok(meta) if meta.file_type().is_symlink() || !meta.is_dir() => {
                return Err("저장 폴더에 연결된 경로나 다른 항목이 있습니다.".into())
            }
            Ok(_) => (),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                fs::create_dir(&path).map_err(message)?
            }
            Err(e) => return Err(message(e)),
        }
    }
    Ok(path)
}
pub(super) fn plain_file(path: &Path) -> Result<File, String> {
    let meta = fs::symlink_metadata(path).map_err(message)?;
    if !meta.is_file() || meta.file_type().is_symlink() {
        return Err("일반 파일이 필요합니다.".into());
    }
    File::open(path).map_err(message)
}
pub(super) fn matches_file(path: &Path, item: &ModelFile, cancel: &AtomicBool) -> bool {
    let Ok(mut file) = plain_file(path) else {
        return false;
    };
    if file.metadata().map(|m| m.len()).ok() != Some(item.bytes) {
        return false;
    }
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 1024 * 1024];
    loop {
        if cancel.load(Ordering::Acquire) {
            return false;
        }
        match file.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => hash.update(&buffer[..n]),
            Err(_) => return false,
        }
    }
    format!("{:x}", hash.finalize()) == item.sha256
}
pub(super) fn invalidate_readiness(directory: &Path) -> Result<(), String> {
    let marker = directory.join("verified.json");
    if marker.exists() {
        plain_file(&marker)?;
        fs::rename(
            marker,
            directory.join(format!("verified.invalid-{}.json", Uuid::new_v4())),
        )
        .map_err(message)?;
    }
    Ok(())
}
pub(super) struct Worker(pub(super) std::process::Child);
impl Drop for Worker {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

impl Processing {
    pub fn new(root: PathBuf, resources: PathBuf) -> Arc<Self> {
        Arc::new(Self {
            root,
            resources,
            progress: Mutex::new(Progress::default()),
            running: Mutex::new(None),
            recording_transcription: Mutex::new(RecordingTranscription::default()),
            shutting_down: AtomicBool::new(false),
        })
    }
    fn model(&self) -> Model {
        serde_json::from_str(MODEL).expect("bundled MOSS manifest")
    }
    fn model_dir(&self) -> Result<PathBuf, String> {
        directory(
            &self.root,
            &format!("models/MOSS-{}", self.model().revision),
        )
    }
    fn worker(&self, name: &str) -> PathBuf {
        self.resources.join("native").join(name)
    }
    fn supported(&self) -> bool {
        platform_supported()
            && self.worker("moss/MossHarness").is_file()
            && self.worker("AudioPrepare").is_file()
    }
    pub fn snapshot(&self) -> Progress {
        let mut progress = self.progress.lock().unwrap().clone();
        progress.supported = self.supported();
        (
            progress.summary_supported,
            progress.summary_ready,
            progress.summary_bytes,
        ) = crate::summary::availability(self);
        let model = self.model();
        progress.model_bytes = model.files.iter().map(|file| file.bytes).sum();
        let Ok(path) = self.model_dir() else {
            return progress;
        };
        progress.model_ready = plain_file(&path.join("verified.json"))
            .and_then(|file| {
                let mut marker = String::new();
                file.take(64 * 1024)
                    .read_to_string(&mut marker)
                    .map_err(message)?;
                Ok(marker)
            })
            .ok()
            .as_deref()
            == Some(MODEL)
            && model.files.iter().all(|f| {
                fs::symlink_metadata(path.join(&f.name))
                    .map(|m| m.is_file() && !m.file_type().is_symlink() && m.len() == f.bytes)
                    .unwrap_or(false)
            });
        progress
    }
    pub(super) fn update(&self, action: impl FnOnce(&mut Progress)) {
        let mut progress = self.progress.lock().unwrap();
        let revision = progress.revision.saturating_add(1);
        action(&mut progress);
        progress.revision = revision;
    }
    pub fn cancel(&self, id: &str) -> Result<(), String> {
        let running = self.running.lock().unwrap();
        let job = running
            .as_ref()
            .filter(|r| r.id == id && !r.handle.is_finished())
            .ok_or("현재 작업과 다른 요청입니다.")?;
        job.cancel.store(true, Ordering::Release);
        self.update(|p| p.message = "취소 중".into());
        Ok(())
    }
    pub fn shutdown(&self) {
        self.shutting_down.store(true, Ordering::Release);
        if let Some(job) = self.running.lock().unwrap().take() {
            job.cancel.store(true, Ordering::Release);
            let _ = job.handle.join();
        }
    }
    pub fn resume(&self) {
        self.shutting_down.store(false, Ordering::Release);
    }
    pub(super) fn start(
        self: &Arc<Self>,
        kind: &str,
        meeting_id: Option<String>,
        action: impl FnOnce(Arc<Self>, Arc<AtomicBool>, PathBuf) -> Result<Option<String>, String>
            + Send
            + 'static,
    ) -> Result<Progress, String> {
        let mut running = self.running.lock().unwrap();
        if self.shutting_down.load(Ordering::Acquire) {
            return Err("앱을 종료하고 있습니다.".into());
        }
        if (kind.starts_with("summary") && !crate::summary::availability(self).0)
            || (!kind.starts_with("summary") && !self.supported())
        {
            return Err("이 기기의 처리 실행기가 아직 준비되지 않았습니다.".into());
        }
        if running.as_ref().is_some_and(|r| !r.handle.is_finished()) {
            return Err("다른 작업이 진행 중입니다.".into());
        }
        if let Some(old) = running.take() {
            let _ = old.handle.join();
        }
        let id = Uuid::new_v4().to_string();
        let path = directory(&self.root, &format!("processing/{id}"))?;
        let cancel = Arc::new(AtomicBool::new(false));
        self.update(|p| {
            *p = Progress {
                id: Some(id.clone()),
                kind: kind.into(),
                meeting_id,
                status: "running".into(),
                message: "준비 중".into(),
                ..Progress::default()
            }
        });
        let this = self.clone();
        let flag = cancel.clone();
        let handle = thread::spawn(move || {
            let result = action(this.clone(), flag.clone(), path);
            this.update(|p| match result {
                Ok(meeting) => {
                    if meeting.is_some() {
                        p.meeting_id = meeting;
                    }
                    p.status = "completed".into();
                    p.message = "완료".into();
                }
                Err(error) => {
                    p.status = if flag.load(Ordering::Acquire) {
                        "cancelled"
                    } else {
                        "failed"
                    }
                    .into();
                    p.message = error;
                }
            });
        });
        *running = Some(Running { id, cancel, handle });
        Ok(self.snapshot())
    }
    pub fn prepare_model(self: &Arc<Self>) -> Result<Progress, String> {
        self.prepare_named_model(MODEL, "model", "MOSS")
    }
    pub fn require_meeting_models(&self) -> Result<(), String> {
        meeting_models_ready(&self.snapshot())
    }
    pub fn prepare_meeting_models(
        self: &Arc<Self>,
        include_summary: bool,
    ) -> Result<Progress, String> {
        let progress = self.snapshot();
        if !progress.supported || (include_summary && !progress.summary_supported) {
            return Err("이 환경에서는 음성 인식과 회의 요약을 아직 사용할 수 없습니다.".into());
        }
        let required = self.remaining_model_bytes(MODEL, "MOSS")?
            + if include_summary {
                self.remaining_model_bytes(crate::summary::MANIFEST, "Gemma4-E4B")?
            } else {
                0
            };
        crate::storage_space::check(&self.root, required)?;
        self.start("setup", None, move |this, cancel, _path| {
            let progress = this.snapshot();
            let total = progress.model_bytes
                + if include_summary {
                    progress.summary_bytes
                } else {
                    0
                };
            let first = this.prepare_files(MODEL, "MOSS", &cancel, 0, total)?;
            if include_summary {
                this.prepare_files(
                    crate::summary::MANIFEST,
                    "Gemma4-E4B",
                    &cancel,
                    first,
                    total,
                )?;
            }
            Ok(None)
        })
    }
    pub(super) fn prepare_named_model(
        self: &Arc<Self>,
        manifest: &'static str,
        kind: &str,
        label: &'static str,
    ) -> Result<Progress, String> {
        crate::storage_space::check(&self.root, self.remaining_model_bytes(manifest, label)?)?;
        self.start(kind, None, move |this, cancel, _path| {
            let total = serde_json::from_str::<Model>(manifest)
                .map_err(message)?
                .files
                .iter()
                .map(|file| file.bytes)
                .sum();
            this.prepare_files(manifest, label, &cancel, 0, total)?;
            Ok(None)
        })
    }
    fn remaining_model_bytes(&self, manifest: &str, label: &str) -> Result<u64, String> {
        let model: Model = serde_json::from_str(manifest).map_err(message)?;
        let target = self.root.join(format!("models/{label}-{}", model.revision));
        let length = |path: PathBuf| {
            fs::symlink_metadata(path)
                .ok()
                .filter(|meta| meta.is_file() && !meta.file_type().is_symlink())
                .map(|meta| meta.len())
        };
        Ok(model
            .files
            .iter()
            .map(|file| {
                if length(target.join(&file.name)) == Some(file.bytes) {
                    return 0;
                }
                let partial = length(target.join(format!("{}.part", file.name)))
                    .filter(|bytes| *bytes <= file.bytes)
                    .unwrap_or(0);
                file.bytes - partial
            })
            .sum())
    }
    fn prepare_files(
        &self,
        manifest: &str,
        label: &str,
        cancel: &AtomicBool,
        offset: u64,
        total: u64,
    ) -> Result<u64, String> {
        let model: Model = serde_json::from_str(manifest).map_err(message)?;
        let target = directory(&self.root, &format!("models/{label}-{}", model.revision))?;
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(message)?;
        runtime.block_on(async {
            let client = reqwest::Client::builder()
                .connect_timeout(Duration::from_secs(20))
                .read_timeout(Duration::from_secs(30))
                .build()
                .map_err(message)?;

            let mut done = 0u64;
            for item in &model.files {
                cancelled(cancel)?;
                self.update(|p| {
                    p.model_stage = Some(if label == "MOSS" { "speech" } else { "summary" }.into());
                    p.message = if label == "MOSS" {
                        "음성 인식 모델 확인 중"
                    } else {
                        "요약 모델 확인 중"
                    }
                    .into();
                    p.bytes = offset + done;
                    p.total_bytes = total;
                });
                let destination = target.join(&item.name);
                let matches = matches_file(&destination, item, cancel);
                cancelled(cancel)?;
                if !matches {
                    self.update(|p| {
                        p.message = if label == "MOSS" {
                            "음성 인식 모델 다운로드 중"
                        } else {
                            "요약 모델 다운로드 중"
                        }
                        .into()
                    });
                    let url = format!(
                        "https://huggingface.co/{}/resolve/{}/{}",
                        model.repository, model.revision, item.name
                    );
                    crate::downloads::item(&client, &url, &target, item, cancel, |bytes| {
                        self.update(|p| p.bytes = offset + done + bytes)
                    })
                    .await?;
                }
                done += item.bytes;
                self.update(|p| p.bytes = offset + done);
            }
            Ok::<(), String>(())
        })?;
        cancelled(cancel)?;
        let marker = target.join(format!(".verified-{}", Uuid::new_v4()));
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&marker)
            .map_err(message)?;
        file.write_all(manifest.as_bytes())
            .map_err(crate::storage_space::write_error)?;
        file.sync_all().map_err(crate::storage_space::write_error)?;
        drop(file);
        fs::rename(marker, target.join("verified.json")).map_err(message)?;
        Ok(model.files.iter().map(|file| file.bytes).sum())
    }
    fn run_worker(
        &self,
        executable: &Path,
        args: &[&Path],
        log: &Path,
        cancel: &AtomicBool,
    ) -> Result<(), String> {
        cancelled(cancel)?;
        let output = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(log)
            .map_err(message)?;
        let mut command = Command::new(executable);
        command
            .args(args)
            .current_dir(log.parent().unwrap())
            .env("HF_HUB_OFFLINE", "1")
            .env("TRANSFORMERS_OFFLINE", "1")
            .stdout(Stdio::from(output.try_clone().map_err(message)?))
            .stderr(Stdio::from(output));
        let mut child = Worker(
            command
                .spawn()
                .map_err(|_| "음성 인식을 시작하지 못했습니다.".to_string())?,
        );
        loop {
            cancelled(cancel)?;
            if let Some(status) = child.0.try_wait().map_err(message)? {
                return if status.success() {
                    Ok(())
                } else {
                    Err(
                        "음성 처리를 완료하지 못했습니다. 원본과 기존 음성 기록은 보관했습니다."
                            .into(),
                    )
                };
            }
            thread::sleep(Duration::from_millis(100));
        }
    }
    pub fn recording_start<T>(
        &self,
        action: impl FnOnce() -> Result<T, String>,
    ) -> Result<T, String> {
        let mut running = self.running.lock().unwrap();
        if self.shutting_down.load(Ordering::Acquire) {
            return Err("앱을 종료하고 있습니다.".into());
        }
        if let Some(job) = running.as_ref() {
            if !job.handle.is_finished() && self.progress.lock().unwrap().kind == "import" {
                return Err("음성 가져오기가 끝난 뒤 녹음을 시작해 주세요.".into());
            }
        }
        if let Some(job) = running.take() {
            job.cancel.store(true, Ordering::Release);
            let _ = job.handle.join();
        }
        action()
    }
    pub fn import(self: &Arc<Self>, core: CoreHandle, source: PathBuf) -> Result<Progress, String> {
        self.start("import", None, move |this, cancel, path| {
            let source = source.canonicalize().map_err(message)?;
            let mut input = plain_file(&source)?;
            let ext = source
                .extension()
                .and_then(|s| s.to_str())
                .unwrap_or("audio");
            if !["wav", "m4a", "mp3", "aac", "aiff", "aif", "caf"]
                .contains(&ext.to_ascii_lowercase().as_str())
            {
                return Err("지원하지 않는 음성 파일입니다.".into());
            }
            let copied = directory(&path, "source")?
                .join(source.file_name().ok_or("음성 파일 이름이 필요합니다.")?);
            let mut output = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&copied)
                .map_err(message)?;
            let before = input.metadata().map_err(message)?;
            let mut buffer = [0u8; 128 * 1024];
            let mut bytes = 0u64;
            loop {
                cancelled(&cancel)?;
                let n = input.read(&mut buffer).map_err(message)?;
                if n == 0 {
                    break;
                }
                output.write_all(&buffer[..n]).map_err(message)?;
                bytes += n as u64;
            }
            output.sync_all().map_err(message)?;
            drop(output);
            if bytes != before.len()
                || input.metadata().map_err(message)?.modified().ok() != before.modified().ok()
            {
                return Err("가져오는 동안 파일이 변경됐습니다. 다시 선택해 주세요.".into());
            }
            this.update(|p| p.message = "음성을 준비하고 있습니다.".into());
            let prepared = path.join("analysis.wav");
            this.run_worker(
                &this.worker("AudioPrepare"),
                &[&copied, &prepared],
                &path.join("prepare.log"),
                &cancel,
            )?;
            cancelled(&cancel)?;
            let title = source
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("가져온 회의")
                .chars()
                .take(200)
                .collect::<String>();
            core.import_audio(&title, &copied, &prepared)
                .map(|m| Some(m.id))
                .map_err(message)
        })
    }
    pub fn transcribe(
        self: &Arc<Self>,
        core: CoreHandle,
        meeting_id: String,
    ) -> Result<Progress, String> {
        let audio = core.audio_path(&meeting_id).map_err(message)?;
        let expected = core
            .transcript(&meeting_id)
            .map_err(message)?
            .map(|d| d.version);
        if !self.snapshot().model_ready {
            return Err("먼저 음성 인식 모델을 준비해 주세요.".into());
        }
        self.start(
            "transcribe",
            Some(meeting_id.clone()),
            move |this, cancel, path| {
                if core.snapshot().map_err(message)?.session.is_some_and(|s| {
                    matches!(
                        s.state,
                        grove_core::SessionState::Recording | grove_core::SessionState::Paused
                    )
                }) {
                    return Err("녹음을 마친 뒤 음성 인식을 시작해 주세요.".into());
                }
                this.update(|p| p.message = "모델을 확인하고 있습니다.".into());
                let model = this.model();
                let directory = this.model_dir()?;
                for item in &model.files {
                    cancelled(&cancel)?;
                    let matches = matches_file(&directory.join(&item.name), item, &cancel);
                    cancelled(&cancel)?;
                    if !matches {
                        invalidate_readiness(&directory)?;
                        return Err("모델 파일을 다시 준비해 주세요.".into());
                    }
                }
                let prepared = path.join("analysis.wav");
                this.run_worker(
                    &this.worker("AudioPrepare"),
                    &[&audio, &prepared],
                    &path.join("prepare.log"),
                    &cancel,
                )?;
                this.update(|p| p.message = "텍스트로 변환 중".into());
                let output = path.join("moss.json");
                this.run_worker(
                    &this.worker("moss/MossHarness"),
                    &[&prepared, &output, &directory],
                    &path.join("moss.log"),
                    &cancel,
                )?;
                cancelled(&cancel)?;
                if fs::metadata(&output).map_err(message)?.len() > 16 * 1024 * 1024 {
                    return Err("음성 기록 결과가 너무 큽니다. 원문 결과는 보관했습니다.".into());
                }
                let raw = fs::read(output).map_err(message)?;
                cancelled(&cancel)?;
                core.commit_transcript(&meeting_id, expected, raw)
                    .map_err(message)?;
                Ok(Some(meeting_id))
            },
        )
    }

    pub fn transcribe_recording(
        self: &Arc<Self>,
        core: CoreHandle,
        snapshot: &Snapshot,
    ) -> Result<Option<Progress>, String> {
        let Some(meeting_id) = self.recording_transcription.lock().unwrap().claim(snapshot) else {
            return Ok(None);
        };
        self.transcribe(core, meeting_id).map(Some)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn completed_recording(session_id: &str, meeting_id: &str) -> Snapshot {
        serde_json::from_value(serde_json::json!({
            "revision": 1,
            "meetings": [{
                "id": meeting_id, "title": "Meeting", "notes": "", "createdAt": 1, "updatedAt": 2,
                "status": "completed", "error": null,
                "audio": { "sessionId": session_id, "relativePath": "audio.wav", "frames": 16000, "sampleRate": 16000, "channels": 1 }
            }],
            "session": {
                "id": session_id, "meetingId": meeting_id, "deviceId": "mic", "deviceName": "Microphone",
                "state": "completed", "elapsedMs": 1000, "savedFrames": 16000,
                "sampleRate": 16000, "channels": 1, "error": null
            }
        })).unwrap()
    }

    #[test]
    fn automatic_transcription_claims_each_finalized_recording_once() {
        let mut automatic = RecordingTranscription::default();
        let first = completed_recording("first", "one");
        assert_eq!(automatic.claim(&first), Some("one".into()));
        assert_eq!(automatic.claim(&first), None);
        let second = completed_recording("second", "two");
        assert_eq!(automatic.claim(&second), Some("two".into()));
        assert_eq!(automatic.claim(&first), None);
        // Cancellation or start failure never releases a recording for an automatic retry.
        assert_eq!(automatic.claim(&second), None);
    }

    #[test]
    fn automatic_transcription_requires_completed_audio_from_the_same_session() {
        for state in [
            SessionState::Recording,
            SessionState::Paused,
            SessionState::Interrupted,
        ] {
            let mut automatic = RecordingTranscription::default();
            let mut snapshot = completed_recording("capture", "one");
            snapshot.session.as_mut().unwrap().state = state;
            assert_eq!(automatic.claim(&snapshot), None);
            snapshot.session.as_mut().unwrap().state = SessionState::Completed;
            snapshot.meetings[0].audio.as_mut().unwrap().session_id = "previous".into();
            assert_eq!(automatic.claim(&snapshot), None);
            snapshot.meetings[0].audio.as_mut().unwrap().session_id = "capture".into();
            assert_eq!(automatic.claim(&snapshot), Some("one".into()));
        }
        let mut automatic = RecordingTranscription::default();
        let mut snapshot = completed_recording("capture", "one");
        snapshot.meetings[0].audio = None;
        assert_eq!(automatic.claim(&snapshot), None);
        snapshot.meetings.clear();
        assert_eq!(automatic.claim(&snapshot), None);
    }

    #[test]
    fn identical_processing_progress_does_not_need_a_new_event() {
        let first = Progress {
            kind: "transcribe".into(),
            status: "running".into(),
            ..Default::default()
        };
        assert!(first == first.clone());
        let mut changed = first.clone();
        changed.status = "cancelled".into();
        assert!(first != changed);
        changed = first.clone();
        changed.model_ready = true;
        assert!(first != changed);
    }

    fn setup() -> (tempfile::TempDir, Arc<Processing>) {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        let process = Processing::new(root.clone(), root.clone());
        (temporary, process)
    }
    #[test]
    fn shutdown_rejects_new_jobs_even_without_a_running_worker() {
        let (_temp, process) = setup();
        process.shutdown();
        assert_eq!(
            process.prepare_model().err().unwrap(),
            "앱을 종료하고 있습니다."
        );
        assert!(process.running.lock().unwrap().is_none());
    }
    #[test]
    fn recording_waits_for_summary_cancellation_before_starting_capture() {
        let (_temp, process) = setup();
        let cancel = Arc::new(AtomicBool::new(false));
        let flag = cancel.clone();
        let finished = Arc::new(AtomicBool::new(false));
        let ended = finished.clone();
        let handle = thread::spawn(move || {
            while !flag.load(Ordering::Acquire) {
                thread::sleep(Duration::from_millis(5));
            }
            ended.store(true, Ordering::Release);
        });
        *process.running.lock().unwrap() = Some(Running {
            id: "summary".into(),
            cancel,
            handle,
        });
        process.update(|p| {
            p.kind = "summary".into();
            p.status = "running".into();
        });
        process
            .recording_start(|| {
                assert!(finished.load(Ordering::Acquire));
                Ok(())
            })
            .unwrap();
        assert!(process.running.lock().unwrap().is_none());
    }
    #[test]
    fn fixed_manifest_hash_rejects_changed_model_files() {
        let (temp, _) = setup();
        let file = temp.path().join("model");
        fs::write(&file, b"model").unwrap();
        let item = ModelFile {
            name: "model".into(),
            bytes: 5,
            sha256: format!("{:x}", Sha256::digest(b"model")),
        };
        let cancel = AtomicBool::new(false);
        assert!(matches_file(&file, &item, &cancel));
        cancel.store(true, Ordering::Release);
        assert!(!matches_file(&file, &item, &cancel));
        cancel.store(false, Ordering::Release);
        fs::write(&file, b"other").unwrap();
        assert!(!matches_file(&file, &item, &cancel));
    }
    #[cfg(unix)]
    #[test]
    fn cancellation_kills_and_reaps_a_running_worker() {
        let (temp, process) = setup();
        let flag = Arc::new(AtomicBool::new(false));
        let worker_flag = flag.clone();
        let log = temp.path().join("sleep.log");
        let now = std::time::Instant::now();
        let worker = thread::spawn(move || {
            process.run_worker(
                Path::new("/bin/sleep"),
                &[Path::new("30")],
                &log,
                &worker_flag,
            )
        });
        thread::sleep(Duration::from_millis(150));
        flag.store(true, Ordering::Release);
        assert!(worker.join().unwrap().is_err());
        assert!(now.elapsed() < Duration::from_secs(3));
    }
    #[test]
    fn stalled_network_future_can_be_cancelled() {
        let flag = Arc::new(AtomicBool::new(false));
        let other = flag.clone();
        let setter = thread::spawn(move || {
            thread::sleep(Duration::from_millis(150));
            other.store(true, Ordering::Release);
        });
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        assert!(runtime
            .block_on(interruptible(&flag, std::future::pending::<()>()))
            .is_err());
        setter.join().unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn linked_model_file_and_job_directories_are_rejected() {
        let (temp, process) = setup();
        let source = temp.path().join("source");
        fs::write(&source, b"test").unwrap();
        let link = temp.path().join("linked");
        std::os::unix::fs::symlink(&source, &link).unwrap();
        assert!(plain_file(&link).is_err());
        assert!(directory(&process.root, "../outside").is_err());
        let sub = temp.path().join("processing");
        std::os::unix::fs::symlink(temp.path(), sub).unwrap();
        assert!(directory(&process.root, "processing/job").is_err());
    }
}

#[cfg(test)]
mod setup_tests {
    use super::*;
    #[test]
    fn meeting_entry_requires_speech_but_not_optional_summary() {
        for supported in [false, true] {
            for summary_supported in [false, true] {
                for model_ready in [false, true] {
                    for summary_ready in [false, true] {
                        let status = Progress {
                            supported,
                            summary_supported,
                            model_ready,
                            summary_ready,
                            ..Default::default()
                        };
                        assert_eq!(
                            meeting_models_ready(&status).is_ok(),
                            supported && model_ready
                        );
                    }
                }
            }
        }
    }
}
