import SwiftUI
import AppKit
import NavigatorSyncCore

/// Navigator Sync — a menu-bar agent (no Dock icon). The onboarding and
/// settings windows are opened imperatively via NSWindow + NSHostingController
/// (SwiftUI scenes don't open reliably in an .accessory app), and the menu bar
/// uses NSStatusItem so its icon can reflect overall state.
@main
struct NavigatorSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No visible scene: the app lives in the menu bar. This empty Settings
        // scene is never shown (LSUIElement/accessory policy).
        Settings { EmptyView() }
    }

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let menuModel = MenuModel()

    private var statusItem: NSStatusItem?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?

    private var engine: SyncEngine?
    private var syncLoopTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        if settings.setupComplete {
            startEngine()
        } else {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        syncLoopTask?.cancel()
        refreshTask?.cancel()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: SFSymbols.menuBarIdle, accessibilityDescription: "Navigator Sync")
        let menu = NSMenu()
        let hostingItem = NSMenuItem()
        hostingItem.view = NSHostingView(rootView: menuContent())
        menu.addItem(hostingItem)
        item.menu = menu
        statusItem = item
    }

    private func updateStatusIcon() {
        let symbol = menuModel.overallNeedsAttention
            ? SFSymbols.menuBarAttention : SFSymbols.menuBarIdle
        statusItem?.button?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: "Navigator Sync")
        // Rebuild the hosted menu view so it reflects the latest model.
        if let menu = statusItem?.menu, let first = menu.items.first {
            first.view = NSHostingView(rootView: menuContent())
        }
    }

    private func menuContent() -> some View {
        MenuContentView(
            model: menuModel,
            workFolderPath: settings.workFolderPath,
            onSyncNow: { [weak self] in self?.syncNow() },
            onSyncMatter: { [weak self] code in self?.syncNow(code: code) },
            onOpenInFinder: { [weak self] code in self?.openInFinder(code) },
            onSettings: { [weak self] in self?.showSettings() },
            onRerunSetup: { [weak self] in self?.showOnboarding() },
            onQuit: { NSApp.terminate(nil) }
        )
    }

    // MARK: - Engine

    private func startEngine() {
        guard settings.workFolderPath != nil else { return }
        let locator = CLILocator.live()
        guard let jjURL = try? locator.locate(.jj),
            let navURL = try? locator.locate(.navigator)
        else {
            menuModel.discoveryError = "A helper tool is missing. Open Settings to fix it."
            updateStatusIcon()
            return
        }
        let jj = SubprocessJJClient(runner: SubprocessCommandRunner(), jjExecutable: jjURL)
        let navigator = SubprocessNavigatorClient(
            runner: SubprocessCommandRunner(), navigatorExecutable: navURL, host: settings.host)
        let engine = SyncEngine(navigator: navigator, jj: jj, config: settings.syncConfig)
        self.engine = engine

        // Periodic discovery + sync loop (owned, cancelled on terminate).
        let interval = settings.intervalSeconds
        syncLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                await engine.discover()
                await engine.syncNow()
                await self?.refreshSnapshot()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func refreshSnapshot() async {
        guard let engine else { return }
        let snapshot = await engine.snapshot()
        let error = await engine.discoveryError()
        menuModel.matters = snapshot
        menuModel.discoveryError = error
        updateStatusIcon()
    }

    private func syncNow(code: String? = nil) {
        guard let engine else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await engine.discover()
            await engine.syncNow()
            await self?.refreshSnapshot()
        }
    }

    private func openInFinder(_ code: String) {
        guard let base = settings.workFolderPath else { return }
        let dir = URL(fileURLWithPath: base).appendingPathComponent(code, isDirectory: true)
        NSWorkspace.shared.open(dir)
    }

    // MARK: - Windows

    private func showOnboarding() {
        let coordinator = SetupCoordinator(
            settings: settings,
            checker: .live(navigatorHost: settings.host))
        let view = OnboardingView(coordinator: coordinator) { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
            self?.startEngine()
        }
        let window = makeWindow(title: "Navigator Sync Setup", content: view,
            width: 600, height: 500)
        window.level = .floating
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func showSettings() {
        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView(settings: settings)
        let window = makeWindow(title: "Navigator Sync Settings", content: view,
            width: 460, height: 360)
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(
        title: String, content: some View, width: CGFloat, height: CGFloat
    ) -> NSWindow {
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: width, height: height))
        window.center()
        return window
    }
}
