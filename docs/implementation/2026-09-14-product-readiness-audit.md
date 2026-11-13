# Product readiness audit — September 14, 2026

Starting revision: `f362555`. This is a current source audit against R01–R16 in the product specification, not a release certificate. Previous goal work made progress (committed eligibility correction with test/build evidence). The complete-product goal remains active.

## Findings that determine the next work

1. **Related-file discovery can still stall and hide missing coverage.** `AppScanner.scanLeftovers` calls `contentsOfDirectory`, recursively measures each match without a time/entry budget, and suppresses root errors with `try?`. The model has a 305-second watchdog but no incremental related-file results. Current increment: bounded report, progress, explicit incomplete measurement, and selection consistent with inspection.
2. **Duplicate hashing trusts an open path too much.** `CleanerScanner.sha256` opens through FileHandle without checking regular-file type or comparing identity and metadata before/after hashing. Current increment: descriptor-based stable hashing with cancellation and fixture coverage for links, special files and mutation.
3. **Application removal does not yet satisfy the shared reviewed-plan contract.** `CleanupSafety.validateApp` rereads Info.plist with unbounded `Data(contentsOf:)`, validates bundle identifier and top-level parent, but does not carry inventory-time file identity through review. `uninstall` moves the bundle without the recursive validator used by generic cleanup. Nested app discovery also exceeds the current top-level uninstall scope. Next P1/R06 increment must unify inspection and action eligibility, bounded metadata, immutable identity checks, and supported nested-root policy. Do not claim a matching bundle identifier proves it is the reviewed app.
4. **Related-file actions do not yet carry scan snapshots.** `AppLeftoverItem` lacks an identity snapshot and the support cleanup calls `trash` without `allItems`; generic structural validation alone cannot establish scan-to-action continuity. Address with the same typed reviewed-plan work.
5. **Recovery is still manual.** `HistoryView` reads durable records and reveals a recorded destination; it neither verifies that the object still exists nor offers identity-checked restore. Pending reconciliation, collision refusal, alternate destinations, retention and export remain P1/R15 work.
6. **Path comparisons are not volume-aware.** `ProtectionRules.contains` and `CleanupSafety.uniqueURLs` lowercase paths. Conservative protection is intentional, but selection/deduplication must not conflate distinct case-sensitive-volume objects. Hard-link-aware duplicate accounting also remains missing.
7. **Storage is a summary, not an explorer.** `StorageView` renders folder bars and Finder reveal only. Package exclusions mean it does not measure all installed content. No drill-down, volume accounting or logical/allocated comparison is present.
8. **Startup metadata has the same unbounded-read pattern.** `StartupScanner.readDefinition` uses `Data(contentsOf:options:.mappedIfSafe)` and its store has cooperative cancellation but no independent access watchdog. Reuse bounded regular-file metadata reading and a controlled job lifecycle before adding direct startup operations.

## Requirement-by-requirement evidence

| Requirement | Current authoritative source/evidence | Completion finding and required proof |
|---|---|---|
| R01 orchestration | `AppModel`, `ScanSession`, scan responsiveness tests | Limited. Bounded jobs exist; selected modules and structured scope coverage require implementation and end-to-end cancellation/permission evidence. |
| R02 cleanup | `CleanerScanner`, `CleanupSafety`, cleanup fixture tests | Limited. Need versioned adapter/rule catalog, app-closure policy, exclusions persistence and complete reviewed-plan validation. |
| R03 storage | `StorageView`, `CleanerScanner.analyzeStorage` | Limited. Need tree navigation, independent traversal policy, coverage and APFS/volume accounting tests. |
| R04 duplicates | `scanDuplicates`, `sha256`, `validateDuplicates` | Limited. Stable hashing work underway; hard links, identity across review, adjustable minimum, scalable benchmarks and retained-copy UX remain. |
| R05 similar images | No similarity provider or comparison view in Sources | Missing. Need local image processing, review UI and validated grouping quality. |
| R06 apps | `AppScanner`, `ApplicationsView`, `CleanupSafety.validateApp` | Limited. See findings 1/3/4; ownership graph, supported reset and verified update catalog remain missing. |
| R07 startup | `StartupScanner`, `MaintenanceStore` | Limited. Reads definitions; no observed enabled state or reversible supported management. |
| R08 maintenance | `MaintenanceStore` | Limited. Current actions open Apple tools/settings; an allowlisted operation engine and recovery do not exist. |
| R09 monitoring | `SystemMonitor`, `SystemMetrics`, metric tests | Limited. CPU/memory/disk exist; trends, battery/thermal/network, notifications and multi-machine checks remain. |
| R10 privacy | No browser adapter in Sources | Missing. Disposable-profile feasibility, profile/category handling and closed-browser execution required. |
| R11 on-demand protection | No provider or quarantine target in Package.swift/Sources | Missing. Maintained provider, definitions integrity, verdicts, quarantine/restore and evaluation required. |
| R12 real-time protection | No extension target | Missing; separately gated optional expanded protection under the spec. Never count on-demand detection as real-time. |
| R13 cloud | Protected known cloud roots in `ProtectionRules` | Missing management. Exclusions do not implement provider-aware local eviction or prove no hydration. |
| R14 scheduling | `MacSweepApp` has user-triggered launch flags only | Missing. Persisted opt-in scan schedule, sleep/wake, cancellation and reminder behavior required. |
| R15 recovery | `CleanupJournal`, journal tests, `HistoryView` | Limited. Durable intent/outcome exists; restore, availability, reconciliation and lifecycle remain incomplete. |
| R16 release | `Package.swift`, build scripts, local launch evidence | Limited. Ad-hoc local app only; signing/notarization, signed updater, accessibility, diagnostics/support and tested platform matrix required. |

## Execution order

Finish and verify the two concrete scan/hash defects above; then implement the shared identity-aware app/support review contract and recovery before expanding cleanup actions. Continue the original roadmap through storage/duplicates, app ownership and supported operations, monitoring/scheduling, privacy, maintained protection and cloud feasibility, then release validation. These dependencies preserve the full product scope rather than treating disabled controls as feature completion.

The existing benchmark protocol remains unfulfilled: no controlled F100K/F1M fixture measurements or multi-OS/hardware certification are established by normal unit tests. The current work must pass targeted regression tests, the full suite, and a local release build/launch. Those checks establish this increment only; zero remaining product issues is not proven.

## Next P1 acceptance cases

- Replace an inventoried app with a different inode carrying the same bundle identifier after review; execution must refuse it and retain the replacement.
- Replace a support file after discovery; cleanup must report needs-rescan and leave it in place.
- Substitute the selected app's Info.plist with a FIFO, oversized file or symlink; validation must return a bounded explanation before any move.
- Review a nested app in an inventoried supported root; eligibility shown in the UI must agree with execution, including running/system/self restrictions.
- Recover a generated Trash fixture into its original location, refuse an existing destination, and explain a missing or replaced Trash object without overwriting anything.
- Restart with a pending operation and ambiguous source/destination state; show an unresolved outcome without replaying a mutation.

Local environment inspected during this audit: macOS 26.6 (25G5065a), Intel x86_64, Apple Swift 6.3.2. This does not establish runtime compatibility on other machines or OS versions.
