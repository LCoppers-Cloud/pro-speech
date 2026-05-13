import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var apiKeyDraft: String = ""
    @State private var showKey = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Anthropic API key") {
                    HStack {
                        if showKey {
                            TextField("sk-ant-…", text: $apiKeyDraft)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("sk-ant-…", text: $apiKeyDraft)
                        }
                        Button { showKey.toggle() } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                        }
                    }
                    Button("Save") {
                        state.apiKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !state.apiKey.isEmpty {
                        Text("Stored in Keychain").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Anthropic connection") {
                    Button {
                        state.testAnthropicConnection()
                    } label: {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                            Text(state.connectionTestInProgress ? "Testing…" : "Test connection")
                        }
                    }
                    .disabled(state.connectionTestInProgress || state.apiKey.isEmpty)

                    if let s = state.connectionStatus {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: s.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(s.ok ? .green : .orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.message)
                                    .font(.caption)
                                    .multilineTextAlignment(.leading)
                                if let t = s.tokensRemaining {
                                    Text("Rate-window tokens remaining: \(t.formatted())")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if let r = s.requestsRemaining {
                                    Text("Rate-window requests remaining: \(r.formatted())")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if s.tokensRemaining != nil || s.requestsRemaining != nil {
                                    Text("Resets every minute. Anthropic does not expose account balance via API — check the Anthropic Console for credits.")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }

                Section("Audio output") {
                    Picker("Output to", selection: $state.audioRoute) {
                        ForEach(AudioRoute.allCases) { route in
                            Text(route.displayName).tag(route)
                        }
                    }
                    Text(routeHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Status") {
                    LabeledContent("Phase", value: phaseDescription)
                    LabeledContent("Live WPM", value: String(format: "%.0f", state.liveWPM))
                    if !state.statusMessage.isEmpty {
                        Text(state.statusMessage).font(.caption)
                    }
                }

                Section("About") {
                    LabeledContent("Model", value: "claude-haiku-4-5")
                    LabeledContent("Transcription", value: "iOS 26 SpeechAnalyzer (on-device)")
                }
            }
            .navigationTitle("Settings")
            .onAppear { apiKeyDraft = state.apiKey }
        }
    }

    private var routeHelp: String {
        switch state.audioRoute {
        case .auto:
            return "If AirPods (or other Bluetooth audio) are connected, the prompt is whispered into them. Otherwise it plays from the iPhone speaker."
        case .speaker:
            return "Always play from the iPhone speaker, even if AirPods are connected. Useful when you don't want to wear earbuds."
        case .bluetooth:
            return "Only play through Bluetooth audio. If no AirPods are connected, you won't hear anything."
        }
    }

    private var phaseDescription: String {
        switch state.phase {
        case .idle: return "Idle"
        case .preparing: return "Preparing"
        case .countdown(let n): return "Countdown (\(n))"
        case .running: return "Running"
        case .paused(let r): return "Paused — \(r)"
        case .finished: return "Finished"
        }
    }
}
