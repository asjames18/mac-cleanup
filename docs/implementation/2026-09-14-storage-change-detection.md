# Storage folder change detection

The explorer now captures a directory stamp (device/inode/birth time plus modification/change timestamps) before reading. It rechecks the pinned descriptor and reopens the path without following symlinks before returning. A replaced/moved root or substituted ancestor is rejected with a refresh message. Changes to the same directory's contents retain useful entries but mark the listing partial.

Recursive measurement carries each discovered directory identity into its later read so a replacement cannot silently be measured as the original subfolder. Changed/unreadable descendants contribute skipped/partial coverage. The starting root is checked again at the end: replacement rejects the total, while changed root contents mark it partial. Folder-identity errors also clear cached explorer results and totals before asking for refresh. Hard-link identities now include birth time as well as device/inode.

Four deterministic fixture tests cover root replacement after listing, changed contents returning a partial listing, replacement between discovery and descent, and an ancestor swapped to a symlink. The full suite passed 169 tests with six optional checks skipped (175 discovered), zero failures. A final targeted storage rerun follows the cache-clearing UI adjustment.

These are endpoint identity/change checks, not an atomic snapshot. Changes after verification, file-content edits that do not change a directory timestamp, and descendant changes after that descendant was checked can still affect live totals. Broader snapshot semantics, large-tree benchmarks and volume/platform acceptance remain open. No personal files were modified; all mutation tests use generated temporary fixtures.

Final targeted storage run passed all 14 tests with no skips/failures. `./script/build_and_run.sh --verify` rebuilt and reopened MacSweep; strict deep signature verification passed for the local ad-hoc app.
