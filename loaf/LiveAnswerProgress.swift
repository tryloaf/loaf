import SwiftUI

struct LiveAnswerProgress: View {
    let turn: ChatGPTSearchTurn
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { time in
                    let phase = time.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 3) {
                        ForEach(0..<3) { index in
                            Circle().fill(tint).frame(width: 4, height: 4)
                                .opacity(
                                    reduceMotion ? 0.7 : 0.4 + 0.6 * (sin(phase * 3 - Double(index) * 0.8) + 1) / 2
                                )
                                .offset(y: reduceMotion ? 0 : -2 * sin(phase * 3 - Double(index) * 0.8))
                        }
                    }.frame(width: 24, height: 16)
                }.accessibilityHidden(true)
                Text(turn.phase.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .id(turn.phase).transition(.opacity)
                if let query = turn.searchQuery {
                    Text(query).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            if !turn.sources.isEmpty {
                ViewThatFits(in: .horizontal) {
                    sourceRow(Array(turn.sources.prefix(4)))
                    sourceRow(Array(turn.sources.prefix(2)))
                    sourceRow(Array(turn.sources.prefix(1)))
                }
            }
        }.padding(.vertical, 8)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: turn.phase)
            .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: turn.sources.map(\.id))
            .accessibilityElement(children: .combine).accessibilityLabel(turn.phase.title)
    }
    private func sourceRow(_ sources: [LiveSearchSource]) -> some View {
        HStack(spacing: 6) {
            ForEach(sources) { source in
                Link(destination: source.url) {
                    HStack(spacing: 5) {
                        GolzheimIcon(icon: .globe, size: 10)
                        Text(source.url.host ?? source.title).font(.system(size: 10)).lineLimit(1)
                    }
                    .foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 5)
                    .background(tint.opacity(0.08), in: Capsule())
                }.buttonStyle(.plain).transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 5)))
            }
        }
    }
}
