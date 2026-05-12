import ProSpeechBrain
import SwiftUI

struct PersonaPickerView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationStack {
            List(Persona.presets) { persona in
                Button {
                    state.persona = persona
                } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(persona.displayName).font(.headline)
                            Text(persona.systemPromptFragment)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if state.persona.id == persona.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Tone")
        }
    }
}
