import SwiftUI
import AppKit
import NavigatorSyncCore

/// The first-run onboarding wizard. Pure SwiftUI; hosted in an NSWindow by the
/// app delegate. Written in plain language for a non-technical lawyer.
struct OnboardingView: View {
    @State var coordinator: SetupCoordinator
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.top, 24)
                .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 20) {
                    stepContent
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }

            navigationBar
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
        }
        .frame(minWidth: 560, minHeight: 460)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigator Sync Setup")
        .task(id: coordinator.currentStep) {
            // Refresh checks when landing on a check step.
            switch coordinator.currentStep {
            case .tools: coordinator.refreshToolChecks()
            case .signIn: await coordinator.refreshSignIn()
            default: break
            }
        }
    }

    private var stepIndicator: some View {
        VStack(spacing: 8) {
            Text("Step \(coordinator.currentStep.rawValue + 1) of \(OnboardingStep.allCases.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    Circle()
                        .fill(step.rawValue <= coordinator.currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(coordinator.currentStep.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }

    @ViewBuilder
    private var stepContent: some View {
        switch coordinator.currentStep {
        case .welcome:
            stepHeader(symbol: SFSymbols.welcome, title: coordinator.currentStep.title,
                detail: "Navigator Sync keeps the folders for your matters up to date on this Mac. It does the Git work for you, so you never have to use the Terminal.")
        case .workFolder:
            workFolderStep
        case .tools:
            toolsStep
        case .signIn:
            signInStep
        case .ready:
            stepHeader(symbol: SFSymbols.ready, title: coordinator.currentStep.title,
                detail: "Setup is finished. Navigator Sync will now keep your matters in sync and show their status in the menu bar at the top of your screen.")
        }
    }

    private func stepHeader(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(title).font(.title2).fontWeight(.semibold)
            Text(detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .accessibilityElement(children: .combine)
    }

    private var workFolderStep: some View {
        VStack(spacing: 16) {
            stepHeader(symbol: SFSymbols.workFolder, title: coordinator.currentStep.title,
                detail: "Pick a folder on your Mac where your matters will be kept. A folder called Navigator in your home folder is a good choice.")
            if let path = coordinator.settingsWorkFolderPath {
                Label(path, systemImage: SFSymbols.found)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Chosen folder: \(path)")
            }
            Button("Choose Folder…") { chooseFolder() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Opens a window to pick your work folder")
        }
    }

    private var toolsStep: some View {
        VStack(spacing: 16) {
            stepHeader(symbol: SFSymbols.tools, title: coordinator.currentStep.title,
                detail: "Navigator Sync uses two small helper programs. Let's make sure they are installed.")
            checkRow(coordinator.jjCheck, name: "Jujutsu (jj)")
            checkRow(coordinator.navigatorCheck, name: "Navigator")
            Button("Check Again") { coordinator.refreshToolChecks() }
                .accessibilityHint("Checks again whether the helper tools are installed")
        }
    }

    private var signInStep: some View {
        VStack(spacing: 16) {
            stepHeader(symbol: SFSymbols.signIn, title: coordinator.currentStep.title,
                detail: "Navigator Sync needs you to be signed in to your Navigator account.")
            checkRow(coordinator.signInCheck, name: "Navigator account")
            Button("Check Again") { Task { await coordinator.refreshSignIn() } }
                .accessibilityHint("Checks again whether you are signed in")
        }
    }

    private func checkRow(_ check: ReadinessCheck?, name: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: (check?.satisfied ?? false) ? SFSymbols.found : SFSymbols.missing)
                    .foregroundStyle((check?.satisfied ?? false) ? .green : .orange)
                    .accessibilityHidden(true)
                Text(check?.message ?? "Checking \(name)…")
                    .foregroundStyle(.primary)
            }
            if let fix = check?.fixCommand, !(check?.satisfied ?? false) {
                HStack(spacing: 8) {
                    Text(fix)
                        .font(.system(.callout, design: .monospaced))
                        .padding(8)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .textSelection(.enabled)
                    Button {
                        copyToPasteboard(fix)
                    } label: {
                        Image(systemName: SFSymbols.copy)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy this command")
                    .accessibilityLabel("Copy the command to install \(name)")
                }
                Text("Open the Terminal app, paste this line, press Return, then choose Check Again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var navigationBar: some View {
        HStack {
            if !coordinator.isFirstStep {
                Button {
                    coordinator.goBack()
                } label: {
                    Label("Back", systemImage: SFSymbols.chevronLeft)
                }
                .accessibilityLabel("Go back")
            }
            Spacer()
            Button(coordinator.isLastStep ? "Done" : "Continue") {
                if coordinator.isLastStep {
                    coordinator.finish()
                    onFinish()
                } else {
                    coordinator.advance()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!coordinator.canContinue)
            .keyboardShortcut(.defaultAction)
            .accessibilityHint(coordinator.canContinue ? "" : "Finish this step to continue")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.setWorkFolder(url)
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
