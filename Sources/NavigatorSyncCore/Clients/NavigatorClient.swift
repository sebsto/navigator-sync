import Foundation

/// Sign-in state reported by the Navigator client.
public enum SignInState: Sendable, Equatable {
    case signedIn(Identity)
    case signedOut
}

/// Errors from the Navigator client.
public enum NavigatorError: Error, Sendable, Equatable {
    case notSignedIn
    case httpStatus(Int)
    case malformedResponse
}

/// Talks to Navigator: sign-in state via the CLI, and the user's matters via
/// the REST API (`GET /app/api/projects`). Behind a protocol for fakes.
public protocol NavigatorClient: Sendable {
    func whoami() async throws -> SignInState
    func listMatters() async throws -> [MatterDescriptor]
}

/// Abstracts an HTTP GET so the REST path is testable without a network.
public protocol HTTPGetting: Sendable {
    /// Returns (body, statusCode) for a GET with a bearer token.
    func get(url: URL, bearer: String?) async throws -> (Data, Int)
}

/// `HTTPGetting` backed by `URLSession`.
public struct URLSessionHTTP: HTTPGetting {
    public init() {}
    public func get(url: URL, bearer: String?) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }
}

/// One row of the `GET /app/api/projects` response. Decoded leniently: unknown
/// fields are ignored and `repository_url` may be null.
struct ProjectRow: Decodable {
    let id: String
    let code: String
    let name: String
    let status: String
    let repository_url: String?
}

/// `NavigatorClient` using the `navigator` CLI for `whoami` and the REST API for
/// matter discovery.
public struct SubprocessNavigatorClient: NavigatorClient {
    private let runner: any CommandRunning
    private let navigator: URL
    private let http: any HTTPGetting
    private let host: String
    private let bearerProvider: @Sendable () -> String?

    /// - Parameters:
    ///   - host: base host, e.g. `https://www.neonlaw.com`.
    ///   - bearerProvider: supplies the API bearer token (default reads the
    ///     token the `navigator` CLI stored in `~/.navigator.json`).
    public init(
        runner: any CommandRunning,
        navigatorExecutable: URL,
        http: any HTTPGetting = URLSessionHTTP(),
        host: String = "https://www.neonlaw.com",
        bearerProvider: @escaping @Sendable () -> String? = SubprocessNavigatorClient.storedToken
    ) {
        self.runner = runner
        self.navigator = navigatorExecutable
        self.http = http
        self.host = host
        self.bearerProvider = bearerProvider
    }

    public func whoami() async throws -> SignInState {
        let result = try await runner.run(
            executable: navigator,
            arguments: ["site", "whoami", "--host", hostName],
            workingDirectory: nil,
            environment: nil,
            timeout: .seconds(30)
        )
        guard result.isSuccess else {
            // CLI prints "no stored logins" when signed out; treat any failure
            // as signed-out rather than a hard error (the UI prompts sign-in).
            return .signedOut
        }
        // Output form: "email@example.com (role) — expires in 7h59m"
        let line = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let email = line.split(separator: " ").first.map(String.init),
            email.contains("@")
        else {
            return .signedOut
        }
        let role = line.firstMatch(between: "(", and: ")") ?? "unknown"
        return .signedIn(Identity(email: email, role: role, tokenExpiry: nil))
    }

    public func listMatters() async throws -> [MatterDescriptor] {
        guard let url = URL(string: "\(host)/app/api/projects") else {
            throw NavigatorError.malformedResponse
        }
        let (data, status) = try await http.get(url: url, bearer: bearerProvider())
        switch status {
        case 200:
            let rows = try decodeProjects(data)
            return rows.map {
                MatterDescriptor(
                    id: $0.id, code: $0.code, name: $0.name,
                    repositoryURL: $0.repository_url, status: $0.status)
            }
        case 401, 403:
            throw NavigatorError.notSignedIn
        default:
            throw NavigatorError.httpStatus(status)
        }
    }

    func decodeProjects(_ data: Data) throws -> [ProjectRow] {
        do {
            return try JSONDecoder().decode([ProjectRow].self, from: data)
        } catch {
            throw NavigatorError.malformedResponse
        }
    }

    private var hostName: String {
        // The CLI wants a bare host, the REST base is a full URL.
        URL(string: host)?.host ?? host
    }

    /// Reads the bearer token the `navigator` CLI stored for the default host.
    public static let storedToken: @Sendable () -> String? = {
        let path = ("~/.navigator.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hosts = obj["hosts"] as? [String: Any]
        else { return nil }
        // Prefer the production host entry; fall back to the first.
        if let entry = hosts["https://www.neonlaw.com"] as? [String: Any],
            let token = entry["token"] as? String
        {
            return token
        }
        for value in hosts.values {
            if let entry = value as? [String: Any], let token = entry["token"] as? String {
                return token
            }
        }
        return nil
    }
}

extension String {
    /// Returns the substring between the first `open` and the next `close`.
    fileprivate func firstMatch(between open: Character, and close: Character) -> String? {
        guard let o = firstIndex(of: open) else { return nil }
        let afterOpen = index(after: o)
        guard let c = self[afterOpen...].firstIndex(of: close) else { return nil }
        return String(self[afterOpen..<c])
    }
}
