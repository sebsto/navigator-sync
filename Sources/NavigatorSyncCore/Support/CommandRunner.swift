import Foundation
import Subprocess
import System

/// The outcome of running a CLI: exit code plus the captured, bounded output.
/// Output is kept only as diagnostics — no file contents are logged (Req 8).
public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public nonisolated init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    /// True when the process exited with status 0.
    public var isSuccess: Bool { exitCode == 0 }
}

/// Raised when a command does not finish within its timeout. The owning task is
/// cancelled, which triggers the subprocess teardown sequence.
public struct CommandTimeoutError: Error, Sendable, Equatable {
    public let executable: String
    public let timeout: Duration
    public nonisolated init(executable: String, timeout: Duration) {
        self.executable = executable
        self.timeout = timeout
    }
}

/// Runs a CLI as a subprocess and returns its collected output. The protocol
/// keeps `swift-subprocess` out of the clients and lets tests inject a fake.
public protocol CommandRunning: Sendable {
    nonisolated func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        timeout: Duration
    ) async throws -> CommandResult
}

extension CommandRunning {
    /// Convenience with a default 60-second timeout.
    public func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) async throws -> CommandResult {
        try await run(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeout: .seconds(60)
        )
    }
}

/// `CommandRunning` backed by Apple's `swift-subprocess`.
///
/// Output is collected with an explicit byte cap (bounded memory and a privacy
/// floor). Interruption is driven by Swift task cancellation: the configured
/// `teardownSequence` sends SIGINT → SIGTERM → SIGKILL, so a hung CLI is torn
/// down rather than leaked. The timeout is enforced with a task group whose
/// losing branch is cancelled via `cancelAll()`, which cancels the subprocess
/// task and runs that teardown.
public struct SubprocessCommandRunner: CommandRunning {
    /// Maximum bytes captured per stream.
    private let outputByteLimit: Int

    public init(outputByteLimit: Int = 1_048_576) {
        self.outputByteLimit = outputByteLimit
    }

    public nonisolated func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        timeout: Duration
    ) async throws -> CommandResult {
        let limit = outputByteLimit
        let exePath = executable.path

        let platformOptions: PlatformOptions = {
            var opts = PlatformOptions()
            opts.teardownSequence = [
                .send(signal: .interrupt, allowedDurationToNextStep: .seconds(2)),
                .gracefulShutDown(allowedDurationToNextStep: .seconds(3)),
            ]
            return opts
        }()

        let env: Environment = environment.map { vars in
            var updates: [Environment.Key: String?] = [:]
            for (k, v) in vars { updates[Environment.Key(stringLiteral: k)] = v }
            return .inherit.updating(updates)
        } ?? .inherit
        let wd: FilePath? = workingDirectory.map { FilePath($0.path) }

        return try await withThrowingTaskGroup(of: CommandResult.self) { group in
            group.addTask {
                let record = try await Subprocess.run(
                    .path(FilePath(exePath)),
                    arguments: Arguments(arguments),
                    environment: env,
                    workingDirectory: wd,
                    platformOptions: platformOptions,
                    output: .string(limit: limit),
                    error: .string(limit: limit)
                )
                let code: Int32
                switch record.terminationStatus {
                case .exited(let c): code = Int32(c)
                case .signaled(let s): code = Int32(128 + s)
                }
                return CommandResult(
                    exitCode: code,
                    standardOutput: record.standardOutput ?? "",
                    standardError: record.standardError ?? ""
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CommandTimeoutError(executable: exePath, timeout: timeout)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw CommandTimeoutError(executable: exePath, timeout: timeout)
            }
            return first
        }
    }
}
