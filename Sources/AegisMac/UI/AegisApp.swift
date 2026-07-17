import SwiftUI

// MARK: - App

/// The SwiftUI App. Declared WITHOUT `@main` — `main.swift` calls `AegisApp.main()` explicitly.
struct AegisApp: App {
    @StateObject private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 400, minHeight: 520)
                .preferredColorScheme(app.forcedColorScheme)
                .onAppear { app.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        if case .unlocked = app.launchState { app.startTimer() }
                    case .background, .inactive:
                        app.stopTimer()
                    @unknown default:
                        break
                    }
                }
        }
        .commands { AegisCommands() }

        Settings {
            SettingsView()
                .environmentObject(app)
                .environment(\.palette, app.palette(systemIsDark: app.forcedColorScheme == .dark))
        }
    }
}

// MARK: - Root routing view

struct RootView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = app.palette(systemIsDark: colorScheme == .dark)
        Group {
            switch app.launchState {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.backgroundColor)
            case .onboarding:
                OnboardingView()
            case .locked:
                UnlockView()
            case .unlocked:
                MainView()
            case .error(let message):
                errorScreen(message, palette: palette)
            }
        }
        .environment(\.palette, palette)
    }

    private func errorScreen(_ message: String, palette: Palette) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .resizable().scaledToFit().frame(width: 48, height: 48)
                .foregroundColor(palette.errorColor)
            Text("Could not open the vault").font(.title3).bold()
            Text(message).foregroundColor(palette.onSurfaceDimColor).multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.backgroundColor)
    }
}

// MARK: - Menu-bar commands

struct AegisCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Entry") {
                NotificationCenter.default.post(name: .aegisAddEntry, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Vault") {
            Button("Find") {
                NotificationCenter.default.post(name: .aegisFocusSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
            Button("Copy Code") {
                NotificationCenter.default.post(name: .aegisCopyCode, object: nil)
            }
            .keyboardShortcut("c", modifiers: .command)
            Divider()
            Button("Lock") {
                NotificationCenter.default.post(name: .aegisLock, object: nil)
            }
            .keyboardShortcut("l", modifiers: .command)
        }
    }
}
