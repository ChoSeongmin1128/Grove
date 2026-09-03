# Ultra8 default policy and speaker-count controls

2026-09-03. AI-assisted notes; verify against source, tests and current user intent.

## User decision

After the selectable beta.5 release, the user approved Ultra8 as
the automatic default: no entered count or 1–8 uses MOSS + Ultra8; 9+ uses MOSS +
Community-1 with an exact count. Sortformer streaming remains manually selectable.
This supersedes the earlier option-only product decision. It is a user-approved beta
policy, not a published model-quality ranking.
Preserve microphone-only capture, file import, pause, folders and manual speaker reuse.
No system capture or automatic voice identity matching is reintroduced.

## Selection contract

New recording, file import and reprocessing have an engine picker inside that recording's
options. Persistent defaults remain in Settings, not in an always-visible toolbar.

| Engine choice | Automatic speaker count | Entered speaker count |
| --- | --- | --- |
| Automatic engine selection | Ultra8; explicitly warn that unknown-count processing supports at most eight | Ultra8 advisory for 1–8; Community-1 exact for 9+ |
| Sortformer streaming | Up to four output speakers | Advisory only; >4 rejected |
| Ultra8 | Up to eight output speakers | Advisory only; >8 rejected |
| Community-1 | Estimate count | Pass `--num-speakers N` as an actual constraint |

Capacity is not an exact-count hint. Ultra8 has no oracle-count input; changing eight
output columns to four or discarding extra speakers would not constitute an exact-four
model test. No such clipping/reclustering is implemented.

The automatic selection intent is preserved as `.automatic` when saved. Legacy settings
without an engine field default to automatic. Explicit choices stay fixed when counts
change. Legacy unknown-count Sortformer records retain Sortformer without inventing four.
Actual engine provenance belongs to the transcript revision, separately from next/failed
job settings, so a failed Ultra8 retry cannot relabel an old transcript as an Ultra result.

Stored raw results are validated against their recorded actual engine when their intent
was automatic. They must not be reinterpreted by today's automatic routing. Explicit
engine mismatch, impossible capacity and unsupported exact-count combinations remain
errors. Legacy automatic settings adopt the new policy only when a new job is requested;
existing results, corrections, raw outputs and manually chosen engines are not migrated.
An existing exact-count configuration continues to resolve to Community-1 until the user
reopens/reconfirms automatic per-recording options under the new policy.

## Native worker

- Pinned ONNX revision/checksum are in `Ultra8Model.swift`.
- The app uses local `Models/Ultra8/<revision>/` storage, not a private research folder.
- Headless helper: `grove-ultra8 INPUT_WAV MODEL_ONNX OUTPUT_JSON`; CPU provider.
- Engine invocation shares the existing cancellation/process isolation and audio
  normalization. No network inference or model auto-download is introduced.
- Missing helper/model, wrong checksum, >8 speakers, unsupported exact-count policy,
  mismatched metadata, noncanonical labels and incomplete duration fail explicitly.
- Postprocessing is the frozen official NeMo default (0.5 threshold, no median,
  padding or minimum duration). Research CallHome+median output is not substituted.
- Source, pinned dependency lock, patches, build instructions and notices are in
  `scripts/native-ultra8-harness/`. The app includes its executable and collected
  runtime notices; weights stay in the local model cache.

## Validation limits

The user's beta default decision is not an accuracy guarantee.
Eight-speaker architecture does not establish Korean meeting accuracy. Native NeMo
to ONNX numerical parity and long-file memory qualification remain separate. Upstream
preprocessing loads the recording into memory; the helper runs outside the UI process.

For count-effect evaluation, keep ASR text fixed and compare automatic versus constrained
conditions within the same diarizer. Alternate run order and report speaker confusion,
overall diarization error, combined transcript error and resource use separately.
Ultra8/Sortformer have no exact-count condition; do not fabricate one by clipping output.

Private recordings, references, per-recording diagnostics, derived metrics and resource
receipts remain in ignored local storage and are not part of the public documentation.
Consult handoff/release-readiness for actual installation status, not this design note.
