# MacSweep capability and support matrix

Status: initial P0 baseline, September 12, 2026. This is an implementation inventory, not a release claim. It records the repository at the opening of the scan-recovery increment; work added during that increment remains unvalidated until its acceptance evidence is recorded.

## Scan-recovery update

The first implementation increment now separates storage analysis, streams cleanup candidates and progress, applies cooperative scan limits, labels partial coverage/read errors, and checks scan-time file identity before cleanup. The core library includes immutable Trash-plan contracts. Acceptance measurements and limits are recorded in [scan recovery evidence](../implementation/2026-09-12-scan-recovery.md). R01–R16 remain Limited or Blocked: this increment does not complete their full roadmap requirements. The table below retains the opening baseline for comparison.

## September 13 implementation update

Application inventory now returns metadata incrementally from the declared app roots and bounded nested folders, with unmeasured sizes and explicit coverage. Application/related-file jobs share timeout/cancel lifecycle protection. P1 includes an operation journal integrated with Trash plus a History page; in-app restore, journal migration/archival, structured permission records and platform certification remain incomplete. See [increment evidence](../implementation/2026-09-13-app-inventory-history.md). R01/R06/R15 remain Limited; the opening baseline table below is historical.

## Status terms

Later September 14: [reviewed removal and recovery evidence](../implementation/2026-09-14-reviewed-removal-restore.md) adds scan identity through app/support review, background preflight, bounded metadata, and same-volume History restore for verified objects. Old records remain manual when identity is unavailable; real Finder Trash integration is still access-blocked on the test host. R06/R15 remain Limited.

September 14: [current requirement-by-requirement audit](../implementation/2026-09-14-product-readiness-audit.md) records the remaining full-product work. [Related-file scan and stable hashing evidence](../implementation/2026-09-14-scan-hashing-reliability.md) covers bounded progressive leftover scans, incomplete measurement eligibility, effective permissions, stale coverage fixes and descriptor-based hashing. R01/R04/R06 remain Limited; this is not complete-suite acceptance.

- **Built:** the required outcome is implemented end to end in the current baseline. This does not imply validation on every supported platform.
- **Limited:** a useful part exists, but one or more required outcomes, safety properties, or validation gates are missing.
- **Blocked:** no supported implementation of the required outcome exists. A shortcut to another app does not count as implementation.

No R01–R16 capability currently satisfies its complete roadmap outcome, so none is marked built.

## Capability baseline

| ID | Status | Existing baseline | Missing before roadmap acceptance |
|---|---|---|---|
| R01 Smart Care orchestration | Limited | Quick, Deep, Developer, and Duplicates Only presets produce cleanup and storage results; scans run off the main actor and reject stale final results; cancellation is cooperative. | The baseline runs storage traversal before publishing a final report, exposes no incremental results or stage/coverage model, and can appear stuck. The scan-recovery increment proposes separation, progress, partial results, and bounded traversal; those changes are not baseline evidence. |
| R02 Cleanup | Limited | Finds several user-cache, log, download, temporary, Xcode, large-file, and custom-folder candidates. Results start unselected; reviewed targets are revalidated and moved to Finder Trash. Protected roots, symlinks, recent descendants, and nested selections receive safety handling. | Rules are not versioned or expressed as supported-app adapters. Coverage, exclusions, app-closure requirements, allocated-space limits, durable outcome records, and broad rule validation are incomplete. |
| R03 Storage explorer | Limited | Summarizes readable common/custom folders with allocated-size estimates and file/folder counts, ranks results, and reveals items in Finder. The UI acknowledges incomplete accounting. | No independent analyze-storage job in the opening baseline, drill-down/search, volume model, logical-versus-allocated comparison, structured unreadable coverage, APFS-specific limits, or large-fixture performance evidence. |
| R04 Duplicates | Limited | Candidate files are grouped by logical size and SHA-256. Roots are deduplicated, one copy is retained, results start unselected, and retained/target content is rehashed before Trash. | No user-adjustable minimum size, durable file identity/snapshot, complete changed-file plan validation, scalable benchmark evidence, or fully specified cross-category review behavior. |
| R05 Similar images | Blocked | No local image-similarity grouping or comparison UI is present. | Local similarity pipeline, side-by-side review, suggestion semantics, performance/quality validation, and deletion safeguards. |
| R06 Application management | Limited | Inventories `/Applications` and `~/Applications`; shows metadata and possible support files; blocks running, Apple, self, symlinked, out-of-root, or identity-changed app bundles; moves an explicitly reviewed app/support selection to Trash. | Name-based support matches remain advisory rather than an ownership graph. Shared-data policy, reset plans, package receipts/helpers, supported update sources, durable recovery, and broader validation are absent. |
| R07 Startup management | Limited | Reads user/local LaunchAgent and LaunchDaemon plist definitions with warnings and cancellation. It labels definitions separately from observed state and links to macOS Login Items. | No observed enabled/running state, supported direct enable/disable operation, modern background-item inventory, authorization flow, outcome verification, or recovery. |
| R08 Maintenance | Limited | Provides explained links to Login Items, Storage Settings, Software Update, Activity Monitor, and Disk Utility. | These are shortcuts, not maintenance operations. There is no allowlisted action engine, preview/preconditions, authorization design, progress, verified outcome, or recovery workflow. |
| R09 Monitoring | Limited | Displays periodically refreshed CPU, memory, memory pressure, and home-volume free-space readings in the app and menu bar. Metric calculations have unit tests. | Battery, thermal, and network capability reporting; historical trends; configurable quiet notifications; persistence; unavailable-state coverage; and multi-machine validation. |
| R10 Privacy | Blocked | No supported browser/profile adapter or privacy-cleanup operation is present. | Named category adapters, profile discovery, browser-state handling, side-effect preview, revalidation, recovery policy, and validation. MacSweep must not edit macOS permission databases. |
| R11 On-demand protection | Blocked | No malware detection, definitions, verdict, quarantine, restore, or false-positive workflow is present. | A maintained provider and signed-definition design, bounded scanning, secure quarantine/recovery, update integrity, operational ownership, and security validation. No malware-engine or licensing evaluation has been performed in this P0 baseline. |
| R12 Real-time protection | Blocked | No system extension or real-time event pipeline is present. | Apple entitlement approval, maintained engine support, event backpressure, performance budgets, safe disable/uninstall, and security/operational validation. This remains a separately gated expanded-protection capability. |
| R13 Cloud files | Blocked | Generic scans protect known cloud-storage paths from cleanup; this is a safety exclusion, not cloud management. | Provider-aware inventory and local-space release, hydration avoidance, remote/local consequence separation, connection/error handling, and provider validation. No documentation or storage backend support is claimed. |
| R14 Scheduling | Blocked | No scheduled scan or reminder implementation is present. | Opt-in scheduling/reminders, persisted settings, sleep/wake behavior, missed-run policy, cancellation, notifications, and the guarantee that schedules never approve deletion. |
| R15 History and recovery | Limited | Finder Trash provides manual recovery while an item remains there, and each immediate operation reports moved/skipped targets. | No durable per-item journal, stable identity, in-app restore, conflict handling, recovery availability state, export/redaction, or crash recovery. |
| R16 Commercial readiness | Limited | Swift Package Manager declares macOS 13 and produces a local ad-hoc-signed app; the repository documents the local build and its distribution limitation. | Developer ID signing/notarization, secure updater, privacy controls, support/diagnostics workflow, accessibility audit, tested OS/hardware matrix, release pipeline, and any optional licensing implementation. |

## Platform support evidence

The package compiles against a declared **macOS 13 minimum**. That is a compile-time compatibility floor, not runtime validation of macOS 13 or later releases.

The only runtime environment recorded for this P0 baseline is the local machine:

- macOS 26.6, build 25G5065a
- Darwin 25.6.0
- x86_64

No runtime support claim is made for macOS 13–25, other macOS 26 builds, Apple silicon, other Intel Macs, case-sensitive volumes, network/removable volumes, managed Macs, or different permission configurations. The shipping matrix remains open until those environments have explicit build, test, permission, performance, and recovery evidence.

## Initial evaluation proposals

These are small discovery scopes, not implemented capabilities or provider commitments.

### Browser privacy proposal

Evaluate one Chromium-family browser and Safari on disposable test profiles. Inventory profile discovery, named categories (cache, history, cookies/site data, downloads list), running-browser behavior, permission failures, side effects such as sign-out, and safe adapter boundaries. The output should be an evidence memo and fixture tests; it must not clean a real profile.

### Malware provider proposal

Compare at most two maintained on-demand engines/providers for macOS coverage, signed update path, offline behavior, scan/cancel API, verdict detail, quarantine integration constraints, false-positive reporting, license and redistribution terms, update cadence, security history, and named maintenance owner. No engine is selected, bundled, downloaded, or licensed by this baseline. Real-time protection is outside this initial evaluation.

### Cloud provider proposal

Evaluate one built-in macOS provider surface and one third-party File Provider using disposable accounts/fixtures. Determine whether local residency and eviction can be read without hydration, how local-space release differs from remote deletion, and which errors/permissions are observable. The output is an adapter feasibility note only; no generic cleanup or remote deletion path should be added during evaluation.

## P0 completion gaps

This initial matrix does not complete P0. It still needs owners, acceptance evidence links, a tested OS/hardware matrix, benchmark results from the companion protocol, dependency/provenance decisions, privacy and accessibility review, and release-gate tracking. In particular, no malware licensing evaluation has been performed and no browser, malware, cloud, documentation, or storage backend support should be inferred from the proposals above.
