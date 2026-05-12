import SwiftUI

@main
struct ProSpeechApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            SessionView()
                .tabItem { Label("Session", systemImage: "mic.fill") }
            NotesView()
                .tabItem { Label("Notes", systemImage: "doc.text") }
            PersonaPickerView()
                .tabItem { Label("Tone", systemImage: "waveform") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
