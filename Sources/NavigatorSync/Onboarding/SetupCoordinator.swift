import Foundation
import Observation
import NavigatorSyncCore

/// The ordered steps of first-run setup.
enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome
    case workFolder
    case tools
    case signIn
    case ready

    var title: String {
        switch self {
        case .welcome: return "Welcome to Navigator Sync"
        case .workFolder: return "Choose your work folder"
        case .tools: return "Check the helper tools"
        case .signIn: return "Sign in to Navigator"
        case .ready: return "You're all set"
        }
    }
}

/// Drives the onboarding wizard: tracks the current step, runs the readiness
/// checks, and decides when a step is satisfied enough to continue. Pure logic
/// (no SwiftUI), so it is unit-testable with an injected checker.
@MainActor
@Observable
final class SetupCoordinator {
    private let settings: SettingsStore
    private let checker: ReadinessChecker

    var currentStep: OnboardingStep = .welcome

    // Latest check results, shown in the UI.
    var jjCheck: ReadinessCheck?
    var navigatorCheck: ReadinessCheck?
    var signInCheck: ReadinessCheck?

    init(settings: SettingsStore, checker: ReadinessChecker) {
        self.settings = settings
        self.checker = checker
    }

    /// Whether the current step's prerequisite is satisfied so Continue enables.
    var canContinue: Bool {
        switch currentStep {
        case .welcome, .ready:
            return true
        case .workFolder:
            return settings.workFolderPath != nil
        case .tools:
            return (jjCheck?.satisfied ?? false) && (navigatorCheck?.satisfied ?? false)
        case .signIn:
            return signInCheck?.satisfied ?? false
        }
    }

    var isLastStep: Bool { currentStep == OnboardingStep.allCases.last }
    var isFirstStep: Bool { currentStep == .welcome }

    func advance() {
        guard canContinue,
            let next = OnboardingStep(rawValue: currentStep.rawValue + 1)
        else {
            if isLastStep { finish() }
            return
        }
        currentStep = next
    }

    func goBack() {
        guard let prev = OnboardingStep(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prev
    }

    /// Re-run the CLI checks (the "Check again" button on the tools step).
    func refreshToolChecks() {
        jjCheck = checker.checkCLI(.jj)
        navigatorCheck = checker.checkCLI(.navigator)
    }

    /// Re-run the sign-in check.
    func refreshSignIn() async {
        signInCheck = await checker.checkSignIn()
    }

    func setWorkFolder(_ url: URL) {
        settings.workFolderPath = url.path
    }

    /// The currently chosen work folder path, for display.
    var settingsWorkFolderPath: String? { settings.workFolderPath }

    func finish() {
        settings.setupComplete = true
    }
}
