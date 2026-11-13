import AppKit
import SwiftUI

struct ApplicationsView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    private var matchingApps: [InstalledApp] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.installedApps.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
                || $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let matches = matchingApps
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Search apps, IDs or paths", text: $search)
                            .textFieldStyle(.roundedBorder)
                        Button { model.scanInstalledApps() } label: {
                            Label("Refresh Applications", systemImage: "arrow.clockwise")
                                .labelStyle(.iconOnly)
                        }
                        .help("Refresh installed applications")
                        .disabled(model.isBusy || model.waitingForFilesystem)
                    }
                    if !model.installedApps.isEmpty {
                        Text("\(matches.count) of \(model.installedApps.count) applications")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(16)
                Divider()
                if model.installedApps.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "app.badge")
                            .font(.system(size: 44, weight: .regular))
                            .foregroundStyle(.secondary)
                        Text(model.isBusy ? "Discovering applications…" : "Scan installed apps.")
                            .font(.title3.weight(.semibold))
                        Text("Lists apps first without measuring every bundle. Scan related files separately after choosing an app.")
                            .foregroundStyle(.secondary)
                        Button("Scan Applications") { model.scanInstalledApps() }
                            .buttonStyle(.borderedProminent).disabled(model.isBusy || model.waitingForFilesystem)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if matches.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                        Text("No matching applications").font(.headline)
                        Text("Try an app name, bundle ID or part of its path.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Clear Search") { search = "" }
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(matches) { app in
                                AppRow(
                                    app: app,
                                    measurement: model.appMeasurements[app.id],
                                    isSelected: model.selectedAppID == app.id,
                                    onSelect: {
                                        model.selectApp(app)
                                    }
                                )
                                .disabled(model.isBusy || model.waitingForFilesystem)
                                Divider()
                                    .padding(.leading, 52)
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 360)

            Divider()

            VStack(spacing: 0) {
                if let selected = model.selectedApp, !matches.contains(where: { $0.id == selected.id }) {
                    HStack {
                        Text("Selected app is outside this search.").font(.caption).foregroundStyle(.secondary)
                        Button("Clear Search") { search = "" }
                    }.padding(12)
                    Divider()
                }
                appDetailPanel
            }
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)
        }
    }

    private var appDetailPanel: some View {
        Group {
            if let app = model.selectedApp {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "app")
                                    .font(.title2)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 30)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(app.name)
                                        .font(.title3.weight(.semibold))
                                    Text(app.bundleIdentifier ?? "No bundle identifier")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }

                            DetailField(title: "App path", value: app.path)
                            DetailField(title: "App size", value: model.appMeasurements[app.id].map { $0.allocatedBytes.formattedFileSize + " allocated" + ($0.partial ? " · Partial" : "") } ?? app.sizeDescription)
                            if let measured = model.appMeasurements[app.id] {
                                Text("\(measured.logicalBytes.formattedFileSize) logical · \(measured.files) files · \(measured.skipped) skipped. Shared blocks are not guaranteed reclaimable space; links are not followed.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Measure App") { model.measureSelectedApp() }
                                .disabled(model.isBusy || model.waitingForFilesystem)
                            DetailField(title: "Version", value: app.version ?? "Unknown")

                            HStack(spacing: 10) {
                                Button {
                                    model.revealAppInFinder(app)
                                } label: {
                                    Label("Reveal App", systemImage: "finder")
                                }

                                Button {
                                    model.scanSelectedAppLeftovers()
                                } label: {
                                    Label("Find Leftovers", systemImage: "magnifyingglass")
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.isBusy || model.waitingForFilesystem)
                            }

                            Divider()

                            if !model.appLeftoverCoverage.isEmpty {
                                Text(model.appLeftoverCoverage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Related Files to Review")
                                        .font(.headline)
                                    Text("\(model.appLeftovers.filter(\.canSelect).count) selectable · \(model.appLeftovers.filter { !$0.canSelect }.count) unavailable")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button("Select All") {
                                    model.setLeftoverSelection(true)
                                }
                                .disabled(!model.appLeftovers.contains(where: \.canSelect) || model.isBusy || model.waitingForFilesystem)

                                Button("Clear") {
                                    model.setLeftoverSelection(false)
                                }
                                .disabled(model.appLeftovers.isEmpty || model.isBusy)
                            }

                            if model.appLeftovers.isEmpty {
                                Text(model.isBusy ? "Scanning accessible related-file locations…"
                                     : model.appLeftoverScanPerformed ? "No related items were found in the locations covered by this scan."
                                     : "Find leftovers to review related files. No files are selected automatically.")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 20)
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(model.appLeftovers) { leftover in
                                        AppLeftoverRow(item: leftover) {
                                            model.toggleLeftover(leftover)
                                        }.disabled(model.isBusy || model.waitingForFilesystem)
                                        Divider()
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Selected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(model.selectedAppLeftoverSize.formattedFileSize + " measured")
                                .font(.headline)
                        }

                        Button {
                            model.uninstallSelectedApp()
                        } label: {
                            Label("Uninstall App…", systemImage: "app.badge")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || model.waitingForFilesystem || model.appRemovalRestriction(app) != nil)
                        if let reason = model.appRemovalRestriction(app) {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }

                        Button {
                            model.cleanSelectedLeftovers()
                        } label: {
                            Label("Move Leftovers to Trash", systemImage: "trash")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.danger)
                        .disabled(model.selectedAppLeftovers.isEmpty || model.isBusy)
                    }
                    .padding(16)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "app")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Select an app.")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.primary.opacity(0.025))
    }

}

struct AppRow: View {
    let app: InstalledApp
    let measurement: StorageMeasurement?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable().scaledToFit().frame(width: 28, height: 28)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(app.bundleIdentifier ?? app.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(measurement.map { $0.allocatedBytes.formattedFileSize + ($0.partial ? " · Partial" : "") } ?? app.sizeDescription)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select \(app.name)")
    }
}

struct AppLeftoverRow: View {
    let item: AppLeftoverItem
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("Select \(item.name)", isOn: Binding(get: { item.isSelected }, set: { _ in onToggle() }))
                .labelsHidden().disabled(!item.canSelect)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text(item.sizeDescription)
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                }

                Text(item.location)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)

                Text(item.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let reason = item.unavailableReason {
                    Label(reason, systemImage: "lock.fill").font(.caption).foregroundStyle(Theme.warn)
                }
                Text(item.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }
}

struct DetailField: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
