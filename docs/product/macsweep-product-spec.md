# MacSweep complete-suite product specification

Status: proposed development target, September 12, 2026. This document expands the earlier local-build scope; it does not claim the features below already exist or authorize deployment, purchases, account creation, or changes to the user's files.

## Product outcome

MacSweep should become a trustworthy native Mac-care product: users can understand disk usage, reclaim space deliberately, manage supported apps and startup items, investigate performance, and scan for threats with a maintained detection engine. A full release means the supported features work end to end, survive failure, and have explicit coverage limits. A button that opens another app is labeled as a shortcut and never counted as an implemented management operation.

The reference is the breadth of the directly distributed CleanMyMac edition, rather than an exact clone or its App Store subset. MacPaw documents different capabilities across editions. MacSweep retains its own identity and interaction design. [Edition comparison](https://macpaw.com/support/cleanmymac/knowledgebase/missing-features).

## Scope and release definitions

- **Foundation alpha:** reliable file identities, permission-aware scans, persistent settings, progress, operation history and recovery.
- **Core beta:** expanded cleanup, accurate storage exploration, duplicates and similar-image review, ownership-aware app removal, supported startup/maintenance operations, monitoring and scheduled scan reminders.
- **Core production:** core beta plus signed updates, accessibility, multi-OS/hardware validation, diagnostics, documentation and a supported release pipeline. This is a cleanup/maintenance product, not the full security suite.
- **Complete suite:** core production plus supported browser privacy cleanup, validated on-demand malware detection/quarantine, and provider-aware cloud-file management. Real-time protection is a separately gated capability; if absent, the product must say on-demand protection only.
- **Expanded protection:** real-time protection after Apple entitlement approval, engine support and operational/security validation. The full marketed capability checklist must identify this status independently.

## Required product capabilities

| ID | Capability | Required user outcome |
|---|---|---|
| R01 | Smart Care orchestration | Select scan modules, see stage progress and coverage, review grouped results, execute a deliberate plan, see actual outcomes. |
| R02 | Cleanup | Versioned rules for supported caches, logs, stale installers/downloads and developer artifacts; show reasons, exclusions and app-closure requirements. |
| R03 | Storage explorer | Drill into folders and volumes, distinguish logical/allocated space, report unreadable content and APFS measurement limits, search and reveal items. |
| R04 | Duplicates | Content-confirmed duplicates with explicit retained copies, adjustable minimum size, cross-category consistency and action-time validation. |
| R05 | Similar images | Locally computed similarity groups with side-by-side previews; suggestions remain distinct from exact duplicates and are never automatically deleted. |
| R06 | Application management | Inventory supported locations, explain ownership evidence, review uninstall/reset plans, preserve shared data, manage supported updates through verified sources. |
| R07 | Startup management | Distinguish definitions from observed state; directly manage only supported item types and offer clear external-management links for the rest. |
| R08 | Maintenance | An allowlisted set of explained actions, with previews, authorization when needed, preconditions, progress, actual outcome checks and recovery instructions. |
| R09 | Monitoring | Live CPU/memory/storage plus supported battery/thermal/network metrics; unavailable is explicit. Historical trends and quiet configurable notifications. |
| R10 | Privacy | Supported browser/profile adapters with named data categories and side-effect previews; no direct edits to macOS permissions databases. |
| R11 | On-demand protection | Maintained detection provider, fresh signed definitions, bounded scans, meaningful verdicts, explicit quarantine/restore and false-positive reporting. |
| R12 | Real-time protection | Optional separately approved system extension with event backpressure, performance budgets and safe disable/uninstall behavior. |
| R13 | Cloud files | Provider-aware local-space release distinct from remote deletion; no hydration during inventory and no remote deletion through generic cleanup. |
| R14 | Scheduling | Opt-in scans and reminders, sleep/wake handling, cancellation and no automatic deletion. |
| R15 | History and recovery | Durable per-item operation journal, restore when the trashed object still exists, conflict handling, export/redaction and clear unavailable recovery states. |
| R16 | Commercial readiness | Signed/notarized distribution, secure self-updates, privacy controls, support workflow, documented supported OS/feature matrix and optional licensing. |

## Global constraints

1. Swift 6 and native SwiftUI/AppKit; preserve the existing app while incrementally extracting testable modules.
2. macOS 13 is the current compatibility floor. New capabilities must availability-check newer APIs. Phase 0 determines the shipping support matrix from tested hardware/OS coverage; no implicit floor change.
3. Initial production channel: direct Developer ID distribution. An App Store edition is a separate scoped project.
4. Scan and cleanup work stays off the main actor. Each subsystem supports cancellation and rejects stale results.
5. Default behavior is local-first. Files, paths, browsing data and file hashes do not leave the Mac without a disclosed feature-specific decision and user consent.
6. User data cleanup defaults to Trash after an explicit preview. Permanent erasure, snapshot removal and remote deletion are separate actions with their own consequence-specific confirmation; they cannot inherit generic cleanup approval.
7. Malware quarantine is separate from Trash and must prevent ordinary execution while supporting authenticated recovery. Encryption alone is not an adequate quarantine design.
8. Full Disk Access, root privilege, app sandboxing and network access are separate capabilities. No helper bypasses TCC or SIP, no silent permission escalation, and no instruction to weaken system security in a shipping flow.
9. Identity-aware validation must preserve originals, avoid following substituted links, handle case-sensitive volumes and avoid promising that allocated byte counts equal newly free physical storage.
10. No “100% safe,” “all threats removed,” arbitrary health score or unsupported speed/RAM-cleaning claims.
11. Introduce third-party dependencies only with pinned versions, provenance, license review and a maintenance owner. The earlier no-dependency local-build constraint is intentionally revised for an updater and a maintained malware engine.
12. Existing unrelated workspace projects stay untouched. New helper installation, cloud connections, distribution signing and external services are development gates, not actions to perform while writing this plan.

## Acceptance definition

Every capability is tracked as built, validated, limited, blocked or deliberately excluded. Complete-suite release requires all complete-suite capabilities above to pass documented acceptance checks; optional expanded protection is explicitly declared separately. An external approval delay can block a capability, but cannot turn a missing feature into a completed one. There must be zero open release-blocking data-loss, privilege-boundary, quarantine, recovery or update-integrity defects.
