import Foundation

/// Node in the routing matrix (a source on the left or a stream on the right).
struct RoutingNode: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var symbol: String
}

/// Cable from a source node to a stream node.
struct RoutingConnection: Identifiable, Hashable, Sendable {
    var sourceID: RoutingNode.ID
    var streamID: RoutingNode.ID
    var id: String { "\(sourceID)→\(streamID)" }
}

/// Sources → streams (BIGs / BIS subgroups). Today only stream 1 is
/// transmitted; additional streams are UI-only until multi-BIG support lands.
struct RoutingGraph: Sendable, Equatable {
    var sources: [RoutingNode]
    var streams: [RoutingNode]
    var connections: Set<RoutingConnection>

    static func makeDefault(sources: [AudioSourceItem], broadcastName: String) -> RoutingGraph {
        let sourceNodes = sources.prefix(6).map {
            RoutingNode(id: $0.id, title: $0.name, subtitle: $0.category.title, symbol: $0.symbol)
        }
        let streams = [
            RoutingNode(id: "stream.1", title: broadcastName, subtitle: "BIG 1 · BIS L+R", symbol: "dot.radiowaves.left.and.right"),
            RoutingNode(id: "stream.2", title: "Sprache EN", subtitle: "BIG 2 · geplant", symbol: "character.bubble"),
            RoutingNode(id: "stream.3", title: "Hörhilfe Mono", subtitle: "Subgroup · geplant", symbol: "ear"),
        ]
        var connections = Set<RoutingConnection>()
        if let first = sourceNodes.first {
            connections.insert(RoutingConnection(sourceID: first.id, streamID: "stream.1"))
        }
        return RoutingGraph(sources: Array(sourceNodes), streams: streams, connections: connections)
    }

    func isConnected(_ sourceID: RoutingNode.ID, _ streamID: RoutingNode.ID) -> Bool {
        connections.contains(RoutingConnection(sourceID: sourceID, streamID: streamID))
    }

    mutating func connect(_ sourceID: RoutingNode.ID, to streamID: RoutingNode.ID) {
        connections.insert(RoutingConnection(sourceID: sourceID, streamID: streamID))
    }

    mutating func disconnect(_ connection: RoutingConnection) {
        connections.remove(connection)
    }

    mutating func disconnectAll(stream streamID: RoutingNode.ID) {
        connections = connections.filter { $0.streamID != streamID }
    }

    /// Source feeding stream 1 (the one actually transmitted today).
    var primarySourceID: RoutingNode.ID? {
        connections.filter { $0.streamID == "stream.1" }.map(\.sourceID).sorted().first
    }
}
