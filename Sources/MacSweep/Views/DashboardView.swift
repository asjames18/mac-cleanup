import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel
    /// Not observed: live readings flow through `monitor.fast` / `monitor.slow` into the few small views
    /// that show them, so a sample does not rebuild the whole dashboard.
    let monitor: SystemMonitor
    var nudges: NudgeMonitor? = nil
    var actions: NudgeActionHandler? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("YOUR MAC, AT A GLANCE").font(.caption.weight(.semibold))
                            .tracking(1.7).foregroundStyle(.secondary)
                        Text("Make space for what matters.")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                    }
                    Spacer()
                    Label("On this Mac", systemImage: "desktopcomputer")
                        .font(.caption).foregroundStyle(.secondary)
                }
                hero
                HealthCardHost(model: model, inputs: monitor.health)
                if let nudges, let actions { NudgesCard(monitor: nudges, center: nudges.center, handler: actions) }
                if model.lastScanDate != nil && !model.items.isEmpty { spaceCard }
                if model.aiSettings.enabled { aiSuggestions }
                LiveMetricsRow(fast: monitor.fast, slow: monitor.slow)
                    .equatable()
                HStack {
                    Text("A place for every task").font(.title3.weight(.semibold))
                    Spacer()
                    LiveText(store: monitor.fast, style: .captionMono, alignment: .right) { $0.updatedText.map { "Live · \($0)" } ?? "" }
                        .frame(width: 150, height: 16)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    destination(title: "Explore storage", detail: "See which folders take up room.", icon: "chart.bar.xaxis", color: Theme.accent2) {
                        model.mainViewMode = .storage
                    }
                    destination(title: "Manage applications", detail: "Review apps and their support files.", icon: "square.stack.3d.up", color: Theme.accent) {
                        model.mainViewMode = .apps
                    }
                    destination(title: "Find duplicate files", detail: "Compare contents with SHA-256.", icon: "doc.on.doc", color: Theme.warn) {
                        model.selectedPreset = .duplicatesOnly
                        model.mainViewMode = .cleanup
                    }
                    destination(title: "Maintain your Mac", detail: "Review startup definitions and tools.", icon: "slider.horizontal.3", color: Theme.info) {
                        model.mainViewMode = .maintenance
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                    Text("Scans stay on your Mac. You choose what goes to Trash.")
                }.font(.caption).foregroundStyle(.secondary)
            }
            .padding(30).frame(maxWidth: 1250).frame(maxWidth: .infinity)
        }
    }

    private var aiSuggestions: some View {
        SuiteCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Suggestions", systemImage: "wand.and.stars").font(.headline).foregroundStyle(Theme.accent)
                    Spacer()
                    Chip(text: model.aiSettings.provider == .rules ? "Built-in rules · no network" : "Rules + AI on request", color: Theme.muted)
                    if model.aiSettings.provider == .openai {
                        Button {
                            Task { await model.askAI() }
                        } label: {
                            if model.isAskingAI { ProgressView().controlSize(.small) } else { Label("Ask AI", systemImage: "sparkles") }
                        }
                        .disabled(model.isAskingAI || model.lastScanDate == nil || model.isBusy)
                        .help("Sends scan totals (sizes and counts, no file names) to \(model.aiSettings.model.isEmpty ? "your endpoint" : model.aiSettings.model). Up to \(model.aiSettings.timeoutSeconds) s.")
                    }
                    Button { model.refreshSuggestions() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Re-check startup items and protection status. Applied suggestions stay hidden until the next Smart Scan.")
                }
                if let status = model.aiStatus {
                    Text(status).font(.caption).foregroundStyle(Theme.muted)
                }
                let cards = model.suggestionCards
                if cards.isEmpty {
                    Text(model.lastScanDate == nil ? "Run Smart Scan to get suggestions." : "Nothing to suggest right now.")
                        .font(.callout).foregroundStyle(Theme.muted)
                }
                ForEach(cards) { card in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(card.title).font(.callout.weight(.medium))
                            if !card.reason.isEmpty { Text(card.reason).font(.caption).foregroundStyle(Theme.muted) }
                            HStack(spacing: 6) {
                                Chip(text: card.source.label, color: card.source == .rules ? Theme.muted : Theme.accent)
                                if card.facts.bytes > 0 { Chip(text: "≈ \(card.facts.bytes.formattedFileSize)", color: Theme.accent2) }
                                Chip(text: card.facts.risk.label, color: card.facts.risk == .medium ? Theme.warn : card.facts.risk == .low ? Theme.ok : Theme.muted)
                                if card.action.changesFiles {
                                    Chip(text: card.facts.reversible ? "Undoable from Trash or History" : "Can't be undone",
                                         color: card.facts.reversible ? Theme.ok : Theme.danger)
                                }
                            }
                        }
                        Spacer()
                        Button(card.action.changesFiles ? "Apply…" : "Review") { model.applySuggestion(card) }
                            .disabled(model.isBusy || model.waitingForFilesystem)
                    }
                    Divider()
                }
                if model.hiddenSuggestionCount > 0 {
                    Text("\(model.hiddenSuggestionCount) hidden: applied since the last Smart Scan, or refused by macOS in the last 14 days.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    /// "Space you could free": what MacSweep found, split by how safe it is to clean.
    private var spaceCard: some View {
        let breakdown = model.spaceBreakdown
        return SuiteCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Space you could free", systemImage: "chart.pie").font(.headline).foregroundStyle(Theme.accent2)
                    Spacer()
                    Text(breakdown.totalBytes.formattedFileSize).font(.title3.weight(.semibold)).monospacedDigit()
                }
                spaceGroup("Ready to clean", detail: "Caches, logs and reports that apps rebuild", lines: breakdown.readyToClean, total: breakdown.readyBytes, color: Theme.ok)
                spaceGroup("Review first", detail: "Your own files: downloads, extra duplicate copies, large files", lines: breakdown.reviewFirst, total: breakdown.reviewBytes, color: Theme.warn)
                spaceGroup("Review only", detail: "Listed so you know; MacSweep never moves these", lines: breakdown.reviewOnly, total: breakdown.reviewOnlyBytes, color: Theme.muted)
                if !model.includeDeveloperCaches && model.selectedPreset != .developer {
                    Text("Developer caches are not included. Turn them on in Smart Scan to measure them.").font(.caption).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    @ViewBuilder
    private func spaceGroup(_ title: String, detail: String, lines: [SpaceBreakdown.Line], total: Int64, color: Color) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(title).font(.callout.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(Theme.muted)
                    Spacer()
                    Text(total.formattedFileSize).font(.callout.weight(.medium)).monospacedDigit()
                }
                ForEach(lines) { line in
                    Button {
                        model.mainViewMode = .cleanup
                        model.selectedCategory = line.category
                    } label: {
                        HStack {
                            Image(systemName: line.category.systemImage).frame(width: 18).foregroundStyle(Theme.muted)
                            Text("\(line.category.title) · \(line.count)").font(.caption)
                            Spacer()
                            Text(line.bytes.formattedFileSize).font(.caption).monospacedDigit().foregroundStyle(Theme.muted)
                        }.padding(.leading, 16).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var hero: some View {
        HStack(spacing: 28) {
            ZStack {
                Circle().stroke(Theme.accent2.opacity(0.08), lineWidth: 18)
                Circle().trim(from: 0, to: 0.76)
                    .stroke(Theme.accent2.gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "sparkles").font(.system(size: 43, weight: .light)).foregroundStyle(Theme.accent2)
            }.frame(width: 115, height: 115).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 9) {
                Text(model.lastScanDate == nil ? "A fresh start begins here." : "Your scan is ready to review.")
                    .font(.title2.weight(.semibold))
                Text(model.lastScanDate == nil
                     ? "Find old downloads, app caches and files you no longer need. Start with a scan, then take a closer look."
                     : "\(model.items.count) candidates · \(model.totalSize.formattedFileSize) to review. Select only the files you recognize and no longer need.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button {
                        model.mainViewMode = .cleanup
                        if model.lastScanDate == nil { model.scan() }
                    } label: {
                        Label(model.lastScanDate == nil ? "Start Smart Scan" : "Review Results", systemImage: "sparkle.magnifyingglass")
                            .padding(.horizontal, 5).padding(.vertical, 3)
                    }.buttonStyle(.borderedProminent).disabled(model.isBusy || model.waitingForFilesystem)
                    if let date = model.lastScanDate {
                        Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Nothing is removed during a scan.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(30).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line) }
    }

    private func destination(title: String, detail: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SuiteCard {
                HStack(spacing: 14) {
                    Image(systemName: icon).font(.title2).foregroundStyle(color)
                        .frame(width: 45, height: 45)
                        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.headline)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }.contentShape(RoundedRectangle(cornerRadius: Theme.radius))
        }.buttonStyle(.plain)
    }
}

/// Recomputes the health summary only when the model or the (coarsely rounded) health inputs change,
/// and redraws the card only when the summary itself changed.
struct HealthCardHost: View {
    @ObservedObject var model: AppModel
    @ObservedObject var inputs: ReadingStore<HealthInputs>

    var body: some View {
        let readings = inputs.value
        let summary = HealthScore.summarize(diskFree: readings.diskFree, diskTotal: readings.diskTotal,
                                            duplicateWaste: HealthScore.duplicateWaste(model.items),
                                            oldDownloadBytes: HealthScore.oldDownloads(model.items),
                                            memoryPressure: readings.memoryPressure,
                                            scanned: model.lastScanDate != nil)
        HealthCard(summary: summary, model: model).equatable()
    }
}

struct HealthCard: View, Equatable {
    let summary: HealthSummary
    let model: AppModel

    nonisolated static func == (lhs: HealthCard, rhs: HealthCard) -> Bool { lhs.summary == rhs.summary }

    var body: some View {
        let color = summary.score >= 85 ? Theme.ok : summary.score >= 60 ? Theme.warn : Theme.danger
        SuiteCard {
            HStack(alignment: .top, spacing: 22) {
                ZStack {
                    Circle().stroke(Theme.line, lineWidth: 8)
                    Circle().trim(from: 0, to: CGFloat(summary.score) / 100)
                        .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text("\(summary.score)").font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                }
                .frame(width: 78, height: 78)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Health score \(summary.score) of 100")
                VStack(alignment: .leading, spacing: 10) {
                    Text("Mac health · \(summary.label)").font(.headline)
                    if summary.issues.isEmpty {
                        Label("No issues found.", systemImage: "checkmark.circle").font(.callout).foregroundStyle(Theme.ok)
                    }
                    ForEach(summary.issues) { issue in
                        Button { model.mainViewMode = issue.destination } label: {
                            HStack(spacing: 10) {
                                Image(systemName: issue.severity == .bad ? "exclamationmark.octagon.fill" : issue.severity == .warn ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                    .foregroundStyle(issue.severity == .bad ? Theme.danger : issue.severity == .warn ? Theme.warn : Theme.info)
                                Text(issue.text).font(.callout).foregroundStyle(Theme.text)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.muted)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// The three live cards. Nothing here observes the stores: the numbers, captions and bars are AppKit views
/// that redraw themselves, so a sample costs a few small redraws and no SwiftUI update or layout.
struct LiveMetricsRow: View, Equatable {
    let fast: ReadingStore<FastReadings>
    let slow: ReadingStore<SlowReadings>

    nonisolated static func == (lhs: LiveMetricsRow, rhs: LiveMetricsRow) -> Bool { lhs.fast === rhs.fast && lhs.slow === rhs.slow }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            LiveMetricCard(title: "Storage", icon: "internaldrive", color: Theme.accent2, store: slow,
                           value: { $0.diskFreeText ?? "—" }, fraction: { $0.diskUsedFraction },
                           caption: { _ in "Available on your home volume" })
            LiveMetricCard(title: "CPU", icon: "cpu", color: Theme.accent, store: fast,
                           value: { $0.cpuText }, fraction: { $0.cpuFraction }, caption: { _ in "Current processor use" })
            LiveMetricCard(title: "Memory", icon: "memorychip", color: Theme.warn, store: fast,
                           value: { $0.memoryText }, fraction: { $0.memoryFraction }, caption: { "Pressure: \($0.memoryPressure)" })
        }
    }
}

struct LiveMetricCard<Value: Equatable>: View {
    let title: String
    let icon: String
    let color: Color
    let store: ReadingStore<Value>
    let value: (Value) -> String
    let fraction: (Value) -> Double?
    let caption: (Value) -> String

    var body: some View {
        SuiteCard {
            VStack(alignment: .leading, spacing: 14) {
                Label(title, systemImage: icon).foregroundStyle(color).font(.callout.weight(.medium))
                // Fixed sizes: a new value never changes a card's size, so nothing around it re-lays out.
                LiveText(store: store, style: .metric, text: value).frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
                LiveMeter(store: store, color: color, fraction: fraction).frame(height: 7)
                LiveText(store: store, style: .caption, text: caption).frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
            }
        }
    }
}
