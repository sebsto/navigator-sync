import SwiftUI
import AppKit
import SwiftUI
import NavigatorSyncCore

/// Navigator Sync — a menu-bar agent (no Dock icon).
///
/// There is deliberately no SwiftUI `App`/`Scene`: a `Settings`/`WindowGroup`
/// scene renders a stray empty window under `swift run` in an accessory app.
/// Instead `main` builds a plain `NSApplication` with our delegate, which owns
/// the status item, a popover for the menu content, and the onboarding/settings
/// windows.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// The delegate lives for the whole process: app.run() below never returns, so
// this binding is never released.
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let menuModel = MenuModel()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
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

    // MARK: - Status item + popover

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: SFSymbols.menuBarIdle, accessibilityDescription: "Navigator Sync")
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        statusItem = item

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: menuContent())
        popover = pop
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Refresh the content to the latest model before showing.
            popover.contentViewController = NSHostingController(rootView: menuContent())
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
    }

    private func updateStatusIcon() {
        let symbol = menuModel.overallNeedsAttention
            ? SFSymbols.menuBarAttention : SFSymbols.menuBarIdle
        statusItem?.button?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: "Navigator Sync")
    }

    private func menuContent() -> some View {
        MenuContentView(
            model: menuModel,
            workFolderPath: settings.workFolderPath,
            onSyncNow: { [weak self] in self?.closePopover(); self?.syncNow() },
            onSyncMatter: { [weak self] code in self?.syncNow(code: code) },
            onOpenInFinder: { [weak self] code in self?.openInFinder(code) },
            onSettings: { [weak self] in self?.closePopover(); self?.showSettings() },
            onRerunSetup: { [weak self] in self?.closePopover(); self?.showOnboarding() },
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
