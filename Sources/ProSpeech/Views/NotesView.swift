import SwiftUI
import UniformTypeIdentifiers

struct NotesView: View {
    @EnvironmentObject var state: AppState
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $state.notes)
                    .font(.body.monospaced())
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06)))
                    .padding()
                Text("\(state.notes.count) characters · ~\(state.notes.split(whereSeparator: { $0.isWhitespace }).count) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
