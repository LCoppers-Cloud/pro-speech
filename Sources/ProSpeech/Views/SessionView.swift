import ProSpeechBrain
import SwiftUI

struct SessionView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 16) {
            header
            TeleprompterView(
                words: state.bufferWords,
                highlightIndex: state.highlightIndex,
                volatileTail: state.volatileTail
            )
            .frame(maxHeight: .infinity)
            statusBar
            controls
        }
        .padding()
    }

    private var header: some View {
        HStack {
            Text("ProSpeech").font(.title2.bold())
            Spacer()
            Text(state.persona.displayName).foregroundStyle(.secondary)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "speedometer")
            Text("\(Int(state.liveWPM)) WPM")
            Spacer()
            if !state.statusMessage.isEmpty {
                Text(state.statusMessage).foregroundStyle(.secondary).font(.caption)
            }
        }
        .font(.subheadline.monospacedDigit())
        .padding(.horizontal)
    }

    @ViewBuilder
    private var controls: some View {
        switch state.phase {
        case .idle, .finished:
            Button {
                state.beginCountdown()
            } label: {
                Label("Start", systemImage: "play.fill")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
        case .preparing:
            ProgressView("Preparing on-device model…")
        case .countdown(let n):
            Text("\(n)")
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 16))
        case .running, .paused:
            Button(role: .destructive) {
                state.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.bordered)
        }
    }
}

struct TeleprompterView: View {
    let words: [String]
    let highlightIndex: Int
    let volatileTail: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    flowText
                    if !volatileTail.isEmpty {
                        Text(volatileTail)
                            .foregroundStyle(.secondary)
                            .italic()
                            .id("volatile")
                    }
                }
                .padding()
            }
            .onChange(of: highlightIndex) { _, new in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("word-\(new)", anchor: .center)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.secondary.opacity(0.08)))
    }

    private var flowText: some View {
        let array = Array(words.enumerated())
        return WrappingHStack(data: array) { pair in
            let (i, w) = pair
            Text(w)
                .font(.system(size: 28, weight: i < highlightIndex ? .regular : .semibold,
                              design: .rounded))
                .foregroundStyle(i < highlightIndex ? .secondary : .primary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(i == highlightIndex ? Color.accentColor.opacity(0.25) : .clear)
                )
                .id("word-\(i + 1)")
        }
    }
}

/// Minimal flow-layout that wraps children horizontally. iOS 16+.
struct WrappingHStack<Data: RandomAccessCollection, Content: View>: View
where Data.Element: Hashable {
    let data: Data
    let content: (Data.Element) -> Content

    init(data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
    }

    var body: some View {
        FlowLayout {
            ForEach(Array(data), id: \.self) { element in
                content(element)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            totalWidth = max(totalWidth, x)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: totalWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
