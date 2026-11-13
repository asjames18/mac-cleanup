import AppKit
import CryptoKit
import Foundation
import MacSweepCore

@MainActor
final class AppModel: ObservableObject {
    typealias InventoryScan = @Sendable (@escaping @Sendable (AppInventoryUpdate) -> Void) -> AppInventoryReport
    typealias LeftoverScan = @Sendable (InstalledApp, @escaping @Sendable (AppLeftoverUpdate) -> Void) -> AppLeftoverReport
    @Published var items: [CleanupItem] = []
    @Published var storageItems: [StorageItem] = []
    @Published private(set) var appMeasurements: [String: StorageMeasurement] = [:]
    @Published var installedApps: [InstalledApp] = []
    @Published var appLeftovers: [AppLeftoverItem] = []
    @Published var appLeftoverScanPerformed = false
    @Published var appLeftoverCoverage = ""
    @Published var mainViewMode: MainViewMode = .overview
    @Published var selectedCategory: CleanupCategory?
    @Published var selectedAppID: InstalledApp.ID?
    @Published var status: ScanStatus = .idle
    @Published var logText = "Ready." {
        didSet { activityPreview = ActivityPreview(logText) }
    }
    @Published private(set) var activityPreview = ActivityPreview("Ready.")
    @Published private(set) var customFolders: [URL] = [] {
        didSet { saveScanPreferences() }
    }
    @Published private(set) var excludedFolders: [URL] = []
    @Published var selectedPreset: ScanPreset = .quick {
        didSet { saveScanPreferences() }
    }
    @Published var focusedItemID: CleanupItem.ID?
    @Published var toast: Toast?
    /// The confirm sheet currently shown, if any.
    @Published private(set) var pendingConfirmation: PendingConfirmation?
    private var pendingApproval: ((ConfirmationGrant) -> Void)?
    private var pendingCancel: (() -> Void)?
    let confirmationLedger = ConfirmationLedger()
    var now: () -> Date = { Date() }
    @Published var showShortcuts = false
    var toastDuration: Duration = .milliseconds(3_200)

    @Published var scanStartedAt: Date?
    @Published var scanDetail = ""
    @Published var scanSummary = ""
    @Published var waitingForFilesystem = false
    @Published var lastScanDate: Date?
    private var generation = UUID()
    private var cancelWorker: (() -> Void)?
    private var scanTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var timedOutToken: UUID?
    private var activeFileWorkerToken: UUID?
    private var activeLeftoverWorkerToken: UUID?
    private let scanTimeout: Duration?
    private let inventoryScan: InventoryScan?
    private let leftoverScan: LeftoverScan?
    private let appMeasurement: (@Sendable (URL, [URL]) throws -> StorageMeasurement)?
    private let removalPreflight: (@Sendable () throws -> Void)?
    private let cleanerScan: (@Sendable ([URL], ScanPreset) -> ScanReport)?

    private let scanPreferences: ScanPreferences?
    private let sandboxPreferences: SandboxPreferences?
    let settingsStore: SettingsStore?
    typealias Confirmation = @MainActor (_ title: String, _ detail: String) -> Bool
    private let confirmation: Confirmation?

    /// On by default. While on, every Trash move outside the sandbox folder is refused.
    @Published private(set) var sandboxEnabled = true

    var sandboxPolicy: SandboxPolicy {
        SandboxPolicy(enabled: sandboxEnabled, root: TestSandbox.defaultRoot)
    }

    private func saveScanPreferences() {
        scanPreferences?.save(folders: customFolders, preset: selectedPreset, exclusions: excludedFolders)
    }

    init(cleanerScan: (@Sendable ([URL], ScanPreset) -> ScanReport)? = nil, scanTimeout: Duration? = nil,
         inventoryScan: InventoryScan? = nil, appMeasurement: (@Sendable (URL, [URL]) throws -> StorageMeasurement)? = nil, leftoverScan: LeftoverScan? = nil, removalPreflight: (@Sendable () throws -> Void)? = nil, scanPreferences: ScanPreferences? = nil,
         sandboxPreferences: SandboxPreferences? = nil, confirmation: Confirmation? = nil, settingsStore: SettingsStore? = nil) {
        self.scanPreferences = scanPreferences
        self.sandboxPreferences = sandboxPreferences
        self.confirmation = confirmation
        self.settingsStore = settingsStore
        if let settingsStore {
            sandboxEnabled = settingsStore.settings.sandboxEnabled
            aiSettings = settingsStore.settings.ai
            if let note = settingsStore.recoveryNote { logText = note }
        } else {
            sandboxEnabled = sandboxPreferences?.load() ?? true
        }
        if let saved = scanPreferences?.load() {
            excludedFolders = saved.exclusions
            customFolders = saved.folders
            selectedPreset = saved.preset
        }
        self.cleanerScan = cleanerScan
        self.scanTimeout = scanTimeout
        self.inventoryScan = inventoryScan
        self.appMeasurement = appMeasurement
        self.leftoverScan = leftoverScan
        self.removalPreflight = removalPreflight
    }

    var isBusy: Bool {
        switch status {
        case .idle, .complete:
            false
        case .scanning, .cleaning:
            true
        }
    }

    var visibleItems: [CleanupItem] {
        guard let selectedCategory else { return items }
        return items.filter { $0.category == selectedCategory }
    }

    var focusedItem: CleanupItem? {
        guard let focusedItemID else { return visibleItems.first }
        return items.first { $0.id == focusedItemID }
    }

    var selectedItems: [CleanupItem] {
        CleanupSafety.selection(items)
    }

    var totalSize: Int64 {
        CleanupSafety.uniqueItems(items).reduce(0) { $0 + $1.size }
    }

    var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
    }

    var storageSize: Int64 {
        let paths = Set(CleanupSafety.uniqueURLs(storageItems.map(\.url)).map(\.path))
        return storageItems.filter { paths.contains($0.url.path) }.reduce(0) { $0 + $1.size }
    }

    var selectedApp: InstalledApp? {
        guard let selectedAppID else { return installedApps.first }
        return installedApps.first { $0.id == selectedAppID }
    }

    var selectedAppLeftovers: [AppLeftoverItem] {
        appLeftovers.filter { $0.isSelected && $0.canSelect }
    }

    var appLeftoverSize: Int64 {
        let measured = appLeftovers.filter(\.sizeIsKnown)
        let paths = Set(CleanupSafety.uniqueURLs(measured.map(\.url)).map(\.path))
        return measured.filter { paths.contains($0.url.path) }.reduce(0) { $0 + $1.size }
    }

    var selectedAppLeftoverSize: Int64 {
        let paths = Set(CleanupSafety.uniqueURLs(selectedAppLeftovers.map(\.url)).map(\.path))
        return selectedAppLeftovers.filter { paths.contains($0.url.path) }.reduce(0) { $0 + $1.size }
    }

    var summaries: [CategorySummary] {
        CleanupCategory.allCases.compactMap { category in
            let categoryItems = items.filter { $0.category == category }
            guard !categoryItems.isEmpty else { return nil }
            return CategorySummary(
                category: category,
                count: categoryItems.count,
                size: CleanupSafety.uniqueItems(categoryItems).reduce(0) { $0 + $1.size }
            )
        }
    }

    func scan() { startFileScan(storageOnly: false) }

    func analyzeStorage() { startFileScan(storageOnly: true) }

    private func startFileScan(storageOnly: Bool) {
        guard !isBusy, !waitingForFilesystem else { return }
        status = .scanning(storageOnly ? "Analyzing Storage" : "Running \(selectedPreset.title)")
        logText = "Starting scan..."
        if storageOnly { storageItems = [] }
        else { items = []; lastScanDate = nil; focusedItemID = nil; selectedCategory = nil }

        let customFolders = customFolders
        let selectedPreset = selectedPreset
        let token = beginScan()
        activeFileWorkerToken = token
        let scanner = cleanerScan
        let updates: @Sendable (ScanUpdate) -> Void = { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.isBusy else { return }
                self.scanDetail = "\(update.stage) · \(update.examined) entries checked\n\(update.path)"
                if storageOnly { self.storageItems = update.storage.sorted { $0.size > $1.size } }
                else { self.items = update.items }
            }
        }
        let worker = detachedWithExclusions(priority: .userInitiated) {
            if storageOnly { return CleanerScanner.analyzeStorage(customFolders: customFolders, progress: updates) }
            if let scanner { return scanner(customFolders, selectedPreset) }
            return CleanerScanner.scan(customFolders: customFolders, preset: selectedPreset, progress: updates)
        }
        cancelWorker = { worker.cancel() }
        let timeout = scanTimeout ?? .seconds(!storageOnly && selectedPreset == .quick ? 25 : 305)
        armWatchdog(token: token, timeout: timeout, cancel: { worker.cancel() })
        scanTask = Task {
            let report = await worker.value
            workerReturned(token: token)
            guard generation == token, !Task.isCancelled else { return }
            watchdogTask?.cancel()
            if !storageOnly {
                lastScanDate = Date()
                items = report.items.sorted {
                    if $0.category.title == $1.category.title { return $0.size > $1.size }
                    return $0.category.title < $1.category.title
                }
            } else { storageItems = report.storageItems.sorted { $0.size > $1.size } }

            selectedCategory = summaries.first?.category
            focusedItemID = visibleItems.first?.id
            generation = UUID() // Reject any queued progress update after completion.
            status = .complete
            scanSummary = report.coverageSummary + exclusionSummary
            logText = report.messages.joined(separator: "\n")
            showToast(storageOnly ? "Storage analysis finished." : "Scan finished: \(items.count) candidates to review.", kind: .ok)
        }
    }

    private func armWatchdog(token: UUID, timeout: Duration, cancel: @escaping @Sendable () -> Void) {
        watchdogTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.generation == token else { return }
            cancel()
            self.generation = UUID()
            self.timedOutToken = token
            self.waitingForFilesystem = true
            self.status = .idle
            self.scanSummary = "Scan timed out while waiting for filesystem access. Partial results are retained. Check for a macOS folder-access prompt. New scans will be available when the pending operation returns; quit and reopen MacSweep if it remains blocked."
            if self.activeLeftoverWorkerToken == token {
                self.appLeftoverScanPerformed = true
                self.appLeftoverCoverage = "Scan timed out; partial coverage."
            }
            self.appendLog(self.scanSummary + "\nLast progress: " + self.scanDetail)
        }
    }

    private func workerReturned(token: UUID) {
        if activeFileWorkerToken == token {
            if waitingForFilesystem && timedOutToken != token {
                scanSummary = "Cancelled. Partial results are retained; you can start a new scan."
            }
            activeFileWorkerToken = nil
            waitingForFilesystem = false
        }
        if activeLeftoverWorkerToken == token { activeLeftoverWorkerToken = nil }
        if timedOutToken == token {
            timedOutToken = nil
            waitingForFilesystem = false
            scanSummary = "The filesystem wait ended. The previous scan timed out; start a new scan to refresh results."
        }
    }


    func scanInstalledApps() {
        guard !isBusy, !waitingForFilesystem else { return }
        status = .scanning("Scanning apps")
        logText = "Discovering installed apps…"
        installedApps = []
        appMeasurements = [:]
        selectedAppID = nil
        appLeftovers = []
        appLeftoverScanPerformed = false
        appLeftoverCoverage = ""
        let token = beginScan()
        activeFileWorkerToken = token
        let updates: @Sendable (AppInventoryUpdate) -> Void = { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.isBusy else { return }
                self.installedApps = update.apps
                self.scanDetail = update.detail
                self.selectedAppID = self.selectedAppID ?? update.apps.first?.id
            }
        }
        let scanner = inventoryScan
        let worker = detachedWithExclusions(priority: .userInitiated) {
            if let scanner { return scanner(updates) }
            return AppScanner.inventory(progress: updates)
        }
        cancelWorker = { worker.cancel() }
        armWatchdog(token: token, timeout: scanTimeout ?? .seconds(25), cancel: { worker.cancel() })
        scanTask = Task {
            let report = await worker.value
            workerReturned(token: token)
            guard generation == token, !Task.isCancelled else { return }
            watchdogTask?.cancel()
            installedApps = report.apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            selectedAppID = installedApps.first?.id
            generation = UUID()
            status = .complete
            scanSummary = report.messages.joined(separator: " ")
            logText = scanSummary
        }
    }

    private func beginScan() -> UUID {
        watchdogTask?.cancel()
        scanTask?.cancel()
        cancelWorker?()
        generation = UUID()
        scanStartedAt = Date()
        scanDetail = "Preparing accessible folders…"
        scanSummary = ""
        return generation
    }

    func cancelScan() {
        guard case .scanning = status else { return }
        watchdogTask?.cancel()
        waitingForFilesystem = activeFileWorkerToken != nil
        if activeLeftoverWorkerToken != nil {
            appLeftoverScanPerformed = true
            appLeftoverCoverage = "Cancelled; partial coverage."
        }
        generation = UUID()
        cancelWorker?()
        cancelWorker = nil
        scanTask?.cancel()
        scanTask = nil
        status = .idle
        scanSummary = waitingForFilesystem
            ? "Cancellation requested. Partial results are retained. Waiting for the filesystem operation to return before another scan can start; check any macOS access prompt."
            : "Cancelled. Displayed results cover only completed portions of the scan."
        appendLog("Scan cancelled. Displayed results cover only completed portions of the scan.")
    }

    private var exclusionSummary: String {
        excludedFolders.isEmpty ? "" : " \(excludedFolders.count) exclusions active; overlapping targets omitted."
    }

    private func detachedWithExclusions<T: Sendable>(priority: TaskPriority, operation: @escaping @Sendable () -> T) -> Task<T, Never> {
        let exclusions = excludedFolders
        let sandbox = sandboxPolicy
        return Task.detached(priority: priority) {
            TestSandbox.$policy.withValue(sandbox) {
                ProtectionRules.$excludedURLs.withValue(exclusions) { operation() }
            }
        }
    }

    /// Shows the "Do you really want to do this action?" sheet. `onApprove` receives a
    /// single-use grant for exactly the reviewed paths; it never runs without one.
    func requestConfirmation(summary: String, detail: String, urls: [URL], sizes: [String: Int64] = [:],
                             actionTitle: String = "Move to Trash", reversible: Bool = true, allowsSandboxSkip: Bool = false,
                             onCancel: @escaping () -> Void = {}, onApprove: @escaping (ConfirmationGrant) -> Void) {
        if pendingConfirmation != nil { cancelPendingConfirmation() }
        var urls = urls
        var summary = summary
        var outside = TestSandbox.outside(urls, policy: sandboxPolicy)
        if !outside.isEmpty, let decide = sandboxPreflightHandler {
            let preflight = SandboxPreflight(outside: outside.count, total: urls.count,
                                             allowsSkip: allowsSandboxSkip && outside.count < urls.count)
            switch decide(preflight) {
            case .cancel:
                recordAction("sandbox", "Cancelled before confirm: \(preflight.headline).")
                onCancel(); return
            case .skipOutside where preflight.allowsSkip:
                let skipped = Set(outside.map(\.path))
                let original = urls.count
                urls = urls.filter { !skipped.contains($0.path) }
                summary = summary.replacingOccurrences(of: "Move \(original) items", with: "Move \(urls.count) items")
                recordAction("sandbox", "Left out \(SandboxText.items(outside.count)) outside the test sandbox.")
                outside = []
            case .skipOutside:
                onCancel(); return
            case .turnOffSandbox:
                guard applySandbox(false, ignoringBusy: true) else { onCancel(); return }
                outside = []
            }
        }
        guard let preview = confirmationLedger.issue(paths: urls.map(\.path), now: now()) else { onCancel(); return }
        let rows = preview.paths.map { ConfirmRow(path: $0, size: sizes[$0]) }
        pendingConfirmation = PendingConfirmation(preview: preview, summary: summary, detail: detail, rows: rows,
                                                  actionTitle: actionTitle, reversible: reversible, sandboxOn: sandboxEnabled,
                                                  outsideSandbox: outside.count)
        pendingApproval = onApprove
        pendingCancel = onCancel
        if let confirmation {
            // Injected decision (tests and scripted checks) still goes through the ledger.
            if confirmation(ConfirmationLedger.title, summary + "\n" + detail) { approvePendingConfirmation() }
            else { cancelPendingConfirmation() }
        }
    }

    /// Writes one line to logs/actions.log when a settings store is configured.
    func recordAction(_ kind: String, _ message: String) {
        settingsStore?.log.append(kind: kind, message: message, now: now())
    }

    func approvePendingConfirmation() {
        guard let pending = pendingConfirmation else { return }
        let approve = pendingApproval, cancel = pendingCancel
        pendingConfirmation = nil; pendingApproval = nil; pendingCancel = nil
        switch confirmationLedger.consume(token: pending.preview.token, now: now()) {
        case .success(let grant):
            recordAction("confirm", "Approved: \(pending.summary) (\(grant.paths.count) items).")
            approve?(grant)
        case .failure(let failure):
            recordAction("confirm", "Refused: \(pending.summary). \(failure.localizedDescription)")
            appendLog(failure.localizedDescription)
            showToast(failure.localizedDescription, kind: .warn)
            cancel?()
        }
    }

    func cancelPendingConfirmation() {
        guard let pending = pendingConfirmation else { return }
        let cancel = pendingCancel
        confirmationLedger.cancel(token: pending.preview.token)
        recordAction("confirm", "Cancelled: \(pending.summary).")
        pendingConfirmation = nil; pendingApproval = nil; pendingCancel = nil
        cancel?()
    }

    func showToast(_ text: String, kind: Toast.Kind = .info) {
        let next = Toast(text: text, kind: kind)
        toast = next
        let duration = toastDuration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            if self?.toast?.id == next.id { self?.toast = nil }
        }
    }

    /// Applies a key-map action. Returns true when the key was handled.
    @discardableResult
    func handle(_ action: KeyAction) -> Bool {
        switch action {
        case .toggleShortcuts:
            showShortcuts.toggle()
        case .closeOverlay:
            guard showShortcuts else { return false }
            showShortcuts = false
        case .section(let mode):
            mainViewMode = mode
        case .trashSelection:
            guard mainViewMode == .cleanup, !selectedItems.isEmpty, !isBusy, !waitingForFilesystem else { return false }
            cleanSelectedItems()
        }
        return true
    }

    /// Turning the sandbox on is immediate. Turning it off needs an explicit confirm.
    @discardableResult
    func setSandboxEnabled(_ enabled: Bool) -> Bool {
        applySandbox(enabled, ignoringBusy: false)
    }

    /// Scripted runs can answer the "outside the sandbox" question; nil uses an alert (or skips it when scripted).
    var sandboxPreflight: (@MainActor (SandboxPreflight) -> SandboxPreflightChoice)?

    private var sandboxPreflightHandler: (@MainActor (SandboxPreflight) -> SandboxPreflightChoice)? {
        if let sandboxPreflight { return sandboxPreflight }
        // Unit tests run outside an app bundle and never get a modal alert.
        guard confirmation == nil, Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return { AppModel.askSandboxPreflight($0) }
    }

    private static func askSandboxPreflight(_ preflight: SandboxPreflight) -> SandboxPreflightChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = preflight.headline
        alert.informativeText = preflight.detail
        alert.addButton(withTitle: "Turn Off Sandbox…")
        if preflight.allowsSkip { alert.addButton(withTitle: "Continue with \(SandboxText.items(preflight.inside))") }
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .turnOffSandbox
        case .alertSecondButtonReturn: return preflight.allowsSkip ? .skipOutside : .cancel
        default: return .cancel
        }
    }

    /// `ignoringBusy` is only for the pre-confirm question, where a removal flow is paused waiting on the user.
    private func applySandbox(_ enabled: Bool, ignoringBusy: Bool) -> Bool {
        guard ignoringBusy || (!isBusy && !waitingForFilesystem), enabled != sandboxEnabled else { return false }
        if !enabled {
            let approved = confirm(title: "Do you really want to do this action?",
                                   detail: "Turning off the test sandbox lets MacSweep move files anywhere you select to the Trash, not just inside \(TestSandbox.defaultRoot.path). Every move still needs its own confirmation.")
            guard approved else { appendLog("Test sandbox stays on."); return false }
        }
        do { try settingsStore?.update(reason: enabled ? "sandbox-on" : "sandbox-off") { $0.sandboxEnabled = enabled } }
        catch {
            appendLog("Could not save settings: \(error.localizedDescription). The test sandbox stays \(sandboxEnabled ? "on" : "off").")
            showToast("Could not save settings.", kind: .danger)
            return false
        }
        sandboxEnabled = enabled
        sandboxPreferences?.save(enabled)
        recordAction("sandbox", enabled ? "Test sandbox turned on." : "Test sandbox turned off after confirmation.")
        appendLog(enabled ? "Test sandbox turned on." : "Test sandbox turned off after confirmation.")
        showToast(enabled ? "Test sandbox on. Only sandbox files can be moved." : "Test sandbox off. Every move still asks first.",
                  kind: enabled ? .ok : .warn)
        return true
    }

    func revealSandbox() {
        guard let root = try? TestSandbox.prepare() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    // MARK: AI (dormant stub, off by default, no network)

    @Published private(set) var aiSettings: AISettings = .dormant

    var aiRecommendations: [AIRecommendation] {
        AIRecommender.recommendations(settings: aiSettings, items: items)
    }

    /// Validates and saves. Rejects key values; only an environment variable name is stored.
    @discardableResult
    func saveAISettings(_ draft: AISettings) -> String? {
        let valid: AISettings
        do { valid = try draft.validated() }
        catch {
            let message = error.localizedDescription
            showToast(message, kind: .danger)
            return message
        }
        do { try settingsStore?.update(reason: "ai-settings") { $0.ai = valid } }
        catch { return "Could not save settings: \(error.localizedDescription)" }
        aiSettings = valid
        recordAction("ai", "AI settings saved: \(valid.enabled ? "on" : "off"), provider \(valid.provider.rawValue), key variable \(valid.keyEnv.isEmpty ? "none" : valid.keyEnv).")
        showToast(valid.enabled ? "AI suggestions on (local rules, no network)." : "AI suggestions off.", kind: .ok)
        return nil
    }

    /// Every AI Apply asks "Do you really want to do this action?" first, then runs the normal cleanup checks.
    @discardableResult
    func applyAIRecommendation(_ recommendation: AIRecommendation) -> Bool {
        guard aiSettings.enabled, !isBusy, !waitingForFilesystem else { return false }
        guard case .moveToTrash(let urls) = recommendation.action else { return false }
        let targets = CleanupSafety.uniqueURLs(urls)
        guard !targets.isEmpty else { return false }
        let sizes = Dictionary(items.map { ($0.url.path, $0.size) }, uniquingKeysWith: { first, _ in first })
        recordAction("ai", "Apply requested: \(recommendation.title).")
        requestConfirmation(summary: "AI suggestion: \(recommendation.title)", detail: recommendation.detail + " Suggested by local rules; review every item.",
                            urls: targets, sizes: sizes, reversible: recommendation.reversible) { [self] grant in
            guard !isBusy, !waitingForFilesystem, grant.matches(targets.map(\.path)) else { return }
            let scanItems = items
            let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
            let selfURL = Bundle.main.bundleURL
            status = .cleaning
            Task {
                let result = await detachedWithExclusions(priority: .userInitiated) {
                    CleanupSafety.trash(grant, allItems: scanItems, runningURLs: running, selfURL: selfURL)
                }.value
                items.removeAll { item in result.moved.contains { ProtectionRules.contains($0, item.url) } }
                finishTrash(result)
            }
        }
        return true
    }

    func revealActionLog() {
        guard let url = settingsStore?.log.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func addSandboxToScanFolders() {
        guard let root = try? TestSandbox.prepare() else { return }
        addCustomFolders([root])
    }

    func confirm(title: String, detail: String) -> Bool {
        if let confirmation { return confirmation(title, detail) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Yes, continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func appRemovalRestriction(_ app: InstalledApp) -> String? {
        ProtectionRules.$excludedURLs.withValue(excludedFolders) {
            CleanupSafety.appRemovalRestriction(app, runningURLs: NSWorkspace.shared.runningApplications.compactMap(\.bundleURL))
        }
    }

    func chooseExcludedFolders() {
        guard !isBusy, !waitingForFilesystem else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.prompt = "Exclude"
        panel.message = "Protect these files or folders from cleanup and application removal."
        if panel.runModal() == .OK { addExclusions(panel.urls) }
    }

    func addExclusions(_ urls: [URL]) {
        guard !isBusy, !waitingForFilesystem else { return }
        excludedFolders = ScanPreferences.normalized(excludedFolders + urls)
        exclusionsChanged()
    }

    func removeExclusion(_ url: URL) {
        guard !isBusy, !waitingForFilesystem else { return }
        excludedFolders.removeAll { ProtectionRules.normalizedPath($0) == ProtectionRules.normalizedPath(url) }
        exclusionsChanged()
    }

    private func exclusionsChanged() {
        saveScanPreferences()
        // Old coverage and selections no longer describe the configured scope.
        items = []; storageItems = []; appLeftovers = []; appMeasurements = [:]
        appLeftoverScanPerformed = false; appLeftoverCoverage = ""
        selectedCategory = nil; focusedItemID = nil; lastScanDate = nil
        scanSummary = "Exclusions changed. Scan again to refresh results."
        appendLog(scanSummary)
    }

    func chooseCustomFolder() {
        guard !isBusy, !waitingForFilesystem else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders MacSweep can scan for reviewable cleanup candidates."

        if panel.runModal() == .OK {
            addCustomFolders(panel.urls)
        }
    }

    func addCustomFolders(_ urls: [URL]) {
        guard !isBusy, !waitingForFilesystem else { return }
        customFolders = ScanPreferences.normalized(customFolders + urls)
    }

    func removeCustomFolder(_ url: URL) {
        guard !isBusy, !waitingForFilesystem else { return }
        customFolders.removeAll { ProtectionRules.normalizedPath($0) == ProtectionRules.normalizedPath(url) }
    }

    func toggleItem(_ item: CleanupItem) {
        guard !isBusy, !waitingForFilesystem else { return }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isSelected.toggle()
        enforceSelection()
    }

    func focusItem(_ item: CleanupItem) {
        focusedItemID = item.id
    }

    func revealInFinder(_ item: CleanupItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func openItem(_ item: CleanupItem) {
        NSWorkspace.shared.open(item.url)
    }

    func selectApp(_ app: InstalledApp) {
        guard !isBusy, !waitingForFilesystem else { return }
        selectedAppID = app.id
        appLeftovers = []
        appLeftoverScanPerformed = false
        appLeftoverCoverage = ""
    }

    func revealAppInFinder(_ app: InstalledApp) {
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    func measureSelectedApp() {
        guard let app = selectedApp, !isBusy, !waitingForFilesystem else { return }
        appMeasurements[app.id] = nil
        status = .scanning("Measuring app")
        let token = beginScan()
        activeFileWorkerToken = token
        scanDetail = "Measuring accessible contents of \(app.name)…"
        let exclusions = excludedFolders
        let measure = appMeasurement
        let worker = Task.detached(priority: .utility) {
            Result { () throws -> StorageMeasurement in
                try Task.checkCancellation()
                func validateInventory() throws {
                    guard let snapshot = app.snapshot,
                          FileSnapshotReader.validate(expected: snapshot, at: app.url) == .unchanged else {
                        throw CleanupSafety.Rejection.changedSinceScan
                    }
                    if let metadata = app.metadataSnapshot,
                       FileSnapshotReader.validate(expected: metadata, at: app.url.appendingPathComponent("Contents/Info.plist")) != .unchanged {
                        throw CleanupSafety.Rejection.changedSinceScan
                    }
                }
                try validateInventory()
                let result = try measure?(app.url, exclusions) ?? StorageFolderMeasurer.measure(app.url, exclusions: exclusions)
                try Task.checkCancellation()
                try validateInventory()
                return result
            }
        }
        cancelWorker = { worker.cancel() }
        armWatchdog(token: token, timeout: scanTimeout ?? .seconds(25), cancel: { worker.cancel() })
        scanTask = Task {
            let result = await worker.value
            workerReturned(token: token)
            guard generation == token, !Task.isCancelled, selectedApp?.id == app.id else { return }
            watchdogTask?.cancel(); generation = UUID(); status = .complete
            switch result {
            case .success(let value):
                appMeasurements[app.id] = value
                scanSummary = "\(app.name): \(value.allocatedBytes.formattedFileSize) allocated · \(value.logicalBytes.formattedFileSize) logical · \(value.files) files · \(value.skipped) skipped. " + (value.partial ? "Partial measured total." : "Measurement finished.")
            case .failure(let failure): scanSummary = "App measurement unavailable: " + failure.localizedDescription
            }
            logText = scanSummary
        }
    }

    func scanSelectedAppLeftovers() {
        guard let app = selectedApp, !isBusy, !waitingForFilesystem else { return }
        status = .scanning("Scanning app leftovers")
        logText = "Scanning leftovers for \(app.name)..."
        appLeftovers = []
        appLeftoverScanPerformed = false
        appLeftoverCoverage = ""

        let token = beginScan()
        activeFileWorkerToken = token
        activeLeftoverWorkerToken = token
        let updates: @Sendable (AppLeftoverUpdate) -> Void = { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.isBusy, self.selectedApp?.id == app.id else { return }
                self.appLeftovers = update.items.sorted { $0.size > $1.size }
                self.scanDetail = "\(update.detail) · \(update.examined) entries checked"
            }
        }
        let scanner = leftoverScan
        let worker = detachedWithExclusions(priority: .userInitiated) {
            if let scanner { return scanner(app, updates) }
            return AppScanner.scanLeftoversReport(for: app, progress: updates)
        }
        cancelWorker = { worker.cancel() }
        armWatchdog(token: token, timeout: scanTimeout ?? .seconds(25), cancel: { worker.cancel() })
        scanTask = Task {
            let report = await worker.value
            workerReturned(token: token)
            guard generation == token, !Task.isCancelled, selectedApp?.id == app.id else { return }
            watchdogTask?.cancel()
            generation = UUID()

            appLeftovers = report.items.sorted { $0.size > $1.size }
            appLeftoverScanPerformed = true
            status = .complete
            let blocked = report.items.filter { !$0.canSelect }.count
            appLeftoverCoverage = (report.messages.last ?? "Coverage unavailable.") + exclusionSummary
            scanSummary = "Found \(report.items.count) related items. \(blocked) unavailable for cleanup. \(appLeftoverCoverage)"
            logText = report.messages.joined(separator: "\n")
        }
    }

    func toggleLeftover(_ item: AppLeftoverItem) {
        guard !isBusy, !waitingForFilesystem else { return }
        guard let index = appLeftovers.firstIndex(where: { $0.id == item.id }), appLeftovers[index].canSelect else { return }
        appLeftovers[index].isSelected.toggle()
    }

    func setLeftoverSelection(_ isSelected: Bool) {
        guard !isBusy, !waitingForFilesystem else { return }
        for index in appLeftovers.indices {
            appLeftovers[index].isSelected = isSelected && appLeftovers[index].canSelect
        }
    }

    func cleanSelectedLeftovers() {
        let reviewed = selectedAppLeftovers
        let targets = CleanupSafety.uniqueURLs(reviewed.map(\.url))
        guard !targets.isEmpty, !isBusy, !waitingForFilesystem else { return }
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
        let selfURL = Bundle.main.bundleURL
        runRemovalPreflight(work: {
            for item in reviewed { try CleanupSafety.validateSupport(item, runningURLs: running, selfURL: selfURL) }
        }) { [self] in
            let sizes = Dictionary(reviewed.map { ($0.url.path, $0.size) }, uniquingKeysWith: { first, _ in first })
            requestConfirmation(summary: "Move \(targets.count) support items to Trash", detail: "Support matches are advisory and may include shared data. Files are checked again before removal. Changes inside folders may not be detected.",
                                urls: targets, sizes: sizes, onCancel: { [self] in status = .idle }) { [self] grant in
                guard grant.matches(targets.map(\.path)) else { finishTrash(CleanupSafety.TrashResult(messages: ["The approved list did not match the selection. Nothing was moved."])); return }
                Task {
                    let currentRunning = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
                    let result = await detachedWithExclusions(priority: .userInitiated) {
                        CleanupSafety.trashSupport(reviewed, runningURLs: currentRunning, selfURL: selfURL)
                    }.value
                    appLeftovers.removeAll { item in result.moved.contains { ProtectionRules.contains($0, item.url) } }
                    finishTrash(result)
                }
            }
        }
    }

    func setVisibleSelection(_ isSelected: Bool) {
        guard !isBusy, !waitingForFilesystem else { return }
        let visibleIDs = Set(visibleItems.map(\.id))
        for index in items.indices where visibleIDs.contains(items[index].id) {
            items[index].isSelected = isSelected
        }
        enforceSelection()
    }

    private func enforceSelection() {
        let retained = CleanupSafety.retainedCopies(items)
        for index in items.indices where items[index].isSelected {
            if retained.contains(where: { ProtectionRules.contains(items[index].url, $0.url) }) {
                items[index].isSelected = false
            }
        }
    }

    func cleanSelectedItems() {
        let targets = uniqueSelectedItems().map(\.url)
        guard !targets.isEmpty, !isBusy, !waitingForFilesystem else { return }
        let sizes = Dictionary(items.map { ($0.url.path, $0.size) }, uniquingKeysWith: { first, _ in first })
        requestConfirmation(summary: "Move \(targets.count) items to Trash", detail: "Review every target below. Files can be recovered from Finder Trash or History.",
                            urls: targets, sizes: sizes, allowsSandboxSkip: true) { [self] grant in
            guard !isBusy, !waitingForFilesystem else { return }
            let scanItems = items
            let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
            let selfURL = Bundle.main.bundleURL
            status = .cleaning
            Task {
                let result = await detachedWithExclusions(priority: .userInitiated) {
                    CleanupSafety.trash(grant, allItems: scanItems, runningURLs: running, selfURL: selfURL)
                }.value
                items.removeAll { item in result.moved.contains { ProtectionRules.contains($0, item.url) } }
                if let selectedCategory, !items.contains(where: { $0.category == selectedCategory }) {
                    self.selectedCategory = summaries.first?.category
                }
                finishTrash(result)
            }
        }
    }

    private func pathList(_ text: String) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
        view.isEditable = false
        view.isSelectable = true
        view.string = text
        view.font = .systemFont(ofSize: 11)
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        return scroll
    }

    private func finishTrash(_ result: CleanupSafety.TrashResult) {
        status = .complete
        appendLog(result.messages.joined(separator: "\n"))
        recordAction("trash", "Moved \(result.moved.count) items.")
        for message in result.messages { recordAction("trash", message) }
        showToast(result.moved.isEmpty ? "Nothing was moved to Trash." : "Moved \(result.moved.count) items to Trash.",
                  kind: result.moved.isEmpty ? .warn : .ok)
        // Scripted runs (an injected confirmation) report through the log and toast only.
        guard confirmation == nil else { return }
        let report = TrashReport.summarize(movedCount: result.moved.count, messages: result.messages)
        let alert = NSAlert()
        alert.messageText = report.headline
        alert.alertStyle = result.moved.isEmpty ? .warning : .informational
        alert.informativeText = report.summary
            + (report.otherMessages.isEmpty ? "" : " Unknown outcomes require checking the original location and Trash in Finder before further action.")
        alert.addButton(withTitle: "OK")
        if report.hasDetails { alert.addButton(withTitle: "Show Details…") }
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let details = NSAlert()
        details.messageText = report.headline
        details.informativeText = report.summary
        details.accessoryView = pathList(report.detailText)
        details.addButton(withTitle: "OK")
        details.runModal()
    }

    private func appendLog(_ message: String) {
        guard !message.isEmpty else { return }
        if logText == "Ready." || logText.isEmpty {
            logText = message
        } else {
            logText += "\n\(message)"
        }
    }

    private func uniqueSelectedItems() -> [CleanupItem] {
        CleanupSafety.selection(items)
    }

    private func runRemovalPreflight(timeout: Duration = .seconds(25), work: @escaping @Sendable () throws -> Void,
                                     completion: @escaping @MainActor () async -> Void) {
        status = .scanning("Checking files before removal")
        let token = beginScan()
        scanDetail = "Checking files before removal…"
        activeFileWorkerToken = token
        let injected = removalPreflight
        let worker = detachedWithExclusions(priority: .userInitiated) { () -> String? in
            do { if let injected { try injected() } else { try work() }; return nil }
            catch { return error.localizedDescription }
        }
        cancelWorker = { worker.cancel() }
        armWatchdog(token: token, timeout: scanTimeout ?? timeout, cancel: { worker.cancel() })
        scanTask = Task {
            let failure = await worker.value
            workerReturned(token: token)
            guard generation == token, !Task.isCancelled else { return }
            watchdogTask?.cancel()
            cancelWorker = nil
            generation = UUID()
            if let failure { finishTrash(CleanupSafety.TrashResult(messages: [failure])); return }
            status = .cleaning
            await completion()
        }
    }

    func uninstallSelectedApp() {
        guard let app = selectedApp, !isBusy, !waitingForFilesystem else { return }
        let plan = CleanupSafety.AppRemovalPlan(app: app, support: selectedAppLeftovers)
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
        let selfURL = Bundle.main.bundleURL
        runRemovalPreflight(timeout: .seconds(305), work: {
            try CleanupSafety.preflight(plan, runningURLs: running, selfURL: selfURL)
        }) { [self] in
            let urls = [app.url] + plan.support.map(\.url)
            var sizes = Dictionary(plan.support.map { ($0.url.path, $0.size) }, uniquingKeysWith: { first, _ in first })
            if let measured = appMeasurements[app.id] { sizes[app.url.path] = measured.allocatedBytes }
            requestConfirmation(summary: "Move \(app.name) to Trash", detail: "Includes the app and \(plan.support.count) explicitly selected support items. Support matches are advisory and may include shared data. Files are checked again before removal. Changes inside folders may not be detected.",
                                urls: urls, sizes: sizes, onCancel: { [self] in status = .idle }) { [self] grant in
                guard grant.matches(urls.map(\.path)) else { finishTrash(CleanupSafety.TrashResult(messages: ["The approved list did not match the selection. Nothing was moved."])); return }
                Task {
                    let currentRunning = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
                    let result = await detachedWithExclusions(priority: .userInitiated) {
                        CleanupSafety.uninstall(plan, runningURLs: currentRunning, selfURL: selfURL)
                    }.value
                    if result.moved.contains(app.url) {
                        installedApps.removeAll { $0.id == app.id }
                        selectedAppID = installedApps.first?.id
                        appLeftovers = []
                        appLeftoverScanPerformed = false
                        appLeftoverCoverage = ""
                    }
                    finishTrash(result)
                }
            }
        }
    }

}

extension Int64 {
    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
