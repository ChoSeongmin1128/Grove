use crate::{AudioArtifact, CoreError, Meeting, MeetingStatus, Result};
use fs2::FileExt;
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{BufReader, BufWriter, Read, Seek, Write};
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;

const SCHEMA_VERSION: u32 = 1;
const MAX_JSON_BYTES: u64 = 16 * 1024 * 1024;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Encoding {
    F32,
    F64,
    I16,
    I32,
}

impl Encoding {
    pub fn bytes(self) -> usize {
        match self {
            Self::I16 => 2,
            Self::F32 | Self::I32 => 4,
            Self::F64 => 8,
        }
    }

    fn sample(self, bytes: &[u8]) -> f32 {
        match self {
            Self::F32 => f32::from_le_bytes(bytes.try_into().unwrap()),
            Self::F64 => f64::from_le_bytes(bytes.try_into().unwrap()) as f32,
            Self::I16 => i16::from_le_bytes(bytes.try_into().unwrap()) as f32 / 32768.0,
            Self::I32 => i32::from_le_bytes(bytes.try_into().unwrap()) as f32 / 2147483648.0,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum CapturePhase {
    Prepared,
    Recording,
    Paused,
    Completed,
    Interrupted,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Manifest {
    pub schema_version: u32,
    pub meeting_id: String,
    pub session_id: String,
    pub device_id: String,
    pub device_name: String,
    pub sample_rate: u32,
    pub channels: u16,
    pub encoding: Encoding,
    pub started_at: u64,
    pub phase: CapturePhase,
    pub saved_frames: u64,
    pub error: Option<String>,
}

impl Manifest {
    pub fn new(
        meeting_id: &str,
        device_id: &str,
        device_name: &str,
        sample_rate: u32,
        channels: u16,
        encoding: Encoding,
    ) -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            meeting_id: meeting_id.into(),
            session_id: Uuid::new_v4().to_string(),
            device_id: device_id.into(),
            device_name: device_name.into(),
            sample_rate,
            channels,
            encoding,
            started_at: now(),
            phase: CapturePhase::Prepared,
            saved_frames: 0,
            error: None,
        }
    }

    pub fn frame_bytes(&self) -> usize {
        self.channels as usize * self.encoding.bytes()
    }

    pub fn relative_dir(&self) -> PathBuf {
        Path::new("meetings")
            .join(&self.meeting_id)
            .join("sessions")
            .join(&self.session_id)
    }

    pub fn validate(&self) -> Result<()> {
        validate_id(&self.meeting_id)?;
        validate_id(&self.session_id)?;
        if self.schema_version != SCHEMA_VERSION
            || self.sample_rate == 0
            || self.sample_rate > 768_000
            || self.channels == 0
            || self.channels > 64
        {
            return Err(CoreError::Storage(
                "녹음 정보의 형식이 올바르지 않습니다.".into(),
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct StoredMeeting {
    pub schema_version: u32,
    pub meeting: Meeting,
    pub capture_id: Option<String>,
}

pub(crate) struct Store {
    pub root: PathBuf,
    _lock: File,
}

impl Store {
    pub fn open(root: PathBuf) -> Result<Self> {
        ensure_directory(&root)?;
        let root = root.canonicalize()?;
        let lock_path = checked_path(&root, Path::new("store.lock"))?;
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        no_follow(&mut options);
        let lock = options.open(lock_path)?;
        validate_file(&lock)?;
        lock.try_lock_exclusive()
            .map_err(|_| CoreError::StoreBusy)?;
        ensure_directory(&root.join("meetings"))?;
        Ok(Self { root, _lock: lock })
    }

    pub fn load(&self) -> Result<BTreeMap<String, StoredMeeting>> {
        let meetings_path = checked_path(&self.root, Path::new("meetings"))?;
        let mut meetings = BTreeMap::new();
        let mut seen = BTreeSet::new();
        for entry in fs::read_dir(meetings_path)? {
            let entry = entry?;
            if entry.file_type()?.is_symlink() || !entry.file_type()?.is_dir() {
                return Err(CoreError::Storage(
                    "회의 폴더의 형식이 올바르지 않습니다.".into(),
                ));
            }
            let id = entry.file_name().to_string_lossy().into_owned();
            validate_id(&id)?;
            let relative = Path::new("meetings").join(&id).join("meeting.json");
            let path = checked_path(&self.root, &relative)?;
            if !path.exists() {
                let sessions = checked_path(
                    &self.root,
                    &Path::new("meetings").join(&id).join("sessions"),
                )?;
                if sessions.exists() {
                    return Err(CoreError::Storage(
                        "회의 정보가 없는 녹음 폴더가 있습니다.".into(),
                    ));
                }
                continue;
            }
            let stored: StoredMeeting = read_json(&path)?;
            if stored.schema_version != SCHEMA_VERSION
                || stored.meeting.id != id
                || !seen.insert(stored.meeting.id.clone())
            {
                return Err(CoreError::Storage(
                    "중복되거나 올바르지 않은 회의 정보가 있습니다.".into(),
                ));
            }
            validate_text(&stored.meeting.title, &stored.meeting.notes)?;
            if let Some(capture_id) = &stored.capture_id {
                validate_id(capture_id)?;
            }
            if let Some(audio) = &stored.meeting.audio {
                validate_artifact(&id, audio)?;
                checked_path(&self.root, Path::new(&audio.relative_path))?;
            }
            meetings.insert(id, stored);
        }
        Ok(meetings)
    }

    pub fn create(&self, title: String, notes: String) -> Result<StoredMeeting> {
        validate_text(&title, &notes)?;
        let timestamp = now();
        let meeting = Meeting {
            id: Uuid::new_v4().to_string(),
            title,
            notes,
            created_at: timestamp,
            updated_at: timestamp,
            status: MeetingStatus::Draft,
            audio: None,
            error: None,
        };
        let relative = Path::new("meetings").join(&meeting.id);
        let directory = checked_path(&self.root, &relative)?;
        fs::create_dir(&directory)?;
        let stored = StoredMeeting {
            schema_version: SCHEMA_VERSION,
            meeting,
            capture_id: None,
        };
        self.save(&stored)?;
        Ok(stored)
    }

    pub fn save(&self, stored: &StoredMeeting) -> Result<()> {
        validate_id(&stored.meeting.id)?;
        let relative = Path::new("meetings")
            .join(&stored.meeting.id)
            .join("meeting.json");
        write_json(&self.root, &relative, stored)
    }

    pub fn prepare_capture(&self, manifest: &Manifest) -> Result<File> {
        manifest.validate()?;
        let meeting_dir = Path::new("meetings").join(&manifest.meeting_id);
        let sessions_dir = checked_path(&self.root, &meeting_dir.join("sessions"))?;
        ensure_directory(&sessions_dir)?;
        let directory = checked_path(&self.root, &manifest.relative_dir())?;
        fs::create_dir(&directory)?;
        write_manifest(&self.root, manifest)?;
        create_new(&checked_path(
            &self.root,
            &manifest.relative_dir().join("audio.pcm"),
        )?)
    }

    pub fn recover(&self, meetings: &mut BTreeMap<String, StoredMeeting>) -> Result<()> {
        for stored in meetings.values_mut() {
            let Some(session_id) = stored.capture_id.clone() else {
                if matches!(
                    stored.meeting.status,
                    MeetingStatus::Recording | MeetingStatus::Paused
                ) {
                    return Err(CoreError::Storage(
                        "녹음 정보가 누락된 회의가 있습니다.".into(),
                    ));
                }
                continue;
            };
            let relative = Path::new("meetings")
                .join(&stored.meeting.id)
                .join("sessions")
                .join(&session_id)
                .join("manifest.json");
            let path = checked_path(&self.root, &relative)?;
            let mut manifest: Manifest = read_json(&path)?;
            manifest.validate()?;
            if manifest.meeting_id != stored.meeting.id || manifest.session_id != session_id {
                return Err(CoreError::Storage(
                    "회의와 녹음 정보가 일치하지 않습니다.".into(),
                ));
            }
            let unfinished = matches!(
                manifest.phase,
                CapturePhase::Prepared | CapturePhase::Recording | CapturePhase::Paused
            ) || matches!(
                stored.meeting.status,
                MeetingStatus::Recording | MeetingStatus::Paused
            );
            let interrupted = stored.meeting.status == MeetingStatus::Interrupted
                || manifest.phase == CapturePhase::Interrupted;
            let playback_needs_repair = interrupted && self.audio_path(&stored.meeting).is_err();
            if !unfinished && !playback_needs_repair {
                continue;
            }
            let raw = checked_path(&self.root, &manifest.relative_dir().join("audio.pcm"))
                .and_then(|path| open_read(&path));
            if let Err(error) = raw {
                stored.meeting.status = MeetingStatus::Interrupted;
                stored.meeting.audio = None;
                stored.meeting.error = Some(format!(
                    "원본 녹음을 읽을 수 없어 복구하지 못했습니다: {error}"
                ));
                stored.meeting.updated_at = now();
                self.save(stored)?;
                continue;
            }
            manifest.phase = CapturePhase::Interrupted;
            manifest.error = Some("녹음이 중단되었습니다. 저장된 구간을 복구했습니다.".into());
            let outcome = finalize_audio(&self.root, &mut manifest);
            stored.meeting.status = MeetingStatus::Interrupted;
            stored.meeting.error = manifest.error.clone();
            stored.meeting.updated_at = now();
            match outcome {
                Ok(audio) => stored.meeting.audio = audio,
                Err(error) => {
                    stored.meeting.audio = None;
                    stored.meeting.error = Some(format!("녹음이 중단되었습니다. 원본은 보관되지만 재생 파일을 만들지 못했습니다: {error}"));
                }
            }
            self.save(stored)?;
        }
        Ok(())
    }

    pub fn audio_path(&self, meeting: &Meeting) -> Result<PathBuf> {
        let artifact = meeting
            .audio
            .as_ref()
            .ok_or_else(|| CoreError::InvalidState("재생할 녹음이 없습니다.".into()))?;
        if matches!(
            meeting.status,
            MeetingStatus::Recording | MeetingStatus::Paused
        ) {
            return Err(CoreError::InvalidState(
                "녹음을 종료한 뒤 재생할 수 있습니다.".into(),
            ));
        }
        validate_artifact(&meeting.id, artifact)?;
        let path = checked_path(&self.root, Path::new(&artifact.relative_path))?;
        validate_playback(
            &path,
            artifact.frames,
            artifact.sample_rate,
            artifact.channels,
        )?;
        Ok(path)
    }
}

pub(crate) fn validate_id(id: &str) -> Result<()> {
    if Uuid::parse_str(id)
        .map(|value| value.to_string())
        .ok()
        .as_deref()
        != Some(id)
    {
        return Err(CoreError::InvalidInput(
            "회의 또는 녹음 ID가 올바르지 않습니다.".into(),
        ));
    }
    Ok(())
}

pub(crate) fn validate_text(title: &str, notes: &str) -> Result<()> {
    if title.len() > 16 * 1024
        || notes.len() > 2 * 1024 * 1024
        || title.contains('\0')
        || notes.contains('\0')
    {
        return Err(CoreError::InvalidInput(
            "제목 또는 메모가 너무 길거나 올바르지 않습니다.".into(),
        ));
    }
    Ok(())
}

fn validate_artifact(meeting_id: &str, artifact: &AudioArtifact) -> Result<()> {
    validate_id(meeting_id)?;
    validate_id(&artifact.session_id)?;
    let expected = format!(
        "meetings/{meeting_id}/sessions/{}/audio.wav",
        artifact.session_id
    );
    if artifact.relative_path != expected || artifact.sample_rate == 0 || artifact.channels == 0 {
        return Err(CoreError::Storage(
            "녹음 파일 경로가 올바르지 않습니다.".into(),
        ));
    }
    Ok(())
}

pub(crate) fn write_manifest(root: &Path, manifest: &Manifest) -> Result<()> {
    manifest.validate()?;
    write_json(
        root,
        &manifest.relative_dir().join("manifest.json"),
        manifest,
    )
}

pub(crate) fn finalize_audio(
    root: &Path,
    manifest: &mut Manifest,
) -> Result<Option<AudioArtifact>> {
    manifest.validate()?;
    let raw = checked_path(root, &manifest.relative_dir().join("audio.pcm"))?;
    let file = open_read(&raw)?;
    let length = file.metadata()?.len();
    let frames = length / manifest.frame_bytes() as u64;
    manifest.saved_frames = frames;
    if frames == 0 {
        write_manifest(root, manifest)?;
        return Ok(None);
    }
    if length % manifest.frame_bytes() as u64 != 0 {
        manifest.phase = CapturePhase::Interrupted;
        manifest.error = Some("마지막 녹음 구간이 불완전하여 저장된 구간만 복구했습니다.".into());
    }
    let sample_count = frames
        .checked_mul(u64::from(manifest.channels))
        .ok_or_else(|| CoreError::Storage("녹음 길이를 읽을 수 없습니다.".into()))?;
    if sample_count > (u32::MAX as u64 - 1024) / 4 {
        write_manifest(root, manifest)?;
        return Err(CoreError::Storage(
            "WAV 파일 크기 한도를 넘었습니다. 원본 녹음은 보관되어 있습니다.".into(),
        ));
    }
    let wav_relative = manifest.relative_dir().join("audio.wav");
    let wav_path = checked_path(root, &wav_relative)?;
    if wav_path.exists()
        && validate_playback(&wav_path, frames, manifest.sample_rate, manifest.channels).is_err()
    {
        if !fs::symlink_metadata(&wav_path)?.is_file() {
            return Err(CoreError::Storage(
                "재생 파일 경로에 다른 항목이 있습니다.".into(),
            ));
        }
        let backup_relative = manifest
            .relative_dir()
            .join(format!("audio.invalid.{}.wav", Uuid::new_v4()));
        let backup = checked_path(root, &backup_relative)?;
        if backup.exists() {
            return Err(CoreError::Storage(
                "재생 파일의 보존 경로가 이미 존재합니다.".into(),
            ));
        }
        checked_path(root, &wav_relative)?;
        fs::rename(&wav_path, &backup)?;
        sync_parent(&backup)?;
    }
    if !wav_path.exists() {
        let temporary = manifest
            .relative_dir()
            .join(format!("audio.{}.wav.tmp", Uuid::new_v4()));
        let temporary_path = checked_path(root, &temporary)?;
        let output = create_new(&temporary_path)?;
        let durable = output.try_clone()?;
        let mut writer = hound::WavWriter::new(
            BufWriter::new(output),
            hound::WavSpec {
                channels: manifest.channels,
                sample_rate: manifest.sample_rate,
                bits_per_sample: 32,
                sample_format: hound::SampleFormat::Float,
            },
        )
        .map_err(wav_error)?;
        let mut input = BufReader::new(file);
        let mut sample = [0_u8; 8];
        for _ in 0..sample_count {
            input.read_exact(&mut sample[..manifest.encoding.bytes()])?;
            writer
                .write_sample(
                    manifest
                        .encoding
                        .sample(&sample[..manifest.encoding.bytes()]),
                )
                .map_err(wav_error)?;
        }
        writer.finalize().map_err(wav_error)?;
        durable.sync_all()?;
        checked_path(root, &wav_relative)?;
        if wav_path.exists() {
            return Err(CoreError::Storage("재생 파일이 이미 존재합니다.".into()));
        }
        fs::rename(&temporary_path, &wav_path)?;
        sync_parent(&wav_path)?;
    }
    write_manifest(root, manifest)?;
    Ok(Some(AudioArtifact {
        session_id: manifest.session_id.clone(),
        relative_path: wav_relative.to_string_lossy().replace('\\', "/"),
        frames,
        sample_rate: manifest.sample_rate,
        channels: manifest.channels,
    }))
}

fn validate_playback(path: &Path, frames: u64, sample_rate: u32, channels: u16) -> Result<()> {
    let file = open_read(path)?;
    let file_length = file.metadata()?.len();
    let reader = hound::WavReader::new(BufReader::new(file)).map_err(wav_error)?;
    let spec = reader.spec();
    let samples = u64::from(reader.len());
    if spec.channels != channels
        || spec.sample_rate != sample_rate
        || spec.bits_per_sample != 32
        || spec.sample_format != hound::SampleFormat::Float
        || u64::from(reader.duration()) != frames
        || samples != frames.saturating_mul(u64::from(channels))
    {
        return Err(CoreError::Storage(
            "녹음 파일과 저장 정보가 일치하지 않습니다.".into(),
        ));
    }
    let mut input = reader.into_inner();
    let data_start = input.stream_position()?;
    if file_length < data_start.saturating_add(samples.saturating_mul(4)) {
        return Err(CoreError::Storage(
            "녹음 재생 파일의 일부가 누락되었습니다.".into(),
        ));
    }
    Ok(())
}

pub(crate) fn read_json<T: DeserializeOwned>(path: &Path) -> Result<T> {
    let file = open_read(path)?;
    if file.metadata()?.len() > MAX_JSON_BYTES {
        return Err(CoreError::Storage("저장 정보가 너무 큽니다.".into()));
    }
    serde_json::from_reader(BufReader::new(file))
        .map_err(|_| CoreError::Storage("저장 정보의 형식이 올바르지 않습니다.".into()))
}

fn write_json(root: &Path, relative: &Path, value: &impl Serialize) -> Result<()> {
    let destination = checked_path(root, relative)?;
    let parent = relative
        .parent()
        .ok_or_else(|| CoreError::Storage("저장 경로가 올바르지 않습니다.".into()))?;
    let temporary = parent.join(format!(".{}.json.tmp", Uuid::new_v4()));
    let temporary_path = checked_path(root, &temporary)?;
    let mut file = create_new(&temporary_path)?;
    serde_json::to_writer(&mut file, value)
        .map_err(|_| CoreError::Storage("저장 정보를 만들 수 없습니다.".into()))?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    checked_path(root, relative)?;
    fs::rename(&temporary_path, &destination)?;
    sync_parent(&destination)
}

pub(crate) fn checked_path(root: &Path, relative: &Path) -> Result<PathBuf> {
    if relative.as_os_str().is_empty()
        || relative
            .components()
            .any(|part| !matches!(part, Component::Normal(_)))
    {
        return Err(CoreError::Storage("저장 경로가 올바르지 않습니다.".into()));
    }
    let mut path = root.to_path_buf();
    validate_existing(&path)?;
    for part in relative.components() {
        path.push(part.as_os_str());
        validate_existing(&path)?;
    }
    Ok(path)
}

fn validate_existing(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() || is_reparse_point(&metadata) {
                return Err(CoreError::Storage(
                    "연결된 파일이나 폴더는 사용할 수 없습니다.".into(),
                ));
            }
            if metadata.is_file() {
                validate_links(&metadata)?;
            }
            Ok(())
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}

fn ensure_directory(path: &Path) -> Result<()> {
    if !path.is_absolute()
        || path
            .components()
            .any(|part| matches!(part, Component::ParentDir | Component::CurDir))
    {
        return Err(CoreError::Storage("절대 저장 경로가 필요합니다.".into()));
    }
    let mut current = PathBuf::new();
    for component in path.components() {
        current.push(component.as_os_str());
        validate_existing(&current)?;
        if !current.exists() {
            fs::create_dir(&current)?;
        }
        if !fs::metadata(&current)?.is_dir() {
            return Err(CoreError::Storage("저장 폴더를 열 수 없습니다.".into()));
        }
    }
    Ok(())
}

pub(crate) fn create_new(path: &Path) -> Result<File> {
    validate_existing(path)?;
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    no_follow(&mut options);
    let file = options.open(path)?;
    validate_file(&file)?;
    Ok(file)
}

pub(crate) fn open_read(path: &Path) -> Result<File> {
    validate_existing(path)?;
    let mut options = OpenOptions::new();
    options.read(true);
    no_follow(&mut options);
    let file = options.open(path)?;
    validate_file(&file)?;
    Ok(file)
}

fn validate_file(file: &File) -> Result<()> {
    let metadata = file.metadata()?;
    if !metadata.is_file() || is_reparse_point(&metadata) {
        return Err(CoreError::Storage("일반 파일이 아닙니다.".into()));
    }
    validate_links(&metadata)
}

#[cfg(unix)]
fn validate_links(metadata: &fs::Metadata) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    if metadata.nlink() != 1 {
        return Err(CoreError::Storage(
            "연결된 파일은 사용할 수 없습니다.".into(),
        ));
    }
    Ok(())
}
#[cfg(not(unix))]
fn validate_links(_: &fs::Metadata) -> Result<()> {
    Ok(())
}

#[cfg(windows)]
fn is_reparse_point(metadata: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    metadata.file_attributes() & 0x400 != 0
}
#[cfg(not(windows))]
fn is_reparse_point(_: &fs::Metadata) -> bool {
    false
}

#[cfg(unix)]
fn no_follow(options: &mut OpenOptions) {
    use std::os::unix::fs::OpenOptionsExt;
    options.custom_flags(libc::O_NOFOLLOW).mode(0o600);
}
#[cfg(windows)]
fn no_follow(options: &mut OpenOptions) {
    use std::os::windows::fs::OpenOptionsExt;
    options.custom_flags(0x0020_0000);
}
#[cfg(not(any(unix, windows)))]
fn no_follow(_: &mut OpenOptions) {}

#[cfg(unix)]
fn sync_parent(path: &Path) -> Result<()> {
    if let Some(parent) = path.parent() {
        File::open(parent)?.sync_all()?;
    }
    Ok(())
}
#[cfg(not(unix))]
fn sync_parent(_: &Path) -> Result<()> {
    Ok(())
}

fn wav_error(error: hound::Error) -> CoreError {
    CoreError::Storage(error.to_string())
}

pub(crate) fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|time| time.as_millis().min(u64::MAX as u128) as u64)
        .unwrap_or(0)
}
