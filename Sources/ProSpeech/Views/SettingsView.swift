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
