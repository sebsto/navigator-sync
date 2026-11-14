import Foundation

/// Centralized SF Symbol names, so iconography stays consistent and is easy to
/// audit in one place. Never use emoji in the UI.
enum SFSymbols {
    // Matter status
    static let upToDate = "checkmark.circle.fill"
    static let syncing = "arrow.triangle.2.circlepath"
    static let offline = "wifi.slash"
    static let needsAttention = "exclamationmark.triangle.fill"

    // Menu bar overall state
    static let menuBarIdle = "folder"
    static let menuBarAttention = "folder.badge.questionmark"

    // Actions
    static let openInFinder = "folder"
    static let syncNow = "arrow.clockwise"
    static let settings = "gearshape"
    static let rerunSetup = "wand.and.stars"

    // Onboarding
    static let welcome = "hand.wave.fill"
    static let workFolder = "folder.fill"
    static let tools = "wrench.and.screwdriver.fill"
    static let signIn = "person.crop.circle.fill"
    static let ready = "checkmark.seal.fill"
    static let copy = "doc.on.doc"
    static let recheck = "arrow.clockwise"
    static let chevronLeft = "chevron.left"
    static let found = "checkmark.circle.fill"
    static let missing = "xmark.circle.fill"
}
