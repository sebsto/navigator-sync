import SwiftUI
import AppKit

/// The settings window: work folder, sync interval, parallelism, default
/// bookmark. Pure SwiftUI.
struct SettingsView: View {
    @State var settings: SettingsStore

    var body: some View {
        Form {
            Section("Work Folder") {
                HStack {
                    Text(settings.workFolderPath ?? "Not chosen")
                        .foregroundStyle(settings.workFolderPath == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Change…") { chooseFolder() }
                        .accessibilityHint("Pick the folder where your matters are kept")
                }
            }
            Section("Syncing") {
                Stepper(value: $settings.intervalSeconds, in: 30...600, step: 30) {
                    Text("Sync every \(settings.intervalSeconds) seconds")
                }
                Stepper(value: $settings.maxParallelSyncs, in: 1...16) {
                    Text("Sync up to \(settings.maxParallelSyncs) matters at once")
                }
            }
            Section("Advanced") {
                LabeledContent("Send changes to") {
                    TextField("Bookmark", text: $settings.defaultBookmark)
                        .frame(width: 160)
                        .accessibilityLabel("Default bookmark to push to")
                }
                LabeledContent("Navigator site") {
                    TextField("Host", text: $settings.host)
                        .frame(width: 220)
                        .accessibilityLabel("Navigator site address")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 360)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings.workFolderPath = url.path
        }
    }
}
