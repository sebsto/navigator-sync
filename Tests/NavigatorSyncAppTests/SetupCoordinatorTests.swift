import Foundation
import Testing

@testable import NavigatorSync
import NavigatorSyncCore

@MainActor
@Suite("SetupCoordinator")
struct SetupCoordinatorTests {

    private func store() -> SettingsStore {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        return SettingsStore(defaults: suite)
    }

    private func checker(
        jjOK: Bool = true, navOK: Bool = true, signedIn: Bool = true
    ) -> ReadinessChecker {
        ReadinessChecker(
            locateCLI: { name in
                let ok = (name == .jj) ? jjOK : navOK
                return ok
                    ? .success(URL(fileURLWithPath: "/opt/homebrew/bin/\(name.rawValue)"))
                    : .failure(.missing(cli: name, installHint: name.installHint))
            },
            signInState: {
                signedIn
                    ? .signedIn(Identity(email: "t@example.com", role: "client", tokenExpiry: nil))
                    : .signedOut
            }
        )
    }

    @Test("welcome can always continue")
    func welcomeContinues() {
        let c = SetupCoordinator(settings: store(), checker: checker())
        #expect(c.canContinue)
    }

    @Test("work folder step blocks until a folder is chosen")
    func workFolderBlocks() {
        let c = SetupCoordinator(settings: store(), checker: checker())
        c.currentStep = .workFolder
        #expect(!c.canContinue)
        c.setWorkFolder(URL(fileURLWithPath: "/tmp/nav"))
        #expect(c.canContinue)
    }

    @Test("tools step blocks until both CLIs are found")
    func toolsBlock() {
        let c = SetupCoordinator(settings: store(), checker: checker(jjOK: true, navOK: false))
        c.currentStep = .tools
        c.refreshToolChecks()
        #expect(!c.canContinue)
        #expect(c.navigatorCheck?.fixCommand == "brew install neon-law/navigator/navigator")
    }

    @Test("tools step passes when both CLIs are found")
    func toolsPass() {
        let c = SetupCoordinator(settings: store(), checker: checker())
        c.currentStep = .tools
        c.refreshToolChecks()
        #expect(c.canContinue)
    }

    @Test("sign-in step blocks when signed out and offers the login command")
    func signInBlocks() async {
        let c = SetupCoordinator(settings: store(), checker: checker(signedIn: false))
        c.currentStep = .signIn
        await c.refreshSignIn()
        #expect(!c.canContinue)
        #expect(c.signInCheck?.fixCommand == "navigator site login --host www.neonlaw.com")
    }

    @Test("sign-in step passes when signed in")
    func signInPasses() async {
        let c = SetupCoordinator(settings: store(), checker: checker(signedIn: true))
        c.currentStep = .signIn
        await c.refreshSignIn()
        #expect(c.canContinue)
    }

    @Test("advance walks forward and finish sets setupComplete")
    func advanceAndFinish() {
        let s = store()
        let c = SetupCoordinator(settings: s, checker: checker())
        #expect(c.currentStep == .welcome)
        c.advance()
        #expect(c.currentStep == .workFolder)
        c.setWorkFolder(URL(fileURLWithPath: "/tmp/nav"))
        c.advance()
        #expect(c.currentStep == .tools)
        c.finish()
        #expect(s.setupComplete)
    }

    @Test("goBack moves to the previous step")
    func goBack() {
        let c = SetupCoordinator(settings: store(), checker: checker())
        c.currentStep = .tools
        c.goBack()
        #expect(c.currentStep == .workFolder)
    }
}

@MainActor
@Suite("SettingsStore")
struct SettingsStoreTests {

    @Test("defaults match the brief and round-trip through UserDefaults")
    func defaultsAndPersistence() {
        let suiteName = "test-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        let s = SettingsStore(defaults: suite)
        #expect(s.intervalSeconds == 60)
        #expect(s.maxParallelSyncs == 4)
        #expect(s.defaultBookmark == "main")

        s.intervalSeconds = 120
        s.workFolderPath = "/tmp/navigator"
        // A fresh store on the same suite sees the persisted values.
        let reloaded = SettingsStore(defaults: suite)
        #expect(reloaded.intervalSeconds == 120)
        #expect(reloaded.workFolderPath == "/tmp/navigator")
    }

    @Test("syncConfig reflects current settings")
    func syncConfigMapping() {
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let s = SettingsStore(defaults: suite)
        s.workFolderPath = "/tmp/w"
        s.maxParallelSyncs = 8
        let cfg = s.syncConfig
        #expect(cfg.workFolder?.path == "/tmp/w")
        #expect(cfg.maxParallelSyncs == 8)
        #expect(cfg.defaultBookmark == "main")
    }
}
