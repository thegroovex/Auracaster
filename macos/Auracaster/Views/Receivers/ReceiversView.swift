import SwiftUI

/// Receivers of our broadcast (placeholder until Broadcast Assistant support)
/// and other Auracast broadcasts nearby (real scan via the helper).
struct ReceiversView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(model.receivers) { receiver in
                    HStack(spacing: 12) {
                        Image(systemName: receiver.kind.symbol)
                            .font(.title3)
                            .foregroundStyle(.green)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(receiver.name)
                            Text(receiver.state.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let battery = receiver.batteryPercent {
                            Label("\(battery) %", systemImage: "battery.75percent")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            } header: {
                Text("Empfänger")
            } footer: {
                Text("Platzhalter: Broadcast-Empfänger sind passiv und für den Sender unsichtbar. Echte Einträge kommen mit der Broadcast-Assistant-Rolle (BASS).")
                    .foregroundStyle(.secondary)
            }

            Section {
                if model.nearbyBroadcasts.isEmpty {
                    Text(model.isScanning ? "Suche läuft …" : "Noch keine Suche durchgeführt.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.nearbyBroadcasts) { broadcast in
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.purple)
                        VStack(alignment: .leading) {
                            Text(broadcast.name ?? "Ohne Namen")
                            Text(String(format: "ID %06X · %@", broadcast.broadcastID, broadcast.address))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let rssi = broadcast.rssi {
                            Text("\(rssi) dBm")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Auracast in der Nähe")
                    Spacer()
                    if model.isScanning { ProgressView().controlSize(.small) }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Suchen", systemImage: "antenna.radiowaves.left.and.right") {
                    model.scanNearby()
                }
                .disabled(model.isScanning)
            }
        }
    }
}

#Preview {
    ReceiversView()
        .environment(AppModel.preview())
}
