import SwiftUI
import UniformTypeIdentifiers

struct NotesView: View {
    @EnvironmentObject var state: AppState
    @State private var showImporter = false
    @FocusState private var notesFocused: Bool

    var body: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $state.notes)
                    .focused($notesFocused)
                    .scrollDismissesKeyboard(.interactively)
                    .font(.body.monospaced())
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
                    .padding()
                Text("\(state.notes.count) characters · ~\(state.notes.split(whereSeparator: { $0.isWhitespace }).count) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { notesFocused = false }
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        if let s = UIPasteboard.general.string {
                            state.notes = s
                        }
                    } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    Button { showImporter = true } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { notesFocused = false }
                        .bold()
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, .text]) { result in
                if case let .success(url) = result,
                   url.startAccessingSecurityScopedResource(),
                   let contents = try? String(contentsOf: url, encoding: .utf8) {
                    state.notes = contents
                    url.stopAccessingSecurityScopedResource()
                }
            }
        }
    }
}
