# Managed-container cleanup eligibility

Reported failure: a Chess related-file scan offered ~/Library/Containers/com.apple.Chess as selectable, then Trash validation rejected it as a protected path or link.

Read-only inspection found the container's standard external aliases to Music, Pictures, Desktop, Downloads, Keychains, Mail and other personal/system-managed locations. Reading its container-manager metadata returned Operation not permitted. Whole-container reset/removal is not a supported MacSweep operation; this fix does not relax protection or claim that macOS containers are universally undeletable.

Changes: managed Containers and Group Containers results retain visibility with an explicit unavailable reason, disabled selection and unmeasured size. Bulk selection and the final selected-target list exclude unavailable items, including stale selected flags. The backend returns the same specific restriction before attempting access or mutation. Supported non-container caches/preferences/logs remain eligible under existing safety validation. Apple app uninstall controls are disabled to match existing backend policy.

Verification: regression tests cover managed-container classification, supported paths, bulk and individual selection, stale selections, backend rejection text and an opt-in read-only scan of the reported Chess container. No user files were deleted. The unrelated real inventory/Quick Scan/OnVUE checks remain opt-in.

Final verification: MACSWEEP_CHECK_CHESS=1 swift test completed with 79 passing tests, zero failures and three unrelated opt-in checks skipped. The actual Chess-container read-only check passed. Release build/launch verification and ad-hoc signature verification succeeded. MacSweep was reopened. No user files were deleted.
