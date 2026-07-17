import SwiftUI
import AppKit

// MARK: - Unlock view (encrypted vault)

struct UnlockView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.palette) private var palette

    @State private var password = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.shield")
                .resizable().scaledToFit().frame(width: 64, height: 64)
                .foregroundColor(palette.primaryColor)
            Text("Unlock your vault").font(.title2).bold()

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .focused($focused)
                .onSubmit(unlock)

            if let error = error {
                Text(error).foregroundColor(palette.errorColor).font(.callout)
            }

            Button("Unlock", action: unlock)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)

            if app.touchIDAvailable {
                Button {
                    unlockTouchID()
                } label: {
                    Label("Use Touch ID", systemImage: "touchid")
                }
                .buttonStyle(.plain)
                .foregroundColor(palette.primaryColor)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.backgroundColor)
        .onAppear { focused = true }
    }

    private func unlock() {
        error = nil
        do {
            try app.unlock(password: password)
        } catch {
            self.error = (error as? AegisError)?.errorDescription ?? "Incorrect password"
        }
    }

    private func unlockTouchID() {
        error = nil
        do {
            try app.unlockWithTouchID()
        } catch {
            self.error = (error as? AegisError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - Onboarding (first launch)

struct OnboardingView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.palette) private var palette

    private enum Step { case choose, createPassword }
    @State private var step: Step = .choose
    @State private var password = ""
    @State private var confirm = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "shield.lefthalf.filled")
                .resizable().scaledToFit().frame(width: 64, height: 64)
                .foregroundColor(palette.primaryColor)
            Text("Welcome to Aegis").font(.title).bold()

            switch step {
            case .choose:
                chooseView
            case .createPassword:
                createPasswordView
            }

            if let error = error {
                Text(error).foregroundColor(palette.errorColor).font(.callout)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.backgroundColor)
    }

    private var chooseView: some View {
        VStack(spacing: 12) {
            Text("Create a new vault or import an existing Aegis export.")
                .foregroundColor(palette.onSurfaceDimColor)
            Button {
                step = .createPassword
            } label: { Label("Create password-protected vault", systemImage: "lock") }
                .frame(width: 300)
            Button {
                createPlaintext()
            } label: { Label("Create unencrypted vault", systemImage: "lock.open") }
                .frame(width: 300)
            Button {
                importFile()
            } label: { Label("Import existing vault file…", systemImage: "square.and.arrow.down") }
                .frame(width: 300)
        }
    }

    private var createPasswordView: some View {
        VStack(spacing: 12) {
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder).frame(width: 260)
            SecureField("Confirm password", text: $confirm).textFieldStyle(.roundedBorder).frame(width: 260)
            HStack {
                Button("Back") { step = .choose; error = nil }
                Button("Create") { createEncrypted() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
    }

    private func createEncrypted() {
        error = nil
        guard password == confirm else { error = "Passwords do not match"; return }
        do {
            try app.createNewVault(password: password)
        } catch {
            self.error = (error as? AegisError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func createPlaintext() {
        error = nil
        do {
            try app.createNewVault(password: nil)
        } catch {
            self.error = (error as? AegisError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func importFile() {
        error = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try app.importVaultFileAsNew(url: url)
            } catch {
                self.error = (error as? AegisError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
