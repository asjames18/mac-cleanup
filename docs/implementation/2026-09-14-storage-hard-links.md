# Hard-link accounting in main storage analysis

The main storage scanner previously counted every regular-file path. A generated fixture confirmed that adding a second hard link doubled both its file count and allocated total. Analysis now counts each device/inode/birth-time identity once per analyzed root, bringing this aspect into line with the folder explorer's existing measurement behavior.

A regular-file metadata helper opens parent components with O_NOFOLLOW and uses fstatat with AT_SYMLINK_NOFOLLOW for the leaf. Identity and allocation come from that same stat result. It never reads file contents, follows leaf links or opens special files. Invalid identity/type/allocation and failed reads contribute to partial coverage. Allocated bytes use st_blocks × 512, with overflow checks on individual entries and accumulation. This adds metadata I/O; no throughput improvement is claimed.

The UI labels unique file counts and explains that folder totals may overlap and shared blocks are not guaranteed reclaimable space. Deduplication is per root, not across independently displayed roots. APFS clones with distinct identities can still share blocks; the scanner remains a live metadata traversal, not an atomic filesystem snapshot or complete volume allocation model. Existing hidden/package/protected exclusions remain.

The hard-link regression failed before the fix and passed afterward. Added direct metadata checks reject symlinks/FIFOs and preserve sparse-file logical size and identity. Final full suite: 201 discovered, 194 passed, seven optional checks skipped, zero failures, 12.1 seconds (`build/diagnostics/storage-hardlink-full-tests.txt`). No personal files were modified. Real-volume accounting certification and the complete storage/product roadmap remain open.

Release rebuild/relaunch passed in 48.96 seconds, with strict deep signature verification passing (`build/diagnostics/storage-hardlink-build.txt`).
