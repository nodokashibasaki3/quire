import SwiftUI

struct CanvasSettingsView: View {
    @Environment(CanvasSync.self) private var sync

    @State private var host: String = ""
    @State private var token: String = ""
    @State private var statusMessage: String = ""
    @State private var statusKind: StatusKind = .neutral
    @State private var isLoading: Bool = false

    private enum StatusKind { case neutral, success, error }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            VStack(alignment: .leading, spacing: 6) {
                Text("Canvas host")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.inkSecondary)
                TextField("your-school.instructure.com", text: $host)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Access token")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.inkSecondary)
                SecureField("paste your Canvas token", text: $token)
                    .textFieldStyle(.roundedBorder)
                Text("Generate at \(host) → Account → Settings → New Access Token.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.inkTertiary)
            }

            if !statusMessage.isEmpty {
                statusView
            }

            controls
                .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 460)
        .background(Color.paper)
        .preferredColorScheme(.light)
        .onAppear(perform: loadFromKeychain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Canvas")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.ink)
            Text("Sync upcoming assignments into today's page.")
                .font(.system(size: 12))
                .foregroundStyle(Color.inkSecondary)
        }
    }

    private var statusView: some View {
        let color: Color = {
            switch statusKind {
            case .neutral: return Color.inkSecondary
            case .success: return Color.accentPersimmon
            case .error: return Color.red.opacity(0.85)
            }
        }()
        return Text(statusMessage)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color.opacity(0.08))
            )
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(action: testConnection) {
                Text("Test")
            }
            .disabled(isLoading || token.isEmpty || host.isEmpty)

            Button(action: saveAndSync) {
                Text("Save & Sync")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isLoading || token.isEmpty || host.isEmpty)

            Spacer()

            Button(role: .destructive, action: clear) {
                Text("Clear")
            }
            .disabled(isLoading)
        }
    }

    // MARK: - Actions

    private func loadFromKeychain() {
        if let creds = CanvasKeychain.load() {
            host = creds.host
            token = creds.token
            statusMessage = "Credentials loaded from Keychain."
            statusKind = .neutral
        }
    }

    private func testConnection() {
        guard !isLoading else { return }
        let credentials = CanvasCredentials(host: cleanedHost(), token: token)
        isLoading = true
        statusMessage = "Testing…"
        statusKind = .neutral
        Task {
            do {
                let name = try await CanvasClient(credentials: credentials).testConnection()
                statusMessage = "Connected as \(name)."
                statusKind = .success
            } catch {
                statusMessage = error.localizedDescription
                statusKind = .error
            }
            isLoading = false
        }
    }

    private func saveAndSync() {
        let credentials = CanvasCredentials(host: cleanedHost(), token: token)
        do {
            try CanvasKeychain.save(credentials)
            sync.refreshConfiguredFlag()
            statusMessage = "Saved. Running sync…"
            statusKind = .neutral
            isLoading = true
            Task {
                await sync.syncNow()
                isLoading = false
                switch sync.status {
                case .success(_, let added):
                    statusMessage = added == 0 ? "All caught up — no new items." : "Added \(added) item\(added == 1 ? "" : "s") to today."
                    statusKind = .success
                case .error(let msg):
                    statusMessage = msg
                    statusKind = .error
                default:
                    break
                }
            }
        } catch {
            statusMessage = error.localizedDescription
            statusKind = .error
        }
    }

    private func clear() {
        CanvasKeychain.clear()
        sync.refreshConfiguredFlag()
        token = ""
        statusMessage = "Credentials cleared from Keychain."
        statusKind = .neutral
    }

    private func cleanedHost() -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("https://") { h.removeFirst("https://".count) }
        if h.hasPrefix("http://") { h.removeFirst("http://".count) }
        while h.hasSuffix("/") { h.removeLast() }
        return h
    }
}
