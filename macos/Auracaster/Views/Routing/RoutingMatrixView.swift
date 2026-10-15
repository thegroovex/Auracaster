import SwiftUI

/// Node matrix: sources (left) → streams (right) with Bézier cables drawn in a
/// Canvas. Drag from a source (or its port) onto a stream to connect; use the
/// stream's context menu to disconnect.
struct RoutingMatrixView: View {
    @Environment(AppModel.self) private var model

    @State private var dragSourceID: RoutingNode.ID?
    @State private var dragLocation: CGPoint?
    @State private var targetStreamID: RoutingNode.ID?

    private let nodeWidth: CGFloat = 230
    private let nodeHeight: CGFloat = 58
    private let rowSpacing: CGFloat = 14
    private let topInset: CGFloat = 12
    private let snapDistance: CGFloat = 44
    private static let space = "routingMatrix"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Routing")
                    .font(.largeTitle.weight(.bold))
                Text("Quelle auf einen Stream ziehen, um sie zu verbinden. Stream 1 wird gesendet; weitere Streams (mehrere BIGs / Subgroups) folgen.")
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                matrix(size: proxy.size)
            }
            .frame(minHeight: CGFloat(rows) * (nodeHeight + rowSpacing) + topInset * 2)
        }
        .padding(28)
    }

    private var rows: Int { max(model.routing.sources.count, model.routing.streams.count, 1) }

    // MARK: Layout

    private func sourceCenter(_ index: Int) -> CGPoint {
        CGPoint(x: nodeWidth / 2, y: topInset + CGFloat(index) * (nodeHeight + rowSpacing) + nodeHeight / 2)
    }

    private func streamCenter(_ index: Int, width: CGFloat) -> CGPoint {
        CGPoint(x: width - nodeWidth / 2, y: topInset + CGFloat(index) * (nodeHeight + rowSpacing) + nodeHeight / 2)
    }

    private func outPort(_ index: Int) -> CGPoint {
        let center = sourceCenter(index)
        return CGPoint(x: center.x + nodeWidth / 2, y: center.y)
    }

    private func inPort(_ index: Int, width: CGFloat) -> CGPoint {
        let center = streamCenter(index, width: width)
        return CGPoint(x: center.x - nodeWidth / 2, y: center.y)
    }

    // MARK: Matrix

    @ViewBuilder
    private func matrix(size: CGSize) -> some View {
        let routing = model.routing
        let sourceIndex = Dictionary(uniqueKeysWithValues: routing.sources.enumerated().map { ($1.id, $0) })
        let streamIndex = Dictionary(uniqueKeysWithValues: routing.streams.enumerated().map { ($1.id, $0) })

        // Pre-computed geometry so the Canvas closure only captures values.
        let cables: [Cable] = routing.connections.compactMap { connection in
            guard let s = sourceIndex[connection.sourceID], let t = streamIndex[connection.streamID] else { return nil }
            return Cable(from: outPort(s), to: inPort(t, width: size.width),
                         isLive: model.isLive && connection.streamID == "stream.1")
        }
        let pending: Cable? = {
            guard let dragSourceID, let dragLocation, let s = sourceIndex[dragSourceID] else { return nil }
            return Cable(from: outPort(s), to: dragLocation, isLive: false)
        }()

        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for cable in cables {
                    Self.draw(cable, in: &context, dashed: false)
                }
                if let pending {
                    Self.draw(pending, in: &context, dashed: true)
                }
            }

            GlassEffectContainer(spacing: 20) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(routing.sources.enumerated()), id: \.element.id) { index, node in
                        NodeView(node: node, tint: .blue, isHighlighted: dragSourceID == node.id,
                                 portEdge: .trailing)
                            .frame(width: nodeWidth, height: nodeHeight)
                            .position(sourceCenter(index))
                            .gesture(connectGesture(from: node.id, size: size, streamIndex: streamIndex))
                    }

                    ForEach(Array(routing.streams.enumerated()), id: \.element.id) { index, node in
                        NodeView(node: node, tint: .purple, isHighlighted: targetStreamID == node.id,
                                 portEdge: .leading)
                            .frame(width: nodeWidth, height: nodeHeight)
                            .position(streamCenter(index, width: size.width))
                            .contextMenu { streamMenu(for: node) }
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
    }

    // MARK: Interaction

    private func connectGesture(
        from sourceID: RoutingNode.ID,
        size: CGSize,
        streamIndex: [RoutingNode.ID: Int]
    ) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                dragSourceID = sourceID
                dragLocation = value.location
                targetStreamID = nearestStream(to: value.location, width: size.width, streamIndex: streamIndex)
            }
            .onEnded { value in
                if let streamID = nearestStream(to: value.location, width: size.width, streamIndex: streamIndex) {
                    withAnimation(.snappy) {
                        model.connect(source: sourceID, to: streamID)
                    }
                }
                dragSourceID = nil
                dragLocation = nil
                targetStreamID = nil
            }
    }

    private func nearestStream(to point: CGPoint, width: CGFloat, streamIndex: [RoutingNode.ID: Int]) -> RoutingNode.ID? {
        var best: (id: RoutingNode.ID, distance: CGFloat)?
        for (id, index) in streamIndex {
            let center = streamCenter(index, width: width)
            let frame = CGRect(x: center.x - nodeWidth / 2, y: center.y - nodeHeight / 2,
                               width: nodeWidth, height: nodeHeight)
                .insetBy(dx: -snapDistance, dy: -rowSpacing / 2)
            guard frame.contains(point) else { continue }
            let port = inPort(index, width: width)
            let distance = hypot(port.x - point.x, port.y - point.y)
            if best == nil || distance < best!.distance { best = (id, distance) }
        }
        return best?.id
    }

    @ViewBuilder
    private func streamMenu(for stream: RoutingNode) -> some View {
        let connected = model.routing.connections.filter { $0.streamID == stream.id }
        if connected.isEmpty {
            Text("Keine Quelle verbunden")
        } else {
            ForEach(Array(connected).sorted { $0.sourceID < $1.sourceID }) { connection in
                let name = model.routing.sources.first { $0.id == connection.sourceID }?.title ?? connection.sourceID
                Button("Trennen: \(name)") {
                    withAnimation(.snappy) { model.disconnect(connection) }
                }
            }
        }
    }

    // MARK: Drawing

    private struct Cable: Sendable {
        var from: CGPoint
        var to: CGPoint
        var isLive: Bool
    }

    nonisolated private static func draw(_ cable: Cable, in context: inout GraphicsContext, dashed: Bool) {
        let dx = max(60, abs(cable.to.x - cable.from.x) * 0.45)
        var path = Path()
        path.move(to: cable.from)
        path.addCurve(
            to: cable.to,
            control1: CGPoint(x: cable.from.x + dx, y: cable.from.y),
            control2: CGPoint(x: cable.to.x - dx, y: cable.to.y)
        )
        let gradient = Gradient(colors: [.blue, .purple])
        let shading = GraphicsContext.Shading.linearGradient(gradient, startPoint: cable.from, endPoint: cable.to)

        if !dashed {
            // Wide, translucent underlay as a soft halo (plain drawing, no blur).
            var halo = context
            halo.opacity = 0.25
            halo.stroke(path, with: shading,
                           style: StrokeStyle(lineWidth: cable.isLive ? 10 : 7, lineCap: .round))
        }
        var core = context
        core.opacity = dashed ? 0.7 : 1
        core.stroke(path, with: dashed ? .color(.secondary) : shading,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: dashed ? [6, 5] : []))
        // Port dots.
        for point in [cable.from, cable.to] {
            let dot = Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
            core.fill(dot, with: .color(.white))
        }
    }
}

/// One node card in the matrix.
private struct NodeView: View {
    var node: RoutingNode
    var tint: Color
    var isHighlighted: Bool
    var portEdge: HorizontalEdge

    var body: some View {
        HStack(spacing: 10) {
            if portEdge == .leading { port }
            Image(systemName: node.symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(node.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if portEdge == .trailing { port }
        }
        .padding(.horizontal, 12)
        .glassEffect(isHighlighted ? .regular.tint(tint.opacity(0.35)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 16))
        .contentShape(.rect(cornerRadius: 16))
    }

    private var port: some View {
        Circle()
            .strokeBorder(tint, lineWidth: 2)
            .background(Circle().fill(.background))
            .frame(width: 12, height: 12)
    }
}

#Preview {
    RoutingMatrixView()
        .environment(AppModel.preview())
        .frame(width: 900, height: 520)
}
