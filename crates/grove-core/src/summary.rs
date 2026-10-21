use crate::engine::Engine;
use crate::store;
use crate::{CoreError, Result, Transcript, TranscriptVersion};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::io::Write;
use std::path::{Path, PathBuf};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SummaryProvenance {
    pub model: String,
    pub model_revision: String,
    pub model_sha256: String,
    pub runtime: String,
    pub prompt_version: String,
    pub template: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Summary {
    pub id: String,
    pub text: String,
    pub created_at: u64,
    pub source_version: TranscriptVersion,
    pub source_sha256: String,
    pub provenance: SummaryProvenance,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SummaryView {
    pub document: Summary,
    pub stale: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SummaryDraft {
    pub source: Transcript,
    pub expected_id: Option<String>,
    pub text: String,
    pub provenance: SummaryProvenance,
    pub receipt: serde_json::Value,
}
pub fn transcript_digest(doc: &Transcript) -> Result<String> {
    let bytes = serde_json::to_vec(doc).map_err(|e| CoreError::Storage(e.to_string()))?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}
fn location(id: &str) -> Result<PathBuf> {
    store::validate_id(id)?;
    Ok(Path::new("meetings").join(id).join("summaries"))
}
impl Engine {
    pub fn summary(&self, id: &str) -> Result<Option<SummaryView>> {
        let directory = location(id)?;
        if !self.meetings.contains_key(id) {
            return Err(CoreError::MeetingNotFound);
        }
        let path = store::checked_path(&self.store.root, &directory.join("current.json"))?;
        if !path.exists() {
            return Ok(None);
        }
        let document: Summary = store::read_json(&path)?;
        let current = self.transcript(id)?;
        let stale = match current {
            Some(doc) => transcript_digest(&doc)? != document.source_sha256,
            None => true,
        };
        Ok(Some(SummaryView { document, stale }))
    }
    pub fn commit_summary(&mut self, id: &str, draft: SummaryDraft) -> Result<Summary> {
        self.require_active_meeting(id)?;
        if self.quitting {
            return Err(CoreError::Unavailable);
        }
        let directory = location(id)?;
        if !self.meetings.contains_key(id) {
            return Err(CoreError::MeetingNotFound);
        }
        if draft.text.trim().is_empty()
            || draft.text.len() > 2 * 1024 * 1024
            || draft.text.contains('\0')
        {
            return Err(CoreError::InvalidInput(
                "요약 내용이 올바르지 않습니다.".into(),
            ));
        }
        let source_sha256 = transcript_digest(&draft.source)?;
        let doc = Summary {
            id: Uuid::new_v4().to_string(),
            text: draft.text.clone(),
            created_at: store::now(),
            source_version: draft.source.version.clone(),
            source_sha256,
            provenance: draft.provenance.clone(),
        };
        let relative = directory.join(&doc.id);
        store::ensure_directory(&store::checked_path(&self.store.root, &relative)?)?;
        let archive =
            serde_json::json!({"document":doc,"source":draft.source,"receipt":draft.receipt});
        let mut file = store::create_new(&store::checked_path(
            &self.store.root,
            &relative.join("run.json"),
        )?)?;
        serde_json::to_writer(&mut file, &archive)
            .map_err(|e| CoreError::Storage(e.to_string()))?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        let current = self
            .transcript(id)?
            .ok_or_else(|| CoreError::InvalidState("전사가 없습니다.".into()))?;
        if transcript_digest(&current)? != doc.source_sha256
            || self.summary(id)?.map(|v| v.document.id) != draft.expected_id
        {
            return Err(CoreError::InvalidState("전사 또는 요약이 변경되어 새 결과를 적용하지 않았습니다. 기존 내용은 유지했습니다.".into()));
        }
        store::write_json(&self.store.root, &directory.join("current.json"), &doc)?;
        Ok(doc)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcript::tests::{output, setup};
    fn draft(source: Transcript, expected_id: Option<String>, text: &str) -> SummaryDraft {
        SummaryDraft {
            source,
            expected_id,
            text: text.into(),
            provenance: SummaryProvenance {
                model: "test".into(),
                model_revision: "1".into(),
                model_sha256: "a".repeat(64),
                runtime: "test".into(),
                prompt_version: "test".into(),
                template: "minutes".into(),
            },
            receipt: serde_json::json!({"finish_reason":"stop"}),
        }
    }
    #[test]
    fn summaries_reopen_without_changing_audio_notes_or_transcript() {
        let (_temp, mut engine, id, _) = setup();
        let source = engine.commit_transcript(&id, None, output()).unwrap();
        let root = engine.store.root.clone();
        let audio = std::fs::read(engine.audio_path(&id).unwrap()).unwrap();
        let before = transcript_digest(&source).unwrap();
        let one = engine
            .commit_summary(&id, draft(source.clone(), None, "요약 [1]"))
            .unwrap();
        let two = engine
            .commit_summary(&id, draft(source, Some(one.id.clone()), "새 요약 [1]"))
            .unwrap();
        assert!(root
            .join(location(&id).unwrap())
            .join(one.id)
            .join("run.json")
            .is_file());
        drop(engine);
        let engine = Engine::open(root).unwrap();
        let saved = engine.summary(&id).unwrap().unwrap();
        assert_eq!(saved.document.id, two.id);
        assert!(!saved.stale);
        assert_eq!(
            transcript_digest(&engine.transcript(&id).unwrap().unwrap()).unwrap(),
            before
        );
        assert_eq!(
            std::fs::read(engine.audio_path(&id).unwrap()).unwrap(),
            audio
        );
    }
    #[test]
    fn changed_source_or_competing_summary_keeps_prior_result() {
        let (_temp, mut engine, id, _) = setup();
        let source = engine.commit_transcript(&id, None, output()).unwrap();
        let one = engine
            .commit_summary(&id, draft(source.clone(), None, "첫 요약"))
            .unwrap();
        assert!(engine
            .commit_summary(&id, draft(source.clone(), None, "늦은 결과"))
            .is_err());
        engine
            .edit_transcript(&id, source.version.clone(), vec!["정정".into()])
            .unwrap();
        assert!(engine
            .commit_summary(&id, draft(source, Some(one.id.clone()), "오래된 원문"))
            .is_err());
        let saved = engine.summary(&id).unwrap().unwrap();
        assert_eq!(saved.document.id, one.id);
        assert!(saved.stale);
        assert!(engine
            .commit_summary(
                &id,
                draft(
                    engine.transcript(&id).unwrap().unwrap(),
                    Some(saved.document.id),
                    "  "
                )
            )
            .is_err());
    }
}
