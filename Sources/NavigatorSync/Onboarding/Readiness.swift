import Foundation
import NavigatorSyncCore

/// Result of checking one prerequisite, with plain-language text for the UI.
nonisolated struct ReadinessCheck: Sendable, Equatable {
    let satisfied: Bool
    let message: String
    /// A command the user can copy to fix it, if any.
    let fixCommand: String?
}

/// Runs the same prerequisite checks the onboarding wizard and the running app
/// both use: the two CLIs are installed, and the user is signed in. Injectable
/// so the step logic is unit-testable without the real machine.
nonisolated struct ReadinessChecker: Sendable {
    let locateCLI: @Sendable (CLIName) -> Result<URL, CLILocatorError>
    let signInState: @Sendable () async -> SignInState

    /// Live checker: real CLILocator + a navigator client for whoami.
    static func live(navigatorHost: String) -> ReadinessChecker {
        let locator = CLILocator.live()
        @Sendable func resolve(_ name: CLIName) -> Result<URL, CLILocatorError> {
            do { return .success(try locator.locate(name)) }
            catch let e as CLILocatorError { return .failure(e) }
            catch { return .failure(.missing(cli: name, installHint: name.installHint)) }
        }
        return ReadinessChecker(
            locateCLI: { resolve($0) },
            signInState: {
                guard case .success(let navURL) = resolve(.navigator) else {
                    return .signedOut
                }
                let client = SubprocessNavigatorClient(
                    runner: SubprocessCommandRunner(),
                    navigatorExecutable: navURL,
                    host: navigatorHost
                )
                return (try? await client.whoami()) ?? .signedOut
            }
        )
    }

    /// Check a CLI is installed.
    func checkCLI(_ name: CLIName) -> ReadinessCheck {
        switch locateCLI(name) {
        case .success:
            return ReadinessCheck(
                satisfied: true,
                message: "\(name.rawValue) is installed.",
                fixCommand: nil)
        case .failure(let error):
            let hint: String
            if case .missing(_, let installHint) = error { hint = installHint }
            else { hint = name.installHint }
            return ReadinessCheck(
                satisfied: false,
                message: "\(name.rawValue) is not installed yet.",
                fixCommand: hint)
        }
    }

    /// Check the user is signed in to Navigator.
    func checkSignIn() async -> ReadinessCheck {
        switch await signInState() {
        case .signedIn(let id):
            return ReadinessCheck(
                satisfied: true,
                message: "Signed in as \(id.email).",
                fixCommand: nil)
        case .signedOut:
            return ReadinessCheck(
                satisfied: false,
                message: "You are not signed in to Navigator yet.",
                fixCommand: "navigator site login --host www.neonlaw.com")
        }
    }
}
