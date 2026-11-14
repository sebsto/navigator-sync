import Foundation

/// A scriptable `CommandRunning` for tests: it records every invocation and
/// returns canned results (or throws) without launching a process. Lives in the
/// library (not the test target) so the `JJClient`/`NavigatorClient` adapters
/// can be exercised by their own tests.
///
/// An `actor` so it is `Sendable` and race-free without `nonisolated(unsafe)`
/// or a macOS-15 `Mutex`.
public actor FakeCommandRunner: CommandRunning {

    /// One recorded invocation.
    public struct Invocation: Sendable, Equatable {
        public let executable: String
        public let arguments: [String]
        public let workingDirectory: String?
    }

    private struct Stub {
        let match: @Sendable ([String]) -> Bool
        let outcome: @Sendable () throws -> CommandResult
    }

    private var stubs: [Stub] = []
    private var recorded: [Invocation] = []
    private var fallback: CommandResult

    public init() {
        fallback = CommandResult(exitCode: 0, standardOutput: "", standardError: "")
    }

    /// Add a stub matched on the argument array.
    public func stub(
        when match: @escaping @Sendable ([String]) -> Bool,
        return result: CommandResult
    ) {
        stubs.append(Stub(match: match, outcome: { result }))
    }

    /// Add a stub that throws.
    public func stub(
        when match: @escaping @Sendable ([String]) -> Bool,
        throw error: @escaping @Sendable () -> Error
    ) {
        stubs.append(Stub(match: match, outcome: { throw error() }))
    }

    /// Result returned when no stub matches.
    public func setFallback(_ result: CommandResult) {
        fallback = result
    }

    /// Every recorded invocation, in order.
    public func invocations() -> [Invocation] {
        recorded
    }

    public func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        timeout: Duration
    ) async throws -> CommandResult {
        recorded.append(
            Invocation(
                executable: executable.lastPathComponent,
                arguments: arguments,
                workingDirectory: workingDirectory?.path
            )
        )
        if let stub = stubs.first(where: { $0.match(arguments) }) {
            return try stub.outcome()
        }
        return fallback
    }
}
