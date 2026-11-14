import SwiftUI
import AppKit
import NavigatorSyncCore

/// Observable view-model holding the latest matter snapshot for the menu.
@MainActor
@Observable
final class MenuModel {
    var matters: [MatterView] = []
    var overallNeedsAttention: Bool {
        matters.contains {
            if case .needsAttention = $0.status { return true }
            return false
        }
    }
    var discoveryError: String?
}

/// The dropdown content of the status-bar menu. Pure SwiftUI, hosted in an
/// NSMenu item via NSHostingView.
struct MenuContentView: View {
    @State var model: MenuModel
    var workFolderPath: String?
    var onSyncNow: () -> Void
    var onSyncMatter: (String) -> Void
    var onOpenInFinder: (String) -> Void
    var onSettings: () -> Void
    var onRerunSetup: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.matters.isEmpty {
                emptyState
            } else {
                ForEach(model.matters) { matter in
                    matterRow(matter)
                    Divider()
                }
            }
            footer
        }
        .frame(width: 340)
        .padding(.vertical, 6)
    }

    private var header: some View {
        HStack {
            Text("Navigator Sync").font(.headline)
            Spacer()
            if model.overallNeedsAttention {
                Image(systemName: SFSymbols.needsAttention)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Some matters need attention")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            if let err = model.discoveryError {
                Text(err).foregroundStyle(.orange)
            } else {
                Text("No matters yet")
                Text("Matters assigned to you will appear here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 16)
    }

    private func matterRow(_ matter: MatterView) -> some View {
        let p = StatusPresentation(matter.status)
        return HStack(spacing: 10) {
            Image(systemName: p.symbol)
                .foregroundStyle(p.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(matter.name).font(.body)
                Text(p.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onOpenInFinder(matter.code)
            } label: {
                Image(systemName: SFSymbols.openInFinder)
            }
            .buttonStyle(.borderless)
            .help("Open in Finder")
            .accessibilityLabel("Open \(matter.name) in Finder")

            Button {
                onSyncMatter(matter.code)
            } label: {
                Image(systemName: SFSymbols.syncNow)
            }
            .buttonStyle(.borderless)
            .disabled(matter.status == .syncing)
            .help("Sync now")
            .accessibilityLabel("Sync \(matter.name) now")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(matter.name), \(p.label)")
    }

    private var footer: some View {
        VStack(spacing: 2) {
            menuButton("Sync All Now", symbol: SFSymbols.syncNow, action: onSyncNow)
            menuButton("Settings…", symbol: SFSymbols.settings, action: onSettings)
            menuButton("Re-run Setup…", symbol: SFSymbols.rerunSetup, action: onRerunSetup)
            Divider().padding(.vertical, 2)
            menuButton("Quit Navigator Sync", symbol: "power", action: onQuit)
        }
        .padding(.top, 4)
    }

    private func menuButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16).accessibilityHidden(true)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
