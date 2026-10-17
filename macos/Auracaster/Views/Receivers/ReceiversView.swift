import SwiftUI

/// Receivers of our broadcast and other Auracast broadcasts nearby (real scan
/// via the helper). Receivers join on their own (phone, QR code); managing
/// them from the Mac (Broadcast Assistant) follows in a later version.
struct ReceiversView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                if model.receivers.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("So hören Kopfhörer und Hörgeräte mit", systemImage: "earbuds")
                            .font(.headline)
                        Text("Auracast-Empfänger verbinden sich selbst und bleiben für den Sender unsichtbar. Am Smartphone unter *Auracast* (Samsung: *Auracast-Übertragungen*) den Sender **„\(model.broadcastName)“** wählen – oder im Studio den QR-Code scannen.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Kopfhörer direkt vom Mac aus verbinden (Broadcast-Assistent) folgt in einer späteren Version.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                }
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
                if model.isSimulated && !model.receivers.isEmpty {
                    Text("Simulation – Beispieldaten.")
                        .foregroundStyle(.secondary)
                }
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
