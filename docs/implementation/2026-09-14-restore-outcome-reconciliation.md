# Reviewed restore-outcome reconciliation

A restore can move its item successfully and then fail before recording completion. History previously left that operation pending indefinitely, even when the expected item was present at the exact recorded destination. This increment adds an explicit Verify Restore Outcome action for pending restores, followed by a confirmation sheet that updates History only.

Review reads the durable record and verifies the destination against the recorded Trash object's device, inode, birth time, object type, size and modification time. The former Trash path must be absent, established with descriptor-relative `fstatat` and ENOENT, rather than a boolean existence check. Both parent paths are traversed without symbolic links and rechecked for identity. Review captures the current destination snapshot without changing the journal.

Confirmation acquires the same process/cross-process journal lock used by restore execution, rereads the exact reviewed entry, repeats endpoint verification and requires the observed snapshot to remain identical. Only then does it mark the restore completed and save a reconciliation timestamp. It does not move, delete, copy or overwrite any file. A changed record, changed object, occupied former Trash path, inaccessible endpoint or unsupported path remains unresolved. Successful reconciliation clears the record's pending conflict gate; future removals still require their normal fresh review.

These are checks of current endpoints, not an atomic filesystem snapshot or proof of every past change to a folder's descendants. Records without a pending restore and known destination are not eligible. Uncertain initial cleanup moves remain pending and still require a separate recovery workflow. Permission-denied locations remain unsupported until accessible; no permissions were changed during development.

History review uses its existing cancel/timeout worker gate and discards late confirmation plans. Saving a reviewed outcome uses the mutation path; a UI refresh follows it. History shows the verification date. The optional timestamp preserves decoding of older records, and journal validation rejects a reconciliation timestamp on a non-restored attempt.

## Verification

- Full suite after integration: 188 discovered, 181 passed, seven optional checks skipped, zero failures, 13.8 seconds (`build/diagnostics/restore-reconciliation-full-tests.txt`).
- Added a History workflow test after that run: canceling review leaves pending unchanged; confirming a fresh review updates the row and preserves file contents. Final combined History/restore suite: 24 discovered, 23 passed, one optional check skipped, zero failures (`build/diagnostics/restore-reconciliation-final-tests.txt`).
- Core fixtures simulate a move followed by an I/O error before completion. Checks cover read-only review, successful journal-only reconciliation, stale-plan rejection, changed content, occupied endpoints, symlinks, and pending conflict release after verified completion.
- All mutations used generated temporary fixtures. The optional real Finder Trash round-trip was not rerun; the previously recorded host permission limitation remains unverified. The app UI interaction and VoiceOver paths were not certified by these model-level tests.

The full R01–R16 product remains incomplete. This does not claim general recovery for unknown cleanup outcomes, automatic retry, immutable filesystem snapshots, full release certification or a defect-free product.

Final release build and launch succeeded in 75.44 seconds through `./script/build_and_run.sh --verify`; strict deep signature verification passed. Log: `build/diagnostics/restore-reconciliation-build.txt`.

## Follow-up review: retain reviewed parent identities

A targeted replacement fixture exposed a gap in the first implementation: both parent identities were checked within each verification pass, but not retained between review and confirmation. Replacing the empty former Trash parent after review could therefore still accept the old plan. The regression failed before the change (confirmation unexpectedly succeeded and the record became restored).

The immutable review now retains both parent snapshots. Confirmation compares their object identities against the reviewed identities, as well as repeating the existing within-pass checks. The same fixture now leaves the record pending and preserves file contents. Verification errors also distinguish a missing restored destination, an occupied former Trash location and changed destination metadata; they no longer misidentify the restored destination as the Trash item.

Final targeted History/restore/journal verification: 34 discovered, 33 passed, one optional real-Trash test skipped, zero failures (`build/diagnostics/reconciliation-review-final-tests.txt`). This closes the demonstrated review-to-confirmation parent-replacement gap; endpoint checks still do not constitute an atomic filesystem snapshot.

Follow-up release rebuild/relaunch succeeded in 55.21 seconds and strict deep signature verification passed (`build/diagnostics/reconciliation-review-build.txt`).
