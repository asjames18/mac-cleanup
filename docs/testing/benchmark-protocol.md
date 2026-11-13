# MacSweep scan benchmark protocol

Status: initial P0 protocol, September 12, 2026. This document defines reproducible measurements; it contains no benchmark results. Do not run the 100,000- or 1,000,000-entry cases, scan unrelated user data, or perform cleanup as part of creating this protocol.

## Purpose and gates

The protocol measures scan responsiveness, cancellation, completion cost, resource use, permission handling, and event correctness. It is intended to catch the reported failure mode in which Quick Scan spends many minutes traversing storage before showing a result.

A benchmark run is valid only when it records the source revision, build configuration, fixture manifest/checksum, machine and OS details, volume format/case sensitivity, power state, permission state, warm-up policy, run count, raw event log, and measurement tool/version. Results from unlike environments must be reported separately rather than averaged together.

Quick Scan has a hard regression gate: **it must not start or traverse an unrelated storage-inventory root**. This is a structural and instrumented assertion, independent of elapsed time. A fast accidental storage traversal still fails.

## Safety boundary

- Generate fixtures only beneath a newly created benchmark temporary root whose exact path is recorded.
- Use synthetic files and directories. Do not point the harness at `$HOME`, user libraries, cloud folders, browser profiles, application data, or other user content.
- Benchmark scan and read-only validation paths only. Disable Trash, quarantine, uninstall, remote deletion, and permanent deletion operations.
- The fixture owner may remove the exact generated root after validating its path and manifest. Cleanup of user data is outside this protocol.
- Run expensive cases only in an explicitly scheduled benchmark session. The 1,000,000-entry case requires a disk-space preflight and an abort threshold.

## Reproducible fixtures

Implement a deterministic fixture generator as a test/benchmark utility before collecting results. It must accept `--root`, `--entries`, `--seed`, `--shape`, and `--permission-profile`, refuse non-empty or unsafe roots, and emit a JSON manifest. Use fixed seed `0x4D535750` for the standard suite.

The manifest records generator version, seed, requested/created counts, tree shape, file-size distribution, logical and allocated bytes, duplicate groups, symlinks, protected-name sentinels, old/recent modification dates, permission cases, generation time, and a checksum over the sorted relative-path/type/size plan. Paths are relative to the fixture root.

Create two standard scales with the same distributions:

| Fixture | Entries | Shape and content |
|---|---:|---|
| F100K | 100,000 | 80% regular files, 19% directories, 1% links/special test entries; maximum depth 12; a mix of broad and deep subtrees. Regular files are mostly 0–4 KiB sparse/deterministic payloads, with deterministic 1–4 MiB samples and duplicate groups large enough to exercise hashing. |
| F1M | 1,000,000 | The same seeded ratios and depth policy scaled to one million entries. Payload allocation must remain bounded and reported; abort generation if the preflight reserve would be crossed. |

For each scale, expose distinct roots representing eligible cleanup content, unrelated storage-only content, duplicate candidates, recent/protected content, unreadable content, and custom roots with an intentional overlap. Include deterministic changed-file and replaced-link variants for action-time validation, though this protocol does not execute cleanup.

Permission cases should include readable content, an unreadable subtree where the executing environment can produce `EACCES`, and a control case where permission simulation is unavailable. If root/admin execution or the host filesystem defeats the denial, mark that case unavailable; do not report it as passed.

## Build and run controls

1. Record `git rev-parse HEAD` plus whether the tree is dirty, Swift version, configuration, app/test binary checksum, `sw_vers`, `uname -a`, hardware model, logical CPU count, physical memory, filesystem type, free space, power source, and relevant privacy permissions.
2. Build once outside timed regions. Use a release build for product budgets; use a separately labeled instrumented build for event assertions. Never combine debug and release samples.
3. Close unrelated high-load work, keep power and thermal conditions stable, and record exceptions. Do not disable macOS security features.
4. Run one untimed warm-up when the scenario specifies warm cache. Run cold-cache scenarios only with a documented, safe method; a reboot is acceptable, unsupported cache-purge commands are not.
5. Run at least five measured repetitions per F100K scenario and three per F1M scenario. Preserve every sample and report median, p95 when meaningful, minimum, maximum, and failures. Never discard an outlier without retaining it and stating the reason.
6. Give every run a UUID. Correlate the process/resource sample, scan events, cancellation request, and final state with that ID.

## Scenarios and measurements

| Scenario | Required measurements and assertions |
|---|---|
| Quick / unrelated storage root | Put the eligible Quick roots and the unrelated storage-only root in the fixture. Assert zero storage-stage starts, zero entries visited under the unrelated root, and empty storage inventory. Measure time to first result/event, cancel latency, and full completion. |
| Quick / F100K | Measure time to first result, stage transitions, entries and bytes examined, partial/final coverage, full completion, wall time, CPU time/utilization, peak resident memory, and permission errors. |
| Quick / F1M | Repeat the F100K measurements with preflight/abort limits. This is an explicitly scheduled scalability run, not a routine test. |
| Analyze Storage / F100K and F1M | Run as an independent job. Measure first result, progressive result cadence, coverage, unreadable counts, cancellation, full completion, logical/allocated totals where available, CPU, and memory. Confirm that no cleanup candidates are selected or acted on. |
| Duplicates / deterministic groups | Measure discovery, hash bytes/time, first confirmed group, cancellation during hashing, final exact-group correctness, and memory. Verify logical-size grouping and changed/replaced fixture signals without moving files. |
| Permission failures | Scan the readable, denied, and unavailable-simulation controls. Assert completion or cancellation without hang; explicit error/coverage events; no invented counts for unreadable content; and no permission escalation attempt. |
| Cancellation points | Request cancellation before traversal, during enumeration, during hashing, and after a partial result. Measure request-to-worker-stop and request-to-final-state latency; assert no stale event/result is published after terminal cancellation. |

For every scenario report three user-visible latency measures separately:

- **Time to first result:** scan-start monotonic timestamp to the first non-terminal, user-presentable result or explicit coverage event. A spinner-only update is not a result.
- **Cancellation latency:** cancellation-request timestamp to confirmed worker stop and terminal cancelled state. Record both if they differ.
- **Full completion:** scan-start timestamp to terminal event after all promised results and coverage totals are published.

Measure resource cost with a sampling interval of 100–250 ms and state the interval. Record process CPU time, sampled CPU percentage, peak and median resident memory, peak thread count, and I/O logical/physical bytes when the chosen macOS tool exposes them reliably. Keep raw samples. Instruments/signposts are preferred for stage attribution; `/usr/bin/time -l` or equivalent process statistics may supplement them. Tool overhead must be identified by comparing instrumented and release runs.

## Instrumentation contract

Emit structured events to a local benchmark sink. Paths must be fixture-relative or one-way redacted; logs must never contain unrelated user paths. Use a monotonic clock for durations and wall-clock time only for correlation.

Common fields: `schema_version`, `run_id`, `scan_id`, `event_sequence`, `timestamp_monotonic_ns`, `event_name`, `preset`, `stage`, `fixture_id`, `build_id`, and `terminal_state` where applicable.

Required events and metrics:

| Event | Required metrics |
|---|---|
| `scan_started` | requested modules/roots count and preset |
| `stage_started`, `stage_finished` | stage name, elapsed time, outcome |
| `traversal_progress` | entries/files/directories visited, logical/allocated bytes examined, roots started/completed, current coverage state |
| `result_published` | result kind, cumulative result count/bytes, latency since start; no absolute user path |
| `permission_error` | operation, error domain/code, affected fixture-relative root, skipped entry/root count |
| `hash_progress` | files and logical bytes hashed, failures, elapsed hashing time |
| `cancel_requested`, `worker_stopped` | request/stop timestamps, active stage, cumulative work, latency |
| `scan_finished` | success/cancelled/failed, full elapsed time, final counts/bytes, complete/partial coverage, unreadable/skipped/error totals |
| `stale_event_rejected` | originating scan ID, current generation ID, event type and count |

Validate event sequence numbers, exactly one terminal state, monotonic cumulative counters, no results after a terminal event, no old-generation publication, and agreement between final metrics and the fixture oracle for fully readable runs. Sampling/backpressure behavior must be defined so progress instrumentation cannot grow without bound or dominate traversal time.

## Result record and comparison

Store one machine-readable JSON/JSONL record per run plus a short Markdown summary. The summary identifies the candidate and baseline revisions and shows per-scenario median/p95 first-result, cancellation, completion, peak RSS, CPU time, visited entries, permission errors, and outcome. Attach raw event/resource logs and the fixture manifest checksum.

Treat a result as a regression when a correctness assertion fails, Quick Scan touches the unrelated storage root, cancellation or first-result budgets are exceeded, a run hangs/times out, memory grows without a documented bound, permission errors disappear from coverage, or repeated measurements materially worsen against the pinned baseline. Numeric budgets and allowed variance must be set from the first controlled baseline and product UX targets, reviewed, and then versioned; this protocol does not invent passing numbers before measurement.

## Current evidence and next use

The opening scan-recovery note records a real local Quick Scan at roughly 91.5% CPU after about 21 minutes, with repeated ancestor metadata checks under `scanStorage`/`storageUsage`, and no intermediate results. That observation motivates the scenarios but is not a controlled benchmark result.

The repository's new Quick Scan storage-separation regression test belongs to the active recovery increment. It should be run with the normal test suite and then backed by the instrumented fixture assertion above. Neither that test nor upcoming scanner changes count as completed benchmark evidence until their revision, environment, raw result, and outcome are recorded.
