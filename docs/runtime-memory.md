# Runtime memory policy

This document describes the native source behavior, not an installed build or hardware
qualification. The policy lives in `apps/desktop/src-tauri/src/memory.rs`,
`summary_failure.rs`, `summary.rs` and `processing.rs`.

## OS observations

OS memory state is advisory. Warning, critical and unknown observations do not reject,
cancel, pause or reconfigure a summary. No application-defined RAM percentage threshold
is used. State changes are exposed separately from task progress and failure.

| Platform | Observation | Interpretation |
|---|---|---|
| macOS | `sysctlbyname("kern.memorystatus_vm_pressure_level")` | Best-effort private OS observation through an undocumented sysctl key, not a stable public memory-pressure contract. Recognized values map to normal/warning/critical. Failed reads, unexpected size or unrecognized values map to unknown. |
| Windows | `CreateMemoryResourceNotification(LowMemoryResourceNotification)` and `QueryMemoryResourceNotification` | Official system-wide available-physical-memory notification. Signaled maps to warning; not signaled maps to normal. Handle creation/query failure maps to unknown. |
| Other platforms | No observation provider | Unknown. This does not add inference-platform support. |

Normal means the observed warning is absent, not that a model allocation is guaranteed
to succeed. These signals do not measure all accelerator allocations or establish a
minimum supported memory size. Windows API semantics are documented by Microsoft:
[creation](https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-creatememoryresourcenotification),
[query](https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-querymemoryresourcenotification).

## Failures and recovery

Failure kinds separate cancellation, allocation, unavailable backend, unavailable engine,
protocol, input, output, storage and cleanup. Allocation/backend attribution matches
strict diagnostic forms from the pinned llama.cpp runtime. Free-form memory text, an OS
warning, SIGKILL or unexplained process death alone is not classified as OOM. HTTP and
response-validation failures retain their own failure categories.

| Failure | Recovery |
|---|---|
| Reported allocation failure or generic engine failure | Stop/reap the direct worker, then retry once with the same backend and settings. |
| Confirmed unavailable GPU backend, including a missing required loader/bundled GPU worker | Use the CPU route after any launched direct worker is stopped/reaped. This uses the same single retry budget. |
| Cancellation, protocol, input, output, storage or cleanup failure | No retry. |

The original job owns at most two attempts, with separate attempt folders/logs. Recovery
does not change the model, context, batch or generation-quality settings. CPU fallback
is not presented as a solution to memory exhaustion. Failed cleanup is not hidden by
cancellation or a failed diagnostic write: new processing/recording and successful
normal quit remain blocked when direct-worker termination cannot be confirmed.

## Cancellation and results

- Before retry, recheck cancellation. Recording start and normal quit cancel/join active
  processing before continuing; they do not launch a recovery attempt after cancellation.
- Final commit and accepted user cancellation share a boundary. If cancellation wins,
  no new summary is committed. Once commit begins, cancellation is rejected and
  recording/quit waits for the job's completion.
- Validate complete output and source-reference bounds before commit. Intermediate
  responses are job artifacts, not replacement summaries. The core rechecks the source
  transcript and expected current-summary identity before replacing the current result.
- Failed or cancelled generation preserves the original audio, transcript and prior
  summary. Unexpected parent-process/OS termination has no validated worker cleanup guarantee.

## Verification scope

Fake workers, injected memory observations and loopback responses exercise classification,
the retry limit, direct-worker reaping, cancellation/commit boundaries and preservation.
They do not establish real OS/GPU OOM recovery, actual Windows behavior, long-running
meeting stability or 8GB/16GB hardware qualification. Model quality and performance
remain separate acceptance work.
