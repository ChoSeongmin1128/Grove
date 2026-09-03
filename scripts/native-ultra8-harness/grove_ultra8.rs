//! Local Ultra8 helper. Audio and models are caller-supplied; no network access.
use hmac_sha256::Hash;
use ndarray::Array2;
use parakeet_rs::sortformer::{DiarizationConfig, Sortformer};
use serde::Serialize;
use std::{
    env, fs,
    fs::{File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    time::{Instant, SystemTime, UNIX_EPOCH},
};

const MODEL_REVISION: &str = "2a45f114eaf920b4d50b04a5964cc1aab35ddf5f";
const MODEL_SHA256: &str = "c64a1fb633ad52b77103ce0c0a0dd2b5f55a71f029083ed819901e36c7420c0a";
const SAMPLE_RATE: u32 = 16_000;
const SPEAKERS: usize = 8;
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

#[derive(Debug, Serialize, PartialEq)]
struct Segment {
    start: f64,
    end: f64,
    speaker: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Output {
    schema_version: u32,
    engine: &'static str,
    max_speakers: usize,
    speaker_count_constraint: Option<usize>,
    model_revision: &'static str,
    #[serde(rename = "modelSHA256")]
    model_sha256: &'static str,
    postprocessing: &'static str,
    duration_seconds: f64,
    processing_seconds: f64,
    inference_seconds: f64,
    frame_count: usize,
    segments: Vec<Segment>,
}

fn model_digest(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    let mut hash = Hash::new();
    let mut buffer = [0_u8; 65_536];
    loop {
        let size = file.read(&mut buffer)?;
        if size == 0 {
            break;
        }
        hash.update(&buffer[..size]);
    }
    Ok(hash.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

fn frame_time(frame: usize) -> f64 {
    // NeMo uses float32 frame positions, then rounds timestamps to two decimals.
    ((frame as f32 * 0.08_f32) as f64 * 100.0).round() / 100.0
}

fn default_segments(predictions: &Array2<f32>, audio_samples: usize) -> Result<Vec<Segment>> {
    if predictions.ncols() != SPEAKERS || predictions.nrows() == 0 {
        return Err("Expected nonempty, eight-column speaker activities".into());
    }
    if predictions
        .iter()
        .any(|p| !p.is_finite() || !(0.0..=1.0).contains(p))
    {
        return Err("Speaker activities must be finite probabilities".into());
    }
    let duration = audio_samples as f64 / f64::from(SAMPLE_RATE);
    let mut segments = Vec::new();
    for speaker in 0..SPEAKERS {
        let mut active_start = None;
        for (frame, probability) in predictions.column(speaker).iter().enumerate() {
            // Published NeMo default: > .5 starts, < .5 stops, equality retains
            // state; no median smoothing, padding, minimum duration, or merging.
            if *probability > 0.5 && active_start.is_none() {
                active_start = Some(frame);
            } else if *probability < 0.5 {
                if let Some(start) = active_start.take() {
                    push_segment(&mut segments, start, frame, speaker, duration);
                }
            }
        }
        if let Some(start) = active_start {
            push_segment(&mut segments, start, predictions.nrows(), speaker, duration);
        }
    }
    segments.sort_by(|a, b| {
        a.start
            .total_cmp(&b.start)
            .then_with(|| a.speaker.cmp(&b.speaker))
    });
    Ok(segments)
}

fn push_segment(out: &mut Vec<Segment>, start: usize, end: usize, speaker: usize, duration: f64) {
    let start = frame_time(start);
    let end = frame_time(end).min(duration);
    if end > start {
        out.push(Segment {
            start,
            end,
            speaker: speaker.to_string(),
        });
    }
}

fn write_new_output(path: &Path, bytes: &[u8]) -> Result<()> {
    let file_name = path
        .file_name()
        .ok_or("Output needs a file name")?
        .to_string_lossy();
    let nonce = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
    let temporary = path.with_file_name(format!(".{file_name}.{}.{nonce}.tmp", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    let operation = (|| -> Result<()> {
        file.write_all(bytes)?;
        file.sync_all()?;
        // A same-directory hard link publishes a complete file atomically and
        // fails when the requested destination already exists; never overwrite.
        fs::hard_link(&temporary, path)?;
        Ok(())
    })();
    drop(file);
    let _ = fs::remove_file(&temporary);
    operation
}

fn run() -> Result<()> {
    let args: Vec<_> = env::args_os().collect();
    if args.len() != 4 {
        return Err("Usage: grove-ultra8 INPUT_WAV MODEL_ONNX OUTPUT_JSON".into());
    }
    let started = Instant::now();
    let input = PathBuf::from(&args[1]);
    let model = PathBuf::from(&args[2]);
    let output = PathBuf::from(&args[3]);
    if fs::symlink_metadata(&output).is_ok() {
        return Err("Refusing to overwrite an existing output".into());
    }
    let mut reader = hound::WavReader::open(&input)?;
    let spec = reader.spec();
    if spec.sample_rate != SAMPLE_RATE
        || spec.channels != 1
        || spec.bits_per_sample != 16
        || spec.sample_format != hound::SampleFormat::Int
    {
        return Err("Input must be 16 kHz mono PCM16 WAV".into());
    }
    if reader.duration() == 0 {
        return Err("Input contains no audio samples".into());
    }
    if model_digest(&model)? != MODEL_SHA256 {
        return Err("Ultra8 model checksum does not match the pinned revision".into());
    }
    let audio: Vec<f32> = reader
        .samples::<i16>()
        .map(|sample| sample.map(|s| f32::from(s) / 32_768.0))
        .collect::<std::result::Result<_, _>>()?;
    let mut diarizer = Sortformer::with_config(&model, None, DiarizationConfig::default())?;
    if (
        diarizer.chunk_len,
        diarizer.right_context,
        diarizer.fifo_len,
        diarizer.spkcache_len,
    ) != (340, 40, 40, 376)
    {
        return Err("Unexpected Ultra8 streaming metadata".into());
    }
    let infer_started = Instant::now();
    let raw = diarizer.diarize_chunk_raw(&audio)?;
    let inference_seconds = infer_started.elapsed().as_secs_f64();
    let minimum_frames = audio.len().div_ceil(1_280);
    if !(minimum_frames..=minimum_frames + 1).contains(&raw.predictions.nrows()) {
        return Err("Incomplete or excessive model frame coverage".into());
    }
    let segments = default_segments(&raw.predictions, audio.len())?;
    let result = Output {
        schema_version: 1,
        engine: "ultra8",
        max_speakers: SPEAKERS,
        speaker_count_constraint: None,
        model_revision: MODEL_REVISION,
        model_sha256: MODEL_SHA256,
        postprocessing: "nemo-default-0.5",
        duration_seconds: audio.len() as f64 / f64::from(SAMPLE_RATE),
        processing_seconds: started.elapsed().as_secs_f64(),
        inference_seconds,
        frame_count: raw.predictions.nrows(),
        segments,
    };
    write_new_output(&output, &serde_json::to_vec_pretty(&result)?)?;
    eprintln!(
        "Ultra8 completed in {:.3}s",
        started.elapsed().as_secs_f64()
    );
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("Ultra8: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn equal_threshold_retains_state_and_padding_is_clipped() {
        let mut frames = Array2::zeros((6, SPEAKERS));
        for (i, p) in [0.5, 0.6, 0.5, 0.4, 0.6, 0.9].iter().enumerate() {
            frames[[i, 0]] = *p;
        }
        assert_eq!(
            default_segments(&frames, 6_000).unwrap(),
            vec![
                Segment {
                    start: 0.08,
                    end: 0.24,
                    speaker: "0".into()
                },
                Segment {
                    start: 0.32,
                    end: 0.375,
                    speaker: "0".into()
                },
            ]
        );
    }

    #[test]
    fn preserves_overlapping_speakers_without_forcing_eight() {
        let mut frames = Array2::zeros((3, SPEAKERS));
        frames[[0, 0]] = 0.8;
        frames[[0, 7]] = 0.8;
        frames[[1, 7]] = 0.8;
        let segments = default_segments(&frames, 4_800).unwrap();
        assert_eq!(segments.len(), 2);
        assert_eq!(segments[0].speaker, "0");
        assert_eq!(segments[1].speaker, "7");
        assert_eq!(segments[1].end, 0.16);
    }

    #[test]
    fn rejects_invalid_activity_and_preserves_silence() {
        assert!(default_segments(&Array2::zeros((1, 4)), 1_280).is_err());
        let mut frames = Array2::zeros((1, SPEAKERS));
        assert!(default_segments(&frames, 1_280).unwrap().is_empty());
        frames[[0, 0]] = f32::NAN;
        assert!(default_segments(&frames, 1_280).is_err());
        frames[[0, 0]] = 1.01;
        assert!(default_segments(&frames, 1_280).is_err());
    }

    #[test]
    fn output_metadata_uses_the_app_contract() {
        let output = Output {
            schema_version: 1,
            engine: "ultra8",
            max_speakers: 8,
            speaker_count_constraint: None,
            model_revision: MODEL_REVISION,
            model_sha256: MODEL_SHA256,
            postprocessing: "nemo-default-0.5",
            duration_seconds: 1.0,
            processing_seconds: 0.1,
            inference_seconds: 0.05,
            frame_count: 13,
            segments: vec![],
        };
        let value = serde_json::to_value(output).unwrap();
        assert_eq!(value["schemaVersion"], 1);
        assert_eq!(value["engine"], "ultra8");
        assert_eq!(value["maxSpeakers"], 8);
        assert!(value["speakerCountConstraint"].is_null());
        assert_eq!(value["modelRevision"], MODEL_REVISION);
        assert_eq!(value["modelSHA256"], MODEL_SHA256);
        assert_eq!(value["postprocessing"], "nemo-default-0.5");
        assert_eq!(value["durationSeconds"], 1.0);
    }

    #[test]
    fn output_publish_never_overwrites() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory =
            env::temp_dir().join(format!("grove-ultra8-unit-{}-{nonce}", std::process::id()));
        fs::create_dir(&directory).unwrap();
        let output = directory.join("output.json");
        write_new_output(&output, b"original").unwrap();
        assert!(write_new_output(&output, b"replacement").is_err());
        assert_eq!(fs::read(&output).unwrap(), b"original");
        assert_eq!(fs::read_dir(&directory).unwrap().count(), 1);
        fs::remove_file(output).unwrap();
        fs::remove_dir(directory).unwrap();
    }
}
