# Storage size map

Continues approved P3.1 storage visualization work. The explorer now offers List and Size Map views of the current search matches. The list remains the default and provides all entries, folder measurement controls and an alternative to tiles that are too small to label.

The map compares recorded allocated-byte weights: regular-file metadata and explicitly measured folder contents. It displays the twelve largest positive items plus a group for remaining positive items, preserving their combined weight. Folder tiles open that folder; file tiles reveal their file in Finder; the remaining-items tile returns to the list. All tiles have descriptive accessibility labels and tooltips. Small tiles omit visual text instead of overflowing.

Unknown or unsupported entries and zero recorded allocation are counted separately, never assigned invented areas. A partial folder measurement is marked partial; a partial zero measurement is unknown. Independent folder measurements and file metadata can count shared storage more than once, so the map does not represent unique disk allocation, guaranteed reclaimable space or an atomic snapshot. Measurement and listing coverage remain governed by the existing bounded readers. No new cleanup operation is introduced.

Map preparation occurs with background search, and results share its generation token. Refresh, navigation, query changes, exclusions and folder identity failures invalidate the map. A fresh measurement invalidates the previous recorded value before recalculating it. Tile geometry uses a bounded binary partition with normalized weights to avoid overflow from extreme finite inputs.

Validation includes proportional area, non-overlap, extreme/invalid weights, grouping conservation, unknown/partial handling, measurement-to-map updates and stale search rejection. A generated in-memory fixture was rendered in an owned NSHostingView window and visually inspected at `build/previews/storage-map/storage-map.png`: major tile labels, partial status and the separate unknown count were legible; a narrow tile correctly used its tooltip/accessibility label rather than overflowing text. This is a fixture layout check, not full VoiceOver or hardware interaction certification.

Full-volume indexing, APFS/cloud accounting, large-volume benchmarks, measured UI frame latency and broader accessibility interaction testing remain open. P3.1 and the full R01–R16 product scope are not marked complete by this increment.

The full suite passed before the final fresh-measurement invalidation: 185 discovered, 178 passed, seven optional checks skipped, zero failures (13.3 seconds), `build/diagnostics/storage-map-full-tests.txt`. After that correction, all 22 targeted storage tests passed with no skips or failures, `build/diagnostics/storage-map-final-tests.txt`. The optional real Finder Trash round-trip remains unverified; it was not rerun.

Final release build and launch succeeded through `./script/build_and_run.sh --verify` in 49.06 seconds; strict deep code-signature verification passed. Build evidence: `build/diagnostics/storage-map-build.txt`.
