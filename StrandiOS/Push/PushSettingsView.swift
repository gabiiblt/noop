#if os(iOS)
import SwiftUI
import StrandDesign

/// Settings for the optional self-hosted export (default OFF). Data goes one way, to the address you
/// enter, over HTTPS with your own token; nothing is read back and nothing goes anywhere else.
struct PushSettingsView: View {
    @AppStorage(PushSettings.enabledKey) private var enabled = false
    @AppStorage(PushSettings.endpointKey) private var endpoint = ""
    @ObservedObject private var push = PushCoordinator.shared
    @State private var tokenDraft = ""
    @State private var tokenStored = PushSettings.token() != nil
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        ScreenScaffold(title: "Self-hosted Export",
                       subtitle: "Send your data one way to a server you own.") {
            VStack(alignment: .leading, spacing: 16) {
                connectionCard
                statusCard
            }
        }
    }

    private var gateOpen: Bool {
        return PushSettings.shouldRun(enabled: enabled, endpoint: endpoint,
                                      token: tokenStored ? "stored" : nil)
    }

    private var connectionCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.forward.app.fill")
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Export to my server")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Toggle(isOn: $enabled) {
                    Text("Send my data")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .onChange(of: enabled) { _, _ in
                    PushBackgroundScheduler.updateSchedule()
                    PushWake.reRegister()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Address").strandOverline()
                    TextField("https://server.example.ts.net/push", text: $endpoint)
                        .modifier(PushFieldChrome())
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Server address")
                    if !endpoint.isEmpty && !PushSettings.isValidEndpoint(endpoint) {
                        Text("The address must start with https:// (your token is never sent in clear text).")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(tokenStored ? "Token (saved in the Keychain)" : "Token").strandOverline()
                    SecureField(tokenStored ? "Paste a new token to replace it" : "Paste your token", text: $tokenDraft)
                        .modifier(PushFieldChrome())
                        .accessibilityLabel("Token")
                    HStack {
                        NoopButton("Save token", systemImage: "key.fill", kind: .primary, action: saveToken)
                            .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if tokenStored {
                            NoopButton("Remove", systemImage: "trash", kind: .secondary, action: removeToken)
                        }
                        Spacer()
                    }
                }

                HStack {
                    NoopButton(testing ? "Testing" : "Test connection", systemImage: "network",
                               kind: .secondary, action: testConnection)
                        .disabled(testing || !PushSettings.isValidEndpoint(endpoint) || !tokenStored)
                    Spacer()
                }
                if let testResult {
                    Text(testResult)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Off by default. When on, NOOP sends the data stored on this iPhone to the address above, one way: nothing is read back and nothing is sent anywhere else. Uploads catch up whenever iOS lets the app run, so your server can be a little behind. Test connection sends no health data.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Status").strandOverline()
                Text(push.statusLine)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let last = push.lastRunAt {
                    Text("Last run \(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                HStack {
                    NoopButton(push.isRunning ? "Uploading" : "Upload now", systemImage: "arrow.up.circle.fill",
                               kind: .primary, action: uploadNow)
                        .disabled(push.isRunning || !gateOpen)
                    Spacer()
                }
            }
        }
    }

    private func saveToken() {
        if PushSettings.setToken(tokenDraft) {
            tokenDraft = ""
            tokenStored = true
            testResult = nil
            PushBackgroundScheduler.updateSchedule()
            PushWake.reRegister()
        } else {
            testResult = "Could not save the token to the Keychain."
        }
    }

    private func removeToken() {
        PushSettings.clearToken()
        tokenStored = false
        PushBackgroundScheduler.updateSchedule()
    }

    private func testConnection() {
        testing = true
        testResult = nil
        Task {
            let message = await push.testConnection()
            testResult = message
            testing = false
        }
    }

    private func uploadNow() {
        PushBackgroundScheduler.updateSchedule()
        Task { await push.run(.manual) }
    }
}

/// The text-field chrome used by the Coach key field, kept to design tokens.
private struct PushFieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(StrandFont.body)
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: NoopMetrics.radiusControl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: NoopMetrics.radiusControl, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }
}
#endif
