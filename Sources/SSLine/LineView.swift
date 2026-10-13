import SwiftUI

enum Layout {
    static let panelHeight: CGFloat = 210
    static let ropeTop: CGFloat = 10
    static let spacing: CGFloat = 174
    static let cardWidth: CGFloat = 150
    static let pinAbove: CGFloat = 9.5
}

struct LineView: View {
    @ObservedObject var line: Line

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                Rope(width: width)

                if line.items.isEmpty {
                    Hint()
                        .position(x: width / 2, y: Layout.ropeTop + 34)
                        .transition(.opacity)
                }

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: Layout.spacing - Layout.cardWidth) {
                            ForEach(line.items) { item in
                                PeggedView(item: item, line: line)
                                    .frame(width: Layout.cardWidth, height: Layout.panelHeight - Layout.ropeTop,
                                           alignment: .top)
                            }
                        }
                        .padding(.horizontal, 50)
                        // Scrolling to the start of the strip rather than to the
                        // newest card keeps the padding before it on screen.
                        .id(Self.stripID)
                        .padding(.top, Layout.ropeTop - Layout.pinAbove)
                        .frame(minWidth: width, minHeight: Layout.panelHeight, alignment: .top)
                    }
                    .scrollClipDisabled()
                    .onChange(of: line.items.first?.id, initial: true) { _, newest in
                        guard newest != nil else { return }
                        // Inside onChange the strip still has its old layout;
                        // scroll once it has the new card.
                        DispatchQueue.main.async { proxy.scrollTo(Self.stripID, anchor: .leading) }
                    }
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: line.items.map(\.id))
            .animation(.easeInOut(duration: 0.3), value: line.items.isEmpty)
            // Tucked away, the whole line waits above the top edge and slides
            // out from under the menu bar, the way an auto-hiding Dock does.
            .offset(y: line.revealed ? 0 : -(Layout.panelHeight + 12))
            .animation(line.revealed ? .spring(response: 0.28, dampingFraction: 0.86)
                                     : .easeIn(duration: 0.22), value: line.revealed)
            .onPreferenceChange(HitRectsKey.self) { rects in
                let viewport = CGRect(origin: .zero, size: geo.size)
                line.hitRects = rects.filter { $0.value.intersects(viewport) }
            }
        }
    }

    private static let stripID = "strip"
}

private struct Hint: View {
    var body: some View {
        Text(L("Take a screenshot and it will hang here"))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}

/// A thin, neutral line: a mid gray core with a faint highlight and a soft
/// shadow, so it reads on light and dark backgrounds alike. It fades out at
/// both ends so it seems to come from beyond the screen.
struct Rope: View {
    let width: CGFloat

    private var path: Path {
        Path { p in
            p.move(to: CGPoint(x: -20, y: Layout.ropeTop))
            p.addLine(to: CGPoint(x: width + 20, y: Layout.ropeTop))
        }
    }

    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: 0.55), lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .allowsHitTesting(false)
    }
}

struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
