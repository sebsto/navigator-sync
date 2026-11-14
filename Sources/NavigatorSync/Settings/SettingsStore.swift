import Foundation
import Observation
import NavigatorSyncCore

/// Persistent settings, each stored under its own `UserDefaults` key in `didSet`
/// (no re-serialize-everything-on-any-change). `UserDefaults` is injected so
/// tests use a clean suite.
@MainActor
@Observable
final class SettingsStore {
    private let defaults: UserDefaults

    private enum Key {
        static let workFolderPath = "workFolderPath"
        static let intervalSeconds = "intervalSeconds"
        static let maxParallelSyncs = "maxParallelSyncs"
        static let defaultBookmark = "defaultBookmark"
        static let host = "host"
        static let setupComplete = "setupComplete"
    }

    var workFolderPath: String? {
        didSet { defaults.set(workFolderPath, forKey: Key.workFolderPath) }
    }
    var intervalSeconds: Int {
        didSet { defaults.set(intervalSeconds, forKey: Key.intervalSeconds) }
    }
    var maxParallelSyncs: Int {
        didSet { defaults.set(maxParallelSyncs, forKey: Key.maxParallelSyncs) }
    }
    var defaultBookmark: String {
        didSet { defaults.set(defaultBookmark, forKey: Key.defaultBookmark) }
    }
    var host: String {
        didSet { defaults.set(host, forKey: Key.host) }
    }
    var setupComplete: Bool {
        didSet { defaults.set(setupComplete, forKey: Key.setupComplete) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        workFolderPath = defaults.string(forKey: Key.workFolderPath)
        intervalSeconds = defaults.object(forKey: Key.intervalSeconds) as? Int ?? 60
        maxParallelSyncs = defaults.object(forKey: Key.maxParallelSyncs) as? Int ?? 4
        defaultBookmark = defaults.string(forKey: Key.defaultBookmark) ?? "main"
        host = defaults.string(forKey: Key.host) ?? "https://www.neonlaw.com"
        setupComplete = defaults.bool(forKey: Key.setupComplete)
    }

    /// Build the engine's `SyncConfig` from the current settings.
    var syncConfig: SyncConfig {
        SyncConfig(
            workFolder: workFolderPath.map { URL(fileURLWithPath: $0) },
            intervalSeconds: intervalSeconds,
            maxParallelSyncs: maxParallelSyncs,
            defaultBookmark: defaultBookmark,
            bookmarkOverrides: [:],
            host: host
        )
    }
}
