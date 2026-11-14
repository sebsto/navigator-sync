import Foundation
import Testing

@testable import NavigatorSyncCore

/// End-to-end tests that drive the real SubprocessJJClient against local bare
/// repos (no network, no Navigator account). Skipped automatically if `jj` is
/// not installed, so CI without jj stays green.
@Suite("Integration (real jj, local repos)")
struct IntegrationTests {

    /// Reads matters.json produced by fixtures/make-fake-dataset.sh.
    private struct FixtureNavigator: NavigatorClient {
        let matters: [MatterDescriptor]
        func whoami() async throws -> SignInState {
            .signedIn(Identity(email: "test@example.com", role: "lawyer", tokenExpiry: nil))
        }
        func listMatters() async throws -> [MatterDescriptor] { matters }
    }

    private func jjAvailable() -> URL? {
        try? CLILocator.live().locate(.jj)
    }

    /// Build a bare repo seeded with a `trunk` bookmark, returning its file URL.
    private func makeRemote(_ jj: URL, root: URL, code: String) throws {
        let fm = FileManager.default
        let remote = root.appendingPathComponent("remotes/\(code).git")
        try fm.createDirectory(at: remote, withIntermediateDirectories: true)
        _ = try runGit(["init", "--bare", "-q", remote.path])
        let seed = root.appendingPathComponent("seed-\(code)")
        try fm.createDirectory(at: seed, withIntermediateDirectories: true)
        _ = try runJJ(jj, ["git", "init"], cwd: seed)
        try "title: \(code)\n".write(
            to: seed.appendingPathComponent("navigator.yaml"), atomically: true, encoding: .utf8)
        _ = try runJJ(jj, ["describe", "-m", "seed"], cwd: seed)
        _ = try runJJ(jj, ["bookmark", "create", "-r", "@", "trunk"], cwd: seed)
        _ = try runJJ(jj, ["git", "remote", "add", "origin", remote.path], cwd: seed)
        _ = try runJJ(jj, ["git", "push", "--bookmark", "trunk", "--remote", "origin"], cwd: seed)
    }

    @discardableResult
    private func runJJ(_ jj: URL, _ args: [String], cwd: URL) throws -> String {
        let p = Process()
        p.executableURL = jj
        p.arguments = args
        p.currentDirectoryURL = cwd
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    @discardableResult
    private func runGit(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    @Test("discovers, clones, and syncs a local matter to up-to-date")
    func endToEnd() async throws {
        guard let jj = jjAvailable() else { return }  // skip without jj

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("navint-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        // Configure jj identity for this test's processes.
        _ = try runJJ(jj, ["config", "set", "--user", "user.name", "Test"], cwd: root)
        _ = try runJJ(jj, ["config", "set", "--user", "user.email", "t@example.com"], cwd: root)

        try makeRemote(jj, root: root, code: "acme")

        let matters = [
            MatterDescriptor(
                id: "1", code: "acme", name: "Acme",
                repositoryURL: root.appendingPathComponent("remotes/acme.git").absoluteString,
                status: "open")
        ]
        let navigator = FixtureNavigator(matters: matters)
        let jjClient = SubprocessJJClient(runner: SubprocessCommandRunner(), jjExecutable: jj)
        let config = SyncConfig(workFolder: work, defaultBookmark: "trunk")
        let engine = SyncEngine(navigator: navigator, jj: jjClient, config: config)

        await engine.discover()
        #expect(await engine.registeredCount() == 1)
        // The clone landed on disk.
        #expect(fm.fileExists(atPath: work.appendingPathComponent("acme").path))

        await engine.syncNow()
        let views = await engine.snapshot()
        #expect(views.count == 1)
        // A freshly cloned, unchanged matter ends up up-to-date (nothing to push).
        if case .upToDate = views[0].status {} else {
            Issue.record("expected upToDate, got \(views[0].status)")
        }
    }
}
