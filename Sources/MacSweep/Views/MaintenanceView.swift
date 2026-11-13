import SwiftUI

struct MaintenanceView: View {
    @StateObject private var store = MaintenanceStore()

    private let columns = [
        GridItem(.adaptive(minimum: 138, maximum: 210), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    tools
                    definitionsSection
                }
                .padding(24)
            }
        }
        .frame(minWidth: 780, minHeight: 560)
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search definitions")
        .task { store.refresh() }
        .onDisappear { store.cancel() }
        .alert(
            "Maintenance",
            isPresented: Binding(
                get: { store.message != nil },
                set: { if !$0 { store.message = nil } }
            )
        ) {
            Button("OK", role: .cancel) { store.message = nil }
        } message: {
            Text(store.message ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.teal.gradient)
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text("Maintenance")
                    .font(.title2.weight(.semibold))
                Text("Inspect startup definitions and open Apple’s built-in management tools.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Scanning launch definitions")
                Button("Cancel") { store.cancel() }
            } else {
                Button { store.refresh() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .padding(20)
        .background(.regularMaterial)
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apple Tools")
                .font(.headline)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ToolCard(title: "Login Items", detail: "Manage apps allowed at login.", icon: "person.crop.circle.badge.clock", action: store.openLoginItems)
                ToolCard(title: "Storage", detail: "Review storage recommendations.", icon: "internaldrive", action: store.openStorageSettings)
                ToolCard(title: "Software Update", detail: "Check macOS updates.", icon: "arrow.triangle.2.circlepath", action: store.openSoftwareUpdate)
                ToolCard(title: "Activity Monitor", detail: "Inspect active processes.", icon: "waveform.path.ecg", action: store.openActivityMonitor)
                ToolCard(title: "Disk Utility", detail: "Inspect disks and volumes.", icon: "externaldrive", action: store.openDiskUtility)
            }
        }
    }

    private var definitionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Startup Definitions")
                    .font(.headline)
                Spacer()
                Text("\(store.filteredDefinitions.count) found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Read-only startup files in your Library and the Mac’s local Library. This list does not include every login item and does not indicate whether an item is enabled or currently running.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !store.warnings.isEmpty {
                Label {
                    Text("Some files could not be read. \(store.warnings.joined(separator: " "))")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(Theme.warn)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Scan warning: \(store.warnings.joined(separator: " "))")
            }

            Group {
                if store.isLoading && store.definitions.isEmpty {
                    statusView(icon: "magnifyingglass", title: "Reading launch definitions…", detail: "MacSweep is inspecting the three launchd folders.")
                } else if store.filteredDefinitions.isEmpty {
                    statusView(
                        icon: store.searchText.isEmpty ? "checkmark.circle" : "line.3.horizontal.decrease.circle",
                        title: store.searchText.isEmpty ? "No startup definitions found" : "No matching definitions",
                        detail: store.searchText.isEmpty ? "No readable startup files were found in the scoped folders." : "Try a different name, label, source, or program."
                    )
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(store.filteredDefinitions) { definition in
                            DefinitionRow(definition: definition) {
                                store.reveal(definition)
                            }
                            Divider().padding(.leading, 48)
                        }
                    }
                }
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            }
        }
    }

    private func statusView(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(Theme.accent2)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(36)
    }
}

private struct ToolCard: View {
    let title: String
    let detail: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Theme.accent2)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack {
                    Text("Open")
                    Spacer()
                    Image(systemName: "arrow.up.forward.app")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.accent2)
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(title)")
    }
}

private struct DefinitionRow: View {
    let definition: StartupDefinition
    let reveal: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: definition.source == .localLaunchDaemons ? "gearshape.2" : "doc.badge.gearshape")
                .font(.title3)
                .foregroundStyle(Theme.accent2)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(definition.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(definition.source.rawValue)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.teal.opacity(0.12), in: Capsule())
                }

                Text(definition.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let program = definition.program {
                    Label(program, systemImage: "terminal")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 14) {
                    if let runAtLoad = definition.runAtLoad {
                        Text("Launch at load: \(runAtLoad ? "Yes" : "No")")
                    }
                    if let keepAlive = definition.keepAlive {
                        Text("Keep running: \(keepAlive)")
                    }
                }
                .foregroundStyle(.secondary)
            }
            .font(.caption)

            Spacer(minLength: 12)

            Button(action: reveal) {
                Label("Reveal", systemImage: "folder")
            }
            .controlSize(.small)
            .accessibilityLabel("Reveal \(definition.displayName) plist in Finder")
        }
        .padding(14)
    }
}
