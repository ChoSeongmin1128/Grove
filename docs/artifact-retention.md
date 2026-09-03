# Artifact retention

2026-09-03. AI-assisted notes; verify running processes, tracked/ignored status and actual
references before another cleanup. Only explicitly scoped regenerable artifacts may be removed.

## Keep

- Installed app and its active MOSS, Ultra8, Sortformer and Community-1 model caches.
- `results/native-workers`, source/patches/locks/licenses needed to package those workers.
- Original recordings, working reference annotations, raw outputs, scores, resource JSON,
  qualitative comparisons, inference scripts and model/config/version records.
- Pinned DiariZen upstream and Nemotron source checkouts. A folder called `runtime` can be
  source, not a disposable interpreter environment.
- Public repository contains code/docs/synthetic fixtures only. Private artifacts remain
  under ignored `results/` and `test-data/` and must never be staged by broad force-add.

## Cleanup procedure

1. Identify exact targets and check running processes, current packaging inputs and
   Git-tracked/ignored status. Never infer disposability from a directory name alone.
2. Preserve source, dependency locks, licenses and reproduction instructions before
   removing an interpreter environment or model cache used by research scripts.
3. Record private checksums and recovery locations locally. Do not publish artifact
   inventories that reveal recording counts, model results or private evaluation details.
4. Move only approved, regenerable targets to a dedicated recoverable Trash location.
   Do not follow symlinks into other caches or recordings. Moving to Trash is not proof
   that the corresponding disk space has been freed.
5. Verify retained inputs/workers and packaging references after cleanup. Document that
   removed environments/weights require recreation or download before research reruns.

## Publication boundary

Public documentation contains product behavior, reproduction methods, source versions,
licenses and validation limitations. Recording-derived metrics, resource receipts,
qualitative diagnoses and cleanup inventories remain under ignored local storage.
Before redacting a working note, preserve its unmodified copy under ignored
`results/publication-private-notes/`; redaction is not authorization to delete private evidence.
