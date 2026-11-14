import SwiftUI
import NavigatorSyncCore

/// Visual presentation for a matter status: a symbol, a tint, and a short
/// human label. The symbol + label pairing means status never relies on color
/// alone (Requirement 13.3).
struct StatusPresentation {
    let symbol: String
    let tint: Color
    let label: String

    init(_ status: MatterStatus) {
        switch status {
        case .upToDate:
            symbol = SFSymbols.upToDate
            tint = .green
            label = "Up to date"
        case .syncing:
            symbol = SFSymbols.syncing
            tint = .blue
            label = "Syncing"
        case .offline:
            symbol = SFSymbols.offline
            tint = .secondary
            label = "Offline"
        case .needsAttention(let reason):
            symbol = SFSymbols.needsAttention
            tint = .orange
            label = StatusPresentation.attentionLabel(reason)
        }
    }

    /// Plain-language reason, written for a lawyer (Requirement 12.8 / 13.6).
    static func attentionLabel(_ reason: AttentionReason) -> String {
        switch reason {
        case .conflict:
            return "Needs attention: changes clash, please review"
        case .authFailure:
            return "Needs attention: please sign in again"
        case .pushRejected:
            return "Needs attention: could not send your changes"
        case .cliMissing(let tool):
            return "Needs attention: \(tool) is not installed"
        case .repositoryNotProvisioned:
            return "Not ready yet: this matter has no repository"
        case .workingCopyProblem:
            return "Needs attention: something went wrong syncing"
        }
    }
}

/// App-wide theme. Semantic colors adapt to light/dark automatically via
/// system colors; this type is the single place UI reads styling from.
@MainActor
@Observable
final class Theme {
    static let shared = Theme()
    private init() {}

    var primaryText: Color { .primary }
    var secondaryText: Color { .secondary }
    var accent: Color { .accentColor }

    // Reduce Motion is read from the environment at the view level; exposed here
    // for non-view code that needs it.
    var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
