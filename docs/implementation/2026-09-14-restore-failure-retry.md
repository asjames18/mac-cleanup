# Restore failures and reviewed retry

A restore rejected before the rename, or definitively rejected by rename with a destination collision, cross-volume error or access denial, now records a durable `failed` restore attempt with its reason. History labels this “Restore failed · not moved.” After the cause is resolved, the user can review a new plan and explicitly confirm it. The original plan no longer matches the journal and is rejected. Availability and new review still validate the recorded Trash identity and destination.

Unknown rename errors, errors after the move, and failures persisting the final outcome remain pending. They are not eligible for retry. If recording a known failure itself fails, the prior durable pending intent remains authoritative. Existing pending records are not reclassified based on assumptions about what happened.

The permission-denied fixture verifies a real rejected rename in a generated temporary directory, the persisted failure, rejection of the old plan, journal reload, and a successful explicitly reviewed retry after restoring fixture permissions. A separate fixture moves its generated file and then injects an I/O failure; the resulting pending record blocks review while the moved file remains intact. These tests do not use personal files or actual Finder Trash.

Validation: the full suite passed 141 tests with six optional integration checks skipped (147 discovered). A subsequent additional post-move uncertainty regression is covered by the targeted restore suite. The previously documented real Finder Trash access limitation remains open; default skipped integration checks are not evidence of successful real Trash recovery.

Final targeted restore run: 16 passed, one optional real Finder Trash integration skipped, zero failures. `./script/build_and_run.sh --verify` rebuilt and reopened MacSweep successfully; strict deep codesign verification passed for the local ad-hoc app.
