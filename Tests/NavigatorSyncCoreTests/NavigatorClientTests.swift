import Foundation
import Testing

@testable import NavigatorSyncCore

/// Scriptable HTTP fake.
private struct StubHTTP: HTTPGetting {
    let body: Data
    let status: Int
    func get(url: URL, bearer: String?) async throws -> (Data, Int) { (body, status) }
}

@Suite("SubprocessNavigatorClient")
struct NavigatorClientTests {

    private func make(
        fake: FakeCommandRunner,
        http: any HTTPGetting = StubHTTP(body: Data("[]".utf8), status: 200)
    ) -> SubprocessNavigatorClient {
        SubprocessNavigatorClient(
            runner: fake,
            navigatorExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/navigator"),
            http: http,
            host: "https://www.neonlaw.com",
            bearerProvider: { "test-token" }
        )
    }

    @Test("whoami parses signed-in email and role")
    func whoamiSignedIn() async throws {
        let fake = FakeCommandRunner()
        await fake.stub(when: { $0.contains("whoami") },
            return: CommandResult(
                exitCode: 0,
                standardOutput: "sebastien.stormacq@gmail.com (client) — expires in 7h59m\n",
                standardError: ""))
        let state = try await make(fake: fake).whoami()
        #expect(state == .signedIn(Identity(
            email: "sebastien.stormacq@gmail.com", role: "client", tokenExpiry: nil)))
    }

    @Test("whoami failure maps to signed-out")
    func whoamiSignedOut() async throws {
        let fake = FakeCommandRunner()
        await fake.stub(when: { $0.contains("whoami") },
            return: CommandResult(exitCode: 1, standardOutput: "",
                standardError: "no stored logins"))
        let state = try await make(fake: fake).whoami()
        #expect(state == .signedOut)
    }

    @Test("listMatters decodes a populated payload")
    func listMattersPopulated() async throws {
        let json = """
        [
          {"id":"1","code":"acme-llc-formation","name":"Acme LLC","status":"open","repository_url":"file:///r/acme.git"},
          {"id":"2","code":"widget-works","name":"Widget Works","status":"open","repository_url":null}
        ]
        """
        let client = make(fake: FakeCommandRunner(),
            http: StubHTTP(body: Data(json.utf8), status: 200))
        let matters = try await client.listMatters()
        #expect(matters.count == 2)
        #expect(matters[0].code == "acme-llc-formation")
        #expect(matters[0].repositoryURL == "file:///r/acme.git")
        #expect(matters[1].repositoryURL == nil)
    }

    @Test("listMatters handles an empty list (200 [])")
    func listMattersEmpty() async throws {
        let client = make(fake: FakeCommandRunner(),
            http: StubHTTP(body: Data("[]".utf8), status: 200))
        let matters = try await client.listMatters()
        #expect(matters.isEmpty)
    }

    @Test("listMatters maps 401/403 to notSignedIn")
    func listMattersUnauthorized() async {
        let client = make(fake: FakeCommandRunner(),
            http: StubHTTP(body: Data("{}".utf8), status: 403))
        await #expect(throws: NavigatorError.notSignedIn) {
            try await client.listMatters()
        }
    }

    @Test("listMatters maps a 500 to httpStatus")
    func listMattersServerError() async {
        let client = make(fake: FakeCommandRunner(),
            http: StubHTTP(body: Data("{}".utf8), status: 500))
        await #expect(throws: NavigatorError.httpStatus(500)) {
            try await client.listMatters()
        }
    }

    @Test("malformed JSON throws malformedResponse")
    func listMattersMalformed() async {
        let client = make(fake: FakeCommandRunner(),
            http: StubHTTP(body: Data("not json".utf8), status: 200))
        await #expect(throws: NavigatorError.malformedResponse) {
            try await client.listMatters()
        }
    }
}
