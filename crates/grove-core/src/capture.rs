use crate::store::{self, CapturePhase, Encoding, Manifest};
use crate::{AudioArtifact, CoreError, Device, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use rtrb::{Consumer, Producer, RingBuffer};
use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

const FAULT_OVERFLOW: u8 = 1;
const FAULT_DEVICE: u8 = 2;
const FAULT_WRITER: u8 = 3;
const FAULT_FORMAT: u8 = 4;
const CHECKPOINT_INTERVAL: Duration = Duration::from_secs(1);
const MAX_QUEUE_BYTES: usize = 8 * 1024 * 1024;

pub(crate) struct Signals {
    accepting: AtomicBool,
    callbacks: AtomicUsize,
    fault: AtomicU8,
    saved_bytes: AtomicU64,
    phase: AtomicU8,
}

impl Signals {
    fn new() -> Self {
        Self {
            accepting: AtomicBool::new(false),
            callbacks: AtomicUsize::new(0),
            fault: AtomicU8::new(0),
            saved_bytes: AtomicU64::new(0),
            phase: AtomicU8::new(0),
        }
    }

    fn fail(&self, code: u8) {
        let _ = self
            .fault
            .compare_exchange(0, code, Ordering::AcqRel, Ordering::Acquire);
        self.accepting.store(false, Ordering::Release);
    }

    pub fn error(&self) -> Option<String> {
        match self.fault.load(Ordering::Acquire) {
            0 => None,
            FAULT_OVERFLOW => Some("녹음 저장이 입력을 따라가지 못해 중단했습니다.".into()),
            FAULT_DEVICE => {
                Some("마이크 입력이 중단되었습니다. 저장된 구간은 보관했습니다.".into())
            }
            FAULT_WRITER => Some("녹음 파일을 저장하지 못해 중단했습니다.".into()),
            _ => Some("마이크의 오디오 형식이 변경되어 녹음을 중단했습니다.".into()),
        }
    }

    fn quiesce(&self) {
        self.accepting.store(false, Ordering::SeqCst);
        while self.callbacks.load(Ordering::SeqCst) != 0 {
            thread::yield_now();
        }
    }
}

pub(crate) struct CallbackSink {
    producer: Producer<u8>,
    signals: Arc<Signals>,
    frame_bytes: usize,
}

impl CallbackSink {
    pub fn write(&mut self, input: &[u8]) {
        self.signals.callbacks.fetch_add(1, Ordering::SeqCst);
        if self.signals.accepting.load(Ordering::SeqCst)
            && self.signals.fault.load(Ordering::Acquire) == 0
        {
            if input.len() % self.frame_bytes != 0 {
                self.signals.fail(FAULT_FORMAT);
            } else if !input.is_empty() {
                match self.producer.write_chunk(input.len()) {
                    Ok(mut chunk) => {
                        let (first, second) = chunk.as_mut_slices();
                        let split = first.len();
                        first.copy_from_slice(&input[..split]);
                        second.copy_from_slice(&input[split..]);
                        chunk.commit_all();
                    }
                    Err(_) => self.signals.fail(FAULT_OVERFLOW),
                }
            }
        }
        self.signals.callbacks.fetch_sub(1, Ordering::SeqCst);
    }
}

enum WriterCommand {
    Flush(mpsc::SyncSender<Result<u64>>),
    Finish(CapturePhase, Option<String>),
}

pub(crate) struct CaptureOutcome {
    pub manifest: Manifest,
    pub audio: Option<AudioArtifact>,
}

pub(crate) struct Capture {
    pub manifest: Manifest,
    pub signals: Arc<Signals>,
    stream: Option<cpal::Stream>,
    writer: Option<JoinHandle<CaptureOutcome>>,
    control: mpsc::Sender<WriterCommand>,
}

impl Capture {
    pub fn prepare(root: &Path, manifest: Manifest, raw: File) -> Result<(Self, CallbackSink)> {
        let capacity = (manifest.sample_rate as usize)
            .checked_mul(manifest.frame_bytes())
            .and_then(|bytes| bytes.checked_mul(2))
            .ok_or_else(|| CoreError::Audio("마이크의 오디오 형식을 지원하지 않습니다.".into()))?;
        let capacity = capacity.min(MAX_QUEUE_BYTES);
        let capacity = capacity - capacity % manifest.frame_bytes();
        Self::prepare_with_capacity(root, manifest, raw, capacity)
    }

    fn prepare_with_capacity(
        root: &Path,
        manifest: Manifest,
        raw: File,
        capacity: usize,
    ) -> Result<(Self, CallbackSink)> {
        let (producer, consumer) = RingBuffer::<u8>::new(capacity);
        let signals = Arc::new(Signals::new());
        let (control, commands) = mpsc::channel();
        let root = root.to_path_buf();
        let writer_manifest = manifest.clone();
        let writer_signals = signals.clone();
        let writer = thread::Builder::new()
            .name("grove-audio-writer".into())
            .spawn(move || {
                writer_loop(
                    root,
                    writer_manifest,
                    raw,
                    consumer,
                    writer_signals,
                    commands,
                )
            })?;
        let sink = CallbackSink {
            producer,
            signals: signals.clone(),
            frame_bytes: manifest.frame_bytes(),
        };
        Ok((
            Self {
                manifest,
                signals,
                stream: None,
                writer: Some(writer),
                control,
            },
            sink,
        ))
    }

    pub fn attach_stream(
        &mut self,
        device: &cpal::Device,
        config: cpal::SupportedStreamConfig,
        mut sink: CallbackSink,
    ) -> Result<()> {
        let signals = self.signals.clone();
        let stream = device
            .build_input_stream_raw(
                config.config(),
                config.sample_format(),
                move |data, _| sink.write(data.bytes()),
                move |_| signals.fail(FAULT_DEVICE),
                Some(Duration::from_secs(5)),
            )
            .map_err(|error| CoreError::Audio(format!("마이크를 열 수 없습니다: {error}")))?;
        stream
            .play()
            .map_err(|error| CoreError::Audio(format!("녹음을 시작할 수 없습니다: {error}")))?;
        self.stream = Some(stream);
        Ok(())
    }

    pub fn begin(&mut self) {
        self.manifest.phase = CapturePhase::Recording;
        self.signals.phase.store(1, Ordering::Release);
        if self.signals.fault.load(Ordering::Acquire) == 0 {
            self.signals.accepting.store(true, Ordering::Release);
        }
    }

    pub fn frames(&self) -> u64 {
        self.signals.saved_bytes.load(Ordering::Acquire) / self.manifest.frame_bytes() as u64
    }

    pub fn pause(&mut self) -> Result<()> {
        self.signals.quiesce();
        self.signals.phase.store(2, Ordering::Release);
        self.manifest.phase = CapturePhase::Paused;
        self.flush()?;
        Ok(())
    }

    pub fn resume(&mut self) -> Result<()> {
        if let Some(error) = self.signals.error() {
            return Err(CoreError::Audio(error));
        }
        self.signals.phase.store(1, Ordering::Release);
        self.manifest.phase = CapturePhase::Recording;
        self.signals.accepting.store(true, Ordering::SeqCst);
        Ok(())
    }

    pub fn flush(&self) -> Result<u64> {
        let (reply, response) = mpsc::sync_channel(1);
        self.control
            .send(WriterCommand::Flush(reply))
            .map_err(|_| CoreError::Storage("녹음 저장이 중단되었습니다.".into()))?;
        response
            .recv()
            .map_err(|_| CoreError::Storage("녹음 저장이 중단되었습니다.".into()))?
    }

    pub fn finish(mut self, phase: CapturePhase, error: Option<String>) -> Result<CaptureOutcome> {
        self.finish_inner(phase, error)
    }

    fn finish_inner(
        &mut self,
        phase: CapturePhase,
        error: Option<String>,
    ) -> Result<CaptureOutcome> {
        self.signals.quiesce();
        self.stream.take();
        let _ = self.control.send(WriterCommand::Finish(phase, error));
        let writer = self.writer.take().ok_or(CoreError::Unavailable)?;
        writer.join().map_err(|_| {
            CoreError::Storage(
                "녹음 저장이 예기치 않게 종료되었습니다. 원본은 다음 실행에서 복구합니다.".into(),
            )
        })
    }
}

impl Drop for Capture {
    fn drop(&mut self) {
        if self.writer.is_some() {
            let prepared = self.manifest.phase == CapturePhase::Prepared;
            let phase = if prepared {
                CapturePhase::Prepared
            } else {
                CapturePhase::Interrupted
            };
            let error = (!prepared).then(|| "앱이 종료되어 녹음을 중단했습니다.".to_string());
            let _ = self.finish_inner(phase, error);
        }
    }
}

pub(crate) fn devices() -> Result<Vec<Device>> {
    let host = cpal::default_host();
    let default_id = host
        .default_input_device()
        .and_then(|device| device.id().ok());
    let devices = host
        .input_devices()
        .map_err(|error| CoreError::Audio(format!("마이크 목록을 불러오지 못했습니다: {error}")))?;
    let mut result = Vec::new();
    for device in devices {
        let Ok(id) = device.id() else {
            continue;
        };
        let Ok(description) = device.description() else {
            continue;
        };
        result.push(Device {
            is_default: Some(&id) == default_id.as_ref(),
            id: id.to_string(),
            name: description.name().to_owned(),
        });
    }
    result.sort_by(|a, b| {
        b.is_default
            .cmp(&a.is_default)
            .then_with(|| a.name.cmp(&b.name))
            .then_with(|| a.id.cmp(&b.id))
    });
    result.dedup_by(|a, b| a.id == b.id);
    Ok(result)
}

pub(crate) fn select_device(
    id: &str,
) -> Result<(cpal::Device, cpal::SupportedStreamConfig, Encoding)> {
    if cfg!(target_endian = "big") {
        return Err(CoreError::Audio(
            "이 시스템의 오디오 저장 형식을 지원하지 않습니다.".into(),
        ));
    }
    let host = cpal::default_host();
    let device = if id == "default" {
        host.default_input_device()
    } else {
        let parsed: cpal::DeviceId = id
            .parse()
            .map_err(|_| CoreError::Audio("선택한 마이크를 찾을 수 없습니다.".into()))?;
        if parsed.host() != host.id() {
            return Err(CoreError::Audio(
                "선택한 마이크를 지원하지 않습니다.".into(),
            ));
        }
        host.device_by_id(&parsed)
    }
    .ok_or_else(|| CoreError::Audio("선택한 마이크가 연결되어 있지 않습니다.".into()))?;
    if !device.supports_input() {
        return Err(CoreError::Audio("마이크 입력 장치가 아닙니다.".into()));
    }
    let config = device.default_input_config().map_err(|error| {
        CoreError::Audio(format!("마이크의 오디오 형식을 읽을 수 없습니다: {error}"))
    })?;
    let encoding = match config.sample_format() {
        cpal::SampleFormat::F32 => Encoding::F32,
        cpal::SampleFormat::F64 => Encoding::F64,
        cpal::SampleFormat::I16 => Encoding::I16,
        cpal::SampleFormat::I32 => Encoding::I32,
        _ => {
            return Err(CoreError::Audio(
                "이 마이크의 기본 오디오 형식은 아직 지원하지 않습니다.".into(),
            ))
        }
    };
    Ok((device, config, encoding))
}

struct PendingAudio {
    consumer: Consumer<u8>,
    write_failed: bool,
}

impl PendingAudio {
    fn new(consumer: Consumer<u8>) -> Self {
        Self {
            consumer,
            write_failed: false,
        }
    }

    fn write_to(
        &mut self,
        raw: &mut impl Write,
        signals: &Signals,
        frame_bytes: usize,
    ) -> Result<()> {
        if self.write_failed {
            return Err(CoreError::Storage(
                "실패한 녹음 쓰기는 다시 실행하지 않습니다.".into(),
            ));
        }
        let result = drain_audio(&mut self.consumer, raw, signals, frame_bytes);
        if result.is_err() {
            self.write_failed = true;
        }
        result
    }
}

fn drain_audio(
    consumer: &mut Consumer<u8>,
    raw: &mut impl Write,
    signals: &Signals,
    frame_bytes: usize,
) -> Result<()> {
    let mut available = consumer.slots();
    available -= available % frame_bytes;
    while available != 0 {
        let count = available.min((64 * 1024 / frame_bytes).max(1) * frame_bytes);
        let chunk = consumer
            .read_chunk(count)
            .map_err(|_| CoreError::Storage("녹음 저장 대기열을 읽을 수 없습니다.".into()))?;
        let (first, second) = chunk.as_slices();
        raw.write_all(first)?;
        raw.write_all(second)?;
        chunk.commit_all();
        signals
            .saved_bytes
            .fetch_add(count as u64, Ordering::Release);
        available -= count;
    }
    Ok(())
}

fn checkpoint(root: &Path, raw: &File, manifest: &mut Manifest, signals: &Signals) -> Result<u64> {
    raw.sync_data()?;
    manifest.saved_frames = raw.metadata()?.len() / manifest.frame_bytes() as u64;
    manifest.phase = match signals.phase.load(Ordering::Acquire) {
        1 => CapturePhase::Recording,
        2 => CapturePhase::Paused,
        _ => CapturePhase::Prepared,
    };
    store::write_manifest(root, manifest)?;
    Ok(manifest.saved_frames)
}

fn writer_loop(
    root: PathBuf,
    mut manifest: Manifest,
    mut raw: File,
    consumer: Consumer<u8>,
    signals: Arc<Signals>,
    commands: mpsc::Receiver<WriterCommand>,
) -> CaptureOutcome {
    let mut last_checkpoint = Instant::now();
    let mut pending = PendingAudio::new(consumer);
    let (phase, mut error) = loop {
        if let Err(error) = pending.write_to(&mut raw, &signals, manifest.frame_bytes()) {
            signals.fail(FAULT_WRITER);
            break (
                CapturePhase::Interrupted,
                Some(format!("녹음을 저장하지 못했습니다: {error}")),
            );
        }
        match commands.try_recv() {
            Ok(WriterCommand::Flush(reply)) => {
                let result = pending
                    .write_to(&mut raw, &signals, manifest.frame_bytes())
                    .and_then(|_| checkpoint(&root, &raw, &mut manifest, &signals));
                let failed = result.is_err();
                let _ = reply.send(result);
                if failed {
                    signals.fail(FAULT_WRITER);
                    break (
                        CapturePhase::Interrupted,
                        Some("녹음 파일의 저장을 확인하지 못했습니다.".into()),
                    );
                }
                last_checkpoint = Instant::now();
            }
            Ok(WriterCommand::Finish(phase, error)) => break (phase, error),
            Err(mpsc::TryRecvError::Disconnected) => {
                break (
                    CapturePhase::Interrupted,
                    Some("녹음 제어가 종료되었습니다.".into()),
                )
            }
            Err(mpsc::TryRecvError::Empty) => {}
        }
        if last_checkpoint.elapsed() >= CHECKPOINT_INTERVAL {
            if let Err(error) = checkpoint(&root, &raw, &mut manifest, &signals) {
                signals.fail(FAULT_WRITER);
                break (
                    CapturePhase::Interrupted,
                    Some(format!("녹음 파일의 저장을 확인하지 못했습니다: {error}")),
                );
            }
            last_checkpoint = Instant::now();
        }
        thread::sleep(Duration::from_millis(4));
    };
    signals.accepting.store(false, Ordering::SeqCst);
    while signals.callbacks.load(Ordering::SeqCst) != 0 {
        thread::yield_now();
    }
    if error.is_none() {
        error = signals.error();
    }
    if !pending.write_failed {
        if let Err(write_error) = pending.write_to(&mut raw, &signals, manifest.frame_bytes()) {
            error = Some(format!(
                "녹음의 마지막 구간을 저장하지 못했습니다: {write_error}"
            ));
        }
    }
    if let Err(sync_error) = raw.sync_all() {
        error = Some(format!("녹음 저장을 확인하지 못했습니다: {sync_error}"));
    }
    manifest.saved_frames = raw
        .metadata()
        .map(|metadata| metadata.len() / manifest.frame_bytes() as u64)
        .unwrap_or(0);
    signals.saved_bytes.store(
        manifest.saved_frames * manifest.frame_bytes() as u64,
        Ordering::Release,
    );
    drop(raw);
    manifest.phase = if error.is_some() && phase != CapturePhase::Prepared {
        CapturePhase::Interrupted
    } else {
        phase
    };
    manifest.error = error;
    if manifest.phase == CapturePhase::Completed && manifest.saved_frames == 0 {
        manifest.phase = CapturePhase::Interrupted;
        manifest.error = Some("녹음된 오디오가 없습니다.".into());
    }
    let audio = if phase == CapturePhase::Prepared {
        if let Err(error) = store::write_manifest(&root, &manifest) {
            manifest.error = Some(error.to_string());
        }
        None
    } else {
        match store::finalize_audio(&root, &mut manifest) {
            Ok(audio) => audio,
            Err(error) => {
                manifest.phase = CapturePhase::Interrupted;
                manifest.error = Some(format!(
                    "원본은 보관했지만 재생 파일을 만들지 못했습니다: {error}"
                ));
                let _ = store::write_manifest(&root, &manifest);
                None
            }
        }
    };
    CaptureOutcome { manifest, audio }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::Store;
    use std::fs;

    fn setup(capacity: usize) -> (tempfile::TempDir, Store, Capture, CallbackSink) {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap().join("dev");
        let store = Store::open(root).unwrap();
        let meeting = store.create("회의".into(), "메모".into()).unwrap();
        let manifest = Manifest::new(
            &meeting.meeting.id,
            "synthetic",
            "시험 입력",
            1000,
            1,
            Encoding::F32,
        );
        let raw = store.prepare_capture(&manifest).unwrap();
        let (capture, sink) =
            Capture::prepare_with_capacity(&store.root, manifest, raw, capacity).unwrap();
        (temporary, store, capture, sink)
    }

    #[test]
    fn paused_input_is_not_saved_and_elapsed_uses_written_frames() {
        let (_temporary, store, mut capture, mut sink) = setup(4096);
        capture.begin();
        sink.write(&[0.25_f32.to_le_bytes(); 100].concat());
        capture.pause().unwrap();
        assert_eq!(capture.frames(), 100);
        sink.write(&[0.5_f32.to_le_bytes(); 100].concat());
        capture.flush().unwrap();
        assert_eq!(capture.frames(), 100);
        capture.resume().unwrap();
        sink.write(&[0.75_f32.to_le_bytes(); 50].concat());
        let outcome = capture.finish(CapturePhase::Completed, None).unwrap();
        assert_eq!(outcome.manifest.saved_frames, 150);
        assert_eq!(outcome.manifest.phase, CapturePhase::Completed);
        let audio = outcome.audio.unwrap();
        let mut reader = hound::WavReader::open(store.root.join(audio.relative_path)).unwrap();
        assert_eq!(
            reader
                .samples::<f32>()
                .map(|sample| sample.unwrap())
                .collect::<Vec<_>>(),
            [vec![0.25; 100], vec![0.75; 50]].concat()
        );
    }

    #[test]
    fn overflow_is_interrupted_instead_of_success() {
        let (_temporary, _store, mut capture, mut sink) = setup(4);
        capture.begin();
        sink.write(&[0_u8; 8]);
        assert!(capture.signals.error().is_some());
        let outcome = capture.finish(CapturePhase::Completed, None).unwrap();
        assert_eq!(outcome.manifest.phase, CapturePhase::Interrupted);
        assert!(outcome.manifest.error.is_some());
    }

    #[test]
    fn partial_write_is_not_replayed_after_the_disk_recovers() {
        struct OnceFailWriter {
            file: File,
            remaining: usize,
            failed_once: bool,
        }
        impl Write for OnceFailWriter {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                if !self.failed_once && self.remaining == 0 {
                    self.failed_once = true;
                    return Err(std::io::Error::other("injected transient write failure"));
                }
                let count = if self.failed_once {
                    bytes.len()
                } else {
                    bytes.len().min(self.remaining)
                };
                let written = self.file.write(&bytes[..count])?;
                self.remaining = self.remaining.saturating_sub(written);
                Ok(written)
            }
            fn flush(&mut self) -> std::io::Result<()> {
                self.file.flush()
            }
        }
        let temporary = tempfile::tempdir().unwrap();
        let store = Store::open(temporary.path().canonicalize().unwrap().join("dev")).unwrap();
        let meeting = store.create("회의".into(), "".into()).unwrap();
        let mut manifest = Manifest::new(
            &meeting.meeting.id,
            "synthetic",
            "시험 입력",
            1000,
            1,
            Encoding::F32,
        );
        let raw = store.prepare_capture(&manifest).unwrap();
        let (mut producer, mut consumer) = RingBuffer::<u8>::new(16);
        for _ in 0..8 {
            producer.push(0).unwrap();
        }
        for _ in 0..8 {
            consumer.pop().unwrap();
        }
        let input = [
            0.25_f32.to_le_bytes(),
            0.5_f32.to_le_bytes(),
            0.75_f32.to_le_bytes(),
        ]
        .concat();
        let mut chunk = producer.write_chunk(input.len()).unwrap();
        let (first, second) = chunk.as_mut_slices();
        assert!(!first.is_empty() && !second.is_empty());
        let split = first.len();
        first.copy_from_slice(&input[..split]);
        second.copy_from_slice(&input[split..]);
        chunk.commit_all();
        let signals = Signals::new();
        let mut pending = PendingAudio::new(consumer);
        let mut writer = OnceFailWriter {
            file: raw,
            remaining: 10,
            failed_once: false,
        };
        assert!(pending.write_to(&mut writer, &signals, 4).is_err());
        assert!(writer.failed_once);
        assert_eq!(writer.file.metadata().unwrap().len(), 10);
        assert!(pending.write_to(&mut writer, &signals, 4).is_err());
        assert_eq!(writer.file.metadata().unwrap().len(), 10);
        writer.file.sync_all().unwrap();
        drop(writer);
        manifest.phase = CapturePhase::Interrupted;
        let artifact = store::finalize_audio(&store.root, &mut manifest)
            .unwrap()
            .unwrap();
        assert_eq!(artifact.frames, 2);
        assert_eq!(
            fs::read(store.root.join(manifest.relative_dir()).join("audio.pcm")).unwrap(),
            input[..10]
        );
        let mut playback = hound::WavReader::open(store.root.join(artifact.relative_path)).unwrap();
        assert_eq!(
            playback
                .samples::<f32>()
                .map(|sample| sample.unwrap())
                .collect::<Vec<_>>(),
            vec![0.25, 0.5]
        );
    }

    #[test]
    fn checkpoint_write_failure_is_reported_and_raw_survives() {
        let (_temporary, store, mut capture, mut sink) = setup(1024);
        capture.begin();
        sink.write(&[0.5_f32.to_le_bytes(); 16].concat());
        capture.pause().unwrap();
        let path = store
            .root
            .join(capture.manifest.relative_dir())
            .join("manifest.json");
        let saved = fs::read(&path).unwrap();
        fs::remove_file(&path).unwrap();
        fs::create_dir(&path).unwrap();
        assert!(capture.flush().is_err());
        let outcome = capture.finish(CapturePhase::Completed, None).unwrap();
        assert_eq!(outcome.manifest.phase, CapturePhase::Interrupted);
        assert!(outcome.manifest.error.is_some());
        assert!(
            store
                .root
                .join(outcome.manifest.relative_dir())
                .join("audio.pcm")
                .metadata()
                .unwrap()
                .len()
                >= 64
        );
        fs::remove_dir(&path).unwrap();
        fs::write(path, saved).unwrap();
    }
}
