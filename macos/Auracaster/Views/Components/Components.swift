import SwiftUI

// MARK: - On-Air button

/// Prominent Liquid Glass button; tinted red while live.
struct OnAirButton: View {
    @Environment(AppModel.self) private var model
    var controlSize: ControlSize = .large

    var body: some View {
        Button {
            model.toggleBroadcast()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.isLive ? "dot.radiowaves.left.and.right" : "play.fill")
                    .symbolEffect(.variableColor.iterative, isActive: model.isLive)
                Text(title)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.glassProminent)
        .tint(model.isLive ? .red : .accentColor)
        .controlSize(controlSize)
        .disabled(model.isTransitioning)
        .help(model.isLive ? "Broadcast beenden" : "Broadcast starten")
        .animation(.smooth, value: model.isLive)
    }

    private var title: String {
        switch model.engineStatus.state {
        case .live: "On Air"
        case .starting: "Startet …"
        case .stopping: "Stoppt …"
        default: "Senden"
        }
    }
}

// MARK: - Latency pill

struct LatencyPill: View {
    enum Style { case plain, glass }

    var milliseconds: Int
    var isLive: Bool
    var style: Style = .glass

    var body: some View {
        let content = HStack(spacing: 5) {
            Circle()
                .fill(isLive ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text("\(milliseconds) ms")
                .monospacedDigit()
                .fontWeight(.medium)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .help("Geschätzte Ende-zu-Ende-Latenz (LC3-Frame + Presentation Delay)")

        switch style {
        case .plain:
            content
        case .glass:
            content.glassEffect(.regular, in: .capsule)
        }
    }
}

// MARK: - Dongle status

struct DongleStatusView: View {
    var status: DongleStatus

    var body: some View {
        Label {
            Text(status.title)
        } icon: {
            Image(systemName: status.symbol)
                .foregroundStyle(color)
        }
        .labelStyle(.titleAndIcon)
        .help(status.detail)
    }

    private var color: Color {
        switch status {
        case .connected: .green
        case .detected: .green
        case .simulated: .orange
        case .error: .red
        case .notStarted: .secondary
        }
    }
}

// MARK: - Stereo level meter

/// Horizontal L/R meter (RMS bar + peak tick), green → yellow → red.
struct StereoLevelMeter: View {
    var levels: StereoLevels
    var barHeight: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            channel("L", index: 0)
            channel("R", index: 1)
        }
        .animation(.linear(duration: 0.05), value: levels)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pegel")
        .accessibilityValue(String(format: "L %.0f dB, R %.0f dB", levels.peak.first ?? -120, levels.peak.last ?? -120))
    }

    private func channel(_ label: String, index: Int) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(LinearGradient(
                            stops: [
                                .init(color: .green, location: 0),
                                .init(color: .green, location: 0.7),
                                .init(color: .yellow, location: 0.85),
                                .init(color: .red, location: 1),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: width * levels.normalizedRMS(index))
                        }
                    Rectangle()
                        .fill(Color.primary.opacity(0.8))
                        .frame(width: 2)
                        .offset(x: max(0, width * levels.normalizedPeak(index) - 2))
                        .opacity(levels.normalizedPeak(index) > 0 ? 1 : 0)
                }
            }
            .frame(height: barHeight)
        }
    }
}

// MARK: - Section card

/// Content card on system Liquid Glass (no custom blur).
struct GlassCard<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label {
                    Text(title)
                } icon: {
                    if let systemImage { Image(systemName: systemImage) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}
