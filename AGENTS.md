# Grove Agent Instructions

This file applies to the entire repository.

## Document trust

Documents under `docs/` are wholly or partly AI-assisted working notes. Read them
critically. Verify claims in this order:

1. the current user request
2. running app state, local files, logs, and measurements
3. current source code and tests
4. primary documentation and upstream repositories
5. Grove planning and handoff documents

If documentation and code differ, the code explains current behavior but does not
automatically define the correct product requirement. Separate verified facts,
inference, proposals, and unverified items.

## Product boundaries

- Grove is a general-purpose local macOS meeting recorder and transcription app.
- New recording is microphone-only. Do not reintroduce computer/system-output capture;
  file import and read-only compatibility with existing recordings remain supported.
- Do not hardcode organization names, project terms, people, or private meeting examples.
- User glossaries are optional machine-local profiles and never public defaults.
- Preserve original audio and raw transcripts. Store corrections, speaker assignments,
  and summaries as separate revisions.
- Keep source channel, anonymous speaker cluster, and confirmed human profile separate.
- Do not use ScreenCaptureKit or request screen-recording permission for an audio-only
  capture route.
- Do not expose internal implementation terms as the default user-facing language.

## Private data

- Never commit audio, video, transcripts, speaker labels, voice embeddings, licensed
  datasets, benchmark outputs, user glossaries, or local paths.
- Keep private fixtures under ignored `test-data/` and generated outputs under ignored
  `results/`.
- Before every public push, inspect `git status`, tracked files, and staged diffs for
  private names, paths, credentials, and media.

## Installation and artifacts

- The canonical installed app is `/Applications/Grove.app`.
- Validate tests, release packaging, code signing, and a smoke test before replacing it.
- An explicit user-approved local-beta exception may waive full UI QA. Record the
  exception and remaining limitations; never call unperformed checks a pass. Do not
  interrupt an active user test or overwrite the bundle they are running.
- Research-only work does not authorize replacing the installed app.
- Do not leave duplicate apps or generated artifacts in Downloads or `/Applications`.

## Git account and publication

- Grove commits and pushes use the personal `ChoSeongmin1128` account/repository.
- Use that account's public noreply commit identity; do not expose a private email or
  change global Git author settings for this project.
- After completing commit/push work, restore the active `gh` account to `nathan-glorang`
  and verify the switch. Do not leave the personal account active between tasks.
- Inspect the exact staged files and diff before every push. Raw/test meeting data,
  user libraries, local model files and generated result artifacts remain excluded.
- Personal-meeting-derived benchmark numbers and qualitative error analyses also stay
  private, even when names/audio have been removed. Public docs contain product behavior,
  generic methodology and upstream technical information, not private sample results.

## Work sequence

1. Read this file and `docs/handoff.md`.
2. Read only the task-relevant documents and verify important claims in code.
3. Distinguish research/review from implementation authorization.
4. Check migration compatibility before changing stored meeting data.
5. Add proportionate tests and run the relevant validation commands.
6. Update `docs/handoff.md` with results, remaining risks, and whether the installed app
   changed.

Default validation:

```bash
swift test
python3 -m unittest discover -s tests -v
./scripts/package_app.sh release
codesign --verify --deep --strict dist/Grove.app
```

## Document index

- [`docs/transcript-library-ux.md`](docs/transcript-library-ux.md): compact transcript rows,
  folder drag/drop and navigation, processing versus speaker-review states, explicit
  confirmation and schema-5 compatibility; distinct from dataset annotation.
- [`docs/recording-file-management.md`](docs/recording-file-management.md): recording title
  changes, original file export/path access, source protection and verification limits.
- [`docs/artifact-retention.md`](docs/artifact-retention.md): active app assets versus
  regenerable experiments; retained evidence and scoped cleanup.
- [`docs/review-mode-spec.md`](docs/review-mode-spec.md): planned native review workflow,
  edit/invalidation/undo matrix and phased completion gates; NOT implemented.
- [`docs/annotation-schema.md`](docs/annotation-schema.md): planned audio/model/correction/
  review/snapshot identities, timebases, content binding and migration.
- [`docs/labeling-guidelines-ko.md`](docs/labeling-guidelines-ko.md): planned Korean
  verbatim labeling, uncertainty, overlap and independent completeness rules.
- [`docs/dataset-export.md`](docs/dataset-export.md): planned backup versus approved dataset,
  immutable snapshots, RTTM/UEM, permission and development/holdout separation.

- [`docs/ultra8-option-and-speaker-count.md`](docs/ultra8-option-and-speaker-count.md):
  Ultra8 automatic-default policy, count boundaries, same-engine comparisons, native worker
  and historical engine provenance.

- [`docs/microphone-folders-and-speaker-reuse.md`](docs/microphone-folders-and-speaker-reuse.md):
  microphone-only recording, pause/resume, per-file options, folders, manual speaker
  reuse, and the evidence-based hold on automatic voice identity matching.

- [`docs/release-readiness.md`](docs/release-readiness.md): requirement-by-requirement
  completion audit, pending authorization/runtime gates, and installation resume sequence.

- [`docs/grove-v0.3-implementation-plan-2026-09-03.md`](docs/grove-v0.3-implementation-plan-2026-09-03.md):
  approved v0.3 scope, typography, speaker/text editing, export, and engine-validation gates.
- [`docs/handoff.md`](docs/handoff.md): current implementation state and next work.
- [`docs/open-source-local-meeting-apps-2026-09-02.md`](docs/open-source-local-meeting-apps-2026-09-02.md):
  local meeting app source review.
- [`docs/speaker-diarization-research-2026-09-03.md`](docs/speaker-diarization-research-2026-09-03.md):
  diarization model research and Grove evaluation plan.
- [`docs/app-v0.2-implementation-2026-09-02.md`](docs/app-v0.2-implementation-2026-09-02.md):
  historical v0.2 implementation notes; current code takes precedence.
