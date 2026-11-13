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
                    Label("AI suggestions", systemImage: "wand.and.stars").font(.headline).foregroundStyle(Theme.accent)
                    Spacer()
                    Chip(text: "Local rules · no network", color: Theme.muted)
                }
                let recommendations = model.aiRecommendations
                if recommendations.isEmpty {
                    Text(model.aiSettings.provider == .rules ? "Run Smart Scan to get suggestions." : "This provider is not connected in this version.")
                        .font(.callout).foregroundStyle(Theme.muted)
                }
                ForEach(recommendations) { recommendation in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(recommendation.title).font(.callout.weight(.medium))
                            Text(recommendation.detail).font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Button("Apply…") { model.applyAIRecommendation(recommendation) }
                            .disabled(model.isBusy || model.waitingForFilesystem)
                    }
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
