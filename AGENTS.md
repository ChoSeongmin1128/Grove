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
- Research-only work does not authorize replacing the installed app.
- Do not leave duplicate apps or generated artifacts in Downloads or `/Applications`.

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

- [`docs/handoff.md`](docs/handoff.md): current implementation state and next work.
- [`docs/open-source-local-meeting-apps-2026-09-02.md`](docs/open-source-local-meeting-apps-2026-09-02.md):
  local meeting app source review.
- [`docs/speaker-diarization-research-2026-09-03.md`](docs/speaker-diarization-research-2026-09-03.md):
  diarization model research and Grove evaluation plan.
- [`docs/app-v0.2-implementation-2026-09-02.md`](docs/app-v0.2-implementation-2026-09-02.md):
  historical v0.2 implementation notes; current code takes precedence.
