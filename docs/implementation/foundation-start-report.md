# P1 foundation start — 2026-09-12

## Delivered

- Added public `MacSweepCore` library, app dependency, and `MacSweepCoreTests` target.
- Added public, immutable, Codable/Sendable `FileIdentity`, `FileSnapshot`, `TrashTarget`, and `TrashPlan`, plus `TargetValidation` and pure `TrashPlanValidator.validate(expected:current:)`.
- Identity uses the actual `lstat` device and inode (`st_dev` / `st_ino`), never a normalized or lowercased path. Hard-link fixture confirms identity survives different paths. Zero inode is rejected.
- `FileSnapshotReader.capture(_:) throws` accepts regular files and directories, records logical metadata size, modification and change timestamps, and performs no content read. Content digest is nil.
- `FileSnapshotReader.validate(expected:at:)` compares fresh metadata with the immutable scan snapshot; replacement and metadata changes require a rescan; failed/unsafe capture returns unavailable.
- Reader uses `lstat` for each parent and final component, rejects symlinks, unsupported types, non-file URLs, embedded NUL and parent traversal components. No FileManager attribute calls in production core.

## Observed test evidence

1. Added target and contract tests before implementing types. `swift test --filter MacSweepCoreTests` failed with missing `FileSnapshot`, `FileIdentity`, `TrashPlan`, and validator symbols.
2. Implemented contracts. `swift test --filter TrashPlanValidatorTests` passed 2 tests.
3. Added real filesystem fixtures before the reader. `swift test --filter FileSnapshotReaderTests` failed with missing `FileSnapshotReader`.
4. First reader run found 6 fixture failures because Foundation's `resolvingSymlinksInPath()` still returned `/var/folders/...` on this host. The strict reader correctly rejected `/var`, a symlink. Changed only trusted fixture-root setup to Darwin `realpath`; did not weaken candidate validation.
5. `swift test --filter MacSweepCoreTests` passed all 11 tests with zero failures at 22:02:47 local time. The test runner reports x86_64-apple-macos14.0. Covered stable file/directory, hard-link identity, same-size/same-mtime replacement, changed file, missing file, final symlink, parent symlink, symlink/.., invalid scheme, immutable-plan JSON roundtrip, and pure validator outcomes.

The replacement fixture retains the old inode under another name before creating the replacement, preventing inode recycling from making the test probabilistic. No user file was deleted; teardown only removes each test's own temporary fixture directory.

## Scope and limitations

This is the first identity/validation increment, not completion of P1. There is no durable operation journal, restore manifest, atomic mutation executor, or content verification yet. `TrashPlan` is immutable input, not mutation authorization. The app must continue independent protected-path and allowed-scope checks.

`lstat` checks and a subsequent Trash operation are not atomic. Concurrent parent substitution or target replacement after validation remains a TOCTOU risk. A directory snapshot describes the directory entry metadata, not all descendants; edits to existing descendants may leave the parent unchanged. The reader is metadata-only and cannot establish duplicate content equality. Digest-bearing expected snapshots conservatively differ from fresh metadata-only snapshots.

Device/inode identity is verified only on this host's fixture volume. Inodes can be reused and device IDs are not persistent volume UUIDs across remounts/reboots; network/removable/filesystem semantics are not certified by these tests. Timestamp conversion uses Foundation Date precision. Explicitly unsupported or untrusted filesystem semantics require additional policy before mutation. Broad OS/hardware coverage and final app integration/full regression verification remain with the parent task.

## Integration handoff follow-up

The final repeat after source-file rename encountered concurrent app compilation errors for unfinished `ScanLimit`, `ScanUpdate`, and `ScanSession` types. The compiler also exposed the app's `CleanupItem: Hashable` requirement; added synthesized `Hashable` conformance to `FileSnapshot` (which includes Equatable). No comparison semantics changed. Core-only test-target compilation is checked independently; parent task must rerun the linked tests once app integration settles.
