# Folder access checks

Settings now offers an explicit Check Access action for Downloads, Desktop, Documents, Trash and added scan folders. It does not run automatically. A directory-relative, no-follow reader opens each ancestor and attempts one directory-list read. It reports readable, denied, missing, unsupported path or a specific system error without reading file contents, writing files or changing permissions. Readable means only that this process could list that folder at that moment; it does not prove descendant access, write access, cleanup eligibility or a global Full Disk Access grant.

The background store publishes results incrementally, caps each pass at 200 normalized paths, and reports any remaining unchecked locations. A 20-second watchdog and Cancel preserve partial results and retain a worker gate until an outstanding filesystem call returns. Canceled/late results cannot appear as completed checks. Leaving the view cancels the check.

Guidance links to Apple's current [Privacy & Security settings guide](https://support.apple.com/guide/mac-help/mchl211c911f/mac), verified September 14, 2026. The guide documents Files & Folders and Full Disk Access. It also documents App Management for app updates/removal; folder listing probes do not establish that capability.

Four targeted tests passed for generated readable/missing/unreadable folders, links, regular-file rejection, timeout/retry gating, cancellation and late-result suppression. A separate Settings layout test passed, and its own-window screenshot was inspected at `build/previews/access/settings.png`: guidance and controls are readable and the initial state is Not checked. Tests did not probe personal folders or alter system permissions.

Signing inspection found `com.local.MacSweep`, ad-hoc signature, no team identifier and no emitted entitlements. This feature does not replace stable release identity, notarization, onboarding or permission-enabled real Finder Trash recovery. Those remain open.

Release verification: `./script/build_and_run.sh --verify` built and reopened MacSweep. `codesign --verify --deep --strict build/MacSweep.app` passed for the local ad-hoc bundle.
