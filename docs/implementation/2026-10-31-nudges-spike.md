# Smart nudges, phase 0: ad-hoc signing check

Run on Antonio's MacBook Pro (Intel i7-9750H, macOS 26.6) with `open -n build/MacSweep.app --args --nudge-spike`.
The report is written to `~/Library/Application Support/MacSweep/logs/nudge-spike.json`.

| Check | Result |
|---|---|
| Signature | `adhoc` (`codesign -dv`: flags=0x2(adhoc), no TeamIdentifier) |
| Notification permission prompt | Shown. macOS displays the "MacSweep Notifications" permission banner for the ad-hoc signed bundle `com.local.MacSweep`. Status reads `notDetermined` before the request and `denied` while the prompt is unanswered; the request did not return within 20 s because it waits for the user. |
| SMAppService.mainApp | Works with ad-hoc signing: `notFound` → `register()` → `enabled` (macOS showed "Login Item Added"), then `unregister()` → `notRegistered`. |

Decision: no fallbacks needed. Notifications stay behind the user's own Allow click; when they are
not allowed, nudges still show as dashboard cards and the menu bar dot, and Settings offers "Open
Notification Settings". Launch at login uses `SMAppService.mainApp` with `--background`.
