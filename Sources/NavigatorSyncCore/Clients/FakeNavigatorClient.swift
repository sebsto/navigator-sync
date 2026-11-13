import Foundation

/// A scriptable `NavigatorClient` for engine tests.
public actor FakeNavigatorClient: NavigatorClient {
    private var matters: [MatterDescriptor]
    private var signInState: SignInState
    private var listError: (@Sendable () -> Error)?

    public init(
        matters: [MatterDescriptor] = [],
        signInState: SignInState = .signedIn(Identity(email: "t@example.com", role: "client", tokenExpiry: nil))
    ) {
        self.matters = matters
        self.signInState = signInState
    }

    public func setMatters(_ m: [MatterDescriptor]) { matters = m }
    public func setListError(_ e: (@Sendable () -> Error)?) { listError = e }

    public func whoami() async throws -> SignInState { signInState }

    public func listMatters() async throws -> [MatterDescriptor] {
        if let listError { throw listError() }
        return matters
    }
}
